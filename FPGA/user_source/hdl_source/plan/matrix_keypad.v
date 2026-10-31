// Passive 4x4 matrix. Only the selected row drives LOW; other rows float.
// contrast_held is valid only for an accepted S15/S16 until the scan changes.
// A complete, debounced release is required before every single-key event.
module matrix_keypad #(
 parameter integer ROW_CYCLES=6250,
 parameter integer DEBOUNCE_FRAMES=20
)(input clk,rst,input [3:0] columns,inout [3:0] rows,
 output reg key_valid,output reg [3:0] key_code,output reg [1:0] contrast_held);
localparam CB=ROW_CYCLES>1?$clog2(ROW_CYCLES):1;
localparam DB=DEBOUNCE_FRAMES>1?$clog2(DEBOUNCE_FRAMES+1):1;
reg [CB-1:0] timer;reg [1:0] row;
(* async_reg="true",syn_preserve=1 *) reg [3:0] col_meta,col_sync;
reg [15:0] scan,candidate;reg [DB-1:0] stable;
reg locked;
wire [15:0] frame_bits={~col_sync,scan[11:0]};
wire single=frame_bits!=0&&((frame_bits&(frame_bits-16'd1))==0);
genvar g;
generate for(g=0;g<4;g=g+1)begin:g_rows
 assign rows[g]=!rst&&row==g?1'b0:1'bz;
end endgenerate
integer i;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  timer<=0;row<=0;col_meta<=15;col_sync<=15;scan<=0;candidate<=0;
  stable<=0;locked<=1;key_valid<=0;key_code<=0;contrast_held<=0;
 end else begin
  col_meta<=columns;col_sync<=col_meta;key_valid<=0;
  if(timer==ROW_CYCLES-1)begin
   timer<=0;row<=row+1'b1;scan[row*4+:4]<=~col_sync;
   if(row==3)begin
    if(frame_bits!=0&&!single)locked<=1;
    if(frame_bits!=candidate)begin candidate<=frame_bits;stable<=1;contrast_held<=0;end
    else if(stable<DEBOUNCE_FRAMES)begin
     stable<=stable+1'b1;
     if(stable==DEBOUNCE_FRAMES-1)begin
      if(frame_bits==0)locked<=0;
      else if(single&&!locked)begin
       locked<=1;key_valid<=1;contrast_held<=frame_bits[15:14];
       for(i=0;i<16;i=i+1)if(frame_bits[i])key_code<=i;
      end
     end
    end
   end
  end else timer<=timer+1'b1;
 end
end
endmodule
