// AT24C32 journal. Two disjoint 128-byte records at 0x000 and 0x080.
// Byte0 is the commit marker, bytes1..125 are CRC protected, 126..127 CRC.
// Never write the selected record. Invalidate and read back the other marker,
// write/verify its body, then publish its marker last. No writes during boot.
// Byte writes plus 12ms settle also support the older 10ms AT24C32 revision.
module med_plan_eeprom #(
 parameter integer CLK_HZ=25000000,
 parameter integer WRITE_WAIT_CYCLES=(CLK_HZ/1000)*12,
 parameter integer IO_TIMEOUT_CYCLES=CLK_HZ/4
)(
 input clk,rst,save_request,edit_bank,
 output reg boot_done,boot_valid,boot_bank,output reg [2:0] boot_status,
 output reg available,save_done,save_success,
 output memory_owner,output [4:0] memory_address,
 output reg memory_write,output reg [35:0] memory_wdata,input [35:0] memory_rdata,
 output reg bus_request,bus_read,output [6:0] bus_device,
 output reg [11:0] bus_address,output reg [7:0] bus_write_data,
 input bus_ready,bus_done,bus_error,input [7:0] bus_read_data
);
localparam PROBE=0,BOOT_BYTE=1,BOOT_PARSE=2,ADVANCE_BOOT=3,BANK_END=4,CHOOSE=5,
 IDLE=6,INVALIDATE=7,CHECK_INVALID=8,STREAM_INIT=9,PREPARE=10,FETCH=11,FETCH_WAIT=12,
 TRANSFER=13,TRANSFER_DONE=14,ADVANCE_SAVE=15,COMMIT=16,CHECK_COMMIT=17,FINISH=18,
 IO_REQUEST=19,IO_WAIT=20,IO_DELAY=21,CRC_BITS=22,FAILED=23;
reg [4:0] state,resume,crc_resume;
reg [2:0] device;
reg scan_bank,journal_bank,target_bank,save_bank,verifying;
reg [1:0] valid_banks,enabled_banks;
reg [15:0] generation,generation0,generation1;
wire [15:0] new_generation=boot_valid?generation+16'd1:16'd0;
reg [6:0] index;
reg [3:0] record_index;
reg [2:0] field,crc_bit;
reg [35:0] record;
reg [7:0] received;
wire [7:0] expected=encoded;
reg [15:0] crc,stored_crc;
reg bad,any_enabled;
reg [11:0] previous0,previous1,previous2;
reg [1:0] group_name;
localparam integer TIMER_BITS=$clog2(IO_TIMEOUT_CYCLES+WRITE_WAIT_CYCLES+2);
reg [TIMER_BITS-1:0] timer;
wire record_area=index>=16&&index<96;
wire [35:0] decoded={received[3:0],record[35:4]};
wire duplicate=decoded[33]&&((record_index[1:0]>=1&&previous0[11]&&previous0[10:0]==decoded[32:22])||
 (record_index[1:0]>=2&&previous1[11]&&previous1[10:0]==decoded[32:22])||
 (record_index[1:0]==3&&previous2[11]&&previous2[10:0]==decoded[32:22]));
