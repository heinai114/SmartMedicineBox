// Original native GDI16 weekday pixels are read from a dual-port ROM.
// Foreground/shadow use the existing two-stage RGB/DE/VS path; no row caches.
module video_rtc_overlay #(parameter integer X_ACTIVE=640,Y_ACTIVE=480,ENABLE_TEMPERATURE=1,
    ENABLE_TEMP_HINT=0,HINT_SHOW_FRAMES=300,parameter TEMP_FONT_FILE="temperature_font.dat")(
    input clk,rst, input [23:0] time_bcd,date_bcd,
    input [2:0] weekday, input time_valid,waveform_frame_enable,
    input [19:0] temperature_bcd,input temperature_negative,temperature_valid,
    input hint_blocked,
    input I_de,I_vs, input [23:0] I_data,
    output reg O_de,O_vs, output reg [23:0] O_data
);
reg vs_d,de_d;
reg [9:0] x,y;
wire [9:0] px=!de_d?10'd0:x;
wire frame_tick=I_vs&&!vs_d;
wire [1:0] hint_kind;
generate if(ENABLE_TEMP_HINT)begin:g_temperature_hint
    temperature_hint_control #(.SHOW_FRAMES(HINT_SHOW_FRAMES)) u_control(
        .clk(clk),.rst(rst),.frame_tick(frame_tick),.temperature_bcd(temperature_bcd),
        .temperature_negative(temperature_negative),.temperature_valid(temperature_valid),
        .blocked(hint_blocked),.visible_kind(hint_kind));
end else begin:g_no_temperature_hint
    assign hint_kind=2'd0;
end endgenerate
reg [23:0] shown_time,shown_date;
reg [2:0] shown_weekday;
reg shown_valid,shown_wave;
reg [19:0] shown_temperature;
reg shown_temperature_negative,shown_temperature_valid;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        vs_d<=0;de_d<=0;x<=0;y<=0;
        shown_time<=0;shown_date<=0;shown_weekday<=0;shown_valid<=0;shown_wave<=0;
        shown_temperature<=0;shown_temperature_negative<=0;shown_temperature_valid<=0;
    end else begin
        vs_d<=I_vs;de_d<=I_de;
        if(frame_tick) begin
            x<=0;y<=0;shown_time<=time_bcd;shown_date<=date_bcd;shown_weekday<=weekday;
            shown_valid<=time_valid;shown_wave<=waveform_frame_enable;
            shown_temperature<=temperature_bcd;shown_temperature_negative<=temperature_negative;
            shown_temperature_valid<=temperature_valid;
        end else if(I_de) x<=px+1'b1;
        else if(de_d) begin x<=0;if(y<Y_ACTIVE-1)y<=y+1'b1;end
    end
