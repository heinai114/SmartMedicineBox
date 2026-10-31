// Explicit 16-bit physical port geometry; 36-bit entries use three 32K blocks.
module med_plan_store #(parameter INDEX_BITS=4)(
 input wclk,write,input [INDEX_BITS-1:0] write_index,input [35:0] write_data,
 input rclk,input [INDEX_BITS-1:0] read_index,output [35:0] read_data,write_read_data
);
wire [47:0] rd,wd;wire [47:0] value={12'd0,write_data};
assign read_data=rd[35:0];assign write_read_data=wd[35:0];
genvar bank;
generate for(bank=0;bank<3;bank=bank+1)begin:g_bank
 EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
  .DATA_WIDTH_B(16),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),.MODE("DP"),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
  // Runtime clients ignore A's result on writes. Native write-through avoids
  // synthesis glue that otherwise retains the previous read result.
  .WRITEMODE_A(INDEX_BITS==5?"WRITETHROUGH":"NORMAL"),
  .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("NONE"),.FILL_ALL("NONE"))u_ram(
  .dia(value[bank*16+:16]),.dib(16'd0),
  .addra({{(11-INDEX_BITS){1'b0}},write_index}),.addrb({{(11-INDEX_BITS){1'b0}},read_index}),
  .cea(1'b1),.ceb(1'b1),.ocea(1'b1),.oceb(1'b1),.clka(wclk),.clkb(rclk),
  .wea(write),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),
  .doa(wd[bank*16+:16]),.dob(rd[bank*16+:16]));
end endgenerate
endmodule
