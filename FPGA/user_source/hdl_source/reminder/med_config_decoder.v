// MED1: fixed 512 bytes, 16 records x8, CRC16-CCITT over bytes0..509.
// Plan RAM stays immutable after publication. No partial plan is valid.
module med_config_decoder(
 input clk,rst,start,valid,input [7:0] data,input finish,file_error,output ready,
 output reg done,plan_valid,output reg [2:0] status,
 output reg config_write,output reg [3:0] config_index,output reg [35:0] config_data
);
reg [9:0] index;
reg [15:0] crc,stored_crc;
assign ready=!done;
reg bad,any_enabled;
// MED1 version 1 has the original fixed names. Version 2 uses header bytes
// 8..11 as independent 0..3 name selections; CRC covers these bytes too.
reg named_version;
reg [1:0] name0,name1,name2,name3;
reg [55:0] record;
// Records are grouped by medicine. Only the previous3 times in that group
// are needed for duplicate detection, instead of a16-way register/mux table.
reg [16:0] previous0,previous1,previous2;
wire [3:0] slot=(index-16)>>3;
wire [2:0] field=(index-16)&7;
wire [1:0] selected_name=slot[3:2]==0?name0:(slot[3:2]==1?name1:(slot[3:2]==2?name2:name3));
wire [4:0] hour=record[15:12]*5'd10+record[11:8];
wire [5:0] minute=record[23:20]*6'd10+record[19:16];
function bcd;input [7:0] v;begin bcd=v[7:4]<=9&&v[3:0]<=9;end endfunction
function [15:0] crc_byte;input [15:0] c;input [7:0] b;integer i;reg [15:0] t;
 begin t=c^{b,8'd0};for(i=0;i<8;i=i+1)t=t[15]?(t<<1)^16'h1021:t<<1;crc_byte=t;end
endfunction
always @(posedge clk or posedge rst)begin
 if(rst)begin
  index<=0;crc<=16'hffff;stored_crc<=0;bad<=0;any_enabled<=0;record<=0;
  done<=0;plan_valid<=0;status<=0;
  config_write<=0;config_index<=0;config_data<=0;
  previous0<=0;previous1<=0;previous2<=0;
  named_version<=0;name0<=0;name1<=1;name2<=2;name3<=3;
 end else if(start)begin
  index<=0;crc<=16'hffff;stored_crc<=0;bad<=0;any_enabled<=0;
  record<=0;done<=0;plan_valid<=0;status<=0;
  config_write<=0;
  previous0<=0;previous1<=0;previous2<=0;
  named_version<=0;name0<=0;name1<=1;name2<=2;name3<=3;
 end else begin
  config_write<=0;
  if(!done)begin
  if(valid&&ready)begin
   index<=index+1'b1;
   if(index<510)crc<=crc_byte(crc,data);
   if(index==510)stored_crc[7:0]<=data;
   if(index==511)stored_crc[15:8]<=data;
   if(index<16)case(index)
    0:if(data!="M")bad<=1;1:if(data!="E")bad<=1;
    2:if(data!="D")bad<=1;3:if(data!="1")bad<=1;
    4:begin named_version<=data==2;if(data!=1&&data!=2)bad<=1;end
    5:if(data!=16)bad<=1;
    6:if(data!=0)bad<=1;7:if(data!=2)bad<=1;
    8,9,10,11:begin
     if(named_version)begin
      if(data>3)bad<=1;
      case(index[1:0])0:name0<=data[1:0];1:name1<=data[1:0];2:name2<=data[1:0];3:name3<=data[1:0];endcase
     end else if(data!=0)bad<=1;
    end
    default:if(data!=0)bad<=1;
   endcase
   else if(index<144)begin
    record<={data,record[55:8]};
    if(field==7)begin
     // record holds bytes0..6 little endian. Entry medicine is slot/4+1.
     case(slot[1:0])
      0:begin previous0<={record[0],record[23:8]};previous1<=0;previous2<=0;end
      1:previous1<={record[0],record[23:8]};
      2:previous2<={record[0],record[23:8]};
      default:;
     endcase
     config_write<=1;config_index<=slot;
     config_data<={selected_name,record[0],hour,minute,record[43:24],record[49:48]};
     if(record[7:0]>1||data!=0)bad<=1;
     if(record[0])begin
      any_enabled<=1;
      if((slot[1:0]>=1&&previous0[16]&&previous0[15:0]==record[23:8])||
         (slot[1:0]>=2&&previous1[16]&&previous1[15:0]==record[23:8])||
         (slot[1:0]==3&&previous2[16]&&previous2[15:0]==record[23:8]))bad<=1;
      if(!bcd(record[15:8])||record[15:8]>8'h23||
         !bcd(record[23:16])||record[23:16]>8'h59||
         !bcd(record[31:24])||!bcd(record[39:32])||
         record[47:44]!=0||record[43:40]>9||record[43:24]==0||record[55:48]>2)bad<=1;
     end else if(record!=0)bad<=1;
    end
   end else if(index<510&&data!=0)bad<=1;
   if(index>=512)bad<=1;
  end
  if(file_error)begin done<=1;status<=6;end
  else if(finish)begin
   if(index!=512||bad)begin done<=1;status<=4;end
   else if(crc!=stored_crc)begin done<=1;status<=5;end
   else begin done<=1;plan_valid<=1;status<=any_enabled?1:2;end
  end
  end
 end
end
endmodule