end
function [7:0] digit_row;
    input [3:0] digit,row;
    begin case({digit,row})
            8'h02: digit_row=8'h38;
            8'h03: digit_row=8'h6C;
            8'h04: digit_row=8'hC6;
            8'h05: digit_row=8'hC6;
            8'h06: digit_row=8'hD6;
            8'h07: digit_row=8'hD6;
            8'h08: digit_row=8'hC6;
            8'h09: digit_row=8'hC6;
            8'h0A: digit_row=8'h6C;
            8'h0B: digit_row=8'h38;
            8'h12: digit_row=8'h18;
            8'h13: digit_row=8'h38;
            8'h14: digit_row=8'h78;
            8'h15: digit_row=8'h18;
            8'h16: digit_row=8'h18;
            8'h17: digit_row=8'h18;
            8'h18: digit_row=8'h18;
            8'h19: digit_row=8'h18;
            8'h1A: digit_row=8'h18;
            8'h1B: digit_row=8'h7E;
            8'h22: digit_row=8'h7C;
            8'h23: digit_row=8'hC6;
            8'h24: digit_row=8'h06;
            8'h25: digit_row=8'h0C;
            8'h26: digit_row=8'h18;
            8'h27: digit_row=8'h30;
            8'h28: digit_row=8'h60;
            8'h29: digit_row=8'hC0;
            8'h2A: digit_row=8'hC6;
            8'h2B: digit_row=8'hFE;
            8'h32: digit_row=8'h7C;
            8'h33: digit_row=8'hC6;
            8'h34: digit_row=8'h06;
            8'h35: digit_row=8'h06;
            8'h36: digit_row=8'h3C;
            8'h37: digit_row=8'h06;
            8'h38: digit_row=8'h06;
            8'h39: digit_row=8'h06;
            8'h3A: digit_row=8'hC6;
            8'h3B: digit_row=8'h7C;
            8'h42: digit_row=8'h0C;
            8'h43: digit_row=8'h1C;
            8'h44: digit_row=8'h3C;
            8'h45: digit_row=8'h6C;
            8'h46: digit_row=8'hCC;
            8'h47: digit_row=8'hFE;
            8'h48: digit_row=8'h0C;
            8'h49: digit_row=8'h0C;
            8'h4A: digit_row=8'h0C;
            8'h4B: digit_row=8'h1E;
            8'h52: digit_row=8'hFE;
            8'h53: digit_row=8'hC0;
            8'h54: digit_row=8'hC0;
            8'h55: digit_row=8'hC0;
            8'h56: digit_row=8'hFC;
            8'h57: digit_row=8'h06;
            8'h58: digit_row=8'h06;
            8'h59: digit_row=8'h06;
            8'h5A: digit_row=8'hC6;
            8'h5B: digit_row=8'h7C;
            8'h62: digit_row=8'h38;
            8'h63: digit_row=8'h60;
            8'h64: digit_row=8'hC0;
            8'h65: digit_row=8'hC0;
            8'h66: digit_row=8'hFC;
            8'h67: digit_row=8'hC6;
            8'h68: digit_row=8'hC6;
            8'h69: digit_row=8'hC6;
            8'h6A: digit_row=8'hC6;
            8'h6B: digit_row=8'h7C;
            8'h72: digit_row=8'hFE;
            8'h73: digit_row=8'hC6;
            8'h74: digit_row=8'h06;
            8'h75: digit_row=8'h06;
            8'h76: digit_row=8'h0C;
            8'h77: digit_row=8'h18;
            8'h78: digit_row=8'h30;
            8'h79: digit_row=8'h30;
            8'h7A: digit_row=8'h30;
            8'h7B: digit_row=8'h30;
            8'h82: digit_row=8'h7C;
            8'h83: digit_row=8'hC6;
            8'h84: digit_row=8'hC6;
            8'h85: digit_row=8'hC6;
            8'h86: digit_row=8'h7C;
            8'h87: digit_row=8'hC6;
            8'h88: digit_row=8'hC6;
            8'h89: digit_row=8'hC6;
            8'h8A: digit_row=8'hC6;
            8'h8B: digit_row=8'h7C;
            8'h92: digit_row=8'h7C;
            8'h93: digit_row=8'hC6;
            8'h94: digit_row=8'hC6;
            8'h95: digit_row=8'hC6;
            8'h96: digit_row=8'h7E;
            8'h97: digit_row=8'h06;
            8'h98: digit_row=8'h06;
            8'h99: digit_row=8'h06;
            8'h9A: digit_row=8'h0C;
            8'h9B: digit_row=8'h78;
        default:digit_row=0;
    endcase end
