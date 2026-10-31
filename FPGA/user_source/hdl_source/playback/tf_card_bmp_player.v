
module tf_card_bmp_player #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter integer VOICE_ENABLE     = 0,
    parameter integer SAVE_SUPPORT=0,EXPORT_GEOMETRY=0,
    parameter integer SCENE_OVERRIDE=0,
    parameter integer VOICE_LOOP_MODE  = 0,
    parameter integer VOICE_BMI_BIND   = 0,
    parameter integer VOICE_TWO_SCENES = 0,
    parameter integer VOICE_FIVE_SCENES = 0,
    parameter integer VOICE_DETAIL_MODE = 0,
    parameter integer VOICE_LAYERS = 2,
    parameter integer VOICE_LAYER_CYCLE = 0,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd5
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       media_start_enable,
    input                       key_auto,
    // Held command bundle: {reminder owns scene, actual medicine name[1:0]}.
    // Request cannot change again until completion ACK crosses back.
    input scene_request_async,input [2:0] scene_command_async,
    output reg scene_ack,output reg scene_owned,output scene_fault,
    output [3:0]                state_code,
    output reg                  display_valid,
    output [23:0]               debug_digits,
    output reg [11:0]           display_width,
    output reg [11:0]           display_height,
    output reg                  display_epoch,
    output reg [2:0]            display_file_index,
    output                      bmi_scene,
    output                      bmi_repeat_enable,
    output                      narration_scene,
    input                       test_mode,
    input                       detail_request,
    input                       voice_key_hold,
    output reg [1:0]            detail_mode,

    input                       fade_black,
    input                       fade_idle,
    output reg                  fade_request,
    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,

    output                      write_req,
    input                       write_req_ack,
    input                       write_ready,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,
    input voice_busy,
    input voice_sd_req,input [31:0] voice_sd_addr,
    output [7:0] voice_sd_data,output voice_sd_valid,output voice_sd_end,
    output voice_sd_error,output voice_sd_init_done,
    output reg voice_play_request,output reg voice_stop_request,
    input save_write_req,save_read_req,input [31:0] save_addr,input [7:0] save_data,
    output [7:0] save_read_data,output save_valid,save_read_end,save_write_end,save_data_req,save_error,
 output geometry_ready,output [31:0] geometry_fat,geometry_data,
 output [27:0] geometry_root,geometry_limit,output [6:0] geometry_mask,output [2:0] geometry_shift
);

wire key_next_press;
wire key_auto_press;

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire core_sec_read,core_sec_valid,core_sec_end,sd_soft_reset;
wire sd_init_done;wire core_sec_write,core_write_end,core_data_req;
assign save_read_data=sd_sec_read_data;
wire [31:0] core_sec_addr;
assign voice_sd_data=sd_sec_read_data;
assign voice_sd_init_done=sd_init_done;
generate if(VOICE_ENABLE) begin: g_voice_sd
    sd_sector_arbiter #(.SAVE_SUPPORT(SAVE_SUPPORT))u_arbiter(
        .clk(clk),.rst(rst),.bmp_req(sd_sec_read),.bmp_addr(sd_sec_read_addr),
        .bmp_valid(sd_sec_read_data_valid),.bmp_end(sd_sec_read_end),
        .voice_req(voice_sd_req),.voice_addr(voice_sd_addr),.voice_valid(voice_sd_valid),.voice_end(voice_sd_end),
        .voice_error(voice_sd_error),.soft_reset(sd_soft_reset),
        .core_req(core_sec_read),.core_addr(core_sec_addr),.core_valid(core_sec_valid),.core_end(core_sec_end),
        .save_write_req(save_write_req),.save_read_req(save_read_req),.save_addr(save_addr),
        .save_valid(save_valid),.save_read_end(save_read_end),.save_write_end(save_write_end),.save_data_req(save_data_req),.save_error(save_error),
        .core_write_req(core_sec_write),.core_write_end(core_write_end),.core_data_req(core_data_req)
    );
end else begin: g_image_only
    assign core_sec_read=sd_sec_read;assign core_sec_addr=sd_sec_read_addr;assign core_sec_write=0;
    assign save_valid=0;assign save_read_end=0;assign save_write_end=0;assign save_data_req=0;assign save_error=0;
    assign sd_sec_read_data_valid=core_sec_valid;assign sd_sec_read_end=core_sec_end;
    assign sd_soft_reset=0;assign voice_sd_valid=0;assign voice_sd_end=0;assign voice_sd_error=0;
