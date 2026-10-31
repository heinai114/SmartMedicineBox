// All scheduling, envelope and tone enables share video_clk. Normal running
// uses a non-decreasing date/minute watermark: no catch-up or replay on edits.
module med_reminder #(parameter CLK_HZ=25_000_000,parameter TONE_HZ=2000,parameter RUNTIME_EDIT=0,parameter SCENE_SYNC=0)(
 input clk,rst,input cfg_done_async,cfg_valid_async,input [2:0] cfg_status_async,
 input [35:0] cfg_entry,output [3:0] cfg_read_index,
 input time_valid,input [23:0] time_bcd,date_bcd,
 output [3:0] led,output buzzer,
 output reg [2:0] display_medicine,output reg [15:0] display_time,
 output reg [19:0] display_dose,output reg [1:0] display_unit,
 output reg [1:0] display_name,
 output display_active,output reg plan_ready,plan_valid,output reg [2:0] plan_status,
 input runtime_commit,runtime_any_enabled,output runtime_ready,input scene_ready
);
localparam HALF=CLK_HZ/2,TONE_HALF=CLK_HZ/(2*TONE_HZ);
(* async_reg="true",syn_preserve=1 *)reg [1:0] cfg_done_sync;
reg [3:0] settle;
reg [23:0] watermark_date;reg [15:0] watermark_minute;reg have_watermark;
reg scanning,scan_wait;reg [3:0] slot,read_index_q;reg [15:0] fired,due;
reg [23:0] scan_date;reg [15:0] scan_time;
wire [35:0] entry=cfg_entry;
wire [15:0] now_minute=time_bcd[23:8];
localparam HALF_BITS=HALF<=1?1:$clog2(HALF),TONE_BITS=TONE_HALF<=1?1:$clog2(TONE_HALF);
reg [HALF_BITS-1:0] half_count;reg [2:0] phase;reg ringing;
reg [3:0] medicine_mask;reg [15:0] shown_slots;
reg [15:0] alert_time;reg [5:0] text_halves;
reg [3:0] shown_slot;reg [2:0] rotation_halves;
reg message_ready;
reg [TONE_BITS-1:0] tone_count;reg tone;
wire tick=half_count==HALF-1;
wire [4:0] scan_hour=scan_time[15:12]*5'd10+scan_time[11:8];
wire [5:0] scan_minute=scan_time[7:4]*6'd10+scan_time[3:0];
assign cfg_read_index=scanning?slot:shown_slot;
assign runtime_ready=plan_ready&&!scanning&&!ringing&&text_halves==0&&due==0;
assign led=ringing&&!phase[0]?medicine_mask:4'd0;
assign buzzer=ringing&&!phase[0]?tone:1'b1; // Board PNP off at1.
assign display_active=text_halves!=0&&message_ready;
integer m;
always @(posedge clk or posedge rst)begin
 if(rst)begin
  cfg_done_sync<=0;settle<=0;plan_ready<=0;plan_valid<=0;plan_status<=0;
  have_watermark<=0;watermark_date<=0;watermark_minute<=0;fired<=0;due<=0;
  slot<=0;scanning<=0;scan_wait<=0;read_index_q<=0;scan_date<=0;scan_time<=0;
  half_count<=0;phase<=0;ringing<=0;medicine_mask<=0;shown_slots<=0;
  alert_time<=0;text_halves<=0;shown_slot<=0;rotation_halves<=0;message_ready<=0;
  display_medicine<=0;display_time<=0;display_dose<=0;display_unit<=0;display_name<=0;
  tone_count<=0;tone<=1;
 end else begin
  cfg_done_sync<={cfg_done_sync[0],cfg_done_async};
  if(!plan_ready&&cfg_done_sync[1])begin
   if(settle==8)begin plan_ready<=1;plan_valid<=cfg_valid_async;plan_status<=cfg_status_async;end
   else settle<=settle+1'b1;
  end
  // Free-running half-second enable, restarted on a new alert. No new clock.
  if(tick)half_count<=0;else half_count<=half_count+1'b1;
  if(tone_count==TONE_HALF-1)begin tone_count<=0;tone<=~tone;end else tone_count<=tone_count+1'b1;
  if(tick)begin
   if(ringing)begin if(phase==5)ringing<=0;else phase<=phase+1'b1;end
   if(text_halves!=0)text_halves<=text_halves-1'b1;
   if(text_halves!=0&&(!SCENE_SYNC||scene_ready))begin
    if(rotation_halves==5)begin
     rotation_halves<=0;shown_slot<=shown_slot+1'b1;
    end else rotation_halves<=rotation_halves+1'b1;
   end
  end
  // Locate a due slot for display; skipped indices take at most16 pixel clocks.
  if(shown_slots!=0&&!shown_slots[shown_slot])shown_slot<=shown_slot+1'b1;
  read_index_q<=cfg_read_index;
  if(!scanning&&shown_slots[read_index_q])begin
   display_medicine<={1'b0,read_index_q[3:2]}+3'd1;
   display_time<=alert_time;display_dose<=entry[21:2];display_unit<=entry[1:0];
   display_name<=entry[35:34];
   message_ready<=1;
  end
  if(!time_valid)begin
   scanning<=0;due<=0;ringing<=0;text_halves<=0;message_ready<=0;
  end else if(plan_ready&&plan_valid)begin
   if(!scanning)begin
    // First valid sample arms the current minute (reboot can repeat it).
    // Later samples only advance. Backward correction waits for the watermark.
    if(!have_watermark||date_bcd>watermark_date||
       (date_bcd==watermark_date&&now_minute>watermark_minute))begin
     if(!have_watermark||date_bcd>watermark_date)fired<=0;
     watermark_date<=date_bcd;watermark_minute<=now_minute;have_watermark<=1;
     scan_date<=date_bcd;scan_time<=now_minute;slot<=0;due<=0;scanning<=1;scan_wait<=1;
    end
   end else if(scan_wait)scan_wait<=0;
   else begin
    if(entry[33]&&!fired[slot]&&entry[32:22]=={scan_hour,scan_minute})begin due[slot]<=1;fired[slot]<=1;end
    scan_wait<=1;
    if(slot==15)begin
     scanning<=0;
     // Separate publication clock includes the final slot without stale NBA.
     slot<=0;
    end else slot<=slot+1'b1;
   end
   if(!scanning&&due!=0)begin
    shown_slots<=due;due<=0;alert_time<=scan_time;text_halves<=60;rotation_halves<=0;shown_slot<=0;
    message_ready<=0;
    ringing<=1;phase<=0;half_count<=0;tone_count<=0;tone<=1;
    for(m=0;m<4;m=m+1)medicine_mask[m]<=|due[m*4+:4];
   end
  end
  if(RUNTIME_EDIT&&runtime_commit)begin
   // The new bank is already selected; suppress consumption of old RAM data.
   scanning<=0;scan_wait<=1;due<=0;shown_slots<=0;ringing<=0;text_halves<=0;message_ready<=0;
   fired<=0;have_watermark<=time_valid;watermark_date<=date_bcd;watermark_minute<=now_minute;
   plan_ready<=1;plan_valid<=1;plan_status<=runtime_any_enabled?3'd1:3'd2;
  end
 end
end
endmodule
