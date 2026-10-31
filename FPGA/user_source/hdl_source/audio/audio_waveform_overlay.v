// Post-volume mono PCM analysis: one triggered scope and eight real octave bands.
// The existing stereo port interface and two complete RGB/DE/VS stages remain.
module audio_waveform_overlay #(
 parameter integer CLK_FREQ_HZ=25000000,X_ACTIVE=640,Y_ACTIVE=480,AUTO_WAIT_SAMPLES=960
)(input I_clk,I_rst,I_enable_async,input I_audio_valid,input [23:0] I_left,I_right,
 input [3:0] I_volume_level,input I_de,I_vs,input [23:0] I_data,
 output reg O_de,O_vs,output reg [23:0] O_data,output O_frame_enable);
localparam DB_CYCLES=CLK_FREQ_HZ/50,DB_BITS=DB_CYCLES>1    ?    $clog2(DB_CYCLES):1;
localparam WAIT_BITS=AUTO_WAIT_SAMPLES>1    ?    $clog2(AUTO_WAIT_SAMPLES):1;
(* syn_preserve=1,async_reg="true" *)reg [1:0] enable_sync;
reg enable_stable,active_enable;reg [DB_BITS-1:0] enable_count;
reg vs_d;wire frame_start=I_vs&&!vs_d;reg [9:0] x;reg [8:0] y;
assign O_frame_enable=active_enable;
reg [3:0] display_volume;
always @(posedge I_clk or posedge I_rst)begin
 if(I_rst)display_volume<=10;else if(frame_start)display_volume<=I_volume_level;
