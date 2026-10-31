// Borrow the existing FAT reader once, before media scanning. Abort requests
// only after a complete sector or the existing arbiter's bounded reset.
module med_config_boot #(parameter TIMEOUT=500_000_000)(
 input clk,rst,sd_init_done,file_busy,file_done,file_error,input [3:0] file_error_code,
 input file_valid,input [7:0] file_data,
 output boot_active,output reg boot_done,output start,cancel,config_ready,
 output plan_valid,output [2:0] status,
 output config_write,output [3:0] config_index,output [35:0] config_data
);
localparam WAIT=0,START=1,READ=2,CHECK=3,ABORT=4,RELEASE=5,DONE=6;
reg [2:0] state;reg [28:0] timer;reg [3:0] gap;
reg [2:0] fault;reg aborted;
wire decoded_done,decoded_valid;wire [2:0] decoded_status;
assign boot_active=!boot_done;
assign start=state==START;
assign cancel=state==ABORT||state==RELEASE;
assign plan_valid=boot_done&&!aborted&&decoded_valid;
assign status=boot_done?(aborted?fault:decoded_status):3'd0;
med_config_decoder u_decode(.clk(clk),.rst(rst),.start(start),
 .valid(state==READ&&file_valid),.data(file_data),.ready(config_ready),
 .finish(state==READ&&file_done),.file_error(1'b0),
 .done(decoded_done),.plan_valid(decoded_valid),.status(decoded_status),
 .config_write(config_write),.config_index(config_index),.config_data(config_data));
always @(posedge clk or posedge rst)begin
 if(rst)begin state<=WAIT;boot_done<=0;timer<=0;gap<=0;fault<=0;aborted<=0;end
 else case(state)
 WAIT:if(sd_init_done)begin state<=START;timer<=0;end
 START:state<=READ;
 READ:begin
  if(file_error)begin fault<=file_error_code==4?3:6;aborted<=1;state<=ABORT;end
  else if(file_done)state<=CHECK;
  else if(timer==TIMEOUT-1)begin fault<=7;aborted<=1;state<=ABORT;end
  else timer<=timer+1'b1;
 end
 CHECK:if(decoded_done)begin state<=RELEASE;gap<=0;end
 ABORT:if(!file_busy)begin state<=RELEASE;gap<=0;end
 RELEASE:if(gap==8)begin boot_done<=1;state<=DONE;end else gap<=gap+1'b1;
 default:;
 endcase
end
endmodule
