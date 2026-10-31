`timescale 1ns/1ps
module tb_hint_integration;
reg clk=0,rst=1,vs=0,valid=0,blocked=0;
reg [19:0] temperature=20'h00000;
always #5 clk=~clk;
video_rtc_overlay #(.ENABLE_TEMP_HINT(1),.HINT_SHOW_FRAMES(3),.TEMP_FONT_FILE("temperature_hint_font.dat")) dut(
 .clk(clk),.rst(rst),.time_bcd(24'h123456),.date_bcd(24'h261025),.weekday(3'd1),.time_valid(1'b1),.waveform_frame_enable(1'b1),
 .temperature_bcd(temperature),.temperature_negative(1'b0),.temperature_valid(valid),.hint_blocked(blocked),
 .I_de(1'b0),.I_vs(vs),.I_data(24'h123456),.O_de(),.O_vs(),.O_data());
task tick;begin @(negedge clk);end endtask
task frame;begin vs=1;tick;vs=0;repeat(12)tick;end endtask
task check_kind;input integer value;begin if(dut.hint_kind!==value)$fatal(1,"Integrated controller kind got %0d expected %0d",dut.hint_kind,value);end endtask
initial begin
 repeat(8)tick;rst=0;frame;check_kind(0);frame;check_kind(0);
 valid=1;temperature=20'h03000;blocked=1;frame;check_kind(0);frame;check_kind(0);
 blocked=0;frame;check_kind(1);blocked=1;frame;check_kind(0);
 blocked=0;frame;check_kind(1);frame;check_kind(1);frame;check_kind(0);frame;check_kind(0);
 temperature=20'h02800;frame;check_kind(0);
 temperature=20'h01500;frame;check_kind(0);frame;check_kind(2);
 valid=0;temperature=0;frame;check_kind(0);
 valid=1;temperature=20'h01500;frame;check_kind(2);frame;check_kind(2);frame;check_kind(0);
 temperature=20'h02500;frame;check_kind(0);
 $display("PASS integrated RTC hint: actual VS pulses drive controller; valid/priority inputs, custom duration, high/cold one-shots, no forced internal signals");$finish;
end
initial begin #100000;$fatal(1,"Integration watchdog");end
endmodule
