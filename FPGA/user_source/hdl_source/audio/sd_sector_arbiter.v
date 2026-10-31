// One official SD engine, ownership held through one whole read/write sector.
module sd_sector_arbiter #(parameter TIMEOUT=100_000_000,parameter SAVE_SUPPORT=0)(
 input clk,rst,input bmp_req,input [31:0] bmp_addr,output bmp_valid,bmp_end,
 input voice_req,input [31:0] voice_addr,output voice_valid,voice_end,
 output reg voice_error,soft_reset,output core_req,output reg [31:0] core_addr,
 input core_valid,core_end,
 input save_write_req,save_read_req,input [31:0] save_addr,
 output save_valid,save_read_end,save_write_end,save_data_req,output reg save_error,
 output core_write_req,input core_write_end,core_data_req
);
localparam IDLE=0,BUSY=1,GAP=2,RESET=3;
reg [1:0] state,owner;reg writing;reg [26:0] timer;reg [3:0] reset_count;
wire save_pending=SAVE_SUPPORT&&(save_write_req||save_read_req);
wire transaction_end=writing ? core_write_end : core_end;
assign core_req=state==BUSY&&!writing;
assign core_write_req=state==BUSY&&writing;
assign bmp_valid=state==BUSY&&owner==0&&core_valid;
assign bmp_end=state==BUSY&&owner==0&&core_end;
assign voice_valid=state==BUSY&&owner==1&&core_valid;
assign voice_end=state==BUSY&&owner==1&&core_end;
assign save_valid=SAVE_SUPPORT&&state==BUSY&&owner==2&&!writing&&core_valid;
assign save_read_end=SAVE_SUPPORT&&state==BUSY&&owner==2&&!writing&&core_end;
assign save_write_end=SAVE_SUPPORT&&state==BUSY&&owner==2&&writing&&core_write_end;
assign save_data_req=SAVE_SUPPORT&&state==BUSY&&owner==2&&writing&&core_data_req;
always @(posedge clk or posedge rst)begin
 if(rst)begin state<=IDLE;owner<=0;writing<=0;timer<=0;core_addr<=0;voice_error<=0;save_error<=0;soft_reset<=0;reset_count<=0;end
 else begin
  voice_error<=0;save_error<=0;
  case(state)
   IDLE:begin
    timer<=0;
    if(save_pending||voice_req||bmp_req)begin
     owner<=save_pending ? 2 : voice_req ? 1 : 0;
     writing<=save_pending&&save_write_req;
     core_addr<=save_pending ? save_addr : voice_req ? voice_addr : bmp_addr;state<=BUSY;
    end
   end
   BUSY:if(transaction_end)state<=GAP;
    else if(timer==TIMEOUT-1)begin state<=RESET;soft_reset<=1;reset_count<=0;voice_error<=owner==1;save_error<=owner==2;end
    else timer<=timer+1'b1;
   GAP:state<=IDLE;
   RESET:if(reset_count==7)begin soft_reset<=0;state<=IDLE;end else reset_count<=reset_count+1'b1;
  endcase
 end
end
endmodule
