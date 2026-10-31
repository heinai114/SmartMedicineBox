
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       key_brightness, // 板上 KEY3：5%步进，长按加速
    input                       sw_adjust_mode, // SW1: up=plan editor, down=discard unsaved edits
    input                       sw_volume_mode, // SW2: 1=KEY3 volume, 0=brightness
    input                       sw_audio_visual, // SW3: 1=post-volume PCM waveforms
    input                       sw_caption_hide, // SW4: 0=subtitle window visible, 1=hidden

    inout                       rtc_sda,         // J1 pin 1 / D14; pull up to 3.3V
    inout                       rtc_scl,         // J1 pin 2 / G11; pull up to 3.3V
    input                       rtc_uart_rx,     // CH340 TXD -> FPGA F12
    output                      rtc_uart_tx,     // FPGA D12 -> CH340 RXD

    inout [3:0]                 keypad_rows,      // J1.3..6 / R1..R4
    input [3:0]                 keypad_columns,   // J1.7..10 / C1..C4

    output [3:0]                med_led,
    output                      med_buzzer,
    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;
wire [11:0] display_width, display_height;
wire        display_epoch;
wire [2:0] display_file_index;
wire bmi_scene,bmi_repeat_enable,narration_scene;
// Register the SD-domain mode permission before the voice FSM, so the wide
// image/control decode does not feed EOF/pending enables combinationally.
(* syn_preserve=1 *) reg bmi_repeat_registered;
always @(posedge sd_card_clk or posedge rst_all) begin
    if(rst_all) bmi_repeat_registered<=0;
    else bmi_repeat_registered<=bmi_repeat_enable;
end

wire [23:0] tf_debug_digits;
// Display-only CDC: mode, switch-complete, catalog count, displayed image.
reg [15:0] tf_display_sync0;
reg [15:0] tf_display_sync1;
wire [6:0] tf_display_segments [0:3];
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tf_display_sync0 <= 16'd0;
        tf_display_sync1 <= 16'd0;
    end else begin
        tf_display_sync0 <= tf_debug_digits[15:0];
        tf_display_sync1 <= tf_display_sync0;
    end
end
genvar tf_digit;
generate
    for (tf_digit = 0; tf_digit < 4; tf_digit = tf_digit + 1) begin: g_tf_display_digit
        seg_decoder u_decoder (
            .bin_data(tf_display_sync1[15-tf_digit*4 -: 4]),
            .seg_data(tf_display_segments[tf_digit])
        );
    end
endgenerate

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_ready;
wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// ===================== M18 OSD 叠加 =====================
wire [23:0] vout_data_osd;      // OSD 叠加后的像素
wire        de_osd;             // OSD 对齐后的 de
wire [12:0] osd_pat_addr;       // 字库地址 (8192 = 13 bit)
wire [31:0] osd_pat_data;       // 字模数据 (32 bit/行)

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        audio_scaled_valid;
wire [23:0] audio_scaled_left;
wire [23:0] audio_scaled_right;
wire [3:0]  volume_level;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 音频链路
wire rst_all;
assign rst_all = ~rst_n | ~audio_pll_lock;

// The memory writer holds ACK until the request is withdrawn. Sample this
// level through two SD-clock registers before it drives the BMP reader FSM.
// Direct memory-clock ACK -> BMP state/enable paths violated setup timing.
(* syn_preserve = 1, async_reg = "true" *) reg [1:0] write_ack_sync_sd;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) write_ack_sync_sd <= 2'b00;
    else write_ack_sync_sd <= {write_ack_sync_sd[0], sd_card_write_req_ack};
end

// 保持你原来的 TF / SDRAM / video 时钟
sdram_timing_pll #(.MEM_DIV(12), .SDR_PHASE(0)) sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

