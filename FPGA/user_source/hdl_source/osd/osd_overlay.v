/* ============================================================================
 * osd_overlay.v  ——  M18  OSD 叠加引擎 (32x32 大字滚动字幕 + Alpha 混合)
 * ============================================================================
 * 插入位置 (top_tf_hdmi_audio.v):
 *
 *   video_delay ──> vout_data_raw ──> [osd_overlay] ──> vout_data ──> video_rgb_to_axis
 *
 * ----------------------------------------------------------------------------
 * 设计要点
 * ----------------------------------------------------------------------------
 * 1. 全程 video_clk 单时钟域; 只查表, 无 ready/valid 握手
 *    => 不给上游反压, 不可能压缩视频时序
 *
 * 2. ★ 核心结构: OSD 判定值和像素走**同一条延迟链** ★
 *      进来一个像素, 先组合地算出"要不要被 OSD 覆盖"(1 bit), 然后:
 *         bg_d  <= {bg_d[D-2:0],  pix_now};   // 24 bit 已混合好的像素
 *         de_d  <= {de_d[D-2:0],  I_de};
 *      在入链前完成像素选择，混合后的 RGB 与 DE 一起延迟。
 *
 * 3. 判定值计算 (2 级流水 + 组合取位):
 *        第1级 v1_x/v1_y
 *        第2级 v2_col/v2_row/v2_i/v2_ok/v2_strip  (都由同一个 v1_x 推出)
 *        组合  slot = osd_msg(v2_i); addr = {slot, v2_row}
 *        组合  pix_on = I_pattern_data[31 - col]
 *
 * 4. 字符格 32x32 像素 (和字库格式绑定, 不要改):
 *        i = px >> 5;  col = 31 - (px & 31);  row = y & 31
 *        字符索引和字内列必须来自同一个滚动坐标 px，否则移动时会拼接错字。
 *        addr = { slot[8:0], row[4:0] } = 14 bit  ->  ROM 8192 x 32 bit
 *
 * ----------------------------------------------------------------------------
 * ★ 字幕顺序 (第一次就是在这里搞反的) ★
 *   一行里最右边那格是 MSG[0], 往左依次 MSG[1]、MSG[2]……
 *   滚动时内容向左走, 所以 **MSG[0] 是最先从右边滚进来的字**。
 *   想让屏幕从左往右读成 "用药注意:请按时服药", 顶层要按"从右到左"填:
 *        MSG_0=药  MSG_1=服  MSG_2=时  MSG_3=按  MSG_4=请
 *        MSG_5=:   MSG_6=意  MSG_7=注  MSG_8=药  MSG_9=用
 * ============================================================================ */

