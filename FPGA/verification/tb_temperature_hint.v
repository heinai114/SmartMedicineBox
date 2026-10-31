`timescale 1ns/1ps
module tb_temperature_hint;
reg clk=0,rst=1,frame_tick=0,temperature_negative=0,temperature_valid=0,blocked=0;
reg [19:0] temperature_bcd=0;
wire [1:0] kind;
always #5 clk=~clk;
temperature_hint_control dut(.clk(clk),.rst(rst),.frame_tick(frame_tick),.temperature_bcd(temperature_bcd),
 .temperature_negative(temperature_negative),.temperature_valid(temperature_valid),.blocked(blocked),.visible_kind(kind));
reg [1:0] held_kind=0;
reg sampled_tick;
always @(posedge clk)begin
 sampled_tick=frame_tick;
 #1;
 if(rst)held_kind=0;
 else begin
  if(!sampled_tick&&kind!==held_kind)$fatal(1,"Hint changed outside frame boundary");
  held_kind=kind;
 end
end
task frame;begin @(negedge clk);frame_tick=1;@(negedge clk);frame_tick=0;repeat(2)@(negedge clk);end endtask
task set_temp;input integer quarters;integer mag,whole,cents;begin
 temperature_negative=quarters<0;mag=quarters<0?-quarters:quarters;whole=mag/4;cents=(mag%4)*25;
 temperature_bcd=((whole/100)<<16)|(((whole/10)%10)<<12)|((whole%10)<<8)|((cents/10)<<4)|(cents%10);
end endtask
task check_result;input integer k,s,r;begin
 if(kind!==k||dut.regime!==s||dut.remaining!==r)$fatal(1,"kind/state/count got %0d/%0d/%0d expected %0d/%0d/%0d",kind,dut.regime,dut.remaining,k,s,r);
end endtask
task reset_control;begin
 rst=1;frame_tick=0;repeat(6)@(negedge clk);rst=0;blocked=0;temperature_valid=1;set_temp(100);frame;check_result(0,0,0);
end endtask
integer i,s,q,v,b,r,initial_remaining,fd,count=0;
initial begin
 repeat(6)@(negedge clk);rst=0;
 repeat(10)begin frame;check_result(0,0,0);end
 temperature_valid=1;set_temp(100);frame;check_result(0,0,0);
 set_temp(119);frame;check_result(0,0,0);
 set_temp(120);frame;check_result(0,1,300);
 for(i=0;i<300;i=i+1)begin frame;check_result(1,1,299-i);end
 repeat(600)begin frame;check_result(0,1,0);end
 temperature_valid=0;set_temp(0);frame;check_result(0,1,0);
 temperature_valid=1;set_temp(120);frame;check_result(0,1,0);
 set_temp(119);frame;check_result(0,1,0);set_temp(113);frame;check_result(0,1,0);
 set_temp(112);frame;check_result(0,0,0);set_temp(119);frame;check_result(0,0,0);
 blocked=1;set_temp(120);frame;check_result(0,1,300);
 repeat(10)begin frame;check_result(0,1,300);end
 blocked=0;for(i=0;i<100;i=i+1)begin frame;check_result(1,1,299-i);end
 blocked=1;repeat(10)begin frame;check_result(0,1,200);end
 temperature_valid=0;set_temp(0);blocked=0;repeat(10)begin frame;check_result(0,1,200);end
 temperature_valid=1;set_temp(120);
 for(i=0;i<200;i=i+1)begin frame;check_result(1,1,199-i);end
 frame;check_result(0,1,0);
 set_temp(-1);frame;check_result(0,2,300);frame;check_result(2,2,299);
 set_temp(67);frame;check_result(2,2,298);set_temp(68);frame;check_result(0,0,0);
 set_temp(61);frame;check_result(0,0,0);set_temp(60);frame;check_result(0,2,300);
 frame;check_result(2,2,299);set_temp(120);frame;check_result(0,1,300);frame;check_result(1,1,299);
 blocked=1;set_temp(100);frame;check_result(0,0,0);set_temp(120);frame;check_result(0,1,300);
 set_temp(100);frame;check_result(0,0,0);blocked=0;frame;check_result(0,0,0);
 set_temp(60);frame;frame;check_result(2,2,299);reset_control;
 blocked=1;set_temp(120);frame;check_result(0,1,300);reset_control;
 // Signed quarter-degree range and every state/validity/priority/count boundary.
 fd=$fopen("../verification/temperature_cases.csv","w");
 for(s=0;s<3;s=s+1)for(q=-512;q<=511;q=q+1)for(v=0;v<2;v=v+1)for(b=0;b<2;b=b+1)for(r=0;r<3;r=r+1)begin
  @(negedge clk);dut.regime=s;initial_remaining=r==0?0:(r==1?1:300);dut.remaining=initial_remaining;
  temperature_valid=v;blocked=b;set_temp(q);frame;
  $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",s,q,v,b,initial_remaining,dut.regime,dut.remaining,kind);
  count=count+1;
 end
 $fclose(fd);
 if(count!=36864)$fatal(1,"Wrong exhaustive count");
 $display("PASS temperature hint: exact 300 visible frames, one-shot episodes, hysteresis, priority pause/cancel, invalid readings, negative fractions, reset and %0d boundary cases",count);$finish;
end
initial begin #10000000;$fatal(1,"Controller watchdog");end
endmodule