endfunction
// Slot order: Star, Period, Sunday, One, Two, Three, Four, Five, Six.
function [5:0] week_index;
    input [3:0] glyph;input [3:0] row;
    begin case({glyph,row})
            8'd1: week_index=6'd1;
            8'd2: week_index=6'd2;
            8'd3: week_index=6'd1;
            8'd4: week_index=6'd2;
            8'd5: week_index=6'd1;
            8'd7: week_index=6'd3;
            8'd8: week_index=6'd4;
            8'd9: week_index=6'd5;
            8'd10: week_index=6'd6;
            8'd11: week_index=6'd1;
            8'd12: week_index=6'd7;
            8'd13: week_index=6'd8;
            8'd14: week_index=6'd8;
            8'd17: week_index=6'd9;
            8'd18: week_index=6'd10;
            8'd19: week_index=6'd11;
            8'd20: week_index=6'd12;
            8'd21: week_index=6'd13;
            8'd22: week_index=6'd12;
            8'd23: week_index=6'd14;
            8'd24: week_index=6'd10;
            8'd25: week_index=6'd11;
            8'd26: week_index=6'd15;
            8'd27: week_index=6'd16;
            8'd28: week_index=6'd17;
            8'd29: week_index=6'd18;
            8'd33: week_index=6'd1;
            8'd34: week_index=6'd1;
            8'd35: week_index=6'd19;
            8'd36: week_index=6'd19;
            8'd37: week_index=6'd19;
            8'd38: week_index=6'd19;
            8'd39: week_index=6'd1;
            8'd40: week_index=6'd19;
            8'd41: week_index=6'd19;
            8'd42: week_index=6'd19;
            8'd43: week_index=6'd19;
            8'd44: week_index=6'd1;
            8'd45: week_index=6'd1;
            8'd46: week_index=6'd19;
            8'd55: week_index=6'd8;
            8'd56: week_index=6'd8;
            8'd67: week_index=6'd20;
            8'd75: week_index=6'd8;
            8'd76: week_index=6'd8;
            8'd82: week_index=6'd4;
            8'd86: week_index=6'd1;
            8'd87: week_index=6'd1;
            8'd92: week_index=6'd8;
            8'd97: week_index=6'd8;
            8'd98: week_index=6'd21;
            8'd99: week_index=6'd21;
            8'd100: week_index=6'd21;
            8'd101: week_index=6'd22;
            8'd102: week_index=6'd23;
            8'd103: week_index=6'd23;
            8'd104: week_index=6'd24;
            8'd105: week_index=6'd25;
            8'd106: week_index=6'd26;
            8'd107: week_index=6'd26;
            8'd108: week_index=6'd26;
            8'd109: week_index=6'd8;
            8'd110: week_index=6'd26;
            8'd113: week_index=6'd4;
            8'd114: week_index=6'd4;
            8'd115: week_index=6'd27;
            8'd116: week_index=6'd28;
            8'd117: week_index=6'd28;
            8'd118: week_index=6'd29;
            8'd119: week_index=6'd30;
            8'd120: week_index=6'd30;
            8'd121: week_index=6'd30;
            8'd122: week_index=6'd30;
            8'd123: week_index=6'd31;
            8'd124: week_index=6'd8;
            8'd125: week_index=6'd32;
            8'd129: week_index=6'd28;
            8'd130: week_index=6'd7;
            8'd131: week_index=6'd33;
            8'd132: week_index=6'd8;
            8'd133: week_index=6'd8;
            8'd135: week_index=6'd34;
            8'd136: week_index=6'd35;
            8'd137: week_index=6'd36;
            8'd138: week_index=6'd37;
            8'd139: week_index=6'd38;
            8'd140: week_index=6'd39;
            8'd141: week_index=6'd40;
        default:week_index=0;
    endcase end
endfunction
function [15:0] week_row;
    input [5:0] index;
    begin case(index)
            6'd1: week_row=16'h1FF8;
            6'd2: week_row=16'h1008;
            6'd3: week_row=16'h1980;
            6'd4: week_row=16'h3FFC;
            6'd5: week_row=16'h2180;
            6'd6: week_row=16'h4180;
            6'd7: week_row=16'h0180;
            6'd8: week_row=16'h7FFE;
            6'd9: week_row=16'h2200;
            6'd10: week_row=16'h227C;
            6'd11: week_row=16'h7F44;
            6'd12: week_row=16'h2244;
            6'd13: week_row=16'h3E7C;
            6'd14: week_row=16'h3E44;
            6'd15: week_row=16'h0044;
            6'd16: week_row=16'h26C4;
            6'd17: week_row=16'h6384;
            6'd18: week_row=16'h418C;
            6'd19: week_row=16'h1808;
            6'd20: week_row=16'h3FF8;
            6'd21: week_row=16'h4242;
            6'd22: week_row=16'h4642;
            6'd23: week_row=16'h4442;
            6'd24: week_row=16'h4C6A;
            6'd25: week_row=16'h587A;
            6'd26: week_row=16'h4002;
            6'd27: week_row=16'h0100;
            6'd28: week_row=16'h0300;
            6'd29: week_row=16'h1FF0;
            6'd30: week_row=16'h0210;
            6'd31: week_row=16'h0610;
            6'd32: week_row=16'h4000;
            6'd33: week_row=16'h0080;
            6'd34: week_row=16'h0420;
            6'd35: week_row=16'h0630;
            6'd36: week_row=16'h0C30;
            6'd37: week_row=16'h0818;
            6'd38: week_row=16'h180C;
            6'd39: week_row=16'h3004;
            6'd40: week_row=16'h2004;
        default:week_row=0;
    endcase end
