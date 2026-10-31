// Compact right card with native GDI pixels and power-of-two text cells.
module video_med_reminder #(parameter X_ACTIVE=640,Y_ACTIVE=480,SCENE_SYNC=0)(
 input clk,rst,input [2:0] medicine,input [1:0] medicine_name,
 input [15:0] alert_time,input [19:0] dose,input [1:0] unit,
 input scene_ready,input active,plan_ready,plan_valid,input [2:0] plan_status,input time_valid,
 input I_de,I_vs,input [23:0] I_data,output reg O_de,O_vs,output reg [23:0] O_data
);
reg vs_d,de_d;reg [9:0] x;reg [$clog2(Y_ACTIVE)-1:0] y;wire [9:0] px=de_d?x:10'd0;
wire frame=I_vs&&!vs_d;
reg [2:0] mode,med;reg [1:0] name_sel,un;reg [15:0] tm;reg [19:0] qty;reg [8:0] startup_frames;
wire [7:0] cx=px[7:0]-8'd224;
// The original raster already advances y on DE falling. Fetch its next-row
// descriptor on that same blank cycle, before the next row's first pixel.
wire [8:0] row_fetch=frame?9'd0:(!I_de&&de_d&&y<Y_ACTIVE-1?y+1'b1:y);
wire [15:0] row_info;wire [2:0] row_kind=row_info[13:11];
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),.MODE("SP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("reminder_card_rows.dat"),.FILL_ALL("NONE"))u_rows(
 .dia(16'd0),.dib(16'd0),.addra({1'b0,mode==4,row_fetch}),.addrb(11'd0),
 .cea(1'b1),.ceb(1'b0),.ocea(1'b1),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(row_info),.dob());
wire region=I_de&&mode!=0&&px>=480&&px<629&&row_info[10];
wire [9:0] skin_group=row_info[9:0]+{7'd0,cx[7:5]};
wire [14:0] skin_addr={skin_group,cx[4:0]};
wire [15:0] skin_data0,skin_data1;reg skin_bank_q;reg [2:0] skin_sub_q;
wire [15:0] skin_word=skin_bank_q?skin_data1:skin_data0;
wire [1:0] skin_q=skin_word>>{skin_sub_q,1'b0};
reg [3:0] foreground,foreground_q;
always @*begin
 foreground=mode==1||mode==2?4:3;
 if(cx>=6&&cx<142)case(row_kind)
  1:foreground=cx<32&&y[3:0]>px[3:0]?7:6;
  4:foreground=8;6:foreground=5;7:foreground=9;
  default:foreground=mode==1||mode==2?4:3;
 endcase
end
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),.MODE("SP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("reminder_card_skin0.dat"),.FILL_ALL("NONE"))u_skin0(
 .dia(16'd0),.dib(16'd0),.addra(skin_addr[13:3]),.addrb(11'd0),
 .cea(1'b1),.ceb(1'b0),.ocea(1'b1),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(skin_data0),.dob());
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),.MODE("SP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("reminder_card_skin1.dat"),.FILL_ALL("NONE"))u_skin1(
 .dia(16'd0),.dib(16'd0),.addra(skin_addr[13:3]),.addrb(11'd0),
 .cea(1'b1),.ceb(1'b0),.ocea(1'b1),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(skin_data1),.dob());

reg [10:0] font_addr;reg [3:0] font_bit,character;reg [1:0] error_name,unit_name;
reg text_pixel;reg [1:0] shade,shade_q;
always @*begin
 font_addr={1'b0,name_sel,y[4:0],px[6:4]};font_bit=~px[3:0];character=0;text_pixel=0;shade=0;error_name=mode[1:0]-2'd1;unit_name=0;
 case(row_kind)
  3:begin font_addr={2'b11,error_name,y[3:0],px[6:4]};text_pixel=px>=496&&px<576;shade=3;end
  2:begin text_pixel=px>=496&&px<616;end
  4:begin
    case(px[6:4])
     2:character=tm[15:12];3:character=tm[11:8];4:character=10;
     5:character=tm[7:4];6:character=tm[3:0];default:character=0;
    endcase
    font_addr={1'b0,character[3:2],2'b11,character[1:0],y[3:0]};text_pixel=px>=544&&px<624;shade=2;
    // Native12px index in the unused fourth status bank, aligned with the16px time.
    if(px>=520&&px<532&&y>=242&&y<254&&med>=1&&med<=4)begin
     font_addr=11'd1920+{4'd0,med-3'd1,4'd0}+{7'd0,y[3:0]-4'd2};
     font_bit=4'd15-(px-10'd520);text_pixel=1;
    end
   end
  5:begin
    if(px<592)begin
     case(px[6:4])
      7:character=qty[19:16];0:character=qty[15:12];1:character=qty[11:8];
      2:character=10;3:character=qty[7:4];4:character=qty[3:0];default:character=0;
     endcase
     font_addr={2'b10,character,y[4:0]};text_pixel=px>=496&&!(px[6:4]==7&&qty[19:16]==0)&&!(px[6:4]==0&&qty[19:12]==0);shade=1;
    end else begin
     unit_name=un==0?0:(un==1?1:(px[6:4]==6?3:2));
     font_addr={4'b1011,unit_name,y[4:0]};text_pixel=px<(un==2?10'd624:10'd608)&&y[4:0]<19;shade=1;
    end
   end
  default:;
 endcase
end
wire [15:0] font_q;
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
 .DATA_WIDTH_B(16),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),.MODE("SP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("reminder_card_font.dat"),.FILL_ALL("NONE"))u_font(
 .dia(16'd0),.dib(16'd0),.addra(font_addr),.addrb(11'd0),
 .cea(1'b1),.ceb(1'b0),.ocea(1'b1),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(font_q),.dob());
reg [23:0] rgb_q;reg de_q,vs_q,region_q,text_q;reg [3:0] bit_q;
wire [3:0] font_palette=shade_q==0?4'd7:(shade_q==1?4'd10:(shade_q==2?4'd11:4'd12));
wire [3:0] base_palette=skin_q==1?4'd1:(skin_q==2?4'd2:(skin_q==3?foreground_q:4'd0));
wire [3:0] pixel_palette=!region_q?4'd0:(text_q&&font_q[bit_q]?font_palette:base_palette);
always @(posedge clk or posedge rst)begin
 if(rst)begin
  vs_d<=0;de_d<=0;x<=0;y<=0;mode<=0;med<=0;name_sel<=0;tm<=0;qty<=0;un<=0;startup_frames<=0;
  rgb_q<=0;de_q<=0;vs_q<=0;region_q<=0;text_q<=0;bit_q<=0;skin_bank_q<=0;skin_sub_q<=0;foreground_q<=0;shade_q<=0;
  O_de<=0;O_vs<=0;O_data<=0;
 end else begin
  vs_d<=I_vs;de_d<=I_de;
  if(frame)begin
   x<=0;y<=0;
   // First alert is immediate. Later cards retain their coherent old snapshot
   // through preloading; publish the next medicine only after scene completion.
   if(!SCENE_SYNC||mode!=4||!active||scene_ready)begin
    med<=medicine;name_sel<=medicine_name;tm<=alert_time;qty<=dose;un<=unit;
   end
   if(plan_ready&&startup_frames<300)startup_frames<=startup_frames+1'b1;
   if(plan_ready&&!plan_valid)mode<=plan_status==3?3:1;
   else if(plan_ready&&plan_valid&&!time_valid)mode<=2;
   else if(active)mode<=4;
   else if(plan_ready&&plan_status==2&&startup_frames<300)mode<=3;
   else mode<=0;
  end else if(I_de)x<=px+1'b1;
  else if(de_d)begin x<=0;if(y<Y_ACTIVE-1)y<=y+1'b1;end
  rgb_q<=I_data;de_q<=I_de;vs_q<=I_vs;region_q<=region;text_q<=text_pixel;bit_q<=font_bit;
  skin_bank_q<=skin_addr[14];skin_sub_q<=skin_addr[2:0];foreground_q<=foreground;shade_q<=shade;
  O_de<=de_q;O_vs<=vs_q;
  case(pixel_palette)
   1:O_data<={1'b0,rgb_q[23:17],1'b0,rgb_q[15:9],1'b0,rgb_q[7:1]};
   2:O_data<=24'h153d38;
   3:O_data<=24'h6ddfc0;4:O_data<=24'hd6ad60;5:O_data<=24'h4e8e7a;
   6:O_data<=24'h9ee3cb;7:O_data<=24'hf1f8f4;8:O_data<=24'hc4d8d1;9:O_data<=24'ha6c8ba;
   10:O_data<=24'hf5d986;11:O_data<=24'hb5f4d5;12:O_data<=24'hffd080;
   default:O_data<=rgb_q;
  endcase
 end
end
endmodule
