// Original 32px glyphs plus a one-pixel 3x3 black outline.
// Rasterize the binary mask one pixel/right and one row/down in advance.
// Two mask bits per column retain the previous two rows in one small BRAM.
// All RGB/DE/VS outputs retain their original five-clock latency.
module video_scene_caption #(parameter INDEX_FILE="third_font_index.hex",parameter ROWS_FILE="third_font_rows.hex",parameter VISIBILITY_CONTROL=0)(
 input clk,input rst,input I_de,input I_vs,input [23:0] I_data,input I_hide_async,
 input [4:0] scenes,input test_mode,input [4:0] pcm_track,input pcm_playing,input sample_taken,
 output reg O_de,output reg O_vs,output reg [23:0] O_data);
localparam PHASE_BITS=20;
function [19:0] scene_samples;input [4:0] mode;begin case(mode)
5'd1:scene_samples=20'd452616;
5'd2:scene_samples=20'd346056;
5'd3:scene_samples=20'd371736;
5'd4:scene_samples=20'd455736;
5'd5:scene_samples=20'd296856;
5'd7:scene_samples=20'd389976;
5'd8:scene_samples=20'd561576;
5'd9:scene_samples=20'd536376;
5'd10:scene_samples=20'd444216;
5'd11:scene_samples=20'd592776;
5'd12:scene_samples=20'd933096;
5'd13:scene_samples=20'd820776;
5'd14:scene_samples=20'd1021656;
5'd15:scene_samples=20'd656136;
5'd16:scene_samples=20'd727656;
default:scene_samples=20'd0;endcase end endfunction
function [6:0] scene_length;input [4:0] mode;begin case(mode)
5'd1:scene_length=7'd36;
5'd2:scene_length=7'd25;
5'd3:scene_length=7'd27;
5'd4:scene_length=7'd35;
5'd5:scene_length=7'd24;
5'd7:scene_length=7'd32;
5'd8:scene_length=7'd44;
5'd9:scene_length=7'd41;
5'd10:scene_length=7'd35;
5'd11:scene_length=7'd47;
5'd12:scene_length=7'd70;
5'd13:scene_length=7'd64;
5'd14:scene_length=7'd77;
5'd15:scene_length=7'd51;
5'd16:scene_length=7'd60;
default:scene_length=7'd4;endcase end endfunction
function [11:0] scene_distance;input [4:0] mode;begin case(mode)
5'd1:scene_distance=12'd1792;
5'd2:scene_distance=12'd1440;
5'd3:scene_distance=12'd1504;
5'd4:scene_distance=12'd1760;
5'd5:scene_distance=12'd1408;
5'd7:scene_distance=12'd1664;
5'd8:scene_distance=12'd2048;
5'd9:scene_distance=12'd1952;
5'd10:scene_distance=12'd1760;
5'd11:scene_distance=12'd2144;
5'd12:scene_distance=12'd2880;
5'd13:scene_distance=12'd2688;
5'd14:scene_distance=12'd3104;
5'd15:scene_distance=12'd2272;
5'd16:scene_distance=12'd2560;
default:scene_distance=12'd0;endcase end endfunction
function [4:0] scene_track;input [4:0] mode;begin case(mode)
5'd1:scene_track=5'd3;
5'd2:scene_track=5'd4;
5'd3:scene_track=5'd5;
5'd4:scene_track=5'd6;
5'd5:scene_track=5'd2;
5'd7:scene_track=5'd7;
5'd8:scene_track=5'd8;
5'd9:scene_track=5'd9;
5'd10:scene_track=5'd10;
5'd11:scene_track=5'd11;
5'd12:scene_track=5'd12;
5'd13:scene_track=5'd13;
5'd14:scene_track=5'd14;
5'd15:scene_track=5'd15;
5'd16:scene_track=5'd16;
default:scene_track=5'd0;endcase end endfunction
reg [10:0] x;reg [9:0] y;reg vs_d;
wire frame_start=I_vs&&!vs_d;
// SW4 affects presentation only. Keep PCM progress and ROM lookups running
// while hidden; publish the synchronized preference at a frame boundary.
wire window_visible;
generate if(VISIBILITY_CONTROL)begin:g_visibility
 (* async_reg="true",syn_preserve=1 *) reg [1:0] hide_sync;
 reg frame_visible;
 always @(posedge clk or posedge rst)begin
  if(rst)begin hide_sync<=0;frame_visible<=1;end
  else begin
   hide_sync<={hide_sync[0],I_hide_async};
   if(frame_start)frame_visible<=!hide_sync[1];
  end
 end
 assign window_visible=frame_visible;