wire fade_request;
wire fade_black;
wire fade_idle;
wire [8:0] fade_gain;
wire [2:0] transition_effect;
video_fade_controller #(.WAIT_FRAMES(2)) u_video_fade_controller (
    .clk(video_clk), .rst(rst_all), .vs(vs), .request_async(fade_request),
    .gain(fade_gain), .effect(transition_effect), .at_black(fade_black), .idle(fade_idle)
);

// ===================== TF 多图扫描与缓存（双缓冲） =====================
wire config_done,config_valid,config_boot_bank;
wire [2:0] config_status;wire [3:0] config_read_index;wire [35:0] config_read_data;
wire plan_active_bank,plan_edit_bank,plan_applied,plan_any_enabled,plan_commit_ready,plan_commit_request;
wire editor_visible,editor_busy,editor_open,editor_action_valid;wire [4:0] editor_action;
wire [1:0] editor_medicine,editor_slot;wire [2:0] editor_digit,editor_error;wire [7:0] editor_names;wire [35:0] editor_entry;
wire editor_mem_req,editor_mem_write,editor_mem_ready;reg editor_mem_valid;
wire [4:0] editor_mem_addr,save_ram_addr;wire [35:0] editor_mem_wdata,editor_mem_rdata,ram_fast_data,save_ram_data;
wire save_ram_owner,save_ram_write,save_request,save_done,save_success,save_available;
wire plan_bus_request,plan_bus_read,plan_bus_ready,plan_bus_done,plan_bus_error;
wire [6:0] plan_bus_device;wire [11:0] plan_bus_address;wire [7:0] plan_bus_write_data,plan_bus_read_data;
// Editor, scheduler, journal and both RAM ports share video_clk.
assign editor_mem_ready=config_done&&!save_ram_owner;
assign editor_mem_rdata=ram_fast_data;
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)editor_mem_valid<=0;else editor_mem_valid<=editor_mem_req&&editor_mem_ready;
end
wire geometry_ready;wire [31:0] geometry_fat,geometry_data;wire [27:0] geometry_root,geometry_limit;wire [6:0] geometry_mask;wire [2:0] geometry_shift;
wire voice_busy,voice_sd_req,voice_sd_valid,voice_sd_end,voice_sd_error,voice_sd_init_done;
wire voice_play_request,voice_stop_request;
wire [31:0] voice_sd_addr;
wire [7:0] voice_sd_data,voice_error_code;
wire [15:0] voice_underflows;
wire voice_underflow_seen;
wire voice_test_mode,voice_test_selected,image_auto_key_n;
wire music_selected_ui,music_active;
wire [4:0] music_audio_track;
wire reminder_scene_owned,reminder_scene_ack,reminder_scene_fault;
reg reminder_scene_request;reg [2:0] reminder_scene_command;
(* async_reg="true",syn_preserve=1 *) reg [1:0] reminder_scene_ack_sync,reminder_scene_fault_sync;
wire [2:0] reminder_scene_wanted=reminder_active?{1'b1,reminder_name}:3'd0;
wire reminder_scene_ready=reminder_active&&reminder_scene_ack_sync[1]==reminder_scene_request&&reminder_scene_command==reminder_scene_wanted;
// One outstanding command. The bundle is held until the SD scheduler has
// completed entry (or reported a failed read); changes coalesce while busy.
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)begin
  reminder_scene_request<=0;reminder_scene_command<=0;
  reminder_scene_ack_sync<=0;reminder_scene_fault_sync<=0;
 end else begin
  reminder_scene_ack_sync<={reminder_scene_ack_sync[0],reminder_scene_ack};
  reminder_scene_fault_sync<={reminder_scene_fault_sync[0],reminder_scene_fault};
  if(reminder_scene_ack_sync[1]==reminder_scene_request&&reminder_scene_command!=reminder_scene_wanted)begin
   reminder_scene_command<=reminder_scene_wanted;reminder_scene_request<=~reminder_scene_request;
  end
 end
