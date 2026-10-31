// KEY3/SW2 retain brightness/volume. S15 decreases contrast; S16 increases it.
// Only these two matrix keys share the KEY3 500/1500/2500ms hold acceleration.
// Hold accelerates and saturates; switching modes requires release/repress.
// Compact shared HUD hides 2s after adjustment or mode selection.
// RGB, DE, VS and transition controls share the contrast register stage.
module video_brightness_osd #(
    parameter integer CLK_FREQ_HZ = 25_000_000,
    parameter integer X_ACTIVE = 640,
    parameter integer Y_ACTIVE = 480,
    parameter integer FADE_ENABLE = 0,
    parameter FONT_FILE="brightness_font.dat"
)(
    input wire I_clk,
    input wire I_rst,
    input wire I_key_n,
    input wire [1:0] I_contrast_event,
    input wire [1:0] I_contrast_held,
    input wire I_mode_volume,
    input wire I_image_valid,
    input wire I_de,
    input wire I_vs,
    input wire [23:0] I_data,
    input wire [8:0] I_fade_gain,
    input wire [2:0] I_transition_effect,
    output reg O_de,
    output reg O_vs,
    output reg [23:0] O_data,
    output wire [3:0] O_volume_level
);
    localparam integer MS_CYCLES = CLK_FREQ_HZ / 1000;
    localparam integer MS_BITS = MS_CYCLES > 1 ? $clog2(MS_CYCLES) : 1;
    reg [MS_BITS-1:0] ms_count;
    wire ms_tick = ms_count == MS_CYCLES-1;
    (* syn_preserve=1, async_reg="true" *) reg [1:0] key_sync;
    (* syn_preserve=1, async_reg="true" *) reg [1:0] volume_mode_sync;
    localparam [1:0] MODE_BRI=0, MODE_CON=1, MODE_VOL=2;
    wire [1:0] selected_mode = volume_mode_sync[1] ? MODE_VOL : MODE_BRI;
    reg [1:0] mode_stable;
    reg [1:0] mode_candidate;
    reg [4:0] mode_debounce;
    wire mode_change_accepted = selected_mode != mode_stable &&
                                selected_mode == mode_candidate && mode_debounce == 19;
    reg wait_key_release;
    reg key_stable_n;
    reg [4:0] debounce_count;
    reg [11:0] held_ms;
    reg [7:0] repeat_ms;
    wire [7:0] repeat_period = held_ms >= 2500 ? 8'd50 :
                              held_ms >= 1500 ? 8'd100 : 8'd200;
    // Level 1..20 represents 5..100%. A fresh press at 100% wraps to 5%.
    reg [4:0] requested_level;
    reg [4:0] active_level;
    reg [5:0] requested_contrast;
    reg [5:0] active_contrast;
    reg [3:0] requested_volume, active_volume;
    reg [1:0] active_mode, requested_hud_mode;
    // Accepted scanner events are one video clock; retain them until 1ms tick.
    reg [1:0] contrast_pending;
    wire [1:0] contrast_command=I_contrast_event!=0 ? I_contrast_event : contrast_pending;
    wire contrast_press=contrast_command==1 || contrast_command==2;
    wire contrast_hold=I_contrast_held==1 || I_contrast_held==2;
    wire repeat_due=held_ms==499 || (held_ms>=500 && repeat_ms>=repeat_period-1);
    wire key_repeat=!key_stable_n && !key_sync[1] && !wait_key_release &&
                    selected_mode==mode_stable && !mode_change_accepted;

    assign O_volume_level = active_volume;
    localparam [10:0] HUD_TIMEOUT_MS = 11'd2000;
    reg [10:0] hud_remaining_ms;
    reg hud_active;
    wire key_press_accepted = !key_sync[1] && key_stable_n && debounce_count == 19 &&
                              !wait_key_release && selected_mode == mode_stable && !mode_change_accepted &&
                              !contrast_press && !contrast_hold;
    // The first stage adjusts contrast around code 128, then brightness/fade
    // consumes that pixel with its matching DE/VS and transition controls.
    reg [23:0] contrast_pixel;
    reg de_c;
    reg vs_c;
    reg [8:0] fade_c;
    reg [2:0] effect_c;
    reg vs_d;
    wire frame_start = vs_c & ~vs_d;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            ms_count<=0; key_sync<=2'b11; volume_mode_sync<=0;
            mode_stable<=MODE_BRI;mode_candidate<=MODE_BRI;mode_debounce<=0;
            wait_key_release<=0;key_stable_n<=1;debounce_count<=0;
            held_ms<=0;repeat_ms<=0;contrast_pending<=0;
            requested_level<=20;requested_contrast<=20;requested_volume<=10;
            requested_hud_mode<=MODE_BRI;
        end else begin
            key_sync<={key_sync[0],I_key_n};
            volume_mode_sync<={volume_mode_sync[0],I_mode_volume};
            if(I_contrast_event!=0)contrast_pending<=I_contrast_event;
            if(ms_tick)begin
                ms_count<=0;contrast_pending<=0;
                if(selected_mode!=mode_stable)begin
                    if(selected_mode!=mode_candidate)begin
                        mode_candidate<=selected_mode;mode_debounce<=0;
                    end else if(mode_change_accepted)begin
                        mode_stable<=selected_mode;mode_debounce<=0;
                        wait_key_release<=!key_stable_n || !key_sync[1];
                    end else mode_debounce<=mode_debounce+1'b1;
                end else begin mode_debounce<=0;mode_candidate<=mode_stable;end
                if(key_stable_n && key_sync[1])wait_key_release<=0;
                if((contrast_press || contrast_hold) && !key_sync[1])wait_key_release<=1;
                if(key_sync[1]!=key_stable_n)begin
                    if(debounce_count==19)begin
                        debounce_count<=0;key_stable_n<=key_sync[1];
                    end else debounce_count<=debounce_count+1'b1;
                end else debounce_count<=0;

                if(mode_change_accepted)requested_hud_mode<=selected_mode;
                if(key_press_accepted)begin
                    requested_hud_mode<=mode_stable;
                    if(mode_stable==MODE_VOL)
                        requested_volume<=requested_volume==10 ? 4'd0 : requested_volume+1'b1;
                    else requested_level<=requested_level==20 ? 5'd1 : requested_level+1'b1;
                end
                // One sequencer, with matrix adjustment taking priority over KEY3.
                // A changed/ghosted matrix scan clears its hold before rearming.
                if(contrast_press || key_press_accepted ||
                   (!contrast_hold && (!key_repeat || key_sync[1]!=key_stable_n)))begin
                    held_ms<=0;repeat_ms<=0;
                end else if(contrast_hold || key_repeat)begin
                    if(!(&held_ms))held_ms<=held_ms+1'b1;
                    if(repeat_due)repeat_ms<=0;
                    else if(held_ms>=500)repeat_ms<=repeat_ms+1'b1;
                end
                if(contrast_press || contrast_hold)begin
                    requested_hud_mode<=MODE_CON;
                    if(contrast_press || repeat_due)begin
                        if(contrast_press ? contrast_command==1 : I_contrast_held==1)begin
                            if(requested_contrast!=0)requested_contrast<=requested_contrast-1'b1;
                        end else if(requested_contrast<40)requested_contrast<=requested_contrast+1'b1;
                    end
                end else if(key_repeat && repeat_due && key_sync[1]==key_stable_n)begin
                    requested_hud_mode<=mode_stable;
                    if(mode_stable==MODE_VOL)begin
                        if(requested_volume<10)requested_volume<=requested_volume+1'b1;
                    end else if(requested_level<20)requested_level<=requested_level+1'b1;
                end
            end else ms_count<=ms_count+1'b1;
        end
    end
    // Reuse the 1ms timebase; a held key refreshes the timeout even at 100%.
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) hud_remaining_ms <= 11'd0;
        else if (ms_tick) begin
            if (!key_stable_n || key_press_accepted || mode_change_accepted || contrast_press || contrast_hold)
                hud_remaining_ms <= HUD_TIMEOUT_MS;
            else if (hud_remaining_ms != 0)
                hud_remaining_ms <= hud_remaining_ms - 11'd1;
        end
    end
    // HUD visibility, value and image gain latch together in vertical blanking.
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            active_level <= 5'd20; active_contrast <= 6'd20;
            active_volume <= 4'd10;
            active_mode <= MODE_BRI; hud_active <= 1'b0; vs_d <= 1'b0;
        end
        else begin
            vs_d <= vs_c;
            if (frame_start) begin
                active_level <= requested_level;
                active_contrast <= requested_contrast;
                active_volume <= requested_volume;
                active_mode <= requested_hud_mode;
                hud_active <= hud_remaining_ms != 0;
            end
        end
    end

    reg [10:0] x;
    reg [9:0] y;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin x <= 0; y <= 0; end
        else begin
            if (!de_c || x == X_ACTIVE-1) x <= 0;
            else x <= x + 11'd1;
            if (frame_start) y <= 0;
            else if (de_c && x == X_ACTIVE-1)
                y <= y == Y_ACTIVE-1 ? 10'd0 : y + 10'd1;
        end
    end

    // Q8 contrast gain, 0..512. Explicit table avoids run-time division.
    function [9:0] contrast_gain;
        input [5:0] level;
        begin
            case (level)
                0: contrast_gain = 10'd0;
                1: contrast_gain = 10'd13;
                2: contrast_gain = 10'd26;
                3: contrast_gain = 10'd38;
                4: contrast_gain = 10'd51;
                5: contrast_gain = 10'd64;
                6: contrast_gain = 10'd77;
                7: contrast_gain = 10'd90;
                8: contrast_gain = 10'd102;
                9: contrast_gain = 10'd115;
                10: contrast_gain = 10'd128;
                11: contrast_gain = 10'd141;
                12: contrast_gain = 10'd154;
                13: contrast_gain = 10'd166;
                14: contrast_gain = 10'd179;
                15: contrast_gain = 10'd192;
                16: contrast_gain = 10'd205;
                17: contrast_gain = 10'd218;
                18: contrast_gain = 10'd230;
                19: contrast_gain = 10'd243;
                20: contrast_gain = 10'd256;
                21: contrast_gain = 10'd269;
                22: contrast_gain = 10'd282;
                23: contrast_gain = 10'd294;
                24: contrast_gain = 10'd307;
                25: contrast_gain = 10'd320;
                26: contrast_gain = 10'd333;
                27: contrast_gain = 10'd346;
                28: contrast_gain = 10'd358;
                29: contrast_gain = 10'd371;
                30: contrast_gain = 10'd384;
                31: contrast_gain = 10'd397;
                32: contrast_gain = 10'd410;
                33: contrast_gain = 10'd422;
                34: contrast_gain = 10'd435;
                35: contrast_gain = 10'd448;
                36: contrast_gain = 10'd461;
                37: contrast_gain = 10'd474;
                38: contrast_gain = 10'd486;
                39: contrast_gain = 10'd499;
                40: contrast_gain = 10'd512;
                default: contrast_gain = 10'd256;
            endcase
        end
    endfunction
    function [7:0] contrast_channel;
        input [7:0] value;
        input [9:0] gain;
        // Legal Q8 gain is 0..512: product fits signed 17 bits and the
        // rounded/clamped result fits signed 10 bits. Inverting the pixel
        // MSB gives exactly value-128 without a subtractor.
        reg signed [7:0] centered;
        reg signed [16:0] product, rounded;
        // Rounded Q8 result is signed 9 bits: top bits unequal mean overflow.
        begin
            centered = {~value[7],value[6:0]};
            product = centered * $signed({1'b0,gain});
            rounded = product + 17'sd128;
            if (rounded[16] != rounded[15]) contrast_channel = rounded[16] ? 8'd0 : 8'd255;
            else contrast_channel = {~rounded[15],rounded[14:8]};
        end
    endfunction
    wire [9:0] contrast_q8 = contrast_gain(active_contrast);
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            contrast_pixel <= 0; de_c <= 0; vs_c <= 0;
            fade_c <= 9'd256; effect_c <= 0;
        end else begin
            contrast_pixel <= !I_de || !I_image_valid ? 24'd0 :
                {contrast_channel(I_data[23:16],contrast_q8),
                 contrast_channel(I_data[15:8],contrast_q8),
                 contrast_channel(I_data[7:0],contrast_q8)};
            de_c <= I_de; vs_c <= I_vs;
            fade_c <= I_fade_gain; effect_c <= I_transition_effect;
        end
    end

    // Rounded fixed-point gain: round(256 * level * 5 / 100).
    function [8:0] level_gain;
        input [4:0] level;
        begin
            case (level)
                1: level_gain=13;   2: level_gain=26;
                3: level_gain=38;   4: level_gain=51;
                5: level_gain=64;   6: level_gain=77;
                7: level_gain=90;   8: level_gain=102;
                9: level_gain=115; 10: level_gain=128;
               11: level_gain=141; 12: level_gain=154;
               13: level_gain=166; 14: level_gain=179;
               15: level_gain=192; 16: level_gain=205;
               17: level_gain=218; 18: level_gain=230;
               19: level_gain=243; default: level_gain=256;
            endcase
        end
    endfunction
    wire [8:0] brightness_gain = level_gain(active_level);
    // Five masks share the brightness/RGB arithmetic and original two-clock
    // RGB/DE/VS pipeline. All geometry is procedural: no extra image/font RAM.
    // Keep the original center-box geometry and its 64-pixel feather exactly.
    // Geometry is evaluated only below full gain; bit8 bypasses every mask.
    // Size distances from the active raster limits, not unused counter bits.
    localparam X_HALF_BITS=$clog2((X_ACTIVE+128)/2+1);
    localparam Y_HALF_BITS=$clog2((Y_ACTIVE+128)/2+1);
    localparam X_DIST_BITS=$clog2(X_ACTIVE/2+1);
    localparam Y_DIST_BITS=$clog2(Y_ACTIVE/2+1);
    localparam BOX_BITS=$clog2(((X_ACTIVE>Y_ACTIVE?X_ACTIVE:Y_ACTIVE)+128)/2+1)+1;
    localparam DIAG_BITS=$clog2(X_ACTIVE+Y_ACTIVE+65);
    wire [19:0] center_x = fade_c[7:0] * (X_ACTIVE+128);
    wire [19:0] center_y = fade_c[7:0] * (Y_ACTIVE+128);
    wire [X_HALF_BITS-1:0] half_width = center_x >> 9;
    wire [Y_HALF_BITS-1:0] half_height = center_y >> 9;
    wire [X_DIST_BITS-1:0] center_dx = x >= X_ACTIVE/2 ? x-X_ACTIVE/2 : X_ACTIVE/2-x;
    wire [Y_DIST_BITS-1:0] center_dy = y >= Y_ACTIVE/2 ? y-Y_ACTIVE/2 : Y_ACTIVE/2-y;
    wire signed [BOX_BITS-1:0] box_dx = $signed({1'b0,half_width}) - $signed({1'b0,center_dx});
    wire signed [BOX_BITS-1:0] box_dy = $signed({1'b0,half_height}) - $signed({1'b0,center_dy});
    wire signed [BOX_BITS-1:0] box_distance = box_dx < box_dy ? box_dx : box_dy;
    // Fifteen horizontal 32-pixel louvers open symmetrically from each center.
    // Folded low coordinate bits replace division/modulo and absolute value.
    wire [3:0] blind_radius = y[4] ? y[3:0] : ~y[3:0];
    wire [12:0] blind_product = {fade_c[7:0],4'b0} + {2'b0,fade_c[7:0],2'b0};
    wire signed [5:0] blind_delta = $signed({1'b0,blind_product[12:8]}) - $signed({2'b0,blind_radius});
    wire [8:0] blind_gain = blind_delta <= 0 ? 9'd0 : blind_delta >= 4 ? 9'd256 : {1'b0,blind_delta[1:0],6'b0};
    // A soft diagonal front travels from upper left towards lower right.
    wire [20:0] diagonal_product = fade_c[7:0] * (X_ACTIVE+Y_ACTIVE+64);
    wire [DIAG_BITS-1:0] diagonal_front = diagonal_product >> 8;
    wire [DIAG_BITS-1:0] diagonal_coordinate = x + y;
    wire signed [DIAG_BITS:0] diagonal_distance = $signed({1'b0,diagonal_front}) - $signed({1'b0,diagonal_coordinate});
    // 64x64 tiles dissolve in four spatially interleaved groups. Group and
    // within-group progress are direct bit fields: no cell-radius arithmetic.
    // The bottom row is naturally cropped to the active-picture edge.
    wire [1:0] tile_group = {x[6]^y[6],x[7]^y[7]};
    wire [8:0] tile_gain = tile_group < fade_c[7:6] ? 9'd256 :
        tile_group == fade_c[7:6] ? {1'b0,fade_c[5:0],2'b0} : 9'd0;
    function [8:0] feather_alpha;
        input signed [12:0] distance;
        begin
            if (distance <= 0) feather_alpha = 9'd0;
            else if (distance >= 64) feather_alpha = 9'd256;
            else feather_alpha = {1'b0,distance[5:0],2'b00};
        end
    endfunction
    reg [8:0] transition_gain;
    always @* begin
        if (FADE_ENABLE == 0 || fade_c >= 256) transition_gain = 9'd256;
        else if (fade_c == 0) transition_gain = 9'd0;
        else begin
            case (effect_c)
                3'd1: transition_gain = feather_alpha(box_distance);
                3'd2: transition_gain = blind_gain;
                3'd3: transition_gain = feather_alpha(diagonal_distance);
                3'd4: transition_gain = tile_gain;
                default: transition_gain = fade_c;
            endcase
        end
    end
    wire [17:0] combined_product = brightness_gain * transition_gain;
    wire [8:0] effective_gain = combined_product[16:8];
    function [7:0] scale_channel;
        input [7:0] value;
        input [8:0] gain;
        reg [16:0] product;
        begin product = value * gain; scale_channel = product[15:8]; end
    endfunction
    wire [23:0] scaled_image = {scale_channel(contrast_pixel[23:16],effective_gain),
                                scale_channel(contrast_pixel[15:8],effective_gain),
                                scale_channel(contrast_pixel[7:0],effective_gain)};
    wire [23:0] faded = scaled_image;

    // 102x28 footprint, 14px right / 12px top. No rectangular backdrop.
    localparam integer HUD_X = X_ACTIVE-116;
    // All labels use the existing 5%-unit digit formatter; VOL is 10% steps.
    wire [5:0] hud_level = active_mode == MODE_VOL ? {1'b0,active_volume,1'b0} :
                            active_mode == MODE_CON ? active_contrast : {1'b0,active_level};
    wire [7:0] percent = {2'b0,hud_level} + {hud_level,2'b00};
    wire [6:0] bar_percent = active_mode == MODE_CON ? percent[7:1] : percent[6:0];
    wire [10:0] text_x = x - (HUD_X+18);
    wire [9:0] text_y = y - 10'd12;
    wire in_text = de_c && x >= HUD_X+18 && x < HUD_X+82 && y >= 12 && y < 28;
    wire [10:0] shadow_x = x - (HUD_X+19);
    wire [9:0] shadow_y = y - 10'd13;
    wire in_shadow = de_c && x >= HUD_X+19 && x < HUD_X+83 && y >= 13 && y < 29;
    function [7:0] hud_character;
        input [2:0] char_index;
        input [5:0] level;
        input [1:0] display_mode;
        reg [5:0] remainder;
        begin
            remainder = level >= 40 ? level-40 : level >= 20 ? level-20 : level;
            case (char_index)
                0: hud_character=display_mode == MODE_VOL ? "V" : display_mode == MODE_CON ? "C" : "B";
                1: hud_character=display_mode == MODE_BRI ? "R" : "O";
                2: hud_character=display_mode == MODE_VOL ? "L" : display_mode == MODE_CON ? "N" : "I";
                3: hud_character=" ";
                4: hud_character=level >= 40 ? "2" : level >= 20 ? "1" : " ";
                5: hud_character=8'h30 + {3'b0,remainder[5:1]};
                6: hud_character=level[0] ? "5" : "0";
                default: hud_character="%";
            endcase
        end
    endfunction
    // FONT_BEGIN: original standard VGA 8x16 ASCII, shared CJK ROM unchanged.
    function [7:0] parameter_font_row;
        input [7:0] ascii;
        input [3:0] row;
        reg [127:0] glyph;
        begin
            case (ascii)
                8'h42: glyph = 128'h0000FC6666667C66666666FC00000000; // B
                8'h52: glyph = 128'h0000FC6666667C6C666666E600000000; // R
                8'h49: glyph = 128'h00003C18181818181818183C00000000; // I
                8'h43: glyph = 128'h00003C66C2C0C0C0C0C2663C00000000; // C
                8'h4f: glyph = 128'h00007CC6C6C6C6C6C6C6C67C00000000; // O
                8'h4e: glyph = 128'h0000C6E6F6FEDECEC6C6C6C600000000; // N
                8'h56: glyph = 128'h0000C6C6C6C6C6C6C66C381000000000; // V
                8'h4c: glyph = 128'h0000F06060606060606266FE00000000; // L
                8'h30: glyph = 128'h0000386CC6C6D6D6C6C66C3800000000; // 0
                8'h31: glyph = 128'h00001838781818181818187E00000000; // 1
                8'h32: glyph = 128'h00007CC6060C183060C0C6FE00000000; // 2
                8'h33: glyph = 128'h00007CC606063C060606C67C00000000; // 3
                8'h34: glyph = 128'h00000C1C3C6CCCFE0C0C0C1E00000000; // 4
                8'h35: glyph = 128'h0000FEC0C0C0FC060606C67C00000000; // 5
                8'h36: glyph = 128'h00003860C0C0FCC6C6C6C67C00000000; // 6
                8'h37: glyph = 128'h0000FEC606060C183030303000000000; // 7
                8'h38: glyph = 128'h00007CC6C6C67CC6C6C6C67C00000000; // 8
                8'h39: glyph = 128'h00007CC6C6C67E0606060C7800000000; // 9
                8'h25: glyph = 128'h0000000000C6CC183060C60000000000; // %
                default: glyph = 128'd0;
            endcase
            parameter_font_row = glyph[127-row*8 -: 8];
        end
    endfunction
    // FONT_END
    // Predict the existing raster/VS snapshot register updates. RAM reads on
    // that same edge, so the original glyph pixel and shadow retain latency.
    wire [10:0] font_x_next=(!de_c||x==X_ACTIVE-1) ? 11'd0 : x+11'd1;
    wire [9:0] font_y_next=frame_start ? 10'd0 :
        (de_c&&x==X_ACTIVE-1 ? (y==Y_ACTIVE-1 ? 10'd0 : y+10'd1) : y);
    // Parameter snapshots change in vertical blanking; text starts at row12.
    // The active snapshot settles well before the first visible glyph.
    wire [1:0] font_mode_next=active_mode;
    wire [4:0] font_level_next=active_level;
    wire [5:0] font_contrast_next=active_contrast;
    wire [3:0] font_volume_next=active_volume;
    wire [5:0] font_hud_level=font_mode_next==MODE_VOL ? {1'b0,font_volume_next,1'b0} : font_mode_next==MODE_CON ? font_contrast_next : {1'b0,font_level_next};
    wire [10:0] font_tx=font_x_next-(HUD_X+18),font_sx=font_x_next-(HUD_X+19);
    wire [9:0] font_ty=font_y_next-10'd12,font_sy=font_y_next-10'd13;
    wire [11:0] font_a={hud_character(font_tx[5:3],font_hud_level,font_mode_next),font_ty[3:0]};
    wire [11:0] font_b={hud_character(font_sx[5:3],font_hud_level,font_mode_next),font_sy[3:0]};
    wire [7:0] glyph_row,shadow_row;
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(8),.ADDR_WIDTH_A(12),.DATA_DEPTH_A(4096),
      .DATA_WIDTH_B(8),.ADDR_WIDTH_B(12),.DATA_DEPTH_B(4096),.MODE("DP"),
      .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
      .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE(FONT_FILE),.FILL_ALL("NONE"))u_parameter_font(
      .dia(8'd0),.dib(8'd0),.addra(font_a),.addrb(font_b),
      .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(I_clk),.clkb(I_clk),
      .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(glyph_row),.dob(shadow_row));
    wire text_pixel = in_text && glyph_row[7-text_x[2:0]];
    wire shadow_pixel = in_shadow && shadow_row[7-shadow_x[2:0]];
    wire bar_border = de_c && x >= HUD_X && x < HUD_X+102 && y >= 32 && y < 40 &&
                      (x == HUD_X || x == HUD_X+101 || y == 32 || y == 39);
    wire bar_fill = de_c && x >= HUD_X+1 && x < HUD_X+1+bar_percent && y >= 33 && y < 39;
    wire [23:0] mixed = !hud_active ? faded :
                        (text_pixel || bar_border) ? 24'hFFFFFF :
                        bar_fill ? 24'h35D9E8 : shadow_pixel ? 24'h202830 : faded;
    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin O_de <= 0; O_vs <= 0; O_data <= 0; end
        else begin O_de <= de_c; O_vs <= vs_c; O_data <= de_c ? mixed : 24'd0; end
    end
endmodule
