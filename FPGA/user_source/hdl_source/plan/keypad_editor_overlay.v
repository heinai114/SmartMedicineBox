// Fixed-em GDI fonts with shared vertical metrics; narrow baseline decimal.
// Three complete RGB/DE/VS stages and coherent vertical-frame publication.
module keypad_editor_overlay #(parameter TIMED_HINT=0,parameter HINT_CLK_HZ=25_000_000,parameter ROM_FILE="keypad_editor.dat",parameter GEOMETRY_FILE="keypad_geometry.dat",parameter DETAIL_FILE="keypad_detail.dat")(
 input clk,rst,visible,busy,saving,reminder_active,file_available,
 input image_ready,scene_idle,
 input [2:0] error,input [1:0] medicine,slot,input [2:0] digit,
 input [7:0] names,input [35:0] entry,input [2:0] field,
 input I_de,I_vs,input [23:0] I_data,output reg O_de,O_vs,output reg [23:0] O_data
);
localparam [10:0] LARGE_BASE=1152,NAMES_BASE=1856,MESSAGES_BASE=1920,
 LAYOUT_BASE=1536,OPEN_BASE=2016,RANGE_BASE=2020;
localparam [6:0] GLYPH_SPACE=7'd0;
localparam [6:0] GLYPH_ENABLED0=7'd14;
localparam [6:0] GLYPH_ENABLED1=7'd5;
localparam [6:0] GLYPH_DISABLED0=7'd15;
localparam [6:0] GLYPH_DISABLED1=7'd16;
localparam [6:0] GLYPH_TABLET=7'd58;
localparam [6:0] GLYPH_CAPSULE=7'd59;
localparam [6:0] GLYPH_ML0=7'd62;
localparam [6:0] GLYPH_ML1=7'd63;

reg de_d,vs_d;reg [9:0] x;reg [8:0] y;
wire [9:0] px=de_d?x:10'd0;wire frame=I_vs&&!vs_d;
reg shown,busy_q,saving_q,file_q,enabled_q;reg [2:0] error_q,field_q;
reg [1:0] medicine_q,slot_q,name_q,unit_q;reg [4:0] hour_q;reg [5:0] minute_q;reg [19:0] dose_q;
wire [8:0] dx=px-10'd320,dy=y-9'd32;
wire [31:0] gx,gy;
wire [8:0] next_dx=dx+9'd1;
// X is fetched one pixel ahead; Y settles during horizontal blanking. At x0
// both the current/next X and previous/current Y are outside every UI region.
// By x328 all geometry is coherent, without adding a video pipeline cycle.
EG_LOGIC_BRAM #(.DATA_WIDTH_A(32),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
 .DATA_WIDTH_B(32),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),.MODE("DP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE(GEOMETRY_FILE),.FILL_ALL("NONE"))u_geometry(
 .dia(32'd0),.dib(32'd0),.addra({1'b0,next_dx}),.addrb({1'b1,dy}),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(clk),.clkb(clk),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(gx),.dob(gy));
wire panel=shown&&px>=320&&gy[0]&&gx[gy[27:25]];
wire shadow=shown&&px>=320&&gx[6]&&gy[1];
wire hint_window;
generate if(TIMED_HINT)begin:g_timed_hint
 plan_hint_timer #(.CLK_HZ(HINT_CLK_HZ))u_timer(.clk(clk),.rst(rst),.frame_tick(frame),
  .editor_visible(visible),.image_ready(image_ready),.scene_idle(scene_idle),
  .reminder_active(reminder_active),.window_active(hint_window));
end else begin:g_legacy_hint
 assign hint_window=1'b1;