end
assign voice_test_mode=voice_test_selected&&!reminder_scene_owned&&!music_active;
wire detail_request,filtered_next_key_n;
wire [1:0] detail_mode;
// Reserve the current image while KEY4 is being classified. A long press
// begun just before EOF must not lose its image during the one-second hold.
(* async_reg="true",syn_preserve=1 *) reg [1:0] detail_key_hold_sync;
always @(posedge sd_card_clk or posedge rst_all)begin
    if(rst_all)detail_key_hold_sync<=2'b11;
    else detail_key_hold_sync<={detail_key_hold_sync[0],key2};
end
wire [4:0] pcm_track;
wire pcm_sample_taken,pcm_playing;
wire [4:0] requested_voice_track = music_active ? music_audio_track : voice_test_mode ? 5'd1 :
    (detail_mode==2 ? ({2'b0,display_file_index}+5'd11) :
    (detail_mode==1 ? ({2'b0,display_file_index}+5'd6) :
    (display_file_index==3'd5 ? 5'd2 : ((display_file_index>=3'd1&&display_file_index<=3'd4) ? {2'b0,display_file_index}+5'd2 : 5'd0))));
voice_key_select #(.LAYERED_MODE(1)) u_voice_key_select (
    .clk(sd_card_clk),.rst(rst_all),.key_n(key2||reminder_scene_owned||music_active),
    .next_key_n(key1||reminder_scene_owned||music_active),.filtered_next_key_n(filtered_next_key_n),.detail_request(detail_request),
    .short_key_n(image_auto_key_n),.track_select(voice_test_selected)
);
tf_card_bmp_player #(
    .VOICE_ENABLE      (1),
    .SAVE_SUPPORT      (0),
    .EXPORT_GEOMETRY   (1),
    .SCENE_OVERRIDE    (1),
    .VOICE_LOOP_MODE   (1),
    .VOICE_BMI_BIND    (1),
    .VOICE_TWO_SCENES  (0),
    .VOICE_FIVE_SCENES (1),
    .VOICE_DETAIL_MODE (1),
    .VOICE_LAYERS      (3),
    .VOICE_LAYER_CYCLE (1),
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd5)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (filtered_next_key_n),
    .media_start_enable(1'b1),
    .key_auto          (image_auto_key_n),
    .scene_request_async(reminder_scene_request),.scene_command_async(reminder_scene_command),
    .scene_ack(reminder_scene_ack),.scene_owned(reminder_scene_owned),.scene_fault(reminder_scene_fault),
    .state_code        (),
    .display_valid     (display_valid),
    .debug_digits      (tf_debug_digits),
    .display_width     (display_width),
    .display_height    (display_height),
    .display_epoch     (display_epoch),
    .display_file_index(display_file_index),.bmi_scene(bmi_scene),.bmi_repeat_enable(bmi_repeat_enable),
    .narration_scene(narration_scene),.test_mode(voice_test_mode||music_active),
    .detail_request(detail_request),.detail_mode(detail_mode),
    .voice_key_hold(!detail_key_hold_sync[1]),

    .fade_black        (fade_black),
    .fade_idle         (fade_idle),
    .fade_request      (fade_request),
    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (write_ack_sync_sd[1]),
    .write_ready       (sd_card_write_ready),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),
    .voice_busy(voice_busy),.voice_sd_req(voice_sd_req),.voice_sd_addr(voice_sd_addr),
    .voice_sd_data(voice_sd_data),.voice_sd_valid(voice_sd_valid),.voice_sd_end(voice_sd_end),
    .voice_sd_error(voice_sd_error),.voice_sd_init_done(voice_sd_init_done),
    .voice_play_request(voice_play_request),.voice_stop_request(voice_stop_request),
 .geometry_ready(geometry_ready),.geometry_fat(geometry_fat),.geometry_data(geometry_data),
 .geometry_root(geometry_root),.geometry_limit(geometry_limit),.geometry_mask(geometry_mask),.geometry_shift(geometry_shift)
);

// Voice diagnostics use physical digits 3/4 only when an error is present.
(* async_reg="true",syn_preserve=1 *) reg [7:0] voice_error_sync0,voice_error_sync1;
(* async_reg="true",syn_preserve=1 *) reg [1:0] voice_underflow_sync;
always @(posedge clk or posedge rst_all) begin
    if(rst_all) begin voice_error_sync0<=0;voice_error_sync1<=0;voice_underflow_sync<=0;end
    else begin voice_error_sync0<=voice_error_code;voice_error_sync1<=voice_error_sync0;
        voice_underflow_sync<={voice_underflow_sync[0],voice_underflow_seen};end
end
wire [7:0] voice_diagnostic=voice_error_sync1!=0?voice_error_sync1:(voice_underflow_sync[1]?8'h30:8'd0);
wire [6:0] voice_seg0,voice_seg1;
seg_decoder u_voice_seg0(.bin_data(voice_diagnostic[7:4]),.seg_data(voice_seg0));
seg_decoder u_voice_seg1(.bin_data(voice_diagnostic[3:0]),.seg_data(voice_seg1));
// Slots 2..5 are physical digits 5..8: mode, complete, total, current.
seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        (voice_diagnostic==0?8'hFF:{1'b1,voice_seg0}),
    .seg_data_1        (voice_diagnostic==0?8'hFF:{1'b1,voice_seg1}),
    .seg_data_2        ({1'b1,tf_display_segments[0]}),
    .seg_data_3        ({1'b1,tf_display_segments[1]}),
    .seg_data_4        ({1'b1,tf_display_segments[2]}),
    .seg_data_5        ({1'b1,tf_display_segments[3]})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// Synchronize the first-image-valid level before it gates pixel arithmetic.
(* syn_preserve=1, async_reg="true" *) reg [1:0] display_valid_video;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) display_valid_video <= 2'b00;
    else display_valid_video <= {display_valid_video[0], display_valid};
end
// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
wire [23:0] vout_base = display_valid_video[1]&&!reminder_scene_fault_sync[1] ? vout_data_raw : 24'd0;

// S15 decreases and S16 increases contrast globally, including hold acceleration.
// S1-S14 keep one-shot editor events; only S15/S16 expose a held state.
wire keypad_valid,edit_mode_up,editor_pause;wire [3:0] keypad_code;wire [2:0] editor_field;
music_mode_control u_music_mode_control(
    .ui_clk(video_clk),.audio_clk(sd_card_clk),.rst(rst_all),
    .key_valid(keypad_valid),.key_code(keypad_code),
    .ui_blocked(sw_adjust_mode||edit_mode_up||editor_visible||editor_busy||
        reminder_active||!display_valid_video[1]||!fade_idle),
    .scene_owned(reminder_scene_owned),
    .selected_ui(music_selected_ui),.active_audio(music_active),.track_audio(music_audio_track)
);
wire [1:0] contrast_held;
wire [1:0] contrast_event=keypad_valid ? {keypad_code==4'd15,keypad_code==4'd14} : 2'b00;
// KEY3/SW2 select brightness/volume; SW1 still selects plan editing.
wire [23:0] vout_brightness;
wire de_brightness;
wire vs_brightness;
video_brightness_osd #(
    .CLK_FREQ_HZ(25_000_000), .X_ACTIVE(640), .Y_ACTIVE(480), .FADE_ENABLE(1)
) u_video_brightness_osd (
    .I_clk(video_clk), .I_rst(rst_all), .I_key_n(key_brightness),
    .I_contrast_event(contrast_event), .I_contrast_held(contrast_held), .I_mode_volume(sw_volume_mode),
    .I_image_valid(display_valid_video[1]), .O_volume_level(volume_level),
    .I_de(de), .I_vs(vs), .I_data(vout_base), .I_fade_gain(fade_gain),
    .I_transition_effect(transition_effect),
    .O_de(de_brightness), .O_vs(vs_brightness), .O_data(vout_brightness)
);
// Scalar one-hot flags synchronize independently; latched PCM ownership
// suppresses old narration during image changes. Track bundles latch on flush.
(* async_reg="true",syn_preserve=1 *) reg [4:0] scene_video0,scene_video1;
(* async_reg="true",syn_preserve=1 *) reg [1:0] test_scene_video;
genvar scene_i;
generate for(scene_i=0;scene_i<5;scene_i=scene_i+1)begin:g_scene_sync
 always @(posedge video_clk or posedge rst_all)begin
  if(rst_all)begin scene_video0[scene_i]<=0;scene_video1[scene_i]<=0;end
  else begin scene_video0[scene_i]<=display_valid&&display_file_index==scene_i+1;scene_video1[scene_i]<=scene_video0[scene_i];end
 end
end endgenerate
always @(posedge video_clk or posedge rst_all)begin
 if(rst_all)test_scene_video<=0;
 else test_scene_video<={test_scene_video[0],voice_test_mode};
end
wire vs_osd;
video_scene_caption #(.VISIBILITY_CONTROL(1)) u_video_scene_caption (
    .clk(video_clk),.rst(rst_all),.I_de(de_brightness),.I_vs(vs_brightness),.I_data(vout_brightness),
    .scenes(scene_video1),.test_mode(test_scene_video[1]),
    .I_hide_async(sw_caption_hide||(music_selected_ui&&!reminder_active)),
    .pcm_track(pcm_track),.pcm_playing(pcm_playing),.sample_taken(pcm_sample_taken),
    .O_de(de_osd),.O_vs(vs_osd),.O_data(vout_data_osd)
);
// All caption glyphs, including bit-exact legacy reminder glyphs, now share
// one ROM. Original font files and inactive old renderer remain preserved.

// Triggered PCM waveforms blend in a solid panel at the upper left.
// RGB/DE/VS remain aligned; the upper-right HUD and bottom subtitle are separate.
wire de_audio_visual;
wire vs_audio_visual;
wire [23:0] vout_audio_visual;
wire waveform_frame_enable;
audio_waveform_overlay u_audio_waveform_overlay (
    .I_clk(video_clk), .I_rst(rst_all), .I_enable_async(sw_audio_visual),
    .I_volume_level(volume_level),
    .I_audio_valid(audio_scaled_valid), .I_left(audio_scaled_left), .I_right(audio_scaled_right),
    .I_de(de_osd), .I_vs(vs_osd), .I_data(vout_data_osd),
    .O_de(de_audio_visual), .O_vs(vs_audio_visual), .O_data(vout_audio_visual),
    .O_frame_enable(waveform_frame_enable)
);

// RTC lives on the existing pixel clock. The OSD consumes a coherent snapshot
// at VS and the scope's actual frame enable, avoiding a second SW3 debounce.
wire [23:0] rtc_time_bcd;
wire [23:0] rtc_date_bcd;
wire [2:0] rtc_weekday;
wire rtc_time_valid;
wire [19:0] rtc_temperature_bcd;
wire rtc_temperature_negative,rtc_temperature_valid;
// Restore read-only DS3231 temperature polling and the original calendar display.
ds3231_clock #(.ENABLE_TEMPERATURE(1),.ENABLE_PLAN_EEPROM(1)) u_rtc_clock (
    .clk(video_clk),.rst(rst_all),.uart_rx(rtc_uart_rx),.uart_tx(rtc_uart_tx),
    .rtc_scl(rtc_scl),.rtc_sda(rtc_sda),.time_bcd(rtc_time_bcd),.date_bcd(rtc_date_bcd),
    .weekday(rtc_weekday),.time_valid(rtc_time_valid),
    .temperature_bcd(rtc_temperature_bcd),.temperature_negative(rtc_temperature_negative),
    .temperature_valid(rtc_temperature_valid),
    .plan_request(plan_bus_request),.plan_read(plan_bus_read),.plan_device(plan_bus_device),
    .plan_address(plan_bus_address),.plan_write_data(plan_bus_write_data),.plan_ready(plan_bus_ready),
    .plan_done(plan_bus_done),.plan_error(plan_bus_error),.plan_read_data(plan_bus_read_data)
);
wire de_rtc,vs_rtc;
wire [23:0] vout_rtc;
// Low-priority visual hint; all permission signals are in video_clk. Hold its
// remaining display time while images switch or higher-priority UI owns video.
wire temperature_hint_blocked=!display_valid_video[1]||!fade_idle||reminder_active||
    (reminder_scene_command!=0)||(reminder_scene_request!=reminder_scene_ack_sync[1])||
    edit_mode_up||editor_visible||editor_busy||editor_pause||save_ram_owner||save_request;
video_rtc_overlay #(.ENABLE_TEMPERATURE(1),.ENABLE_TEMP_HINT(1),
    .TEMP_FONT_FILE("temperature_hint_font.dat")) u_video_rtc_overlay (
    .clk(video_clk),.rst(rst_all),.time_bcd(rtc_time_bcd),.date_bcd(rtc_date_bcd),
    .weekday(rtc_weekday),.time_valid(rtc_time_valid),
    .temperature_bcd(rtc_temperature_bcd),.temperature_negative(rtc_temperature_negative),
    .temperature_valid(rtc_temperature_valid),
    .hint_blocked(temperature_hint_blocked),
    .waveform_frame_enable(waveform_frame_enable),
    .I_de(de_audio_visual),.I_vs(vs_audio_visual),.I_data(vout_audio_visual),
    .O_de(de_rtc),.O_vs(vs_rtc),.O_data(vout_rtc)
);

// Coherent configuration bundle is held by the SD reader after publication.
// Existing RTC and reminder scheduler share video_clk. No RTC write is added.
wire [2:0] reminder_medicine,reminder_status;
wire [15:0] reminder_time;
wire [19:0] reminder_dose;
wire [1:0] reminder_unit;
wire [1:0] reminder_name;
wire reminder_active,reminder_ready,reminder_valid;
med_plan_store #(.INDEX_BITS(5))u_med_plan_store(.wclk(video_clk),
 .write(save_ram_owner?save_ram_write:(editor_mem_req&&editor_mem_ready&&editor_mem_write)),
 .write_index(save_ram_owner?save_ram_addr:editor_mem_addr),.write_data(save_ram_owner?save_ram_data:editor_mem_wdata),
 .write_read_data(ram_fast_data),.rclk(video_clk),.read_index({plan_active_bank,config_read_index}),.read_data(config_read_data));
med_plan_editor #(.BOOT_BANK_SUPPORT(1),.SAVE_STAY_SUPPORT(1))u_med_plan_editor(.clk(video_clk),.rst(rst_all),.plan_ready(reminder_ready),.plan_valid(reminder_valid),.boot_bank(config_boot_bank),.keep_open(edit_mode_up),.open(editor_open),
 .action_valid(editor_action_valid),.action(editor_action),.visible(editor_visible),.busy(editor_busy),.error(editor_error),
 .medicine(editor_medicine),.slot(editor_slot),.digit(editor_digit),.names(editor_names),.entry(editor_entry),
 .active_bank(plan_active_bank),.edit_bank(plan_edit_bank),.applied(plan_applied),.any_enabled(plan_any_enabled),
 .mem_request(editor_mem_req),.mem_write(editor_mem_write),.mem_address(editor_mem_addr),.mem_wdata(editor_mem_wdata),
 .mem_ready(editor_mem_ready),.mem_valid(editor_mem_valid),.mem_rdata(editor_mem_rdata),
 .save_request(save_request),.save_done(save_done),.save_success(save_success),.commit_request(plan_commit_request),.commit_ready(plan_commit_ready)) /* fehdl keep_hierarchy="true" */;
med_plan_eeprom u_med_plan_eeprom(.clk(video_clk),.rst(rst_all),.save_request(save_request),.edit_bank(plan_edit_bank),
 .boot_done(config_done),.boot_valid(config_valid),.boot_bank(config_boot_bank),.boot_status(config_status),
 .available(save_available),.save_done(save_done),.save_success(save_success),.memory_owner(save_ram_owner),
 .memory_address(save_ram_addr),.memory_write(save_ram_write),.memory_wdata(save_ram_data),.memory_rdata(ram_fast_data),
 .bus_request(plan_bus_request),.bus_read(plan_bus_read),.bus_device(plan_bus_device),.bus_address(plan_bus_address),
 .bus_write_data(plan_bus_write_data),.bus_ready(plan_bus_ready),.bus_done(plan_bus_done),.bus_error(plan_bus_error),.bus_read_data(plan_bus_read_data)) /* fehdl keep_hierarchy="true" */;
med_reminder #(.RUNTIME_EDIT(1),.SCENE_SYNC(1))u_med_reminder(.clk(video_clk),.rst(rst_all),
 .cfg_done_async(config_done),.cfg_valid_async(config_valid),.cfg_status_async(config_status),
 .cfg_entry(config_read_data),.cfg_read_index(config_read_index),.time_valid(rtc_time_valid),.time_bcd(rtc_time_bcd),.date_bcd(rtc_date_bcd),
 .led(med_led),.buzzer(med_buzzer),.display_medicine(reminder_medicine),.display_time(reminder_time),
 .display_dose(reminder_dose),.display_unit(reminder_unit),.display_name(reminder_name),.display_active(reminder_active),
 .plan_ready(reminder_ready),.plan_valid(reminder_valid),.plan_status(reminder_status),
 .runtime_commit(plan_applied),.runtime_any_enabled(plan_any_enabled),.runtime_ready(plan_commit_ready),.scene_ready(reminder_scene_ready));
wire de_reminder,vs_reminder;wire [23:0] vout_reminder;
video_med_reminder #(.SCENE_SYNC(1)) u_video_med_reminder(.clk(video_clk),.rst(rst_all),
 .medicine(reminder_medicine),.medicine_name(reminder_name),.alert_time(reminder_time),.dose(reminder_dose),.unit(reminder_unit),
 .scene_ready(reminder_scene_ready),.active(reminder_active&&fade_idle),.plan_ready(reminder_ready),.plan_valid(reminder_valid),
 .plan_status(reminder_status),.time_valid(rtc_time_valid),
 .I_de(de_rtc),.I_vs(vs_rtc),.I_data(vout_rtc),
 .O_de(de_reminder),.O_vs(vs_reminder),.O_data(vout_reminder));

// Restore the original lower-left BMP resolution cue, including its native
// font, 60-frame hold, 48-frame fade and two RGB/DE/VS register stages.
wire de_resolution, vs_resolution;
wire [23:0] vout_resolution;
video_resolution_hud #(.HOLD_FRAMES(60), .FADE_FRAMES(48)) u_resolution_hud (
    .I_clk(video_clk), .I_rst(rst_all),
    .I_width_async(display_width), .I_height_async(display_height),
    .I_epoch_async(display_epoch), .I_image_valid(display_valid_video[1]),
    .I_scene_idle(fade_idle),
    .I_de(de_reminder), .I_vs(vs_reminder), .I_data(vout_reminder),
    .O_de(de_resolution), .O_vs(vs_resolution), .O_data(vout_resolution)
) /* fehdl keep_hierarchy="true" */;

