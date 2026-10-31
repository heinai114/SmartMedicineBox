// Pure-text original BMP resolution HUD. No background rectangle or frame RAM.
// A tiny synchronous dual-read glyph ROM shares one BRAM, avoiding two large
// combinational glyph decoders on a device already close to its MSLICE limit.
// 25 MHz / 800 / 525 = 59.524 Hz: 60-frame hold then 48-frame fade.
// Metadata is a bundled-data CDC: the SD-domain scheduler updates dimensions
// and epoch together ONLY at successful frame commit and holds them throughout
// the next preload and exit/entry sequence (many complete video frames). Data
// has two settling registers; epoch has three, then one detection register.
// It is presentation-only and never feeds back into SD, SDRAM or audio control.
module video_resolution_hud #(
    parameter integer X_ACTIVE=640, Y_ACTIVE=480,
    parameter integer TEXT_X=16, TEXT_Y=440,
    parameter integer HOLD_FRAMES=60, FADE_FRAMES=48
)(
    input I_clk, input I_rst,
    input [11:0] I_width_async, input [11:0] I_height_async,
    input I_epoch_async, input I_image_valid, input I_scene_idle,
    input I_de, input I_vs, input [23:0] I_data,
    output reg O_de, output reg O_vs, output reg [23:0] O_data
);
(* syn_preserve=1, async_reg="true" *) reg [11:0] width_sync0, width_sync1;
(* syn_preserve=1, async_reg="true" *) reg [11:0] height_sync0, height_sync1;
(* syn_preserve=1, async_reg="true" *) reg [2:0] epoch_sync;
reg epoch_seen;
wire metadata_event = epoch_sync[2] != epoch_seen;
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        width_sync0<=0; width_sync1<=0; height_sync0<=0; height_sync1<=0;
        epoch_sync<=0; epoch_seen<=0;
    end else begin
        width_sync0<=I_width_async; width_sync1<=width_sync0;
        height_sync0<=I_height_async; height_sync1<=height_sync0;
        epoch_sync<={epoch_sync[1:0],I_epoch_async};
        epoch_seen<=epoch_sync[2];
    end
end

// Serial double-dabble conversion, 12 clocks for both dimensions in parallel.
// No per-pixel decimal division; alpha uses three small DSP multipliers to
// leave the scarce MSLICE resources available to the original 100 MHz player.
reg [11:0] width_shift, height_shift;
reg [15:0] width_work, height_work, width_bcd, height_bcd;
reg [3:0] convert_left;
reg pending, converted;
function [15:0] bcd_adjust;
    input [15:0] value;
    integer n;
    begin
        for(n=0;n<4;n=n+1)
            bcd_adjust[n*4 +: 4] = value[n*4 +: 4]>=5 ?
                value[n*4 +: 4]+4'd3 : value[n*4 +: 4];
    end
endfunction
wire [15:0] width_adjusted=bcd_adjust(width_work);
wire [15:0] height_adjusted=bcd_adjust(height_work);

reg vs_last, de_last;
reg [9:0] x, y;
wire frame_tick=I_vs && !vs_last;
// Like the existing overlays, DE edges establish active row coordinates.
wire [9:0] pixel_x = !de_last ? 10'd0 : x;
always @(posedge I_clk or posedge I_rst) begin
    if(I_rst) begin vs_last<=0; de_last<=0; x<=0; y<=0; end
    else begin
        vs_last<=I_vs; de_last<=I_de;
        if(frame_tick) begin x<=0; y<=0; end
        else if(I_de) x<=pixel_x+1'b1;
        else if(de_last) begin x<=0; if(y<Y_ACTIVE-1) y<=y+1'b1; end
    end
end

localparam HIDDEN=0, HOLDING=1, FADING=2;
reg [1:0] phase;
reg [7:0] frames_left;
reg [4:0] alpha;
reg [7:0] fade_accum;
reg [15:0] shown_width, shown_height;
function [2:0] digit_count;
    input [15:0] value;
    begin digit_count=value[15:12]!=0 ? 3'd4 : value[11:8]!=0 ? 3'd3 :
                      value[7:4]!=0 ? 3'd2 : 3'd1; end