module osd_overlay #(
    parameter ROM_LATENCY = 1,
    parameter OSD_DELAY   = 3,

    parameter X_ACTIVE    = 640,
    parameter Y_ACTIVE    = 480,

    // 字符格: 5 表示 32 像素 (和 32x32 字库绑定)
    parameter CELL_BITS   = 5,

    // 字幕条位置 (32 像素高)
    parameter Y_BASE      = 384,

    // 消息内容: 每个字符一个字库槽位, 见 osd_font_map.md
    // 顺序: MSG_0 在最右, 最先滚入
    parameter N           = 10,
    parameter [8:0] MSG_0  = 9'h08F, parameter [8:0] MSG_1  = 9'h08A,
    parameter [8:0] MSG_2  = 9'h088, parameter [8:0] MSG_3  = 9'h085,
    parameter [8:0] MSG_4  = 9'h090, parameter [8:0] MSG_5  = 9'h03A,
    parameter [8:0] MSG_6  = 9'h084, parameter [8:0] MSG_7  = 9'h08D,
    parameter [8:0] MSG_8  = 9'h08F, parameter [8:0] MSG_9  = 9'h08E,
    parameter [8:0] MSG_10 = 9'h000, parameter [8:0] MSG_11 = 9'h000,
    parameter [8:0] MSG_12 = 9'h000, parameter [8:0] MSG_13 = 9'h000,
    parameter [8:0] MSG_14 = 9'h000, parameter [8:0] MSG_15 = 9'h000,
    parameter [8:0] MSG_16 = 9'h000, parameter [8:0] MSG_17 = 9'h000,
    parameter [8:0] MSG_18 = 9'h000, parameter [8:0] MSG_19 = 9'h000,
    parameter [8:0] MSG_20 = 9'h000, parameter [8:0] MSG_21 = 9'h000,
    parameter [8:0] MSG_22 = 9'h000, parameter [8:0] MSG_23 = 9'h000,
    parameter [8:0] MSG_24 = 9'h000, parameter [8:0] MSG_25 = 9'h000,
    parameter [8:0] MSG_26 = 9'h000, parameter [8:0] MSG_27 = 9'h000,
    parameter [8:0] MSG_28 = 9'h000, parameter [8:0] MSG_29 = 9'h000,
    parameter [8:0] MSG_30 = 9'h000, parameter [8:0] MSG_31 = 9'h000,

    parameter [15:0] DIVIDER = 16'd1,
    parameter integer SCROLL_STEP = 4,      // 每次移动 4 像素，约 240 像素/秒
    parameter integer HOLD_FRAMES = 180,    // 水平居中停留约 3 秒

    parameter [23:0] FG_COLOR = 24'hFF_FF_FF,
    parameter [7:0]  ALPHA    = 8'hFF,

    parameter BLINK_EN      = 0,
    parameter [3:0] BLINK_BIT = 4'd6,

    parameter OFF_AW      = 14,
    parameter ADDR_WIDTH  = 13
)(
    input  wire                  I_clk,
    input  wire                  I_rst,

    input  wire                  I_de,
    input  wire [23:0]           I_data,
    input  wire                  I_vs,
    input  wire                  I_scroll_step,

    output reg                   O_de,
    output reg  [23:0]           O_data,

    output wire [ADDR_WIDTH-1:0] O_pattern_addr,
    input  wire [31:0]           I_pattern_data
);

    localparam integer CELL  = 1 << CELL_BITS;
    localparam integer Y_END = Y_BASE + CELL - 1;
    localparam integer N8    = 8 * N;

    localparam integer NEED    = N8 + X_ACTIVE + 1;
    localparam integer OFF_MOD = (NEED <=   4096) ?   4096 :
                                 (NEED <=   8192) ?   8192 :
                                 (NEED <=  16384) ?  16384 : 32768;
    localparam [OFF_AW-1:0] OFF_MASK = OFF_MOD[OFF_AW-1:0];

    // 字幕左边界 = OFF_MOD + N8 - scroll_off - N*CELL + 1。
    // 开始完全位于右边界外，居中时完整显示，结束完全离开左边界。
    localparam integer TEXT_WIDTH = N * CELL;
    localparam integer CENTER_LEFT = (X_ACTIVE - TEXT_WIDTH) / 2;
    localparam integer SCROLL_INIT_I = OFF_MOD + N8 - TEXT_WIDTH + 1 - X_ACTIVE;
    localparam [OFF_AW-1:0] SCROLL_INIT = SCROLL_INIT_I[OFF_AW-1:0];
    localparam integer SCROLL_CENTER = OFF_MOD + N8 - TEXT_WIDTH + 1 - CENTER_LEFT;
    localparam integer SCROLL_MAX = OFF_MOD + N8 + 1;

    /* ---------------- 像素坐标 ---------------- */
    reg [10:0] x_cnt;
    reg [ 9:0] y_cnt;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst)                      x_cnt <= 11'd0;
        else if (!I_de)                 x_cnt <= 11'd0;
        else if (x_cnt == X_ACTIVE - 1) x_cnt <= 11'd0;
        else                            x_cnt <= x_cnt + 11'd1;
    end

    reg  vs_d;
    wire frame_start = I_vs & ~vs_d;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            vs_d  <= 1'b0;
            y_cnt <= 10'd0;
        end else begin
            vs_d <= I_vs;
            if (frame_start)
                y_cnt <= 10'd0;
            else if (I_de && (x_cnt == X_ACTIVE - 1)) begin
                if (y_cnt == Y_ACTIVE - 1) y_cnt <= 10'd0;
                else                       y_cnt <= y_cnt + 10'd1;
            end
        end
    end

    /* ---------------- 滚动相位 ---------------- */
    reg [15:0]       frame_cnt;
    reg [OFF_AW-1:0] scroll_off;
    localparam [1:0] ENTER = 2'd0, HOLD = 2'd1, LEAVE = 2'd2;
    reg [1:0]        scroll_state;
    reg [15:0]       move_frame_cnt;
    reg [31:0]       hold_frame_cnt;
    reg              step_pending;
    reg              step_d;
    wire             step_edge = I_scroll_step & ~step_d;
    wire             move_due = (DIVIDER <= 1) || (move_frame_cnt >= DIVIDER - 1);

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            frame_cnt  <= 16'd0;
            scroll_off <= SCROLL_INIT;
            scroll_state <= ENTER;
            move_frame_cnt <= 16'd0;
            hold_frame_cnt <= 32'd0;
            step_pending <= 1'b0;
            step_d     <= 1'b0;
        end else begin
            step_d <= I_scroll_step;
            if (step_edge) step_pending <= 1'b1;
            // 只在场消隐更新位置，整帧内字符坐标保持不变。
            if (frame_start) begin
                frame_cnt <= frame_cnt + 16'd1;
                step_pending <= 1'b0;
                if (scroll_state == HOLD) begin
                    move_frame_cnt <= 16'd0;
                    if ((HOLD_FRAMES <= 1) || (hold_frame_cnt >= HOLD_FRAMES - 1)) begin
                        scroll_state <= LEAVE;
                        hold_frame_cnt <= 32'd0;
                    end else hold_frame_cnt <= hold_frame_cnt + 32'd1;
                end else if (move_due || step_pending || step_edge) begin
                    move_frame_cnt <= 16'd0;
                    if (scroll_state == ENTER) begin
                        if (scroll_off + SCROLL_STEP >= SCROLL_CENTER) begin
                            scroll_off <= SCROLL_CENTER;
                            scroll_state <= (HOLD_FRAMES == 0) ? LEAVE : HOLD;
                            hold_frame_cnt <= 32'd0;
                        end else scroll_off <= scroll_off + SCROLL_STEP;
                    end else if (scroll_off >= SCROLL_MAX) begin
                        // 保留一帧完全离屏，再从右侧开始下一轮。
                        scroll_off <= SCROLL_INIT;
                        scroll_state <= ENTER;
                    end else if (scroll_off + SCROLL_STEP >= SCROLL_MAX)
                        scroll_off <= SCROLL_MAX;
                    else scroll_off <= scroll_off + SCROLL_STEP;
                end else move_frame_cnt <= move_frame_cnt + 16'd1;
            end
        end
    end

    /* ---------------- 判定值: 2 级流水 ---------------- */
    reg [10:0] v1_x;
    reg [ 9:0] v1_y;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            v1_x <= 11'd0;
            v1_y <= 10'd0;
        end else begin
            v1_x <= x_cnt;
            v1_y <= y_cnt;
        end
    end

    localparam OFF_AW2 = OFF_AW + 2;

    wire [OFF_AW2-1:0] px_sum = {1'b0, OFF_MASK} + {{(OFF_AW2-OFF_AW-1){1'b0}}, N8[OFF_AW:0]};
    wire [OFF_AW2-1:0] px_use = {1'b0, scroll_off} + {{(OFF_AW2-11){1'b0}}, v1_x};
    wire [OFF_AW2-1:0] px     = px_sum - px_use;
    wire [OFF_AW-1:0]  i_full = px[OFF_AW2-1:CELL_BITS];
    wire               i_ok   = (i_full < N);

    reg [CELL_BITS-1:0] v2_col;
    reg [CELL_BITS-1:0] v2_row;
    reg [4:0]           v2_i;
    reg                 v2_ok;
    reg                 v2_strip;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            v2_col   <= {CELL_BITS{1'b0}};
            v2_row   <= {CELL_BITS{1'b0}};
            v2_i     <= 5'd0;
            v2_ok    <= 1'b0;
            v2_strip <= 1'b0;
        end else begin
            // px 随屏幕 x 增大而减小：低位取反得到从左到右的字内列。
            // 与 i_full 同源，滚动 1 像素时字形整体平移，不再拆开笔画。
            v2_col   <= ~px[CELL_BITS-1:0];
            v2_row   <= v1_y[CELL_BITS-1:0];
            v2_i     <= i_full[4:0];
            v2_ok    <= i_ok;
            v2_strip <= (v1_y >= Y_BASE) && (v1_y <= Y_END);
        end
    end

    function [8:0] osd_msg;
        input [4:0] idx;
        begin
            case (idx)
                 5'd0 : osd_msg = MSG_0 ;  5'd1 : osd_msg = MSG_1 ;
                 5'd2 : osd_msg = MSG_2 ;  5'd3 : osd_msg = MSG_3 ;
                 5'd4 : osd_msg = MSG_4 ;  5'd5 : osd_msg = MSG_5 ;
                 5'd6 : osd_msg = MSG_6 ;  5'd7 : osd_msg = MSG_7 ;
                 5'd8 : osd_msg = MSG_8 ;  5'd9 : osd_msg = MSG_9 ;
                 5'd10: osd_msg = MSG_10;  5'd11: osd_msg = MSG_11;
                 5'd12: osd_msg = MSG_12;  5'd13: osd_msg = MSG_13;
                 5'd14: osd_msg = MSG_14;  5'd15: osd_msg = MSG_15;
                 5'd16: osd_msg = MSG_16;  5'd17: osd_msg = MSG_17;
                 5'd18: osd_msg = MSG_18;  5'd19: osd_msg = MSG_19;
                 5'd20: osd_msg = MSG_20;  5'd21: osd_msg = MSG_21;
                 5'd22: osd_msg = MSG_22;  5'd23: osd_msg = MSG_23;
                 5'd24: osd_msg = MSG_24;  5'd25: osd_msg = MSG_25;
                 5'd26: osd_msg = MSG_26;  5'd27: osd_msg = MSG_27;
                 5'd28: osd_msg = MSG_28;  5'd29: osd_msg = MSG_29;
                 5'd30: osd_msg = MSG_30;  default: osd_msg = MSG_31;
            endcase
        end
    endfunction

    wire [8:0] slot_now = v2_ok ? osd_msg(v2_i) : 9'd0;

    assign O_pattern_addr = {slot_now, v2_row};

    reg [CELL_BITS-1:0] v3_col;
    reg                 v3_strip;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            v3_col   <= {CELL_BITS{1'b0}};
            v3_strip <= 1'b0;
        end else begin
            v3_col   <= v2_col;
            v3_strip <= v2_strip;
        end
    end

    wire [CELL_BITS-1:0] col_sel   = (ROM_LATENCY == 0) ? v2_col   : v3_col;
    wire                 strip_sel = (ROM_LATENCY == 0) ? v2_strip : v3_strip;

    wire pix_on   = I_pattern_data[CELL - 1 - col_sel];
    wire blink_on = (BLINK_EN == 0) ? 1'b1 : ~frame_cnt[BLINK_BIT];
    wire osd_v    = strip_sel & pix_on & blink_on;

    /* ---------------- 像素选择 ---------------- */
    wire [7:0]  a8 = ALPHA;
    wire [7:0]  ia = 8'hFF - a8;
    wire [23:0] blend_out = {
        (FG_COLOR[23:16] * a8 + I_data[23:16] * ia + 16'd128) >> 8,
        (FG_COLOR[15: 8] * a8 + I_data[15: 8] * ia + 16'd128) >> 8,
        (FG_COLOR[ 7: 0] * a8 + I_data[ 7: 0] * ia + 16'd128) >> 8
    };
    wire [23:0] premix  = (ALPHA == 8'hFF) ? FG_COLOR : blend_out;
    wire [23:0] pix_now = osd_v ? premix : I_data;

    /* ---------------- 统一延迟链 ---------------- */
    reg [OSD_DELAY-1:0] de_d;
    reg [23:0] bg_d [0:OSD_DELAY-1];
    integer i;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            de_d  <= {OSD_DELAY{1'b0}};
            for (i = 0; i < OSD_DELAY; i = i + 1) bg_d[i] <= 24'd0;
        end else begin
            de_d    <= {de_d[OSD_DELAY-2:0],  I_de};
            bg_d[0] <= pix_now;
            for (i = 1; i < OSD_DELAY; i = i + 1) bg_d[i] <= bg_d[i-1];
        end
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            O_de   <= 1'b0;
            O_data <= 24'd0;
        end else begin
            O_de   <= de_d[OSD_DELAY-1];
            O_data <= bg_d[OSD_DELAY-1];
        end
    end

endmodule


/* ============================================================================
 * osd_font_rom  ——  字库 ROM (BRAM, 1 拍读延迟, 32 bit 宽)
 * ============================================================================ */
module osd_font_rom #(
    parameter ROM_DEPTH  = 8192,
    parameter ADDR_WIDTH = 13,
    parameter INIT_FILE  = "osd_font.mif"
)(
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] addr,
    output reg  [31:0]           dout
);
    reg [31:0] mem [0:ROM_DEPTH-1];

    initial begin
        $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk)
        dout <= mem[addr];

endmodule
