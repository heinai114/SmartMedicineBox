// Project-owned dual-clock FIFO. Pointers are never independently reset when
// changing a file: cancellation drains it under a separate flush handshake.
module voice_async_fifo #(parameter A=12)(
    input rst, input wclk, input wen, input [16:0] wdata,
    output full, output [A:0] used,
    input rclk, input ren, output empty, output reg [16:0] rdata
);
reg [16:0] mem [0:(1<<A)-1];
reg [A:0] wb, wg, rb, rg;
(* async_reg="true",syn_preserve=1 *) reg [A:0] rg0,rg1,wg0,wg1;
wire [A:0] wnext=wb+(wen&&!full);
wire [A:0] rnext=rb+(ren&&!empty);
function [A:0] ungray;
    input [A:0] g; integer i;
    begin ungray[A]=g[A]; for(i=A-1;i>=0;i=i-1) ungray[i]=ungray[i+1]^g[i]; end
endfunction
assign full=wg=={~rg1[A:A-1],rg1[A-2:0]};
assign empty=rg==wg1;
assign used=wb-ungray(rg1);
always @(posedge wclk) if(wen&&!full) mem[wb[A-1:0]]<=wdata;
always @(posedge rclk) rdata<=mem[rb[A-1:0]];
always @(posedge wclk or posedge rst) begin
    if(rst) begin wb<=0;wg<=0;rg0<=0;rg1<=0;end
    else begin wb<=wnext;wg<=(wnext>>1)^wnext;rg0<=rg;rg1<=rg0;end
end
always @(posedge rclk or posedge rst) begin
    if(rst) begin rb<=0;rg<=0;wg0<=0;wg1<=0;end
    else begin rb<=rnext;rg<=(rnext>>1)^rnext;wg0<=wg;wg1<=wg0;end
end
endmodule