endfunction
reg [2:0] width_length, height_length;
wire [8:0] next_fade_accum={1'b0,fade_accum}+9'd16;
always @(posedge I_clk or posedge I_rst) begin
    if(I_rst) begin
        width_shift<=0; height_shift<=0; width_work<=0; height_work<=0;
        width_bcd<=0; height_bcd<=0; convert_left<=0; pending<=0; converted<=0;
        phase<=HIDDEN; frames_left<=0; alpha<=0; fade_accum<=0;
        shown_width<=0; shown_height<=0; width_length<=1; height_length<=1;
    end else begin
        if(metadata_event) begin
            width_shift<=width_sync1; height_shift<=height_sync1;
            width_work<=0; height_work<=0; convert_left<=12;
            converted<=0;
            pending<=width_sync1!=0 && width_sync1<=1920 &&
                     height_sync1!=0 && height_sync1<=1080;
            // Commit happens during black/vertical blanking. Even a new image
            // with identical dimensions restarts the cue because epoch changes.
            phase<=HIDDEN; alpha<=0;
        end else if(convert_left!=0) begin
            width_work<={width_adjusted[14:0],width_shift[11]};
            height_work<={height_adjusted[14:0],height_shift[11]};
            width_shift<={width_shift[10:0],1'b0};
            height_shift<={height_shift[10:0],1'b0};
            convert_left<=convert_left-1'b1;
            if(convert_left==1) begin
                width_bcd<={width_adjusted[14:0],width_shift[11]};
                height_bcd<={height_adjusted[14:0],height_shift[11]};
                converted<=1;
            end
        end
        // All visible timer/format changes are at vertical frame boundaries.
        if(frame_tick && !metadata_event) begin
            if(!I_image_valid || !I_scene_idle) begin phase<=HIDDEN; alpha<=0; end
            else if(pending && converted) begin
                shown_width<=width_bcd; shown_height<=height_bcd;
                width_length<=digit_count(width_bcd); height_length<=digit_count(height_bcd);
                pending<=0; phase<=HOLDING; frames_left<=HOLD_FRAMES;
                alpha<=16; fade_accum<=0;
            end else if(phase==HOLDING) begin
                if(frames_left<=1) begin phase<=FADING; frames_left<=FADE_FRAMES; end
                else frames_left<=frames_left-1'b1;
            end else if(phase==FADING) begin
                if(frames_left<=1) begin phase<=HIDDEN; frames_left<=0; alpha<=0; end
                else begin
                    frames_left<=frames_left-1'b1;
                    if(next_fade_accum>=FADE_FRAMES) begin
                        fade_accum<=next_fade_accum-FADE_FRAMES;
                        if(alpha!=0) alpha<=alpha-1'b1;
                    end else fade_accum<=next_fade_accum[7:0];
                end
            end
        end
    end
end

function [3:0] decimal_digit;
    input [15:0] bcd; input [2:0] position;
    begin
        case(position)
            0: decimal_digit=bcd[15:12]; 1: decimal_digit=bcd[11:8];
            2: decimal_digit=bcd[7:4]; 3: decimal_digit=bcd[3:0];
            default: decimal_digit=15;
        endcase
    end
endfunction
function [3:0] character;
    input [3:0] slot;
    reg [3:0] separator_slot,height_start;
    reg [4:0] height_end;
    reg [2:0] width_position,height_position;
    begin
        // Explicit ranges avoid32-bit unsized arithmetic in both pixel/ROM
        // address paths. Positions are modulo8 exactly like decimal_digit's
        // original3-bit argument; the upper bound keeps all5 significant bits.
        separator_slot={1'b0,width_length}+4'd1;
        height_start={1'b0,width_length}+4'd3;
        height_end={1'b0,height_start}+{2'd0,height_length};
        width_position=3'd4-width_length+slot[2:0];
        height_position=3'd4-height_length+slot[2:0]-width_length-3'd3;
        if(slot<width_length) character=decimal_digit(shown_width,width_position);
        else if(slot==separator_slot) character=10;
        else if(slot>=height_start && {1'b0,slot}<height_end)
            character=decimal_digit(shown_height,height_position);
        else character=15;
    end
endfunction
// Standard VGA 8x16 numeric glyphs match the established parameter HUD.
// 256 x 8, slots 0..9 digits, slot 10 multiplication sign, others blank.
reg [7:0] font_mem [0:255];
reg [7:0] text_row_q, shadow_row_q;
initial $readmemh("resolution_font.hex",font_mem);
wire [9:0] tx=pixel_x-TEXT_X, ty=y-TEXT_Y;
wire [9:0] sx=pixel_x-TEXT_X-1, sy=y-TEXT_Y-1;
wire [3:0] text_length=width_length+height_length+4'd3;
wire in_text=I_de && pixel_x>=TEXT_X && tx<{text_length,3'b000} &&
             y>=TEXT_Y && ty<16;
wire in_shadow=I_de && pixel_x>=TEXT_X+1 && sx<{text_length,3'b000} &&
               y>=TEXT_Y+1 && sy<16;
// During an active row pixel_x advances exactly one pixel each clock. The
// shadow at x reads the same glyph that text read at x-1. Cache that nibble
// instead of duplicating the complete variable-length decimal decoder. By
// x=TEXT_X+1 the cache is valid; earlier shadow pixels are outside the region.
wire [3:0] text_character=character(tx[6:3]);
reg [3:0] previous_character;
always @(posedge I_clk)previous_character<=text_character;
wire [7:0] text_address={text_character,ty[3:0]};
wire [7:0] shadow_address={previous_character,sy[3:0]};
// No reset on ROM output registers, preserving BRAM inference.
always @(posedge I_clk) begin
    text_row_q<=font_mem[text_address];
    shadow_row_q<=font_mem[shadow_address];
end
reg [23:0] background_d;
reg de_d, vs_d, in_text_d, in_shadow_d;
reg [2:0] text_bit_d, shadow_bit_d;
wire text_d=in_text_d && text_row_q[7-text_bit_d];
wire shadow_d=in_shadow_d && shadow_row_q[7-shadow_bit_d];
reg [4:0] alpha_d;
// The white and black cases share the same background coefficient.
// white: bg + round((255-bg)*a/16) = round((bg*(16-a)+255*a)/16).
// The opacity/addend is shared across all three8-bit channels; this removes
// their separate input/output multiplexers and white-only feedback adders.
wire [4:0] background_alpha=5'd16-alpha_d;
wire [12:0] foreground_add=text_d?({alpha_d,8'd0}-{8'd0,alpha_d}+13'd8):13'd8;
function [7:0] blend_channel;
    input [7:0] background; input [4:0] opacity; input white;
    reg [12:0] product;
    begin
        product=background*(5'd16-opacity)+(white?({opacity,8'd0}-{8'd0,opacity}):13'd0)+13'd8;
        blend_channel=product[11:4];
    end
endfunction
wire [12:0] red_product=background_d[23:16]*background_alpha+foreground_add;
wire [12:0] green_product=background_d[15:8]*background_alpha+foreground_add;
wire [12:0] blue_product=background_d[7:0]*background_alpha+foreground_add;
always @(posedge I_clk or posedge I_rst) begin
    if(I_rst) begin
        background_d<=0; de_d<=0; vs_d<=0; in_text_d<=0; in_shadow_d<=0; alpha_d<=0;
        text_bit_d<=0; shadow_bit_d<=0;
        O_data<=0; O_de<=0; O_vs<=0;
    end else begin
        background_d<=I_data; de_d<=I_de; vs_d<=I_vs;
        in_text_d<=in_text; in_shadow_d<=in_shadow;
        text_bit_d<=tx[2:0]; shadow_bit_d<=sx[2:0];
        alpha_d<=alpha;
        O_de<=de_d; O_vs<=vs_d;
        if(alpha_d!=0 && (text_d || shadow_d)) begin
            O_data[23:16]<=red_product[11:4];
            O_data[15:8]<=green_product[11:4];
            O_data[7:0]<=blue_product[11:4];
        end else O_data<=background_d;
    end
end
endmodule