end endgenerate
reg hint_frame;
wire hint_allowed=!TIMED_HINT||(image_ready&&scene_idle&&!visible);
wire opener=hint_frame&&hint_allowed&&!shown&&px>=320&&gx[7]&&gy[2]&&!reminder_active;
wire [4:0] row=gy[24:20];
wire header_band=row==1,time_band=row==9,dose_band=row==11,button_band=row==15;
wire [4:0] col=(dx-9'd8)>>4;
wire [4:0] layout_col=row==5?((dx-9'd16)>>4):col;
wire [9:0] text_px=row==5?px-10'd16:px-10'd8;
wire legacy_format=dose_q[19:16]!=0||dose_q[3:0]!=0;
// The normal dose has advances 16,16,8,16. Keep the decimal narrow while
// keeping all arithmetic, stored quantities and digit selection unchanged.
wire compact_dose=dose_band&&!legacy_format&&px>=440&&px<552;
wire unit_region=dose_band&&(legacy_format?(px>=552&&px<584):(px>=504&&px<536));
wire [3:0] compact_col=px<472?col[3:0]:px<480?4'd9:px<496?4'd10:
 (px>=504&&px<536?(px<520?4'd12:4'd13):4'd0);
wire [3:0] compact_bit=px>=504?~(px-10'd504):px>=480?~px[3:0]:~text_px[3:0];
wire dose_ok=dose_q<=20'h09990&&unit_q<=1&&dose_q[3:0]==0&&
 (!enabled_q||dose_q!=0);
wire [2:0] message=!file_q?3'd6:busy_q?(saving_q?3'd1:3'd7):error_q!=0?error_q:!dose_ok?3'd3:3'd0;
reg [10:0] layout_address;
always @*begin
 // Aligned power-of-two strides use wiring instead of pixel-rate multipliers
 // and carry chains. Columns16..19 contain no text and select the blank word.
 layout_address=layout_col[4]?11'd0:{2'b11,row,layout_col[3:0]};
 if(row==7)layout_address=col[4]?11'd0:{5'd29,name_q,col[3:0]};
 if(compact_dose)layout_address={2'b11,5'd11,compact_col};
 if(row==13)layout_address=11'd0;
 if(row==17&&message!=0)layout_address=MESSAGES_BASE+{message-3'd1,4'd0}+{7'd0,col[3:0]};
 if(row==17&&col>=16)layout_address=11'd0;
 if(opener)layout_address=OPEN_BASE+((px-10'd512)>>4);
end
wire [15:0] descriptor,font_row;
reg [10:0] font_address;reg [6:0] glyph;reg [3:0] number;
reg [3:0] row_d,bit_d;reg [4:0] large_row_d;reg small_valid_d,large_valid_d,tiny_valid_d;
// Carry palette indices through the pixel pipe. Constant RGB triplets do not
// need three wide priority multiplexers and two banks of RGB registers.
reg [23:0] rgb_d;reg [3:0] bg_d,fg_d;reg region_d,text_d,de1,vs1;
wire hundreds=dose_q[19:16]!=0,tens=dose_q[15:12]!=0,has_fraction=dose_q[7:0]!=0;
function [3:0] dose_character;
 input [2:0] position;reg [3:0] decimal_point,tenths,hundredths;
 begin
  decimal_point=has_fraction?4'd11:4'd15;
  tenths=has_fraction?dose_q[7:4]:4'd15;
  hundredths=dose_q[3:0]!=0?dose_q[3:0]:4'd15;
  // New quantities always keep two integer digits and one fractional digit.
  // Unsupported old quantities remain truthful until explicitly edited.
  if(!legacy_format)case(position)
   0:dose_character=dose_q[15:12];1:dose_character=dose_q[11:8];
   2:dose_character=4'd11;3:dose_character=dose_q[7:4];default:dose_character=4'd15;
  endcase
  else case(position)
   0:dose_character=hundreds?dose_q[19:16]:tens?dose_q[15:12]:dose_q[11:8];
   1:dose_character=hundreds?dose_q[15:12]:tens?dose_q[11:8]:decimal_point;
   2:dose_character=hundreds?dose_q[11:8]:tens?decimal_point:tenths;
   3:dose_character=hundreds?decimal_point:tens?tenths:hundredths;
   4:dose_character=hundreds?tenths:tens?hundredths:4'd15;
   5:dose_character=hundreds?hundredths:4'd15;
   default:dose_character=4'd15;
  endcase
 end
endfunction
always @*begin
 glyph=descriptor[6:0];number=15;
 case(descriptor[15:12])
  1:number=hour_q>=20?2:hour_q>=10?1:0;
  2:number=hour_q>=20?hour_q-20:hour_q>=10?hour_q-10:hour_q;
  3:number=minute_q/10;
  4:number=minute_q%10;
  5:number=dose_character(descriptor[2:0]);
  6:glyph=enabled_q?(descriptor[0]?GLYPH_ENABLED1:GLYPH_ENABLED0):(descriptor[0]?GLYPH_DISABLED1:GLYPH_DISABLED0);
  7:begin
   glyph=unit_q==0?(descriptor[0]?GLYPH_SPACE:GLYPH_TABLET):unit_q==1?(descriptor[0]?GLYPH_SPACE:GLYPH_CAPSULE):(descriptor[0]?GLYPH_ML1:GLYPH_ML0);
   if(descriptor[1]!=legacy_format)glyph=GLYPH_SPACE;
  end
  8:number=10;
  10:if(legacy_format)number=dose_character(3'd5);
    else glyph=unit_q==0?GLYPH_TABLET:unit_q==1?GLYPH_CAPSULE:GLYPH_ML0;
  default:;
 endcase
 font_address=small_valid_d?{glyph,row_d}:11'd0;
 if((descriptor[15:12]>=1&&descriptor[15:12]<=5)||descriptor[15:12]==8||(descriptor[15:12]==10&&legacy_format))
  font_address=large_valid_d&&number<12?{6'd36+{2'd0,number},large_row_d}:11'd0;
 if(descriptor[15:12]==9)font_address=tiny_valid_d?{4'b1000,descriptor[2:0],row_d}:11'd0;
end
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),.MODE("DP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE(ROM_FILE),.FILL_ALL("NONE"))u_ui(
 .dia(16'd0),.dib(16'd0),.addra(font_address),.addrb(layout_address),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(clk),.clkb(clk),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(font_row),.dob(descriptor));
// Pre-rendered native title/status/range tiles occupy one additional32K ROM.
// Address and selection join the existing three-stage complete video pipe.
wire title_text=panel&&header_band&&px>=344&&px<424&&y>=40&&y<64;
wire opener_title=opener&&px>=520&&px<600&&y>=444&&y<468;
wire range_text=panel&&row==13&&px>=344&&px<440&&unit_q<2;
wire status_text=panel&&row==13&&px>=488&&px<616;
wire detail_text=title_text||opener_title||range_text||status_text;
wire [9:0] detail_x=opener_title?px-10'd520:title_text||range_text?px-10'd344:px-10'd488;
wire [8:0] detail_y=opener_title?y-9'd444:title_text?y-9'd40:y-9'd288;
reg [10:0] detail_address;reg [10:0] detail_address_d;reg detail_d,detail2;
always @*begin
 detail_address=11'd0;
 if(title_text||opener_title)detail_address=11'd1280+{3'd0,detail_x[6:4],detail_y[4:0]};
 if(range_text)detail_address=11'd1024+{3'd0,unit_q[0],7'd0}+{4'd0,detail_x[6:4],detail_y[3:0]};
 if(status_text)detail_address={1'b0,message,7'd0}+{4'd0,detail_x[6:4],detail_y[3:0]};
end
wire [15:0] detail_row;
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),.MODE("DP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE(DETAIL_FILE),.FILL_ALL("NONE"))u_detail(
 .dia(16'd0),.dib(16'd0),.addra(detail_address_d),.addrb(11'd0),
 .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(clk),.clkb(clk),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(detail_row),.dob());
reg [3:0] background,foreground;
wire drug_tab=gy[4]&&gx[9],slot_tab=gy[5]&&gx[9];
wire chosen_drug=gx[19:18]==medicine_q,chosen_slot=gx[19:18]==slot_q;
wire time_box=gx[12]&&time_band,dose_box=gx[12]&&dose_band;
wire time_border=time_box&&(gx[13]||gy[11]);
wire dose_border=dose_box&&(gx[13]||gy[12]);
wire field_x=(field_q==0&&gx[14])||(field_q==1&&gx[15]);
wire time_focus=gy[13]&&field_x;
wire dose_field_x=(field_q==2&&gx[29])||(field_q==3&&gx[30])||(field_q==4&&gx[31]);
always @*begin
 background=4'd1;foreground=4'd0;
 if(shadow)background=4'd0;
 if(panel)begin
  background=4'd2;foreground=4'd1;
  if(gy[3])begin background=4'd3;foreground=4'd2;end
  if(drug_tab)begin background=chosen_drug?4'd4:4'd5;foreground=chosen_drug?4'd2:4'd3;end
  if(slot_tab)begin background=chosen_slot?4'd6:4'd7;foreground=chosen_slot?4'd4:4'd5;end
  if(gy[6]||(gy[7]&&gx[10]))background=4'd8;
  if(gy[8]&&gx[11])begin background=enabled_q?4'd9:4'd10;foreground=enabled_q?4'd6:4'd7;end
  if(time_box||dose_box)background=4'd11;
  if(time_border||dose_border)background=4'd8;
  if(time_focus)background=4'd12;
  if(time_box&&gy[14]&&field_x)background=4'd13;
  if(dose_box&&!legacy_format&&dose_field_x)begin
   if(gy[29])background=4'd12;
   if(gy[30])background=4'd13;
  end
  if(button_band&&gx[17])begin background=gx[16]?4'd15:4'd1;foreground=gx[16]?4'd8:4'd2;end
  if((row==7||row==9||row==11)&&col<4)foreground=4'd9;
  if(row==13)foreground=px<472?4'd10:message==0?4'd13:message==1||message==7?4'd11:4'd12;
  if(row==17)foreground=message==0?4'd13:message==1?4'd11:4'd12;
  if(row==19)foreground=4'd13;
 end
end
reg [23:0] rgb2;reg [3:0] bg2,fg2;reg region2,text2,de2,vs2;reg [3:0] bit2;
wire ink=text2&&(detail2?detail_row[bit2]:font_row[bit2]);
wire [4:0] color=ink?{1'b1,fg2}:{1'b0,bg2};
reg [23:0] color_rgb;
always @*begin
 case(color)
  0:color_rgb={1'b0,rgb2[23:17],1'b0,rgb2[15:9],1'b0,rgb2[7:1]};
  1:color_rgb=24'h23785a;2:color_rgb=24'hf8faf9;3:color_rgb=24'h164b3d;
  4:color_rgb=24'h267257;5:color_rgb=24'hebf1ed;6:color_rgb=24'hd9ece0;
  7:color_rgb=24'hf0f5f1;8:color_rgb=24'hdce7e1;9:color_rgb=24'he0f0e5;
  10:color_rgb=24'he9eeeb;11:color_rgb=24'hffffff;12:color_rgb=24'he6f4ec;
  13:color_rgb=24'h2d8a68;14:color_rgb=24'hecf7f0;15:color_rgb=24'he7eeea;
  16:color_rgb=24'hf7fcf9;17:color_rgb=24'h24463b;18:color_rgb=24'hffffff;
  19:color_rgb=24'h5c7468;20:color_rgb=24'h236b4d;21:color_rgb=24'h6e8277;
  22:color_rgb=24'h36734e;23:color_rgb=24'h829087;24:color_rgb=24'h587064;
  25:color_rgb=24'h5c7468;26:color_rgb=24'h6e8277;27:color_rgb=24'h39805b;
  28:color_rgb=24'had5337;29:color_rgb=24'h6e8277;
  default:color_rgb=24'hffffff;
 endcase
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  hint_frame<=0;de_d<=0;vs_d<=0;x<=0;y<=0;shown<=0;busy_q<=0;saving_q<=0;file_q<=0;enabled_q<=0;error_q<=0;field_q<=0;
  medicine_q<=0;slot_q<=0;name_q<=0;unit_q<=0;hour_q<=0;minute_q<=0;dose_q<=0;
  row_d<=0;large_row_d<=0;small_valid_d<=0;large_valid_d<=0;tiny_valid_d<=0;bit_d<=0;rgb_d<=0;bg_d<=0;fg_d<=0;region_d<=0;text_d<=0;de1<=0;vs1<=0;
  detail_address_d<=0;detail_d<=0;detail2<=0;
  rgb2<=0;bg2<=0;fg2<=0;region2<=0;text2<=0;de2<=0;vs2<=0;bit2<=0;O_data<=0;O_de<=0;O_vs<=0;
 end else begin
  de_d<=I_de;vs_d<=I_vs;
  if(frame)begin
   hint_frame<=hint_window;x<=0;y<=0;shown<=visible&&!reminder_active;busy_q<=busy;saving_q<=saving;file_q<=file_available;
   enabled_q<=entry[33];error_q<=error;field_q<=field;medicine_q<=medicine;slot_q<=slot;
   name_q<=medicine;unit_q<=2'd0;hour_q<=entry[32:28];minute_q<=entry[27:22];dose_q<=entry[21:2];
  end else begin if(I_de)x<=px+1'b1;else x<=0;if(!I_de&&de_d&&y<479)y<=y+1'b1;end
  row_d<=opener?y[3:0]:unit_region?y-9'd255:{gy[16],gy[15],gy[10],gy[9]};
  small_valid_d<=unit_region?(y>=255&&y<271):opener||gy[17];
  large_row_d<=time_band?y-198:y-250;
  large_valid_d<=gy[19];
  tiny_valid_d<=gy[28]&&gx[28];
  bit_d<=opener?~(px-10'd520):compact_dose?compact_bit:~text_px[3:0];rgb_d<=I_data;bg_d<=background;fg_d<=foreground;
  detail_address_d<=detail_address;detail_d<=detail_text;detail2<=detail_d;
  region_d<=I_de&&(panel||shadow||opener);text_d<=I_de&&(panel||opener_title);de1<=I_de;vs1<=I_vs;
  rgb2<=rgb_d;bg2<=bg_d;fg2<=fg_d;region2<=region_d;text2<=text_d;bit2<=bit_d;de2<=de1;vs2<=vs1;
  O_data<=region2?color_rgb:rgb2;O_de<=de2;O_vs<=vs2;
 end
end
endmodule

// Display-only timer counts the existing 800x525 video frames at25MHz.
// Ceil(30*25000000/420000)=1786 frames,30.0048seconds. No pixel-rate
// 30-bit divider is needed; the visible interval is accurate to one frame.
// Boot and an editor close
// queue one window; wait for a usable, idle picture before starting it.
// Suppression does not pause/restart the elapsed-time counter. No image
// epoch or picture index is used, so ordinary browsing cannot retrigger it.
module plan_hint_timer #(parameter CLK_HZ=25_000_000,parameter SECONDS=30,parameter FRAME_CYCLES=420000)(
 input clk,rst,frame_tick,editor_visible,image_ready,scene_idle,reminder_active,
 output window_active
);
localparam TOTAL_FRAMES=(CLK_HZ*SECONDS+FRAME_CYCLES-1)/FRAME_CYCLES;
localparam COUNT_BITS=$clog2(TOTAL_FRAMES+1);
reg [COUNT_BITS-1:0] remaining;
reg pending;
assign window_active=remaining!=0;
always @(posedge clk or posedge rst)begin
 if(rst)begin remaining<=0;pending<=1;end
 else begin
  if(editor_visible)begin remaining<=0;pending<=1;end
  else if(frame_tick&&pending&&image_ready&&scene_idle&&!reminder_active)begin
   remaining<=TOTAL_FRAMES;pending<=0;
  end else if(frame_tick&&remaining!=0)remaining<=remaining-1'b1;
 end
end
endmodule