endfunction
wire [3:0] day_glyph=shown_weekday>=1&&shown_weekday<=7?{1'b0,shown_weekday}+4'd1:4'd15;
reg [3:0] fetch_glyph;
always @* begin
    case(px[1:0])
        0:fetch_glyph=0;
        1:fetch_glyph=1;
        default:fetch_glyph=day_glyph;
    endcase
end
function [10:0] weekday_address;
    input [9:0] xx,yy;
    reg [9:0] dx,dy;reg [3:0] glyph;
    begin
        glyph=15;dx=xx-10'd104;dy=yy-10'd32;
        if(xx>=104&&xx<152&&yy>=32&&yy<48)begin
            case(dx[5:4])
                0:glyph=0;
                1:glyph=1;
                default:glyph=day_glyph;
            endcase
        end
        weekday_address={3'd0,glyph,dy[3:0]};
    end
endfunction
wire [9:0] cjk_shadow_x=px-10'd1,cjk_shadow_y=y-10'd1;
wire [9:0] cjk_dx=px-10'd104,cjk_shadow_dx=cjk_shadow_x-10'd104;
wire [15:0] weekday_foreground_q,weekday_shadow_q;
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),
 .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .INIT_FILE("weekday_font.dat"),.FILL_ALL("NONE")) u_weekday_font(
 .dia(16'd0),.dib(16'd0),.addra(weekday_address(px,y)),.addrb(weekday_address(cjk_shadow_x,cjk_shadow_y)),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(clk),.clkb(clk),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),
 .doa(weekday_foreground_q),.dob(weekday_shadow_q));
reg [3:0] weekday_col_d,weekday_shadow_col_d;
reg weekday_region_d,weekday_shadow_region_d;
always @(posedge clk)begin
 weekday_col_d<=cjk_dx[3:0];weekday_shadow_col_d<=cjk_shadow_dx[3:0];
end
always @(posedge clk or posedge rst)begin
 if(rst)begin weekday_region_d<=0;weekday_shadow_region_d<=0;end
 else begin
  weekday_region_d<=px>=104&&px<152&&y>=32&&y<48&&(px<136||shown_valid);
  weekday_shadow_region_d<=px!=0&&y!=0&&cjk_shadow_x>=104&&cjk_shadow_x<152&&
   cjk_shadow_y>=32&&cjk_shadow_y<48&&(cjk_shadow_x<136||shown_valid);
 end
end
wire weekday_ink=weekday_region_d&&weekday_foreground_q[15-weekday_col_d];
wire weekday_shadow_ink=weekday_shadow_region_d&&weekday_shadow_q[15-weekday_shadow_col_d];
function [3:0] time_digit;
    input [2:0] slot;
    begin case(slot)
        0:time_digit=shown_time[23:20];1:time_digit=shown_time[19:16];
        3:time_digit=shown_time[15:12];4:time_digit=shown_time[11:8];
        6:time_digit=shown_time[7:4];7:time_digit=shown_time[3:0];
        default:time_digit=15;
    endcase end
endfunction
function [3:0] date_digit;
    input [3:0] slot;
    begin case(slot)
        0:date_digit=2;1:date_digit=0;2:date_digit=shown_date[23:20];3:date_digit=shown_date[19:16];
        5:date_digit=shown_date[15:12];6:date_digit=shown_date[11:8];
        8:date_digit=shown_date[7:4];9:date_digit=shown_date[3:0];
        default:date_digit=15;
    endcase end