end
reg capture_bank,display_bank,pending_valid,display_valid,capturing,trigger_armed;
reg capture_triggered,display_triggered;reg [WAIT_BITS-1:0] wait_samples;
reg [7:0] capture_index;reg [5:0] previous_left;
reg [11:0] trace_ram[0:511];reg [11:0] trace_q;
wire [10:0] plot_column=x-11'd32;
wire [23:0] magnitude=I_left[23]    ?    (~I_left+24'd1):I_left;
(* dsp_style="yes" *)wire [28:0] position_product=magnitude*5'd27;
wire [29:0] rounded_position=({1'b0,position_product}+30'd1048576)>>21;
wire [5:0] offset=rounded_position>27    ?    6'd27:rounded_position[5:0];
wire [5:0] position=I_left[23] ? 6'd27+offset:6'd27-offset;
wire rising_cross=trigger_armed&&$signed(I_left)>=24'sd32768;
wire start_capture=I_audio_valid&&!pending_valid&&!capturing&&(rising_cross||wait_samples==AUTO_WAIT_SAMPLES-1);
wire capture_write=!I_rst&&I_audio_valid&&!pending_valid&&(capturing||start_capture);
always @(posedge I_clk)begin
 if(capture_write)trace_ram[{capture_bank,capture_index}]<={capture_index==0    ?    position:previous_left,position};
 trace_q<=trace_ram[{display_bank,plot_column[7:0]}];
end
always @(posedge I_clk or posedge I_rst)begin
 if(I_rst)begin
  enable_sync<=0;enable_stable<=0;active_enable<=0;enable_count<=0;vs_d<=0;x<=0;y<=0;
  capture_bank<=1;display_bank<=0;pending_valid<=0;display_valid<=0;capturing<=0;trigger_armed<=0;
  capture_triggered<=0;display_triggered<=0;wait_samples<=0;capture_index<=0;previous_left<=27;
 end else begin
  enable_sync<={enable_sync[0],I_enable_async};
  if(enable_sync[1]!=enable_stable)begin
   if(enable_count==DB_CYCLES-1)begin enable_stable<=enable_sync[1];enable_count<=0;end
   else enable_count<=enable_count+1'b1;
  end else enable_count<=0;
  vs_d<=I_vs;
  if(!I_de||x==X_ACTIVE-1)x<=0;else x<=x+1'b1;
  if(frame_start)begin
   y<=0;active_enable<=enable_stable;
   if(pending_valid)begin
    display_bank<=capture_bank;display_valid<=1;display_triggered<=capture_triggered;
    capture_bank<=~capture_bank;pending_valid<=0;capture_index<=0;capturing<=0;trigger_armed<=0;wait_samples<=0;
   end
  end else if(I_de&&x==X_ACTIVE-1)y<=y==Y_ACTIVE-1    ?    10'd0:y+1'b1;
  if(I_audio_valid&&!pending_valid&&!capturing)begin
   if(start_capture)begin capturing<=1;capture_triggered<=rising_cross;trigger_armed<=0;wait_samples<=0;end
   else begin if($signed(I_left)<=-24'sd32768)trigger_armed<=1;wait_samples<=wait_samples+1'b1;end
  end
  if(capture_write)begin
   previous_left<=position;
   if(capture_index==255)begin pending_valid<=1;capturing<=0;end else capture_index<=capture_index+1'b1;
  end
 end
end
function [7:0] released;input [7:0] current,held;
 begin released=current>=held||held<=2    ?    current:current>held-8'd2    ?    current:held-8'd2;end endfunction
wire [24:0] rounded_peak={1'b0,magnitude}+25'd32768;
wire [7:0] peak_sample=rounded_peak[23:16];
reg [7:0] peak_acc,meter;reg window_seen,window_nonzero,display_pcm_seen,display_muted;
wire window_muted=window_seen&&I_volume_level==0&&!window_nonzero;
always @(posedge I_clk or posedge I_rst)begin
 if(I_rst)begin peak_acc<=0;meter<=0;window_seen<=0;window_nonzero<=0;display_pcm_seen<=0;display_muted<=0;end
 else if(frame_start)begin
  meter<=window_muted    ?    8'd0:released(peak_acc,meter);display_pcm_seen<=window_seen;display_muted<=window_muted;
  peak_acc<=I_audio_valid    ?    peak_sample:8'd0;window_seen<=I_audio_valid;window_nonzero<=I_audio_valid&&I_left!=0;
 end else if(I_audio_valid)begin
  if(peak_sample>peak_acc)peak_acc<=peak_sample;window_seen<=1;if(I_left!=0)window_nonzero<=1;
 end
end
wire [5:0] band_height;
audio_spectrum_bands u_bands(.clk(I_clk),.rst(I_rst),.valid(I_audio_valid),.sample(I_left[23:8]),
 .frame_tick(frame_start),.read_band(plot_column[7:5]),.height_value(band_height),.mute(I_volume_level==0));
// Geometry, trace/font read and metadata align in stage1; stage2 blends RGB.
reg [23:0] bg_d;reg de_d,vs_meta,enabled_d,trace_valid_d,muted_d;
reg [9:0] x_d;reg [8:0] y_d;reg [7:0] meter_d;
always @(posedge I_clk or posedge I_rst)begin
 if(I_rst)begin bg_d<=0;de_d<=0;vs_meta<=0;enabled_d<=0;trace_valid_d<=0;muted_d<=0;x_d<=0;y_d<=0;meter_d<=0;end
 else begin
  bg_d<=I_data;de_d<=I_de;vs_meta<=I_vs;enabled_d<=active_enable;trace_valid_d<=display_valid;muted_d<=display_muted;
  x_d<=x;y_d<=y;meter_d<=meter;
 end
end
function segment;input [5:0] p,a,b;reg [5:0] lo,hi;
 begin lo=a<=b ? a:b;hi=a<=b ? b:a;segment=p+6'd1>=lo&&p<=hi+6'd1;end endfunction
wire panel=de_d&&x_d>=16&&x_d<304&&y_d>=12&&y_d<216;
wire border=panel&&(x_d==16||x_d==303||y_d==12||y_d==215);
wire plot=panel&&x_d>=32&&x_d<288;
wire lane=plot&&y_d>=42&&y_d<=96;
wire [5:0] ly=y_d[5:0]-6'd42;
wire trace=lane&&(trace_valid_d&&!muted_d    ?    segment(ly,trace_q[11:6],trace_q[5:0]):ly>=26&&ly<=28);
wire [10:0] band_x=x_d-11'd32;
wire [2:0] bar_index=band_x[7:5];
wire [5:0] bar_height=band_height;
wire bar_region=plot&&y_d>=126&&y_d<174;
wire [5:0] bar_y=6'd45-y_d[5:0];
wire bar_body=bar_region&&band_x[4:0]>=6&&band_x[4:0]<26&&bar_y<bar_height;
wire bar_cap=bar_body&&bar_y+6'd2>=bar_height;
wire bar_grid=bar_region&&(y_d==126||y_d==142||y_d==158||y_d==173);
wire [8:0] meter_width={1'b0,meter_d}+{3'd0,meter_d[7:2]};
wire [10:0] meter_x=x_d-11'd64;
wire meter_track=panel&&x_d>=64&&x_d<224&&y_d>=103&&y_d<109;
wire meter_fill=meter_track&&meter_x<meter_width&&meter_x[3:0]!=15;
wire baseline=lane&&y_d==69;
wire grid=lane&&x_d[4:0]==0&&y_d[1:0]==0;
wire separator=panel&&(y_d==38||y_d==116||y_d==194);
function [6:0] percent;input [7:0] v;reg [15:0] wide;
 begin wide=v;percent=((wide<<4)+(wide<<3)+wide+16'd16)>>5;end endfunction
function [4:0] percent_slot;input [1:0] i;input [6:0] p;reg [3:0] tens,ones;
 begin
  tens=p>=90    ?    9:p>=80    ?    8:p>=70    ?    7:p>=60    ?    6:p>=50    ?    5:p>=40    ?    4:p>=30    ?    3:p>=20    ?    2:p>=10    ?    1:0;
  ones=p-tens*4'd10;
  case(i)0:percent_slot=p==100    ?    1:23;1:percent_slot=p==100    ?    0:tens==0    ?    23:{1'b0,tens};
   2:percent_slot=p==100    ?    0:{1'b0,ones};default:percent_slot=11;endcase
 end
endfunction
function [4:0] volume_slot;input [1:0] i;input [3:0] level;
 begin case(i)
  0:volume_slot=level>=10 ? 1:23;
  1:volume_slot=level>=10 ? 0:level==0 ? 23:{1'b0,level};
  2:volume_slot=0;default:volume_slot=11;
 endcase end
endfunction
function [4:0] frequency_slot;input [2:0] b;input [1:0] c;
 begin
  case(b)
   0:case(c)0:frequency_slot=1;1:frequency_slot=2;2:frequency_slot=5;default:frequency_slot=23;endcase
   1:case(c)0:frequency_slot=2;1:frequency_slot=5;2:frequency_slot=0;default:frequency_slot=23;endcase
   2:case(c)0:frequency_slot=5;1,2:frequency_slot=0;default:frequency_slot=23;endcase
   7:case(c)0:frequency_slot=1;1:frequency_slot=6;2:frequency_slot=14;default:frequency_slot=23;endcase
   default:case(c)0:frequency_slot=b==3    ?    1:b==4    ?    2:b==5    ?    4:8;1:frequency_slot=14;default:frequency_slot=23;endcase
  endcase
 end
endfunction
reg [8:0] font_address;reg [3:0] font_column;reg [2:0] text_color;
reg [4:0] slot;reg [3:0] text_row;reg [5:0] tx;reg chinese;wire [7:0] frequency_x=x[7:0]-8'd32;
always @*begin
 slot=23;text_row=0;tx=0;chinese=0;text_color=0;
 if(y>=18&&y<34)begin
  text_row=y-10'd18;
  if(x>=24&&x<88)begin
   tx=x-11'd24;slot={3'd0,tx[5:4]};chinese=1;text_color=1;
  end else if(x>=104&&x<168)begin
   text_color=4;
   if(x<136)begin tx=x-11'd104;slot=tx[4] ? 5'd14:5'd13;chinese=1;end
   else begin tx=x-11'd136;slot=volume_slot(tx[4:3],display_volume);end
  end else if(x>=232&&x<248)begin
   tx=x-11'd232;slot=tx[3] ? 5'd4:5'd19;text_color=4;
  end else if(y>=20&&y<32&&x>=256&&x<288)begin
   tx=x-11'd256;slot=(display_triggered&&display_pcm_seen&&!display_muted) ? 5'd4:5'd6;
   slot=slot+{4'd0,tx[4]};text_row=y-10'd20;chinese=1;text_color=4;
  end
 end else if(y>=98&&y<114)begin
  text_row=y-10'd98;
  if(x>=24&&x<56)begin tx=x-11'd24;slot=tx[4]    ?    5'd9:5'd8;chinese=1;text_color=2;end
  else if(x>=232&&x<264)begin tx=x-11'd232;slot=percent_slot(tx[4:3],percent(meter));text_color=2;end
  else if(x>=272&&x<288)begin tx=x-11'd272;slot=tx[3]    ?    5'd13:5'd12;text_color=4;end
 end else if(y>=176&&y<192&&x>=32&&x<288)begin
  tx=x-11'd32;slot=frequency_slot(frequency_x[7:5],frequency_x[4:3]);text_row=y-10'd176;text_color=4;
 end else if(y>=198&&y<214)begin
  text_row=y-10'd198;
  if(x>=24&&x<72)begin
   tx=x-11'd24;text_color=4;
   case(tx[5:3])0:slot=5;1:slot=10;2,3:slot=3;4:slot=17;default:slot=18;endcase
  end else if(x>=112&&x<152)begin
   tx=x-11'd112;text_color=4;
   case(tx[5:3])0:slot=4;1:slot=8;2:slot=14;3:slot=15;default:slot=16;endcase
  end else if(x>=208&&x<272)begin
   tx=x-11'd208;text_color=4;
   case(tx[5:3])0:slot=20;1:slot=21;2:slot=22;3:slot=2;4:slot=5;5:slot=11;6:slot=12;default:slot=13;endcase
  end
 end
 if(chinese)begin font_address={slot[3:0],text_row};font_column=tx[3:0];end
 else begin font_address={1'b1,slot[4:1],text_row};font_column={slot[0],tx[2:0]};end
end
reg [15:0] panel_font[0:511];reg [15:0] font_q;
initial $readmemb("audio_panel_font.dat",panel_font);
reg [3:0] column_d;reg [2:0] color_d;
always @(posedge I_clk)begin font_q<=panel_font[font_address];column_d<=font_column;color_d<=text_color;end
wire text_pixel=color_d!=0&&font_q[15-column_d];
wire [3:0] palette=text_pixel&&color_d==1  ?  4'd1:
 trace||meter_fill||(text_pixel&&color_d==2)  ?  4'd2:
 bar_cap  ?  4'd1:bar_body  ?  (bar_index<3  ?  4'd2:bar_index<6  ?  4'd3:4'd4):
 text_pixel  ?  4'd5:border||(bar_region&&y_d==126)  ?  4'd6:baseline  ?  4'd7:separator  ?  4'd8:
 grid||bar_grid  ?  4'd9:meter_track  ?  4'd10:y_d<38  ?  4'd11:lane||bar_region  ?  4'd12:4'd13;
function [23:0] palette_rgb;input [3:0] c;
 begin case(c)
  1:palette_rgb=24'hE9F1F7;2:palette_rgb=24'h35D9E8;3:palette_rgb=24'h60C9BD;4:palette_rgb=24'hFFBC58;
  5:palette_rgb=24'h94ACBD;6:palette_rgb=24'h35556F;7:palette_rgb=24'h3B586F;8:palette_rgb=24'h203747;
  9:palette_rgb=24'h182C3E;10:palette_rgb=24'h152E40;11:palette_rgb=24'h142B40;12:palette_rgb=24'h0D1D2C;
  default:palette_rgb=24'h0B1724;
 endcase end
endfunction
wire [23:0] mixed=enabled_d&&panel  ?  palette_rgb(palette):bg_d;
always @(posedge I_clk or posedge I_rst)begin
 if(I_rst)begin O_de<=0;O_vs<=0;O_data<=0;end
 else begin O_de<=de_d;O_vs<=vs_meta;O_data<=de_d    ?    mixed:24'd0;end
end
endmodule

// Eight-level dyadic Haar bank: true post-VOL PCM, nominal125..16kHz.
// Each pair yields average/detail; averages feed the next octave. Each bar
// uses mean absolute detail over1024 samples, with a fixed amplitude scale.
// 12-bit analysis saves logic; output PCM is untouched. No per-track normalization.
module audio_spectrum_bands(input clk,rst,valid,input signed[15:0]sample,
 input frame_tick,input [2:0]read_band,output [5:0]height_value,input mute);
localparam INIT=0,IDLE=1,RD0=2,RD1=3,RD2=4,RD3=5,RD4=6,RD5=7,CALC=8,W_LO=9,W_HI=10,W_HEIGHT=11,W_PREV_LO=12,W_PREV_HI=13,W_CACHE=14,RD6=15,W_TOP=16;
reg[4:0]state;reg[2:0]band;reg[9:0]count;wire block_last=count==1023;
reg signed[11:0]value,detail;reg[20:0]peak;
reg[5:0]old_height;reg pending_valid,capture_bank,display_bank,write_bank,display_valid,frame_muted;
function [5:0] height;input [16:0] amplitude;
 begin
  if(amplitude>=8192)height=48;
  else if(amplitude>=4096)height=32+{2'd0,amplitude[11:8]};
  else if(amplitude>=2048)height=24+{3'd0,amplitude[10:8]};
  else if(amplitude>=1024)height=16+{3'd0,amplitude[9:7]};
  else if(amplitude>=512)height=12+{4'd0,amplitude[8:7]};
  else if(amplitude>=256)height=8+{4'd0,amplitude[7:6]};
  else if(amplitude>=128)height=4+{4'd0,amplitude[6:5]};
  else if(amplitude>=16)height=1+{4'd0,amplitude[6:5]};
  else height=0;
 end
endfunction
// Exact divide by the number of decimated detail samples in a1024-sample block.
// Band0 has512 terms, band7 has4. Slicing keeps every band's amplitude comparable.
// DSP multiplication by a one-hot coefficient implements the octave normalization.
// The exact mathematical result is unchanged; use spare DSP capacity instead of LUT muxes.
wire[7:0] octave_gain=8'd1<<band;
(* dsp_style="yes" *)wire[28:0] normalized_sum=peak*octave_gain;
wire[11:0]detail_abs=detail[11] ? -detail:detail;
wire[11:0]mean_value=normalized_sum[20:9];
wire[5:0]current_height=height({1'b0,mean_value,4'b0});
wire[5:0]falling=old_height>2   ?   old_height-6'd2:6'd0;
wire[5:0]envelope=current_height==0   ?   6'd0:current_height>=old_height   ?   current_height:current_height>falling   ?   current_height:falling;
wire signed[11:0]previous={ram_q[3:0],peak[7:0]};
wire signed[12:0]sum_pair=$signed({value[11],value})+$signed({previous[11],previous});
wire signed[12:0]diff_pair=$signed({value[11],value})-$signed({previous[11],previous});
reg[9:0]address;reg[7:0]write_data;reg write_enable;wire[7:0]ram_q,display_q;
wire[9:0]display_address={6'b000100,display_bank,read_band};
assign height_value=display_valid&&!frame_muted  ?  display_q[5:0]:6'd0;
always @*begin
 address={4'd0,band,3'd0};write_data=0;write_enable=0;
 case(state)
  INIT:begin address={4'd0,count[5:0]};write_enable=1;end
  RD1:address={4'd0,band,3'd1};
  RD2:address={4'd0,band,3'd2};
  RD3:address={4'd0,band,3'd3};
  RD4:address={4'd0,band,3'd4};
  RD5,RD6,CALC:address={4'd0,band,3'd5};
  W_PREV_LO:begin write_data=value[7:0];write_enable=1;end
  W_PREV_HI:begin address={4'd0,band,3'd1};write_data={4'd0,value[11:8]};write_enable=1;end
  W_LO:begin address={4'd0,band,3'd2};write_data=block_last   ?   8'd0:peak[7:0];write_enable=1;end
  W_HI:begin address={4'd0,band,3'd3};write_data=block_last ? 8'd0:peak[15:8];write_enable=1;end
  W_TOP:begin address={4'd0,band,3'd4};write_data=block_last ? 8'd0:{3'd0,peak[20:16]};write_enable=1;end
  W_HEIGHT:begin address={4'd0,band,3'd5};write_data={2'd0,old_height};write_enable=1;end
  W_CACHE:begin address={6'b000100,write_bank,~band};write_data={2'd0,old_height};write_enable=1;end
 endcase
end
EG_LOGIC_BRAM #(.DATA_WIDTH_A(8),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
 .DATA_WIDTH_B(8),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),.MODE("DP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("9K"),.WRITEMODE_A("WRITETHROUGH"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("NONE"),.FILL_ALL("NONE"))u_state(
 .dia(write_data),.dib(8'd0),.addra(address),.addrb(display_address),.cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),
 .clka(clk),.clkb(clk),.wea(write_enable&&!rst),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(ram_q),.dob(display_q));
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=INIT;band<=0;count<=0;value<=0;detail<=0;
  peak<=0;old_height<=0;pending_valid<=0;capture_bank<=1;display_bank<=0;write_bank<=1;display_valid<=0;frame_muted<=0;
 end else begin
  if(frame_tick)begin
   frame_muted<=mute;
   if(pending_valid)begin display_bank<=capture_bank;capture_bank<=~capture_bank;display_valid<=1;pending_valid<=0;end
  end
  case(state)
   INIT:if(count==63)begin state<=IDLE;count<=0;end else count<=count+1'b1;
   IDLE:if(valid)begin value<=sample[15:4];if(count==1023)begin pending_valid<=0;write_bank<=(frame_tick&&pending_valid) ? ~capture_bank:capture_bank;end band<=0;state<=RD0;end
   RD0:state<=RD1;
   RD1:if(!count[band])state<=W_PREV_LO;else begin peak[7:0]<=ram_q;state<=RD2;end
   RD2:begin value<=sum_pair>>>1;detail<=diff_pair>>>1;state<=RD3;end
   RD3:begin peak[7:0]<=ram_q;state<=RD4;end
   RD4:begin peak[15:8]<=ram_q;state<=RD5;end
   RD5:begin peak[20:16]<=ram_q[4:0];state<=RD6;end
   RD6:begin old_height<=ram_q[5:0];state<=CALC;end
   CALC:begin peak<=peak+{9'd0,detail_abs};state<=W_LO;end
   W_LO:begin old_height<=envelope;state<=W_HI;end
   W_HI:state<=W_TOP;
   W_TOP:if(block_last)state<=W_HEIGHT;
        else if(band==7)begin state<=IDLE;count<=count+1'b1;end else begin band<=band+1'b1;state<=RD0;end
   W_HEIGHT:state<=W_CACHE;
   W_CACHE:begin
    if(band==7)begin pending_valid<=1;state<=IDLE;count<=count+1'b1;end
    else begin band<=band+1'b1;state<=RD0;end
   end
   W_PREV_LO:state<=W_PREV_HI;
   W_PREV_HI:begin state<=IDLE;count<=count+1'b1;end
   default:state<=INIT;
  endcase
 end
end
endmodule