wire [15:0] generation_delta=generation1-generation0;
wire choose_one=valid_banks[1]&&(!valid_banks[0]||(!generation_delta[15]&&generation_delta!=0));
assign bus_device={4'b1010,device};
assign memory_owner=!boot_done||(state!=IDLE&&state!=FINISH);
assign memory_address={!boot_done?scan_bank:save_bank,record_index};
function invalid_entry;
 input [35:0] v;
 begin invalid_entry=v[33]&&(v[32:28]>23||v[27:22]>59||v[1:0]>2||v[21:2]==0||
  v[21:18]>9||v[17:14]>9||v[13:10]>9||v[9:6]>9||v[5:2]>9);end
endfunction
reg [7:0] encoded;
always @*begin
 encoded=0;
 case(index)
  1:encoded="M";2:encoded="P";3:encoded="J";4:encoded="1";
  5:encoded=new_generation[7:0];6:encoded=new_generation[15:8];7:encoded=16;
  126:encoded=crc[7:0];127:encoded=crc[15:8];
  default:if(record_area)encoded=record[7:0];
 endcase
end
task transaction;
 input rd;input bank;input [6:0] offset;input [7:0] value;input [4:0] next_state;
 begin
  bus_request<=1;bus_read<=rd;bus_address<={4'd0,bank,offset};bus_write_data<=value;
  timer<=0;resume<=next_state;state<=IO_REQUEST;
 end
endtask
task crc_start;
 input [7:0] value;input [4:0] next_state;
 begin crc<=crc^{value,8'd0};crc_bit<=0;crc_resume<=next_state;state<=CRC_BITS;end
endtask
always @(posedge clk or posedge rst)begin
 if(rst)begin
  state<=PROBE;resume<=PROBE;crc_resume<=PROBE;device<=0;scan_bank<=0;journal_bank<=0;target_bank<=0;save_bank<=0;verifying<=0;
  valid_banks<=0;enabled_banks<=0;generation<=0;generation0<=0;generation1<=0;
  index<=0;record_index<=0;field<=0;record<=0;received<=0;crc<=16'hffff;stored_crc<=0;crc_bit<=0;
  bad<=0;any_enabled<=0;previous0<=0;previous1<=0;previous2<=0;group_name<=0;timer<=0;
  boot_done<=0;boot_valid<=0;boot_bank<=0;boot_status<=0;available<=0;save_done<=0;save_success<=0;
  memory_write<=0;memory_wdata<=0;bus_request<=0;bus_read<=1;bus_address<=0;bus_write_data<=0;
 end else begin
  memory_write<=0;
  case(state)
   PROBE:transaction(1,0,0,0,BOOT_PARSE);
   BOOT_BYTE:transaction(1,scan_bank,index,0,BOOT_PARSE);
   BOOT_PARSE:begin
    available<=1;
    if(index==0&&received!=8'ha5)bad<=1;
    case(index)
     1:if(received!="M")bad<=1;2:if(received!="P")bad<=1;
     3:if(received!="J")bad<=1;4:if(received!="1")bad<=1;
     5:generation[7:0]<=received;6:generation[15:8]<=received;
     7:if(received!=16)bad<=1;
     126:stored_crc[7:0]<=received;127:stored_crc[15:8]<=received;
     default:if(index>=8&&index<126&&!record_area&&received!=0)bad<=1;
    endcase
    if(record_area)begin
     record<={received,record[35:8]};
     if(field==4)begin
      // Validate CRC/fields against the original journal bytes, but publish
      // fixed slot names and tablet units to RAM. Boot never writes EEPROM.
      memory_write<=1;memory_wdata<={record_index[3:2],decoded[33:2],2'd0};
      if(received[7:4]!=0||invalid_entry(decoded)||duplicate)bad<=1;
      if(record_index[1:0]==0)group_name<=decoded[35:34];
      else if(group_name!=decoded[35:34])bad<=1;
      if(decoded[33])any_enabled<=1;
      case(record_index[1:0])
       0:begin previous0<={decoded[33],decoded[32:22]};previous1<=0;previous2<=0;end
       1:previous1<={decoded[33],decoded[32:22]};
       2:previous2<={decoded[33],decoded[32:22]};default:;
      endcase
     end
    end
    if(index!=0&&index<126)crc_start(received,ADVANCE_BOOT);
    else state<=ADVANCE_BOOT;
   end
   CRC_BITS:begin
    crc<=crc[15]?(crc<<1)^16'h1021:crc<<1;crc_bit<=crc_bit+1'b1;
    if(crc_bit==7)state<=crc_resume;
   end
   ADVANCE_BOOT:begin
    if(record_area)begin
     if(field==4)begin field<=0;record_index<=record_index+1'b1;end
     else field<=field+1'b1;
    end
    if(index==127)state<=BANK_END;
    else begin index<=index+1'b1;state<=BOOT_BYTE;end
   end
   BANK_END:begin
    valid_banks[scan_bank]<=!bad&&crc==stored_crc;enabled_banks[scan_bank]<=any_enabled;
    if(!scan_bank)begin
     generation0<=generation;scan_bank<=1;index<=0;record_index<=0;field<=0;
     crc<=16'hffff;stored_crc<=0;bad<=0;any_enabled<=0;state<=BOOT_BYTE;
    end else begin generation1<=generation;state<=CHOOSE;end
   end
   CHOOSE:begin
    boot_done<=1;boot_valid<=|valid_banks;boot_bank<=choose_one;journal_bank<=choose_one;
    generation<=choose_one?generation1:generation0;
    boot_status<=|valid_banks?(enabled_banks[choose_one]?3'd1:3'd2):(available?3'd4:3'd3);
    state<=IDLE;
   end
   IDLE:begin
    save_done<=0;
    if(save_request)begin
     save_success<=0;save_bank<=edit_bank;target_bank<=boot_valid?~journal_bank:1'b0;
     if(available)state<=INVALIDATE;else state<=FAILED;
    end
   end
   INVALIDATE:transaction(0,target_bank,0,0,CHECK_INVALID);
   CHECK_INVALID:transaction(1,target_bank,0,0,STREAM_INIT);
   STREAM_INIT:if(received!=0)state<=FAILED;
    else begin index<=1;record_index<=0;field<=0;crc<=16'hffff;verifying<=0;state<=PREPARE;end
   PREPARE:if(record_area&&field==0)state<=FETCH;
    else state<=TRANSFER;
   FETCH:state<=FETCH_WAIT;
   FETCH_WAIT:begin record<=memory_rdata;state<=TRANSFER;end
   TRANSFER:begin transaction(verifying,target_bank,index,encoded,TRANSFER_DONE);end
   TRANSFER_DONE:begin
    if(verifying&&received!=expected)state<=FAILED;
    else if(!verifying&&index<126)crc_start(expected,ADVANCE_SAVE);
    else state<=ADVANCE_SAVE;
   end
   ADVANCE_SAVE:begin
    if(record_area)begin
     record<={8'd0,record[35:8]};
     if(field==4)begin field<=0;record_index<=record_index+1'b1;end
     else field<=field+1'b1;
    end
    if(index==127)begin
     if(verifying)state<=COMMIT;
     else begin verifying<=1;index<=1;record_index<=0;field<=0;state<=PREPARE;end
    end else begin index<=index+1'b1;state<=PREPARE;end
   end
   COMMIT:transaction(0,target_bank,0,8'ha5,CHECK_COMMIT);
   CHECK_COMMIT:transaction(1,target_bank,0,0,FINISH);
   FINISH:begin
    save_done<=1;save_success<=received==8'ha5;
    if(received==8'ha5&&!save_done)begin journal_bank<=target_bank;generation<=new_generation;boot_valid<=1;end
    if(!save_request)begin save_done<=0;state<=IDLE;end
   end
   FAILED:begin save_done<=1;save_success<=0;if(!save_request)begin save_done<=0;state<=IDLE;end end
   IO_REQUEST:begin
    timer<=timer+1'b1;
    if(bus_ready)begin bus_request<=0;timer<=0;state<=IO_WAIT;end
    else if(timer==IO_TIMEOUT_CYCLES-1)begin
     bus_request<=0;
     if(!boot_done)begin bad<=1;state<=available?BANK_END:CHOOSE;end else state<=FAILED;
    end
   end
   IO_WAIT:begin
    timer<=timer+1'b1;
    if(bus_done)begin
     received<=bus_read_data;timer<=0;
     if(bus_error)begin
      if(!boot_done)begin
       if(!available&&device!=7)begin device<=device+1'b1;state<=PROBE;end
       else if(!available)begin state<=CHOOSE;end
       else begin bad<=1;state<=BANK_END;end
      end else state<=FAILED;
     end else state<=bus_read?resume:IO_DELAY;
    end else if(timer==IO_TIMEOUT_CYCLES-1)begin
     if(!boot_done)begin bad<=1;state<=available?BANK_END:CHOOSE;end else state<=FAILED;
    end
   end
   IO_DELAY:begin timer<=timer+1'b1;if(timer==WRITE_WAIT_CYCLES-1)state<=resume;end
   default:state<=FAILED;
  endcase
 end
end
endmodule