// The passive matrix replaces the entire USB host/report/coordinate path.

matrix_keypad u_matrix_keypad(.clk(video_clk),.rst(rst_all),.columns(keypad_columns),.rows(keypad_rows),
 .key_valid(keypad_valid),.key_code(keypad_code),.contrast_held(contrast_held));
keypad_plan_control u_keypad_plan_control(.clk(video_clk),.rst(rst_all),.sw_edit(sw_adjust_mode),
 .plan_ready(reminder_ready),.visible(editor_visible),.busy(editor_busy),.reminder_active(reminder_active),
 .key_valid(keypad_valid),.key_code(keypad_code),.open(editor_open),.action_valid(editor_action_valid),
 .action(editor_action),.field(editor_field),.mode_up(edit_mode_up),.applied(plan_applied),.frame_vs(vs),.pause(editor_pause));
wire de_editor,vs_editor;
keypad_editor_overlay #(.TIMED_HINT(1))u_keypad_editor_overlay(.clk(video_clk),.rst(rst_all),
 .image_ready(display_valid_video[1]),.scene_idle(fade_idle),
 .visible(editor_visible),.busy(editor_busy),.saving(save_request||plan_commit_request),.reminder_active(reminder_active||editor_pause),.file_available(save_available),
 .error(editor_error),.medicine(editor_medicine),.slot(editor_slot),.digit(editor_digit),.field(editor_field),.names(editor_names),.entry(editor_entry),
 .I_de(de_resolution),.I_vs(vs_resolution),.I_data(vout_resolution),.O_de(de_editor),.O_vs(vs_editor),.O_data(vout_data));

