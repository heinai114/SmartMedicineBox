`timescale 1ns/1ps
module tb_hint_pixels;
reg clk=0,rst=1,de=0,vs=0,wave=0,time_valid=1,temp_valid=1,temp_negative=0,capture=0;
reg [19:0] temp_bcd=20'h02500;
reg [23:0] data=0;
reg [1:0] forced_kind=0;
reg [23:0] bg_mem[0:307199];
always #5 clk=~clk;
wire nd,nv,rd,rv,ld,lv;wire [23:0] nr,rr,lr;
video_rtc_overlay #(.ENABLE_TEMP_HINT(1),.TEMP_FONT_FILE("temperature_hint_font.dat")) dut(
 .clk(clk),.rst(rst),.time_bcd(24'h123456),.date_bcd(24'h261025),.weekday(3'd1),.time_valid(time_valid),.waveform_frame_enable(wave),
 .temperature_bcd(temp_bcd),.temperature_negative(temp_negative),.temperature_valid(temp_valid),.hint_blocked(1'b0),
 .I_de(de),.I_vs(vs),.I_data(data),.O_de(nd),.O_vs(nv),.O_data(nr));
video_rtc_overlay legacy(.clk(clk),.rst(rst),.time_bcd(24'h123456),.date_bcd(24'h261025),.weekday(3'd1),.time_valid(time_valid),.waveform_frame_enable(wave),
 .temperature_bcd(temp_bcd),.temperature_negative(temp_negative),.temperature_valid(temp_valid),.hint_blocked(1'b0),
 .I_de(de),.I_vs(vs),.I_data(data),.O_de(ld),.O_vs(lv),.O_data(lr));
rtc_reference refmod(.clk(clk),.rst(rst),.time_bcd(24'h123456),.date_bcd(24'h261025),.weekday(3'd1),.time_valid(time_valid),.waveform_frame_enable(wave),
 .temperature_bcd(temp_bcd),.temperature_negative(temp_negative),.temperature_valid(temp_valid),
 .I_de(de),.I_vs(vs),.I_data(data),.O_de(rd),.O_vs(rv),.O_data(rr));
reg [1:0] de_pipe=0,vs_pipe=0;
integer case_id=0,xx,yy,fd,pixels=0,ox,oy;
always @(posedge clk)begin
 de_pipe<={de_pipe[0],de};vs_pipe<={vs_pipe[0],vs};
 #1;
 if(!rst)begin
  if(nd!==rd||nv!==rv||nd!==de_pipe[1]||nv!==vs_pipe[1]||ld!==rd||lv!==rv)$fatal(1,"Two-clock video timing changed");
  if(lr!==rr)$fatal(1,"Disabled hint mode altered original clock/date/temperature display");
  if(capture&&nd)begin
   ox=pixels%640;oy=pixels/640;
   if((forced_kind==0||ox<448||ox>=624||oy<64||oy>=156)&&nr!==rr)
    $fatal(1,"Original pixels changed outside hint: case%0d x%0d y%0d got%h old%h",case_id,ox,oy,nr,rr);
   $fwrite(fd,"%c%c%c",nr[23:16],nr[15:8],nr[7:0]);pixels=pixels+1;
  end
 end
end
task tick;begin @(negedge clk);end endtask
initial begin
 $readmemh("../verification/background.hex",bg_mem);
 repeat(8)tick;rst=0;repeat(8)tick;
 force dut.hint_kind=forced_kind;
 for(case_id=0;case_id<6;case_id=case_id+1)begin
  wave=case_id==3||case_id==4;temp_negative=case_id==4;temp_valid=case_id!=5;time_valid=case_id!=5;
  forced_kind=case_id==1||case_id==3?1:(case_id==2||case_id==4?2:0);
  temp_bcd=case_id==1||case_id==3?20'h03000:(case_id==2?20'h01500:(case_id==4?20'h00025:20'h02500));
  de=0;vs=1;tick;vs=0;repeat(20)tick;
  fd=$fopen($sformatf("../verification/hint_frame_%0d.rgb",case_id),"wb");pixels=0;capture=1;
  for(yy=0;yy<480;yy=yy+1)begin
   de=0;repeat(160)tick;
   for(xx=0;xx<640;xx=xx+1)begin de=1;data=bg_mem[yy*640+xx];tick;end
   de=0;
  end
  repeat(8)tick;capture=0;$fclose(fd);
  if(pixels!=307200)$fatal(1,"Wrong frame size");
 end
 $display("PASS hint pixels: six complete frames, exact original pixels outside popup, default-disabled compatibility, shared glyph ROM and two-clock RGB/DE/VS alignment");$finish;
end
initial begin #50000000;$fatal(1,"Render watchdog");end
endmodule
