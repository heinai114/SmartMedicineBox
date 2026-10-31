// Plan editor: constant phase FSM plus a separate memory transaction FSM.
// One outstanding memory transaction. All edits use the inactive RAM bank.
// A verified save must complete before the scheduler can accept publication.
module med_plan_editor #(parameter BOOT_BANK_SUPPORT=0,SAVE_STAY_SUPPORT=0)(
 input clk,rst,plan_ready,plan_valid,open,
 input boot_bank,
 input action_valid,input [4:0] action,
 output reg visible,output busy,output reg [2:0] error,
 output reg [1:0] medicine,slot,output reg [2:0] digit,output reg [7:0] names,
 output reg [35:0] entry,
 output reg active_bank,output edit_bank,output reg applied,
 output reg mem_request,mem_write,output reg [4:0] mem_address,
 output reg [35:0] mem_wdata,input mem_ready,mem_valid,input [35:0] mem_rdata,
 output save_request,input save_done,save_success,
 output commit_request,input commit_ready,output reg any_enabled,
 input keep_open
);
localparam CLOSED=0,COPY_READ=1,COPY_NEXT=2,LOAD=3,READY=4,SWITCH=5,
 VALIDATE_BEGIN=6,VALIDATE_READ=7,VALIDATE_NEXT=8,SAVE=9,COMMIT=10;