end endgenerate
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             bmp_ready;
wire             bmp_load_error;
wire [11:0]      bmp_load_width, bmp_load_height;
(* syn_preserve=1 *) reg metadata_commit;
// Register the display-only metadata enable separately, so adding 25 metadata
// registers does not add that fanout to the original buffer-commit control.
// The validated reader dimensions stay stable far beyond this one SD cycle.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        display_width<=0; display_height<=0; display_epoch<=0;display_file_index<=0;
    end else if (metadata_commit) begin
        display_width<=bmp_load_width;
        display_height<=bmp_load_height;
        display_file_index<=load_sector[2:0];
        display_epoch<=~display_epoch;
    end
end
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
wire assessment_active=(VOICE_TWO_SCENES||VOICE_FIVE_SCENES)&&test_mode;
localparam integer AUTO_COUNT_BITS = CLK_FREQ_HZ<=1 ? 1 : $clog2(CLK_FREQ_HZ);
reg [AUTO_COUNT_BITS-1:0] auto_cnt;
reg [2:0]        img_found_count;
reg [2:0]        img_idx;              // 当前真正显示中的图片编号
reg [2:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg [31:0]       img_sector4;
reg              next_req_pending;
reg              load_busy;
(* async_reg="true",syn_preserve=1 *) reg [1:0] scene_request_sync;
reg [2:0] scene_settle;
reg scene_pending,scene_active,scene_error,scene_load;
reg [1:0] scene_name,scene_return_detail;
reg [2:0] scene_return_idx;
wire scene_begin=SCENE_OVERRIDE&&!scene_pending&&scene_request_sync[1]!=scene_ack&&scene_settle==7;
wire [31:0] scene_sector=scene_active?({30'd0,scene_name}+32'd1):sector_lut(scene_return_idx,{img_sector4,img_sector3,img_sector2,img_sector1,img_sector0});
wire scene_matches=display_valid&&display_file_index==scene_sector[2:0];
wire scene_end=SCENE_OVERRIDE&&scene_pending&&(scene_error||(switch_complete&&scene_matches));
wire scene_restore=scene_end&&!scene_active;
wire scene_voice_ready=!scene_owned||(scene_active&&!scene_pending&&!scene_error&&scene_matches);
assign scene_fault=SCENE_OVERRIDE&&scene_owned&&scene_active&&scene_error;
always @(posedge clk or posedge rst)begin
 if(rst)begin scene_request_sync<=0;scene_settle<=0;end
 else begin
  scene_request_sync<={scene_request_sync[0],scene_request_async};
  if(scene_pending||scene_request_sync[1]==scene_ack)scene_settle<=0;
  else if(scene_settle!=7)scene_settle<=scene_settle+1'b1;
 end
end

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
// Both status levels originate in the video domain.
(* syn_preserve = 1, async_reg = "true" *) reg [1:0] fade_black_sync;
(* syn_preserve = 1, async_reg = "true" *) reg [1:0] fade_idle_sync;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        fade_black_sync <= 2'b00;
        fade_idle_sync <= 2'b00;
    end else begin
        fade_black_sync <= {fade_black_sync[0], fade_black};
        fade_idle_sync <= {fade_idle_sync[0], fade_idle};
    end
end
reg              source_done_seen;
reg              source_busy_seen;
reg              write_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

// Presentation only; no feedback to the scheduler. Completion includes entry
// animation, rather than just source-read or SDRAM-write completion.
wire switch_complete = display_valid && scan_done && !load_busy &&
                       !next_req_pending && !fade_request && fade_idle_sync[1];
// Low four digits, left to right: 0=manual/1=auto, 0=busy/1=complete,
// catalog count, currently committed image (zero before the first commit).
assign debug_digits = {8'd0, 3'd0, (auto_play_en&&!assessment_active), 3'd0, switch_complete,
                       1'b0, img_found_count,
                       (display_valid ? ({1'b0, img_idx} + 4'd1) : 4'd0)};

wire auto_tick;
wire [2:0] next_from_current;

assign write_en   = bmp_data_wr_en;
assign write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};
reg voice_epoch_seen,voice_scene_pending;
reg bmi_started;
reg bmi_cancelled;
reg test_seen;
// A request is owned by the committed, fully entered image. Ignore it once
// a new load has started; it must never attach to the incoming image.
wire detail_accept=VOICE_DETAIL_MODE&&detail_request&&(VOICE_LAYER_CYCLE||(detail_mode<VOICE_LAYERS-1))&&
    narration_scene&&!assessment_active&&(!scene_owned&&!scene_begin)&&scan_done&&!load_busy&&!next_req_pending&&
    !fade_request&&fade_idle_sync[1]&&!key_next_press;
wire layer_key_hold=VOICE_DETAIL_MODE&&voice_key_hold;
assign bmi_scene=VOICE_BMI_BIND&&display_valid&&display_file_index==3'd5;
// All repeat decisions stay in the SD domain with the scheduler. A manual
// next request suppresses repetition until a new image epoch is committed.
assign narration_scene=VOICE_BMI_BIND&&display_valid&&(VOICE_FIVE_SCENES ? (display_file_index>=3'd1&&display_file_index<=3'd5) : (display_file_index==3'd5||(VOICE_TWO_SCENES&&display_file_index==3'd1)));
assign bmi_repeat_enable=narration_scene&&!assessment_active&&scene_voice_ready&&(!auto_play_en||scene_owned)&&!bmi_cancelled;
always @(posedge clk or posedge rst) begin
    if(rst) begin voice_epoch_seen<=0;voice_scene_pending<=0;voice_play_request<=0;voice_stop_request<=0;bmi_started<=0;bmi_cancelled<=0;test_seen<=0;detail_mode<=0;end
    else begin
        voice_play_request<=0;voice_stop_request<=0;test_seen<=assessment_active;
        if(VOICE_ENABLE&&VOICE_BMI_BIND) begin
            if(display_epoch!=voice_epoch_seen) begin
                voice_epoch_seen<=display_epoch;voice_scene_pending<=narration_scene&&!assessment_active;bmi_started<=0;bmi_cancelled<=0;detail_mode<=0;
            end
            if(voice_scene_pending&&scene_voice_ready&&!scene_begin&&!assessment_active&&display_valid&&scan_done&&!load_busy&&!fade_request&&fade_idle_sync[1]&&!key_next_press) begin
                voice_scene_pending<=0;voice_play_request<=1;bmi_started<=1;
            end
            // If auto is disabled just after the tail/flush, stay on PIC05
            // and restart. While busy, the EOF repeat permission is sufficient.
            if(key_auto_press&&!scene_owned&&!scene_begin&&!assessment_active&&auto_play_en&&narration_scene&&bmi_started&&!voice_busy&&
               !voice_scene_pending&&!voice_play_request&&!bmi_cancelled&&
               !next_req_pending&&!load_busy&&!fade_request&&fade_idle_sync[1])
                voice_play_request<=1;
            // A global override never restarts on image epochs or KEY2.
            // Exiting it schedules the current image narration after entry.
            if(assessment_active) begin voice_scene_pending<=0;voice_play_request<=0;bmi_started<=0;bmi_cancelled<=0;end
            else if(test_seen) begin voice_scene_pending<=narration_scene;bmi_started<=0;bmi_cancelled<=0;end
            if(detail_accept) begin
                // A fresh long press wraps the final layer to the intro. The old
                // stream is stopped and the next play uses the same flush/ACK.
                if(VOICE_LAYER_CYCLE&&detail_mode==VOICE_LAYERS-1) detail_mode<=0;
                else detail_mode<=detail_mode+2'd1;
                voice_scene_pending<=1;bmi_started<=0;bmi_cancelled<=0;
                voice_stop_request<=1;voice_play_request<=0;
            end
            if(key_next_press&&!scene_owned&&!scene_begin&&narration_scene&&!assessment_active) begin voice_stop_request<=1;voice_play_request<=0;voice_scene_pending<=0;bmi_cancelled<=1;end
            // A takeover stops the old PCM stream through its original flush/
            // settle/ACK path. Playback waits for the requested committed scene.
            if(scene_begin)begin
                voice_stop_request<=1;voice_play_request<=0;
                voice_scene_pending<=scene_command_async[2];bmi_started<=0;bmi_cancelled<=0;
                if(scene_command_async[2])detail_mode<=0;
            end
            if(scene_restore)begin
                voice_stop_request<=1;voice_play_request<=0;voice_scene_pending<=narration_scene;
                detail_mode<=scene_error?2'd0:scene_return_detail;bmi_started<=0;bmi_cancelled<=0;
            end
        end else if(VOICE_ENABLE&&!VOICE_LOOP_MODE) begin
            if(display_epoch!=voice_epoch_seen) begin voice_epoch_seen<=display_epoch;voice_scene_pending<=1;end
            if(voice_scene_pending&&display_valid&&scan_done&&!load_busy&&!fade_request&&fade_idle_sync[1]) begin
                voice_scene_pending<=0;voice_play_request<=1;
            end
            if(key_next_press&&display_valid) voice_stop_request<=1;
        end
    end
end
wire voice_auto_hold=VOICE_BMI_BIND ? (narration_scene&&!assessment_active&&(!bmi_started||voice_busy||voice_scene_pending||voice_play_request||detail_accept||layer_key_hold)) :
    (VOICE_ENABLE&&!VOICE_LOOP_MODE&&(voice_busy||voice_scene_pending||voice_play_request));
wire bmi_auto_done=VOICE_BMI_BIND&&narration_scene&&!assessment_active&&bmi_started&&!voice_auto_hold;
wire auto_count_enable = (!scene_owned&&!scene_begin) && !voice_auto_hold && !layer_key_hold && !assessment_active && scan_done && auto_play_en && display_valid &&
    !load_busy && !fade_request && fade_idle_sync[1] && first_image_committed &&
    (img_found_count > 3'd1);
// The extra HUD changed placement enough to expose the original wide terminal
// compare -> scheduler/counter feedback at 100 MHz. Compare two halves one
// cycle before the terminal value, then combine the registered matches.
// A counting cycle still sees auto_tick iff auto_cnt == CLK_FREQ_HZ-1.
generate if (CLK_FREQ_HZ<=1) begin: g_auto_every_cycle
    assign auto_tick=1'b1;
end else begin: g_auto_terminal
    localparam integer LOW_BITS=(AUTO_COUNT_BITS+1)/2;
    localparam integer HIGH_BITS=AUTO_COUNT_BITS-LOW_BITS;
    localparam [AUTO_COUNT_BITS-1:0] LOOKAHEAD=CLK_FREQ_HZ-2;
    (* syn_preserve=1 *) reg low_match;
    if(HIGH_BITS>0) begin: g_two_halves
        (* syn_preserve=1 *) reg high_match;
        always @(posedge clk or posedge rst) begin
            if(rst) begin low_match<=0; high_match<=0; end
            else begin
                low_match<=auto_count_enable && auto_cnt[LOW_BITS-1:0]==LOOKAHEAD[LOW_BITS-1:0];
                high_match<=auto_count_enable && auto_cnt[AUTO_COUNT_BITS-1:LOW_BITS]==LOOKAHEAD[AUTO_COUNT_BITS-1:LOW_BITS];
            end
        end
        assign auto_tick=low_match && high_match;
    end else begin: g_one_bit
        always @(posedge clk or posedge rst) begin
            if(rst) low_match<=0;
            else low_match<=auto_count_enable && auto_cnt==LOOKAHEAD;
        end
        assign auto_tick=low_match;
    end
end endgenerate
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

function [2:0] next_index_limited;
    input [2:0] cur;
    input [2:0] count;
    begin
        if (count <= 3'd1 || cur + 3'd1 >= count) next_index_limited = 3'd0;
        else next_index_limited = cur + 3'd1;
    end
endfunction

function [31:0] sector_lut;
    input [2:0] idx;
    input [159:0] catalog;
    begin
        case (idx)
            3'd0: sector_lut = catalog[31:0];
            3'd1: sector_lut = catalog[63:32];
            3'd2: sector_lut = catalog[95:64];
            3'd3: sector_lut = catalog[127:96];
            3'd4: sector_lut = catalog[159:128];
            default: sector_lut = catalog[31:0];
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
            fade_request <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        source_done_seen      <= 1'b0;
        source_busy_seen <= 1'b0;
        write_done_seen <= 1'b0;
        display_valid         <= 1'b0;
        metadata_commit       <= 1'b0;
        scene_ack<=0;scene_owned<=0;scene_pending<=0;scene_active<=0;scene_error<=0;
        scene_name<=0;scene_return_idx<=0;scene_return_detail<=0;scene_load<=0;
    end else begin
        metadata_commit <= 1'b0;
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        if(scene_begin)begin
            scene_pending<=1;scene_active<=scene_command_async[2];
            scene_name<=scene_command_async[1:0];scene_error<=0;
            if(scene_command_async[2]&&!scene_owned)begin
                scene_owned<=1;scene_return_idx<=img_idx;scene_return_detail<=detail_mode;
            end
        end
        if(scene_end)begin
            scene_ack<=scene_request_sync[1];scene_pending<=0;
            if(!scene_active)begin scene_owned<=0;img_idx<=scene_return_idx;end
        end

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            fade_request <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            source_done_seen      <= 1'b0;
            source_busy_seen <= 1'b0;
            write_done_seen <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            // 扫描阶段缓存前 5 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    3'd4: img_sector4 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd5)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && !bmp_ready)
                source_busy_seen <= 1'b1;
            if (load_busy && source_busy_seen && bmp_ready)
                source_done_seen <= 1'b1;
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            if (load_busy && bmp_load_error) begin
                if(scene_pending&&scene_load)scene_error<=1;
                scene_load<=0;
                load_busy <= 1'b0;
                source_done_seen <= 1'b0;
                source_busy_seen <= 1'b0;
                write_done_seen <= 1'b0;
                fade_request <= 1'b0;
            end

            // Preload completes while the old frame stays visible. Keep both
            // completion events latched throughout exit animation; switch
            // buffers only once the video domain acknowledges a black frame.
            if (load_busy && !bmp_load_error && (source_done_seen || (source_busy_seen && bmp_ready)) &&
                (write_done_seen || write_finish_pulse)) begin
                if (!display_valid || (fade_request && fade_black_sync[1])) begin
                    load_busy             <= 1'b0;
                    source_done_seen      <= 1'b0;
                    source_busy_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    disp_buf_idx          <= pending_buf_idx;
                    scene_load<=0;
                    img_idx               <= load_idx;
                    display_valid         <= 1'b1;
                    // Bundled metadata is held until the next successful
                    // commit. Preload and failed reads cannot alter this HUD.
                    metadata_commit       <= 1'b1;
                    first_image_committed <= 1'b1;
                    fade_request          <= 1'b0;
                end else begin
                    fade_request <= 1'b1;
                end
            end

            // 上电后自动发起一次“扫描前 5 张 BMP”
            if (!scan_kicked && bmp_ready && media_start_enable) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
            fade_request <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                source_busy_seen <= 1'b0;
                write_done_seen <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && !scene_owned && !scene_begin && scan_done && (img_found_count > 3'd0))
                    next_req_pending <= 1'b1;

                // 自动播放开/关
                if (key_auto_press && !scene_owned && !scene_begin && !assessment_active && scan_done && (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                end

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (auto_count_enable) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // Drop queued manual requests when the reminder takes ownership.
                if(scene_owned||scene_begin)next_req_pending<=0;
                // Direct named-file read uses the same reader, inactive buffer,
                // source-busy/done, memory-finish and black/entry ACK sequence.
                if(scene_owned&&scene_pending&&!scene_error&&!scene_begin&&scan_done&&bmp_ready&&
                   !load_busy&&!metadata_commit&&!fade_request&&fade_idle_sync[1]&&!scene_matches)begin
                    load_idx<=scene_active?{1'b0,scene_name}:scene_return_idx;
                    load_sector<=scene_sector;
                    pending_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    write_buf_idx<=next_buf_lut(disp_buf_idx,display_valid);
                    load_start_pulse<=1;load_busy<=1;scene_load<=1;
                    source_done_seen<=0;source_busy_seen<=0;write_done_seen<=0;
                    next_req_pending<=0;auto_cnt<=0;
                end
                // 首图自动加载到 buffer0
                else if ((!scene_owned&&!scene_begin)&&scan_done && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= 2'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_busy_seen <= 1'b0;
                    write_done_seen <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // Preload the inactive buffer before starting the animation.
                else if ((!scene_owned&&!scene_begin) && scan_done && bmp_ready && display_valid && !load_busy &&
                         !fade_request && fade_idle_sync[1] &&
                         (next_req_pending || (auto_play_en && !assessment_active && !layer_key_hold && !detail_accept && !key_auto_press && (bmi_auto_done||auto_tick) && img_found_count > 3'd1))) begin
                    next_req_pending <= 1'b0;
                    load_idx <= next_from_current;
                    load_sector <= sector_lut(next_from_current,{img_sector4,img_sector3,img_sector2,img_sector1,img_sector0});
                    pending_buf_idx <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy <= 1'b1;
                    source_done_seen <= 1'b0;
                    source_busy_seen <= 1'b0;
                    write_done_seen <= 1'b0;
                    auto_cnt <= 32'd0;
                end
            end
        end
    end
end

bmp_fit_reader #(.EXPORT_GEOMETRY(EXPORT_GEOMETRY))bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),
 .geometry_ready(geometry_ready),.geometry_fat(geometry_fat),.geometry_data(geometry_data),
 .geometry_root(geometry_root),.geometry_limit(geometry_limit),.geometry_mask(geometry_mask),.geometry_shift(geometry_shift),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .load_width             (bmp_load_width),
    .load_height            (bmp_load_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .write_ready            (write_ready),
    .load_error             (bmp_load_error),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data)
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst|sd_soft_reset),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (core_sec_read),
    .sd_sec_read_addr       (core_sec_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (core_sec_valid),
    .sd_sec_read_end        (core_sec_end),
    .sd_sec_write           (core_sec_write),
    .sd_sec_write_addr      (core_sec_addr),
    .sd_sec_write_data      (save_data),
    .sd_sec_write_data_req  (core_data_req),
    .sd_sec_write_end       (core_write_end)
);

endmodule

