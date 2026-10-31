// SW1 is the persistent visibility request. Cancel/success only pause the UI.
module keypad_plan_control #(parameter integer SW_DEBOUNCE_CYCLES=500000,
 parameter integer ACTION_PAUSE_FRAMES=60)(
 input clk,rst,sw_edit,input plan_ready,visible,busy,reminder_active,
 input key_valid,input [3:0] key_code,
 output reg open,action_valid,output reg [4:0] action,
 output reg [2:0] field,output reg mode_up,
 input applied,frame_vs,output pause
);
localparam CB=SW_DEBOUNCE_CYCLES>1?$clog2(SW_DEBOUNCE_CYCLES):1;
(* async_reg="true",syn_preserve=1 *) reg [1:0] sw_sync;
reg [CB-1:0] sw_count;
localparam PB=ACTION_PAUSE_FRAMES>0?$clog2(ACTION_PAUSE_FRAMES+1):1;
reg [PB-1:0] pause_count;
reg frame_d;
assign pause=|pause_count;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  sw_sync<=0;sw_count<=0;mode_up<=0;pause_count<=0;frame_d<=0;
  open<=0;action_valid<=0;action<=0;field<=0;
 end else begin
  sw_sync<={sw_sync[0],sw_edit};open<=0;action_valid<=0;frame_d<=frame_vs;
  if(sw_sync[1]==mode_up)sw_count<=0;
  else if(sw_count==SW_DEBOUNCE_CYCLES-1)begin mode_up<=sw_sync[1];sw_count<=0;end
  else sw_count<=sw_count+1'b1;
  // During a save, intermediate switch positions do not queue a stale
  // cancel. Use the latest debounced position when editing becomes ready.
  if(!mode_up)pause_count<=0;
  else if(applied)pause_count<=ACTION_PAUSE_FRAMES;
  else if(pause&&frame_vs&&!frame_d)pause_count<=pause_count-1'b1;
  if(visible&&!busy&&!mode_up)begin
   action_valid<=1;action<=24;
  end else if(mode_up&&!visible&&!pause&&!applied&&plan_ready&&!reminder_active)begin
   open<=1;field<=0;
  end else if(mode_up&&visible&&!busy&&!pause&&!applied&&!reminder_active&&key_valid)begin
   action_valid<=1;
   case(key_code)
    0,1,2,3:action<={1'b0,key_code}+5'd1;
    4,5,6,7:action<={1'b0,key_code}+5'd1;
    // S9 enable, S10 field, S11 decrease, S12 increase,
    // S13 cancel, S14 save. Global contrast uses S15/S16 separately.
    8:action<=9;
    9:begin
     field<=field==4?3'd0:field+3'd1;
     if(field>=1&&field<=3)action<=5'd20-{2'd0,field};
     else action_valid<=0;
    end
    10:action<=field==0?5'd13:field==1?5'd15:5'd22;
    11:action<=field==0?5'd12:field==1?5'd14:5'd21;
    12:begin action<=24;pause_count<=ACTION_PAUSE_FRAMES;end
    13:action<=23;
    default:action_valid<=0;
   endcase
  end
 end
end
endmodule