end else begin:g_always_enabled
 assign window_visible=1'b1;
end endgenerate
wire [4:0] mode=test_mode ? 5'd6 : (scenes[0] ? (pcm_track==5'd12 ? 5'd12 : (pcm_track==5'd7 ? 5'd7 : 5'd1)) : (scenes[1] ? (pcm_track==5'd13 ? 5'd13 : (pcm_track==5'd8 ? 5'd8 : 5'd2)) : (scenes[2] ? (pcm_track==5'd14 ? 5'd14 : (pcm_track==5'd9 ? 5'd9 : 5'd3)) : (scenes[3] ? (pcm_track==5'd15 ? 5'd15 : (pcm_track==5'd10 ? 5'd10 : 5'd4)) : (scenes[4] ? (pcm_track==5'd16 ? 5'd16 : (pcm_track==5'd11 ? 5'd11 : 5'd5)) : (5'd0))))));
wire narration_running=pcm_playing&&mode>=1&&mode<=16&&mode!=6&&pcm_track==scene_track(mode);
wire [PHASE_BITS-1:0] total_samples=scene_samples(mode);
wire [11:0] distance=scene_distance(mode);
reg [PHASE_BITS-1:0] scroll_phase;reg [11:0] scroll_px;
wire [PHASE_BITS:0] phase_next={1'b0,scroll_phase}+distance;
reg [4:0] frame_mode;reg frame_active;reg [11:0] frame_scroll;
reg [9:0] legacy_scroll;reg [7:0] legacy_hold;reg [1:0] legacy_state;
wire [9:0] legacy_next=legacy_state==0?(legacy_scroll>=476?10'd480:legacy_scroll+10'd4):
 (legacy_state==2?(legacy_scroll>=956?10'd0:legacy_scroll+10'd4):legacy_scroll);
always @(posedge clk or posedge rst)begin
 if(rst)begin x<=0;y<=0;vs_d<=0;scroll_phase<=0;scroll_px<=0;frame_mode<=0;frame_active<=0;frame_scroll<=0;legacy_scroll<=0;legacy_hold<=0;legacy_state<=0;end
 else begin
  vs_d<=I_vs;
  // Carry x through the three pending pixels in horizontal blanking. This
  // directly addresses the delayed mask ports without tail-address muxes.
  if(I_de||de1||de2||de3)x<={1'b0,x[9:0]+10'd1};else x<=0;
  if(frame_start)y<=0;else if(I_de&&x==639)y<=y==479?0:y+1'b1;
  if(!narration_running)begin scroll_phase<=0;scroll_px<=0;end
  else if(sample_taken&&scroll_px<distance)begin
   if(phase_next>=total_samples)begin scroll_phase<=phase_next-total_samples;scroll_px<=scroll_px+1'b1;end
   else scroll_phase<=phase_next[PHASE_BITS-1:0];
  end
  if(frame_start)begin
   frame_mode<=mode;frame_active<=narration_running;
   frame_scroll<=mode==6?12'd384:(mode==0?{2'd0,legacy_next}:scroll_px);
   if(mode!=0)begin legacy_scroll<=0;legacy_hold<=0;legacy_state<=0;end
   else case(legacy_state)
    0:if(legacy_scroll>=476)begin legacy_scroll<=480;legacy_hold<=0;legacy_state<=1;end else legacy_scroll<=legacy_scroll+4;
    1:if(legacy_hold==179)begin legacy_hold<=0;legacy_state<=2;end else legacy_hold<=legacy_hold+1'b1;
    2:if(legacy_scroll>=956)begin legacy_scroll<=0;legacy_state<=0;end else legacy_scroll<=legacy_scroll+4;
    default:legacy_state<=0;
   endcase
  end
 end
end
wire signed [13:0] text_x=$signed({3'd0,x})+$signed({2'd0,frame_scroll})-14'sd639;
wire [6:0] character_index=text_x[11:5];
wire [6:0] text_length=frame_mode==0 ? 10 : scene_length(frame_mode);
wire content_active=(frame_mode==0||frame_mode==6||frame_active);
// Only the binary source mask looks ahead. RGB and its timing stay in place.
wire glyph=window_visible&&content_active&&I_de&&x>=11&&x<627&&
 y>=387&&y<419&&text_x>=0&&character_index<text_length;
wire [4:0] glyph_row=y-10'd387;
// Fixed caption-to-glyph metadata uses a dedicated 32K RAM. The original
// glyph index/row files and their 21 BRAM9K blocks remain byte-identical.
wire [7:0] text_slot_q;
EG_LOGIC_BRAM #(.DATA_WIDTH_A(8),.ADDR_WIDTH_A(12),.DATA_DEPTH_A(4096),
 .DATA_WIDTH_B(8),.ADDR_WIDTH_B(12),.DATA_DEPTH_B(4096),
 .MODE("SP"),.REGMODE_A("NOREG"),.IMPLEMENT("32K"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("caption_text_slots.dat"),.FILL_ALL("NONE"))
 u_text_slot_rom(.dia(8'd0),.dib(8'd0),.addra({frame_mode,character_index}),.addrb(12'd0),
 .cea(1'b1),.ceb(1'b0),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),
 .doa(text_slot_q),.dob());
reg [4:0] glyph_row1;
always @(posedge clk) glyph_row1<=glyph_row;


wire [13-1:0] address={text_slot_q,glyph_row1};

reg [11:0] index0[0:2047],index1[0:2047],index2[0:2047],index0_q,index1_q,index2_q;
reg [31:0] rows0[0:1023],rows1[0:1023],rows2[0:1023],row0_q,row1_q,row2_q;
reg [1:0] index_bank_q,row_bank_q;
wire [11:0] index_q=index_bank_q==0?index0_q:(index_bank_q==1?index1_q:index2_q);
wire [31:0] row_q=row_bank_q==0?row0_q:(row_bank_q==1?row1_q:row2_q);
initial begin
 $readmemh("third_font_index0.hex",index0);$readmemh("third_font_index1.hex",index1);$readmemh("third_font_index2.hex",index2);
 $readmemh("third_font_rows0.hex",rows0);$readmemh("third_font_rows1.hex",rows1);$readmemh("third_font_rows2.hex",rows2);
end
always @(posedge clk)begin
 index0_q<=index0[address[10:0]];index1_q<=index1[address[10:0]];index2_q<=index2[address[10:0]];index_bank_q<=address[12:11];
 row0_q<=rows0[index_q[9:0]];row1_q<=rows1[index_q[9:0]];row2_q<=rows2[index_q[9:0]];row_bank_q<=index_q[11:10];
end
// Read the mask two clocks after its glyph lookup starts; write one clock
// later. Derive coordinates from the raster and existing DE pipeline, rather
// than storing three complete copies of the pixel address.
reg [1:0] line_memory[0:1023];
reg [1:0] line_q;
reg [23:0] bg1,bg2,bg3,rgb4;
reg de1,de2,de3,de4,vs1,vs2,vs3,vs4,glyph1,glyph2,glyph3;
reg [4:0] col1,col2,col3;
reg vertical1,vertical2,middle_ink;
wire source_ink=glyph3&&row_q[31-col3];
wire next_vertical=(|line_q)||source_ink;
wire [8:0] upper_minus_one=x[9:1]-9'd1;
wire [9:0] active_read_address={x[0]?x[9:1]:upper_minus_one,~x[0]};
wire [9:0] active_write_address={upper_minus_one,x[0]};
wire [9:0] read_address=active_read_address;
wire [9:0] write_address=active_write_address;
// Two zero rows flush the uninitialized mask RAM at startup. Source glyphs
// are zero everywhere outside the caption, so no opaque strip is necessary.
wire paint3=window_visible&&content_active&&de3&&y>=3;
always @(posedge clk)begin
 line_q<=line_memory[read_address];
 if(de3)line_memory[write_address]<={line_q[0],source_ink};
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  bg1<=0;bg2<=0;bg3<=0;rgb4<=0;O_data<=0;de1<=0;de2<=0;de3<=0;de4<=0;O_de<=0;
  vs1<=0;vs2<=0;vs3<=0;vs4<=0;O_vs<=0;glyph1<=0;glyph2<=0;glyph3<=0;
  col1<=0;col2<=0;col3<=0;vertical1<=0;vertical2<=0;middle_ink<=0;
 end else begin
  bg1<=I_data;de1<=I_de;vs1<=I_vs;glyph1<=glyph;col1<=text_x[4:0];
  bg2<=bg1;de2<=de1;vs2<=vs1;glyph2<=glyph1;col2<=col1;
  bg3<=bg2;de3<=de2;vs3<=vs2;glyph3<=glyph2;col3<=col2;
  if(de3)begin vertical2<=vertical1;vertical1<=next_vertical;middle_ink<=line_q[0];end
  else begin vertical1<=0;vertical2<=0;middle_ink<=0;end
  rgb4<=!paint3?bg3:(middle_ink?24'hffffff:((vertical2||vertical1||next_vertical)?24'h000000:bg3));
  de4<=de3;vs4<=vs3;O_data<=rgb4;O_de<=de4;O_vs<=vs4;
 end
end
endmodule
