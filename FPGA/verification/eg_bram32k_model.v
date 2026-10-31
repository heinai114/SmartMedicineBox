// Test-only synchronous single-port read model for the documented primitive.
// The actual TD primitive is used in synthesis; its routed INIT bits are audited.
module EG_LOGIC_BRAM #(
 parameter DATA_WIDTH_A=8,ADDR_WIDTH_A=12,DATA_DEPTH_A=4096,
 parameter DATA_WIDTH_B=8,ADDR_WIDTH_B=12,DATA_DEPTH_B=4096,
 parameter MODE="SP",REGMODE_A="NOREG",REGMODE_B="NOREG",IMPLEMENT="32K",DEBUGGABLE="NO",PACKABLE="NO",
 parameter INIT_FILE="NONE",FILL_ALL="NONE",WRITEMODE_A="NORMAL"
)(input [DATA_WIDTH_A-1:0] dia,input [DATA_WIDTH_B-1:0] dib,
 input [ADDR_WIDTH_A-1:0] addra,input [ADDR_WIDTH_B-1:0] addrb,
 input cea,ceb,ocea,oceb,clka,clkb,wea,web,bea,beb,rsta,rstb,
 output reg [DATA_WIDTH_A-1:0] doa,output reg [DATA_WIDTH_B-1:0] dob);
reg [DATA_WIDTH_A-1:0] mem[0:DATA_DEPTH_A-1];
initial begin
 if((MODE!="SP"&&MODE!="DP")||REGMODE_A!="NOREG"||(IMPLEMENT!="32K"&&IMPLEMENT!="9K")||
    (DATA_WIDTH_A*DATA_DEPTH_A!=32768&&DATA_WIDTH_A*DATA_DEPTH_A!=36864&&DATA_WIDTH_A*DATA_DEPTH_A!=8192))
  $fatal(1,"Unsupported test RAM configuration");
 if(INIT_FILE=="brightness_font.dat")$readmemb("brightness_font.dat",mem);
 else if(INIT_FILE=="audio_filename.dat")$readmemb("audio_filename.dat",mem);
 else if(INIT_FILE=="audio_filename_config.dat")$readmemb("audio_filename_config.dat",mem);
 else if(INIT_FILE=="touch_host_program.dat")$readmemb("touch_host_program.dat",mem);
 else if(INIT_FILE=="touch_mapping.dat")$readmemb("touch_mapping.dat",mem);
 else if(INIT_FILE!="NONE")$readmemb(INIT_FILE,mem);
end
always @(posedge clka)if(cea)begin
 if(rsta)$fatal(1,"RAM unexpectedly reset");
 if(wea)begin if(MODE=="SP"&&INIT_FILE!="NONE")$fatal(1,"ROM write");mem[addra]<=dia;if(WRITEMODE_A=="WRITETHROUGH")doa<=dia;end
 else doa<=mem[addra];
end
generate if(MODE=="DP")begin:g_dp
 always @(posedge clkb)if(ceb)begin
  if(web||rstb)$fatal(1,"Plan RAM read port written/reset");
  dob<=mem[addrb];
 end
end else always @*dob=0;
endgenerate
endmodule