endfunction
// Foreground and one-pixel lower-right black shadow. Outside actual strokes
// the original input RGB passes through, including the former solid panel.
function ascii_pixel;
    input [9:0] xx,yy;
    reg [9:0] dx,dy;reg [3:0] slot,digit;reg colon,dash;reg [7:0] bits;
    begin
        ascii_pixel=0;dx=0;dy=0;slot=0;digit=15;colon=0;dash=0;
        if(xx>=16&&xx<80&&yy>=12&&yy<28) begin
            dx=xx-16;dy=yy-12;slot={1'b0,dx[5:3]};digit=time_digit(slot[2:0]);
            colon=slot==2||slot==5;dash=!shown_valid;
            if(colon) ascii_pixel=(dy[3:0]==5||dy[3:0]==6||dy[3:0]==10||dy[3:0]==11)&&dx[2:0]>=3&&dx[2:0]<=4;
            else if(dash) ascii_pixel=(dy[3:0]==7||dy[3:0]==8)&&dx[2:0]>=1&&dx[2:0]<=6;
            else ascii_pixel=0;
        end else if(xx>=16&&xx<96&&yy>=32&&yy<48) begin
            dx=xx-16;dy=yy-32;slot=dx[6:3];digit=date_digit(slot);
            dash=slot==4||slot==7||!shown_valid;
            if(dash) ascii_pixel=(dy[3:0]==7||dy[3:0]==8)&&dx[2:0]>=1&&dx[2:0]<=6;
            else ascii_pixel=0;
        end
    end
endfunction
// Invalid weekday keeps the original two-row dash; valid glyphs use ROM.
function cjk_pixel;
    input [9:0] xx,yy;input is_shadow;
    reg [9:0] dx,dy;
    begin
        dx=xx-10'd136;dy=yy-10'd32;
        cjk_pixel=!shown_valid&&xx>=136&&xx<152&&yy>=32&&yy<48&&
            (dy==7||dy==8)&&dx[3:0]>=4&&dx[3:0]<12;
    end
endfunction
// The existing two video stages also accommodate synchronous dual-port
// glyph reads. Share numeric rows between calendar and temperature; port A
// is foreground, port B is the lower-right shadow. No line-cache copies.
function [3:0] temperature_glyph;
    input [3:0] slot;
    begin
        temperature_glyph=14;
        case(slot)
            0:if(shown_temperature_valid&&shown_temperature_negative)temperature_glyph=13;
            1:if(shown_temperature[19:16]!=0)temperature_glyph=shown_temperature[19:16];
            2:if(shown_temperature[19:12]!=0)temperature_glyph=shown_temperature[15:12];
            3:temperature_glyph=shown_temperature[11:8];
            4:temperature_glyph=10;
            5:temperature_glyph=shown_temperature[7:4];
            6:temperature_glyph=shown_temperature[3:0];
            7:temperature_glyph=11;
            8:temperature_glyph=12;
        endcase
        if(!shown_temperature_valid&&(slot==1||slot==2||slot==3||slot==5||slot==6))temperature_glyph=13;
    end
endfunction
// New 32x32 SimHei glyphs occupy only the unused upper half of the existing
// numeric ROM. Four bytes per row, bit31 on the left. Original bytes stay put.
function hint_text_region;
    input [9:0] xx,yy;
    begin hint_text_region=xx>=472&&xx<600&&((yy>=76&&yy<108)||(yy>=112&&yy<144));end
endfunction
function [3:0] hint_glyph;
    input [2:0] slot;input cold;
    begin
        case(slot)
            0:hint_glyph=0;1:hint_glyph=1;2:hint_glyph=2;
            3:hint_glyph=cold?8:3;
            4:hint_glyph=cold?9:4;5:hint_glyph=cold?10:5;
            6:hint_glyph=cold?11:6;default:hint_glyph=cold?12:7;
        endcase
    end
endfunction
function [11:0] hint_address;
    input [9:0] xx,yy;
    reg [9:0] dx,dy;reg [2:0] slot;
    begin
        dx=xx-10'd472;dy=yy>=112?yy-10'd112:yy-10'd76;
        slot={yy>=112,dx[6:5]};
        hint_address={1'b1,hint_glyph(slot,hint_kind==2),dy[4:0],dx[4:3]};
    end
endfunction
function [11:0] numeric_address;
    input [9:0] xx,yy;
    reg [9:0] dx,dy;reg [3:0] glyph;
    begin
        dx=0;dy=0;glyph=14;
        if(xx>=16&&xx<80&&yy>=12&&yy<28&&shown_valid)begin
            dx=xx-16;dy=yy-12;glyph=time_digit(dx[5:3]);
        end else if(xx>=16&&xx<96&&yy>=32&&yy<48&&shown_valid)begin
            dx=xx-16;dy=yy-32;glyph=date_digit(dx[6:3]);
        end else if(ENABLE_TEMPERATURE&&xx>=88&&xx<160&&yy>=12&&yy<28)begin
            dx=xx-88;dy=yy-12;glyph=temperature_glyph(dx[6:3]);
        end
        numeric_address={4'd0,glyph,dy[3:0]};
        if(ENABLE_TEMP_HINT&&hint_kind!=0&&hint_text_region(xx,yy))numeric_address=hint_address(xx,yy);
    end
endfunction
function numeric_region;
    input [9:0] xx,yy;
    begin numeric_region=(xx>=16&&xx<80&&yy>=12&&yy<28)||
        (xx>=16&&xx<96&&yy>=32&&yy<48)||(ENABLE_TEMPERATURE&&xx>=88&&xx<160&&yy>=12&&yy<28); end
endfunction
wire [9:0] shadow_x=px-10'd1,shadow_y=y-10'd1;
wire [7:0] numeric_foreground_q,numeric_shadow_q;
EG_LOGIC_BRAM #(.DATA_WIDTH_A(8),.ADDR_WIDTH_A(12),.DATA_DEPTH_A(4096),
 .DATA_WIDTH_B(8),.ADDR_WIDTH_B(12),.DATA_DEPTH_B(4096),
 .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .INIT_FILE(TEMP_FONT_FILE),.FILL_ALL("NONE")) u_temperature_font(
 .dia(8'd0),.dib(8'd0),.addra(numeric_address(px,y)),.addrb(numeric_address(shadow_x,shadow_y)),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(clk),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),
 .doa(numeric_foreground_q),.dob(numeric_shadow_q));
reg [2:0] numeric_col_d,shadow_col_d;
reg numeric_region_d,shadow_region_d;
// Region gates and RGB outputs reset; columns are don't-care until that gate
// becomes valid, and have a full preceding clock to settle after any reset.
always @(posedge clk)begin
    numeric_col_d<=px[2:0];shadow_col_d<=shadow_x[2:0];
end
always @(posedge clk or posedge rst)begin
    if(rst)begin numeric_region_d<=0;shadow_region_d<=0;end
    else begin
        numeric_region_d<=numeric_region(px,y);
        shadow_region_d<=px!=0&&y!=0&&numeric_region(shadow_x,shadow_y);
    end
end
wire numeric_ink=numeric_region_d&&numeric_foreground_q[7-numeric_col_d];
wire numeric_shadow_ink=shadow_region_d&&numeric_shadow_q[7-shadow_col_d];
reg hint_box_d,hint_border_d,hint_text_d,hint_shadow_d,hint_cold_d,hint_title_d;
always @(posedge clk or posedge rst)begin
    if(rst)begin
        hint_box_d<=0;hint_border_d<=0;hint_text_d<=0;hint_shadow_d<=0;hint_cold_d<=0;hint_title_d<=0;
    end else begin
        hint_box_d<=ENABLE_TEMP_HINT&&hint_kind!=0&&px>=448&&px<624&&y>=64&&y<156;
        hint_border_d<=px<=449||px==623||y==64||y==155;
        hint_text_d<=ENABLE_TEMP_HINT&&hint_kind!=0&&hint_text_region(px,y);
        hint_shadow_d<=ENABLE_TEMP_HINT&&hint_kind!=0&&px!=0&&y!=0&&hint_text_region(shadow_x,shadow_y);
        hint_cold_d<=hint_kind==2;hint_title_d<=y<112;
    end
end
wire hint_ink=hint_text_d&&numeric_foreground_q[7-numeric_col_d];
wire hint_shadow_ink=hint_shadow_d&&numeric_shadow_q[7-shadow_col_d];
wire [23:0] hint_color=hint_cold_d?24'h71D7FF:24'hFFCA72;
wire foreground=ascii_pixel(px,y)||cjk_pixel(px,y,0);
wire shadow=px!=0&&y!=0&&(ascii_pixel(px-10'd1,y-10'd1)||cjk_pixel(px-10'd1,y-10'd1,1));
wire foreground_valid=ENABLE_TEMPERATURE&&px>=88&&px<160&&y>=12&&y<28?shown_temperature_valid:shown_valid;
reg [23:0] background_d;
reg foreground_d,shadow_d,valid_d,wave_d,de_pipe,vs_pipe;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        O_de<=0;O_vs<=0;O_data<=0;background_d<=0;
        foreground_d<=0;shadow_d<=0;valid_d<=0;wave_d<=0;de_pipe<=0;vs_pipe<=0;
    end
    else begin
        background_d<=I_data;foreground_d<=foreground;shadow_d<=shadow;
        valid_d<=foreground_valid;wave_d<=shown_wave;de_pipe<=I_de;vs_pipe<=I_vs;
        O_de<=de_pipe;O_vs<=vs_pipe;
        O_data<=!de_pipe?24'd0:
            hint_box_d?(hint_ink?(hint_title_d?hint_color:24'hFFFFFF):hint_shadow_ink?24'h080D12:
                hint_border_d?hint_color:{2'b00,background_d[23:18],2'b00,background_d[15:10],2'b00,background_d[7:2]}):
            wave_d?background_d:
            (foreground_d||numeric_ink||weekday_ink)?(valid_d?24'hE9F1F7:24'hFFBC58):(shadow_d||numeric_shadow_ink||weekday_shadow_ink)?24'h080D12:background_d;
    end
end
endmodule