reg [3:0] state;reg [1:0] memory_phase;
reg [3:0] index;
reg valid_copy;
wire [35:0] response=mem_rdata;
reg [1:0] next_medicine,next_slot;
reg [11:0] previous0,previous1,previous2;
wire [3:0] selection={medicine,slot};
// Slot identity is fixed: medicine 0..3 maps to PIC01..PIC04; unit 0 is tablet.
// Canonicalize RAM copies without changing the source bank or EEPROM on open.
wire [1:0] selected_name=medicine;
wire [35:0] current_entry={medicine,entry[33:2],2'd0};
wire [35:0] normalized_entry={index[3:2],response[33:2],2'd0};
wire duplicate=response[33]&&((index[1:0]>=1&&previous0[11]&&previous0[10:0]==response[32:22])||
 (index[1:0]>=2&&previous1[11]&&previous1[10:0]==response[32:22])||
 (index[1:0]==3&&previous2[11]&&previous2[10:0]==response[32:22]));
assign edit_bank=~active_bank;
assign busy=visible&&(state!=READY||memory_phase!=0);
assign save_request=state==SAVE;
assign commit_request=state==COMMIT;
function [35:0] defaults;
 input [1:0] name;
 begin defaults={name,1'b0,5'd8,6'd0,20'h00100,2'd0};end
endfunction
function bad_entry;
 input [35:0] v;
 begin bad_entry=v[33]&&(v[32:28]>23||v[27:22]>59||v[1:0]!=0||v[21:2]==0||v[21:2]>20'h09990||
  v[21:18]>9||v[17:14]>9||v[13:10]>9||v[9:6]>9||v[5:2]>9||
  v[5:2]!=0);end
endfunction
function [19:0] adjust_dose;
 input [19:0] value;input [2:0] selected_digit;input up;
 reg [19:0] result;reg [3:0] selected,next_digit;
 begin
  // Only an explicit digit edit normalizes an unsupported legacy record.
  // Selected digits wrap independently; never carry into another digit.
  result=(value>20'h09990) ? 20'h09990 : {4'd0,value[15:4],4'd0};
  case(selected_digit)
   3:selected=result[15:12];2:selected=result[11:8];1:selected=result[7:4];default:selected=0;
  endcase
  next_digit=up?(selected==9?4'd0:selected+4'd1):(selected==0?4'd9:selected-4'd1);
  case(selected_digit)
   3:result[15:12]=next_digit;2:result[11:8]=next_digit;1:result[7:4]=next_digit;default:result=value;
  endcase
  adjust_dose=result;
 end
endfunction
task memory;
 input wr;input [4:0] address;input [35:0] value;input [3:0] resume;
 begin mem_request<=1;mem_write<=wr;mem_address<=address;mem_wdata<=value;state<=resume;memory_phase<=1;end
endtask
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=CLOSED;memory_phase<=0;visible<=0;error<=0;medicine<=0;slot<=0;digit<=0;names<=8'he4;
  entry<=0;active_bank<=0;applied<=0;index<=0;valid_copy<=0;
  next_medicine<=0;next_slot<=0;previous0<=0;previous1<=0;previous2<=0;
  mem_request<=0;mem_write<=0;mem_address<=0;mem_wdata<=0;any_enabled<=0;
 end else begin
  applied<=0;
  if(BOOT_BANK_SUPPORT&&!plan_ready)active_bank<=boot_bank;
  if(memory_phase==1)begin
   if(mem_ready)begin mem_request<=0;memory_phase<=2;end
  end else if(memory_phase==2)begin
   if(mem_valid)begin memory_phase<=0;end
  end else case(state)
   CLOSED:if(plan_ready&&(open||(SAVE_STAY_SUPPORT&&visible)))begin
    // A visible CLOSED state resumes after a successful save. Reuse the
    // normal copy path, but retain selection and always copy the new bank.
    visible<=1;error<=0;index<=0;valid_copy<=plan_valid||visible;names<=8'he4;
    if(!visible)begin medicine<=0;slot<=0;digit<=0;end
    if(plan_valid||visible)memory(0,{active_bank,4'd0},0,COPY_READ);
    else memory(1,{~active_bank,4'd0},defaults(0),COPY_NEXT);
   end
   COPY_READ:begin
    memory(1,{~active_bank,index},normalized_entry,COPY_NEXT);
   end
   COPY_NEXT:if(index==15)memory(0,{~active_bank,selection},0,LOAD);
    else begin
     index<=index+1'b1;
     if(valid_copy)memory(0,{active_bank,index+4'd1},0,COPY_READ);
     else memory(1,{~active_bank,index+4'd1},defaults((index+4'd1)>>2),COPY_NEXT);
    end
   LOAD:begin
    // Zero is a valid draft, never replace it with a different amount/time.
    entry<={selected_name,response[33:2],2'd0};
    state<=READY;
   end
   READY:if(action_valid)begin
    error<=0;
    if(action>=1&&action<=8)begin
     next_medicine<=action<=4?action-1'b1:medicine;
     next_slot<=action<=4?slot:action-5'd5;
     memory(1,{~active_bank,selection},current_entry,SWITCH);
    end else case(action)
     9:entry[33]<=~entry[33];
     // Legacy name/unit actions 10/11 are no longer implemented.
     12:entry[32:28]<=entry[32:28]==23?5'd0:entry[32:28]+5'd1;
     13:entry[32:28]<=entry[32:28]==0?5'd23:entry[32:28]-5'd1;
     14:entry[27:22]<=entry[27:22]==59?6'd0:entry[27:22]+6'd1;
     15:entry[27:22]<=entry[27:22]==0?6'd59:entry[27:22]-6'd1;
     16,17,18,19,20:digit<=action>=17&&action<=19?action-5'd16:3'd3;
     21,22:entry[21:2]<=adjust_dose(entry[21:2],digit,action==21);
     23:memory(1,{~active_bank,selection},current_entry,VALIDATE_BEGIN);
     24:begin visible<=0;state<=CLOSED;end
     default:;
    endcase
   end
   SWITCH:begin
    medicine<=next_medicine;slot<=next_slot;
    memory(0,{~active_bank,next_medicine,next_slot},0,LOAD);
   end
   VALIDATE_BEGIN:begin
    index<=0;any_enabled<=0;previous0<=0;previous1<=0;previous2<=0;
    memory(0,{~active_bank,4'd0},0,VALIDATE_READ);
   end
   VALIDATE_READ:begin
    if(duplicate||bad_entry(response))begin
     error<=duplicate?3'd2:3'd3;medicine<=index[3:2];slot<=index[1:0];entry<=normalized_entry;state<=READY;
    end else begin
     if(response[33])any_enabled<=1;
     case(index[1:0])
      0:begin previous0<={response[33],response[32:22]};previous1<=0;previous2<=0;end
      1:previous1<={response[33],response[32:22]};
      2:previous2<={response[33],response[32:22]};default:;
     endcase
     memory(1,{~active_bank,index},normalized_entry,VALIDATE_NEXT);
    end
   end
   VALIDATE_NEXT:if(index==15)state<=SAVE;
    else begin index<=index+1'b1;memory(0,{~active_bank,index+4'd1},0,VALIDATE_READ);end
   SAVE:if(save_done)begin
    if(save_success)state<=COMMIT;
    else begin error<=4;state<=READY;end
   end
   COMMIT:if(commit_ready)begin
    active_bank<=~active_bank;visible<=SAVE_STAY_SUPPORT&&keep_open;
    applied<=1;state<=CLOSED;
   end
   default:state<=CLOSED;
  endcase
 end
end
endmodule