fit_frame_buffer #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_ready       (sd_card_write_ready),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// Independent selected WAV loop. PCM sample enables are derived directly from
// video_clk at 48 kHz, avoiding MCLK/I2S clock-rate and receiver assumptions.
tf_wav_player #(.MUSIC_SUPPORT(1),.SHARED_GEOMETRY(1),.PAUSE_SUPPORT(0),.CONFIG_ENABLE(0),.TRACK_BITS(5),.FIVE_SCENE_MODE(1),.SCENE_REPEAT_MODE(1)) u_tf_voice (
    .clk(sd_card_clk),.pcm_clk(video_clk),.rst(rst_all),.loop_enable(display_valid&&(music_active||voice_test_mode||!narration_scene)),
    .play_request(voice_play_request&&!music_active),.stop_request(voice_stop_request),
    .track_select(requested_voice_track),
    .bmi_repeat_enable(bmi_repeat_registered),
    .sd_init_done(voice_sd_init_done),.sd_req(voice_sd_req),.sd_addr(voice_sd_addr),
    .sd_data(voice_sd_data),.sd_valid(voice_sd_valid),.sd_end(voice_sd_end),.sd_error(voice_sd_error),
    .busy(voice_busy),.error_code(voice_error_code),.underflows(voice_underflows),.underflow_seen(voice_underflow_seen),
    .pcm_valid(audio_valid),.pcm_left(audio_left_data),.pcm_right(audio_right_data),
    .pcm_track(pcm_track),.pcm_sample_taken(pcm_sample_taken),.pcm_playing(pcm_playing),
 .geometry_ready(geometry_ready),.geometry_fat(geometry_fat),.geometry_data(geometry_data),
 .geometry_root(geometry_root),.geometry_limit(geometry_limit),.geometry_mask(geometry_mask),.geometry_shift(geometry_shift)
);

// Both the UI and decoded PCM are in video_clk: no multi-bit CDC is needed.
audio_pcm_volume u_audio_pcm_volume (
    .I_clk(video_clk), .I_rst(rst_all), .I_volume_level(volume_level),
    .I_valid(audio_valid), .I_left(audio_left_data), .I_right(audio_right_data),
    .O_valid(audio_scaled_valid), .O_left(audio_scaled_left), .O_right(audio_scaled_right)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_audio_valid (audio_scaled_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs_editor),
    .I_de          (de_editor),
    .I_rgb         (vout_data),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_scaled_valid),
    .I_audio_left_data  (audio_scaled_left),
    .I_audio_right_data (audio_scaled_right),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule

