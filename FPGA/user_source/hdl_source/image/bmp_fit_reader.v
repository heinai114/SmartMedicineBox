// FAT-named, bounded 24-bit BI_RGB BMP loader and nearest-neighbour fitter.

// Reads through the unchanged official 512-byte SD block interface. A cached

// sector and a synchronous scaled-row RAM allow arbitrary RGB/sector boundaries.

// Every load emits exactly 640*480 BGR-decoded RGB words in bottom-up order,

// including letterbox pixels, for the existing WRITE_V_FLIP=1 memory writer.

module bmp_fit_reader #(parameter EXPORT_GEOMETRY=0) (

    input clk, input rst, output ready,

    input scan_start, input [31:0] scan_start_sector,

    input [31:0] scan_max_sector, input [2:0] scan_target_count,

    output reg scan_done, output reg scan_found_valid,

    output reg [31:0] scan_found_sector, output reg [2:0] scan_found_total,

    input load_start, input [31:0] load_sector, input sd_init_done,

    output [3:0] state_code,

    // Validated original dimensions; the scheduler captures these only at

    // successful frame commit, never while a scanned/preloaded image is shown.

    output [11:0] load_width, output [11:0] load_height,

    output reg write_req, input write_req_ack, input write_ready,

    output reg load_error,

    output sd_sec_read, output [31:0] sd_sec_read_addr,

    input [7:0] sd_sec_read_data, input sd_sec_read_data_valid,

    input sd_sec_read_end,

    output reg bmp_data_wr_en, output reg [23:0] bmp_data,
 output geometry_ready,output [31:0] geometry_fat,geometry_data,
 output [27:0] geometry_root,geometry_limit,output [6:0] geometry_mask,output [2:0] geometry_shift

);

localparam IDLE=0, HEADER_BEGIN=1, SECTOR_READ=2, HEADER_CHECK=3,

    STRIDE=4, SPAN=5, HEADER_RESULT=6, FIT_COMPARE=7, FIT_DIVIDE=8,

    FIT_INIT=9, INIT_ROWS=10, WRITE_WAIT=11, ACK_SETTLE=12,

    Y_PREP=13, Y_ADVANCE=14, ROW_CHECK=15, X_ADVANCE=16,

    PIXEL_ADDR=17, PIXEL_ADDR_ADD=18, BYTE_GET=19, BYTE_WAIT=20,

    BYTE_CAPTURE=21, ROW_STORE=22, OUTPUT_PREP=23,

    OUTPUT_WAIT=24, OUTPUT_EMIT=25, FINISH=26, BYTE_SECTOR=27,

    HEADER_ABS=28, HEADER_VALIDATE=29, FIT_BOUNDS=30, FILE_OPEN_WAIT=31;

reg file_sector_read, open_file;

reg [31:0] file_sector_addr;

wire [7:0] file_sector_data;

wire file_sector_valid,file_sector_end,file_opened,file_error;

wire [31:0] directory_file_bytes;

wire [3:0] file_error_code;

reg [4:0] state, read_return;

reg scan_mode, header_mode, header_good;

// This named-file catalog starts at1, advances only in HEADER_RESULT,
// and stops at5 (or earlier at scan_target_count). Therefore its complete
// reachable set is0..5; it is a file identifier, not a physical SD LBA.
// Keep the external32-bit token and all source/read/write handshakes intact.
reg [2:0] scan_sector;
reg [31:0] load_sector_latched;

fat32_bmp_source #(.EXPORT_GEOMETRY(EXPORT_GEOMETRY))u_fat_source (

    .clk(clk),.rst(rst),.sd_init_done(sd_init_done),.open_file(open_file),

    .file_index(scan_mode?scan_sector[2:0]:load_sector_latched[2:0]),

    .opened(file_opened),.file_error(file_error),.error_code(file_error_code),.file_bytes(directory_file_bytes),

    .sector_req(file_sector_read),.sector_index(file_sector_addr[14:0]),

    .sector_valid(file_sector_valid),.sector_end(file_sector_end),.sector_data(file_sector_data),

    .sd_req(sd_sec_read),.sd_addr(sd_sec_read_addr),.sd_data(sd_sec_read_data),

    .sd_valid(sd_sec_read_data_valid),.sd_end(sd_sec_read_end),
 .geometry_ready(geometry_ready),.geometry_fat(geometry_fat),.geometry_data(geometry_data),
 .geometry_root(geometry_root),.geometry_limit(geometry_limit),.geometry_mask(geometry_mask),.geometry_shift(geometry_shift)

);

reg [8:0] sector_write_index, sector_read_index;

reg [14:0] cached_sector;

reg cache_valid;

reg [7:0] sector_ram [0:511];

reg [7:0] sector_q;

reg [7:0] signature0, signature1;

reg [23:0] file_size, pixel_offset;

reg [6:0] dib_size;

reg [10:0] header_width;

reg [11:0] header_height,abs_header_height;

reg header_range_bad,height_upper_zero,height_upper_ones,height_negative;

reg planes_ok,bit_count_ok,compression_zero;

reg [15:0] file_sectors;

reg [17:0] next_file_sector;

wire [31:0] header_sector = scan_mode ? scan_sector : load_sector_latched;

wire basic_header_ok = signature0 == "B" && signature1 == "M" &&

    !header_range_bad && dib_size >= 7'd40 && dib_size <= 7'd124 && planes_ok &&

    header_width >= 11'd1 && header_width <= 11'd1920 &&

    (height_negative ? height_upper_ones : height_upper_zero) &&

    abs_header_height >= 12'd1 && abs_header_height <= 12'd1080 &&

    bit_count_ok && compression_zero &&

    {1'b0,pixel_offset} >= {18'd0,dib_size} + 25'd14 && pixel_offset < file_size &&

    {8'd0,file_size} <= directory_file_bytes;

reg [11:0] source_width, source_height, span_rows;

assign load_width = source_width;

assign load_height = source_height;

reg top_down;

reg [15:0] row_stride;

reg [24:0] span_end;

reg [9:0] fit_width, fit_height, left_margin, bottom_margin;

reg [9:0] right_edge, top_edge;

reg [9:0] last_scaled_x;

reg [20:0] divide_remaining;

reg [11:0] divide_denominator;

reg [9:0] divide_quotient;

reg divide_width;

wire [21:0] width_measure = source_width * 12'd480;

wire [21:0] height_measure = source_height * 12'd640;

reg [11:0] init_rows;

reg [23:0] source_row_offset, byte_address;

reg [13:0] pixel_row_offset;

reg [11:0] source_y, loaded_source_y, source_x;

reg [12:0] phase_x, phase_y;

wire [12:0] x_denominator = {2'b0, fit_width, 1'b0};

wire [12:0] y_denominator = {2'b0, fit_height, 1'b0};

reg [9:0] scaled_x, canvas_x, canvas_y;

reg line_valid, row_inside, pixel_inside;
// Y_ADVANCE always has a final non-advancing clock before ROW_CHECK.
// Capture the full row-cache predicate on that existing clock; no extra
// FSM/pixel/SDRAM handshake cycle is introduced. ROW_STORE publication
// settles through the existing output states before the next row lookup.
(* syn_preserve=1 *) reg row_cache_hit;
always @(posedge clk or posedge rst) begin
    if(rst) row_cache_hit<=0;
    else row_cache_hit<=line_valid && loaded_source_y==source_y;
end

reg [1:0] byte_channel;

reg [23:0] pixel_latch;

reg [23:0] line_ram [0:1023];

reg [9:0] line_read_index;

reg [23:0] line_q;

reg [3:0] settle_count, emit_gap;

reg [14:0] wanted_sector;

// The next cache lookup is known in BYTE_SECTOR, and a refill's new tag is

// known at its existing END handoff. No extra byte/read/handshake cycle.

reg cache_hit;

always @(posedge clk or posedge rst)begin

    if(rst)cache_hit<=0;

    else if(!sd_init_done||state==HEADER_BEGIN)cache_hit<=0;

    else if(state==BYTE_SECTOR)cache_hit<=cache_valid&&cached_sector==byte_address[23:9];

    else if(state==SECTOR_READ&&!file_error&&file_sector_end)cache_hit<=file_sector_addr[14:0]==wanted_sector;

end

// Header class is known on the existing file-open handoff, one full cycle

// before the first requested sector byte. Keep the last byte enabled when

// END accompanies VALID. Pixel-cache refills never enter this class.

(* syn_preserve=1 *) reg header_read_active;

always @(posedge clk or posedge rst)begin

    if(rst)header_read_active<=0;

    else if(!sd_init_done)header_read_active<=0;

    else if(state==FILE_OPEN_WAIT&&!open_file&&!file_error&&file_opened)header_read_active<=1;

    else if(state!=SECTOR_READ||file_error||file_sector_end)header_read_active<=0;

end

assign ready = state == IDLE;

assign state_code = load_error ? 4'hF : (state == IDLE ? 4'd1 :

    ((state <= HEADER_RESULT || state == HEADER_ABS || state == HEADER_VALIDATE) ? 4'd2 :

    ((state == WRITE_WAIT || state == ACK_SETTLE) ? 4'd3 : 4'd4)));



// No asynchronous reset on RAMs: keep synchronous-read block RAM inference.

always @(posedge clk) begin

    if (state == SECTOR_READ && file_sector_valid)

        sector_ram[sector_write_index] <= file_sector_data;

    sector_q <= sector_ram[sector_read_index];

    if (state == ROW_STORE) line_ram[scaled_x] <= pixel_latch;

    line_q <= line_ram[line_read_index];

end



always @(posedge clk or posedge rst) begin

    if (rst) begin

        signature0 <= 0; signature1 <= 0; file_size <= 0;

        pixel_offset <= 0; dib_size <= 0; header_width <= 0;

        header_height <= 0; header_range_bad <= 0; height_negative <= 0;

        height_upper_zero <= 1; height_upper_ones <= 1; planes_ok <= 0; bit_count_ok <= 0; compression_zero <= 0;

    end else if (state == HEADER_BEGIN) begin

        signature0 <= 0; signature1 <= 0; file_size <= 0;

        pixel_offset <= 0; dib_size <= 0; header_width <= 0;

        header_height <= 0; header_range_bad <= 0; height_negative <= 0;

        height_upper_zero <= 1; height_upper_ones <= 1; planes_ok <= 0; bit_count_ok <= 0; compression_zero <= 0;

    end else if (header_read_active && file_sector_valid) begin

        case (sector_write_index)

            0: signature0 <= file_sector_data;

            1: signature1 <= file_sector_data;

            2: file_size[7:0] <= file_sector_data;

            3: file_size[15:8] <= file_sector_data;

            4: file_size[23:16] <= file_sector_data;

            5: if(file_sector_data!=0) header_range_bad <= 1;

            10: pixel_offset[7:0] <= file_sector_data;

            11: pixel_offset[15:8] <= file_sector_data;

            12: pixel_offset[23:16] <= file_sector_data;

            13: if(file_sector_data!=0) header_range_bad <= 1;

            14: begin dib_size <= file_sector_data[6:0]; if(file_sector_data[7]) header_range_bad <= 1; end

            15: if(file_sector_data!=0) header_range_bad <= 1;

            16: if(file_sector_data!=0) header_range_bad <= 1;

            17: if(file_sector_data!=0) header_range_bad <= 1;

            18: header_width[7:0] <= file_sector_data;

            19: begin header_width[10:8] <= file_sector_data[2:0]; if(file_sector_data[7:3]!=0) header_range_bad <= 1; end

            20: if(file_sector_data!=0) header_range_bad <= 1;

            21: if(file_sector_data!=0) header_range_bad <= 1;

            22: header_height[7:0] <= file_sector_data;

            23: begin header_height[11:8] <= file_sector_data[3:0];

                height_upper_zero <= file_sector_data[7:4]==0;

                height_upper_ones <= file_sector_data[7:4]==15; end

            24: begin height_upper_zero <= height_upper_zero && file_sector_data==0;

                height_upper_ones <= height_upper_ones && file_sector_data==255; end

            25: begin height_upper_zero <= height_upper_zero && file_sector_data==0;

                height_upper_ones <= height_upper_ones && file_sector_data==255;

                height_negative <= file_sector_data[7]; end

            26: planes_ok <= file_sector_data==1;

            27: planes_ok <= planes_ok && file_sector_data==0;

            28: bit_count_ok <= file_sector_data==24;

            29: bit_count_ok <= bit_count_ok && file_sector_data==0;

            30: compression_zero <= file_sector_data==0;

            31: compression_zero <= compression_zero && file_sector_data==0;

            32: compression_zero <= compression_zero && file_sector_data==0;

            33: compression_zero <= compression_zero && file_sector_data==0;

        endcase

    end

end



always @(posedge clk or posedge rst) begin

    if (rst) begin

        state <= IDLE; read_return <= HEADER_ABS;

        scan_mode <= 0; header_mode <= 0; header_good <= 0;

        scan_sector <= 0; load_sector_latched <= 0;

        scan_done <= 0; scan_found_valid <= 0;

        scan_found_sector <= 0; scan_found_total <= 0;

        file_sector_read <= 0; file_sector_addr <= 0; open_file <= 0;

        sector_write_index <= 0; sector_read_index <= 0;

        cache_valid <= 0; cached_sector <= 0; wanted_sector <= 0;

        write_req <= 0; load_error <= 0; bmp_data_wr_en <= 0; bmp_data <= 0;

        source_width <= 0; source_height <= 0; top_down <= 0;

        span_rows <= 0; row_stride <= 0; span_end <= 0;

        file_sectors <= 0; next_file_sector <= 0;

        abs_header_height <= 0;

        fit_width <= 0; fit_height <= 0; left_margin <= 0; bottom_margin <= 0;

        right_edge <= 0; top_edge <= 0;

        last_scaled_x <= 0;

        divide_remaining <= 0; divide_denominator <= 1;

        divide_quotient <= 0; divide_width <= 0;

        init_rows <= 0; source_row_offset <= 0;

        byte_address <= 0; pixel_row_offset <= 0;

        source_y <= 0; source_x <= 0; loaded_source_y <= 0;

        phase_x <= 0; phase_y <= 0; scaled_x <= 0;

        canvas_x <= 0; canvas_y <= 0;

        line_valid <= 0; row_inside <= 0; pixel_inside <= 0;

        byte_channel <= 0; pixel_latch <= 0; line_read_index <= 0;

        settle_count <= 0; emit_gap <= 0;

    end else begin

        file_sector_read <= 0; bmp_data_wr_en <= 0;

        scan_found_valid <= 0; load_error <= 0; open_file <= 0;

        if (emit_gap != 0) emit_gap <= emit_gap - 1'b1;

        if (!sd_init_done) begin

            state <= IDLE; write_req <= 0; cache_valid <= 0; scan_done <= 0;

        end else case (state)

            IDLE: begin

                write_req <= 0;

                if (scan_start) begin

                    scan_mode <= 1; scan_sector <= 3'd1;

                    scan_found_total <= 0; scan_done <= 0; state <= HEADER_BEGIN;

                end else if (load_start) begin

                    scan_mode <= 0; load_sector_latched <= load_sector;

                    state <= HEADER_BEGIN;

                end

            end

            HEADER_BEGIN: begin

                open_file <= 1; file_sector_read <= 0;

                sector_write_index <= 0; header_mode <= 1; cache_valid <= 0;

                header_good <= 0; state <= FILE_OPEN_WAIT;

            end

            FILE_OPEN_WAIT: begin

                // Ignore the previous mount's status during the open pulse.

                if(!open_file && file_error) state <= HEADER_RESULT;

                else if(!open_file && file_opened) begin

                    file_sector_addr <= 0; read_return <= HEADER_ABS; state <= SECTOR_READ;

                end

            end

            SECTOR_READ: begin

                file_sector_read <= 1;

                if (file_sector_valid) sector_write_index <= sector_write_index + 1'b1;

                if(file_error) begin

                    file_sector_read<=0;cache_valid<=0;header_good<=0;

                    if(scan_mode) state<=HEADER_RESULT;

                    else begin load_error<=1;write_req<=0;state<=IDLE;end

                end else if (file_sector_end) begin

                    file_sector_read <= 0; cache_valid <= 1;

                    cached_sector <= file_sector_addr[14:0]; state <= read_return;

                end

            end

            HEADER_ABS: begin

                // Separate signed-height normalization from header checks

                // and register enables after integrating the larger HUD.

                abs_header_height <= height_negative ? (~header_height + 12'd1) : header_height;

                state <= HEADER_VALIDATE;

            end

            HEADER_VALIDATE: begin

                header_good <= basic_header_ok;

                // Header validation bounds file size to 24 bits. Register the

                // rounded sector count before address addition and comparison.

                file_sectors <= ({1'b0,file_size} + 25'd511) >> 9;

                state <= HEADER_CHECK;

            end

            HEADER_CHECK: begin

                if (header_good) begin

                    source_width <= {1'b0,header_width};

                    source_height <= abs_header_height[11:0];

                    top_down <= height_negative; state <= STRIDE;

                end else state <= HEADER_RESULT;

            end

            STRIDE: begin

                row_stride <= (source_width * 16'd3 + 16'd3) & 16'hFFFC;

                next_file_sector <= {1'b0, header_sector[16:0]} + {2'b0, file_sectors};

                span_end <= pixel_offset; span_rows <= source_height; state <= SPAN;

            end

            SPAN: begin

                if (span_rows != 0) begin

                    span_rows <= span_rows - 1'b1; span_end <= span_end + row_stride;

                end else begin

                    if (span_end > file_size)

                        header_good <= 0;

                    state <= HEADER_RESULT;

                end

            end

            HEADER_RESULT: begin

                if (scan_mode) begin

                    if(header_good) begin

                        scan_found_valid<=1;scan_found_sector<=scan_sector;

                        scan_found_total<=scan_found_total+1'b1;

                    end

                    if(scan_sector==5 || (header_good && scan_found_total+3'd1>=scan_target_count)) begin

                        scan_done<=1;state<=IDLE;

                    end else begin scan_sector<=scan_sector+1'b1;state<=HEADER_BEGIN;end

                end else if(header_good) state<=FIT_COMPARE;

                else begin load_error<=1;state<=IDLE;end

            end

            FIT_COMPARE: begin

                divide_quotient <= 0;

                if (width_measure >= height_measure) begin

                    fit_width <= 10'd640; divide_width <= 0;

                    divide_remaining <= height_measure[20:0]; divide_denominator <= source_width;

                end else begin

                    fit_height <= 10'd480; divide_width <= 1;

                    divide_remaining <= width_measure[20:0]; divide_denominator <= source_height;

                end

                state <= FIT_DIVIDE;

            end

            FIT_DIVIDE: begin

                // At most 640 iterations; no large per-pixel divider.

                if (divide_remaining >= divide_denominator) begin

                    divide_remaining <= divide_remaining - divide_denominator;

                    divide_quotient <= divide_quotient + 1'b1;

                end else begin

                    if (divide_width) fit_width <= divide_quotient == 0 ? 10'd1 : divide_quotient;

                    else fit_height <= divide_quotient == 0 ? 10'd1 : divide_quotient;

                    state <= FIT_INIT;

                end

            end

            FIT_INIT: begin

                left_margin <= (10'd640 - fit_width) >> 1;

                bottom_margin <= (10'd480 - fit_height) >> 1;

                source_row_offset <= pixel_offset[23:0];

                init_rows <= top_down ? source_height - 1'b1 : 12'd0;

                phase_y <= {1'b0, source_height}; source_y <= 0;

                canvas_y <= 0; canvas_x <= 0; line_valid <= 0;

                emit_gap <= 0; state <= FIT_BOUNDS;

            end

            FIT_BOUNDS: begin

                // Register these once per image. Keeping an adder in each

                // range check became a 100 MHz critical path after adding HUD.

                // This only adds one setup clock before the write handshake.

                right_edge <= left_margin + fit_width;

                top_edge <= bottom_margin + fit_height;

                last_scaled_x <= fit_width - 10'd1;

                state <= INIT_ROWS;

            end

            INIT_ROWS: begin

                if (init_rows != 0) begin

                    source_row_offset <= source_row_offset + row_stride;

                    init_rows <= init_rows - 1'b1;

                end else begin write_req <= 1; state <= WRITE_WAIT; end

            end

            WRITE_WAIT: begin

                if (write_req_ack) begin

                    write_req <= 0; settle_count <= 4'd15; state <= ACK_SETTLE;

                end

            end

            ACK_SETTLE: begin

                // Wait for the memory request synchronizer and FIFO clear release.

                if (settle_count != 0) settle_count <= settle_count - 1'b1;

                else state <= Y_PREP;

            end

            Y_PREP: begin

                canvas_x <= 0;

                if (canvas_y >= bottom_margin && canvas_y < top_edge) begin

                    row_inside <= 1; state <= Y_ADVANCE;

                end else begin row_inside <= 0; state <= OUTPUT_PREP; end

            end

            Y_ADVANCE: begin

                if (phase_y >= y_denominator) begin

                    phase_y <= phase_y - y_denominator; source_y <= source_y + 1'b1;

                    if (top_down) source_row_offset <= source_row_offset - row_stride;

                    else source_row_offset <= source_row_offset + row_stride;

                end else state <= ROW_CHECK;

            end

            ROW_CHECK: begin

                if (row_cache_hit) state <= OUTPUT_PREP;

                else begin

                    line_valid <= 0; scaled_x <= 0; source_x <= 0;

                    phase_x <= {1'b0, source_width}; state <= X_ADVANCE;

                end

            end

            X_ADVANCE: begin

                if (phase_x >= x_denominator) begin

                    phase_x <= phase_x - x_denominator; source_x <= source_x + 1'b1;

                end else state <= PIXEL_ADDR;

            end

            PIXEL_ADDR: begin

                pixel_row_offset <= source_x * 14'd3; state <= PIXEL_ADDR_ADD;

            end

            PIXEL_ADDR_ADD: begin

                byte_address <= source_row_offset + pixel_row_offset;

                byte_channel <= 0; state <= BYTE_SECTOR;

            end

            BYTE_SECTOR: begin

                // Register the sector addition before cache-tag comparison.

                wanted_sector <= byte_address[23:9];

                state <= BYTE_GET;

            end

            BYTE_GET: begin

                if (cache_hit) begin

                    sector_read_index <= byte_address[8:0]; state <= BYTE_WAIT;

                end else begin

                    file_sector_addr <= {17'd0, wanted_sector};

                    sector_write_index <= 0; header_mode <= 0; cache_valid <= 0;

                    read_return <= BYTE_GET; state <= SECTOR_READ;

                end

            end

            BYTE_WAIT: state <= BYTE_CAPTURE;

            BYTE_CAPTURE: begin

                case (byte_channel)

                    0: pixel_latch[7:0] <= sector_q;

                    1: pixel_latch[15:8] <= sector_q;

                    2: pixel_latch[23:16] <= sector_q;

                endcase

                if (byte_channel == 2) state <= ROW_STORE;

                else begin

                    byte_channel <= byte_channel + 1'b1;

                    byte_address <= byte_address + 1'b1; state <= BYTE_SECTOR;

                end

            end

            ROW_STORE: begin

                if (scaled_x == last_scaled_x) begin

                    line_valid <= 1; loaded_source_y <= source_y; state <= OUTPUT_PREP;

                end else begin

                    scaled_x <= scaled_x + 1'b1;

                    phase_x <= phase_x + {source_width, 1'b0}; state <= X_ADVANCE;

                end

            end

            OUTPUT_PREP: begin

                pixel_inside <= row_inside && canvas_x >= left_margin && canvas_x < right_edge;

                if (row_inside && canvas_x >= left_margin && canvas_x < right_edge) begin

                    line_read_index <= canvas_x - left_margin; state <= OUTPUT_WAIT;

                end else state <= OUTPUT_EMIT;

            end

            OUTPUT_WAIT: state <= OUTPUT_EMIT;

            OUTPUT_EMIT: begin

                if (write_ready && emit_gap == 0) begin

                    bmp_data_wr_en <= 1; bmp_data <= pixel_inside ? line_q : 24'd0;

                    // Bound write rate as well as observing write-domain high water.

                    emit_gap <= 4'd15;

                    if (canvas_x == 10'd639) begin

                        if (canvas_y == 10'd479) state <= FINISH;

                        else begin

                            canvas_y <= canvas_y + 1'b1;

                            if (row_inside) phase_y <= phase_y + {source_height, 1'b0};

                            state <= Y_PREP;

                        end

                    end else begin canvas_x <= canvas_x + 1'b1; state <= OUTPUT_PREP; end

                end

            end

            FINISH: state <= IDLE;

            default: begin write_req <= 0; load_error <= 1; state <= IDLE; end

        endcase

    end

end

endmodule

