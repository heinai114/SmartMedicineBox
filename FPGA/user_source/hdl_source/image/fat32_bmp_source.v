// Read-only PIC01.BMP..PIC05.BMP FAT32 source. Physical addresses never act
// as an image catalog. The complete allocated file chain is checked before
// opening it; sparse checkpoints and a 256-cluster page support reverse seeks.
module fat32_bmp_source # (parameter MAX_FILE_BYTES=16_777_215,parameter EXPORT_GEOMETRY=0)(
 input clk,input rst,input sd_init_done,input open_file,input [2:0] file_index,
 output reg opened,output reg file_error,output reg [3:0] error_code,
 output reg [31:0] file_bytes,
 input sector_req,input [14:0] sector_index,
 output sector_valid,output reg sector_end,output [7:0] sector_data,
 output sd_req,output reg [31:0] sd_addr,input [7:0] sd_data,input sd_valid,input sd_end,
 output geometry_ready,output [31:0] geometry_fat,geometry_data,
 output [27:0] geometry_root,geometry_limit,output [6:0] geometry_mask,output [2:0] geometry_shift
);
// First fully validated volume on this card epoch. Hold the bundle across
// later image scans; a removed/reinitialized card invalidates it immediately.
generate if(EXPORT_GEOMETRY)begin:g_export
 reg valid_q;reg [31:0] fat_q,data_q;reg [27:0] root_q,limit_q;reg [6:0] mask_q;reg [2:0] shift_q;
 assign geometry_ready=valid_q;assign geometry_fat=fat_q;assign geometry_data=data_q;
 assign geometry_root=root_q;assign geometry_limit=limit_q;assign geometry_mask=mask_q;assign geometry_shift=shift_q;
 always @(posedge clk or posedge rst)begin
  if(rst)valid_q<=0;
  else if(!sd_init_done)valid_q<=0;
  else if(state==GEO_ACCEPT&&!geometry_bad)valid_q<=1;
 end
 always @(posedge clk)if(EXPORT_GEOMETRY&&sd_init_done&&!valid_q&&state==GEO_ACCEPT&&!geometry_bad)begin
  fat_q<=fat_base;data_q<=data_base;root_q<=root_cluster;limit_q<=cluster_limit[27:0];mask_q<=spc_mask;shift_q<=spc_shift;
 end
end else begin:g_no_export
 assign geometry_ready=0;assign geometry_fat=0;assign geometry_data=0;assign geometry_root=0;assign geometry_limit=0;assign geometry_mask=0;assign geometry_shift=0;
end endgenerate
localparam IDLE=0,READ=1,BOOT=2,MBR=3,VBR=4,GEO1=5,GEO2=6,GEO3=7,
 ROOT_BEGIN=8,ROOT_END=9,FAT_BEGIN=10,FAT_END=11,GEO_ACCEPT=12,GEO_SHIFT=13,
 OFFSET_INIT=14,OFFSET_SHIFT=15,OFFSET_ADD=16,FAT_CHECK=17,FAT_PREP=18,FAT_WAIT=19,FAT_BYTE=20,
 COUNT_INIT=21,COUNT_SHIFT=22,CHAIN_RECORD=23,FILE_IDLE=24,SEEK_INIT=25,SEEK_SHIFT=26,
 PAGE_SELECT=27,PAGE_WAIT=28,PAGE_FILL=29,PAGE_READY=30,MAP_WAIT=31,MAP_INIT=32,
 PIXEL_READ=33,MAP_SHIFT=34,MAP_ADD=35,ERR=36,FAT_CLASSIFY=37;
localparam M_BOOT=0,M_VBR=1,M_ROOT=2,M_FAT=3;
localparam ROOT_LINK=0,VALIDATE_LINK=1,PAGE_LINK=2;
reg [5:0] state,return_state,offset_return;
reg [1:0] mode,link_kind;
reg [9:0] received;
wire [8:0] ix=received[8:0];
reg [7:0] fat_cache[0:511];reg [7:0] fat_q;
reg [8:0] fat_byte_addr,fat_offset;
reg [1:0] fat_byte_count;
reg fat_cache_valid;reg [31:0] fat_cache_tag;
reg [27:0] checkpoint[0:127],page_map[0:255];
reg [27:0] checkpoint_q,page_q;
reg [14:0] wanted_cluster;
reg [6:0] active_page;
reg [7:0] fill_index,fill_last;
reg [7:0] spc,fats;
reg [15:0] reserved,flags;
reg jump_ok,bps_ok,root_entries_zero,total16_zero,fat16_zero,version_zero,signature_ok;
reg [31:0] total,fat_size;
reg [27:0] root_cluster;
reg [31:0] mbr_lba,mbr_size;reg [7:0] mbr_type;reg mbr_found;
wire [8:0] partition_index=ix-9'd446;
reg [31:0] volume,partition_sectors,fat_base,data_base,volume_end,cluster_count,cluster_limit,min_fat_sectors;
reg [32:0] overhead,volume_end_wide;
reg geometry_bad;reg vbr_fields_bad;
reg [2:0] shift_left,spc_shift;reg spc_ok;
reg [31:0] cluster_offset,cluster_base;
reg [6:0] spc_mask,sector_in_cluster;
reg [27:0] cluster,fat_next,first_cluster,anchor;
reg [15:0] power,steps,chain_index,cluster_total;
reg chain_last;
// The complete 28-bit link is stable in FAT_CLASSIFY before FAT_END uses
// these registered predicates. Preserve EOC priority over range/cycle errors.
reg fat_eoc,fat_bad;
always @(posedge clk or posedge rst)begin
 if(rst)begin fat_eoc<=0;fat_bad<=0;end
 else begin
  fat_eoc<=fat_next>=28'hffffff8;
  fat_bad<=fat_next<2||fat_next>cluster_limit||fat_next>=28'hffffff0||fat_next==anchor;
 end
end
// Index/total are stable for several FAT/cache states before FAT_CHECK.
// Register this terminal comparison to remove its carry/compare chain from
// the validation-state and cycle-detector enables at the 100MHz SD clock.
always @(posedge clk or posedge rst) begin
 if(rst)chain_last<=0;
 else chain_last<=chain_index+16'd1==cluster_total;
end
reg [14:0] count_work;
reg [12:0] root_sectors;
reg found,root_end,entry_match,entry_live;
// Predict the root READ class on its existing ROOT_BEGIN transition. The
// first valid byte sees this flag already set; the last byte still sees it
// before sd_end clears it. This removes state fanout from directory enables.
reg root_read_active;
always @(posedge clk or posedge rst) begin
 if(rst)root_read_active<=0;
 else if(!sd_init_done)root_read_active<=0;
 else if(state==ROOT_BEGIN)root_read_active<=1;
 else if(state!=READ||sd_end)root_read_active<=0;
end
reg [2:0] target_file;
reg [7:0] entry_attr,entry_high_byte;
reg [27:0] entry_cluster,found_cluster;
reg [23:0] entry_size;
reg entry_accept,request_armed;
reg [14:0] requested_sector;
reg [6:0] requested_spc_sector;
reg [31:0] mapped_offset;
// File length is immutable throughout chain validation and opened-file seeks.
// Keep subtraction out of each request's 100MHz bounds/state-enable path.
reg [22:0] last_file_sector;
always @(posedge clk or posedge rst)begin
 if(rst)last_file_sector<=0;
 else last_file_sector<=(file_bytes-32'd1)>>9;
end
// Predict PIXEL_READ on its existing MAP_ADD transition, so the state
// decoder does not drive every consumer's byte-enable tree. Both entry
// and exit occur on the same edges as the original state predicate.
(* syn_preserve=1 *) reg pixel_read_active;
always @(posedge clk or posedge rst)begin
 if(rst)pixel_read_active<=0;
 else if(!sd_init_done)pixel_read_active<=0;
 else if(state==MAP_ADD)pixel_read_active<=1;
 else if(state!=PIXEL_READ||sd_end)pixel_read_active<=0;
end

// BPB fields finish long before byte511. Keep wide field validation and
// geometry sums out of VBR's state/enable path. Signature remains checked
// directly, including a last valid byte coincident with sector END.
always @(posedge clk or posedge rst)begin
 if(rst)begin vbr_fields_bad<=1;overhead<=0;volume_end_wide<=0;fat_base<=0;end
 else begin
  vbr_fields_bad<=!jump_ok||!bps_ok||!spc_ok||reserved==0||!(fats==1||fats==2)||
   !root_entries_zero||!total16_zero||!fat16_zero||!version_zero||fat_size==0||total==0||
   (flags[7]&&flags[3:0]>=fats)||(partition_sectors!=0&&total>partition_sectors);
  overhead<={17'd0,reserved}+({1'b0,fat_size}<<(fats==2));
  volume_end_wide<={1'b0,volume}+{1'b0,total};
  fat_base<=volume+reserved+((flags[7]&&flags[0])?fat_size:32'd0);
 end
end
assign sd_req=state==READ||state==PIXEL_READ;
assign sector_valid=pixel_read_active&&sd_valid;
assign sector_data=sd_data;
function [7:0] target_char;
 input [3:0] n;
 begin case(n)
  0:target_char="P";1:target_char="I";2:target_char="C";3:target_char="0";
  4:target_char=8'h30+{5'd0,target_file};8:target_char="B";9:target_char="M";
  10:target_char="P";default:target_char=" ";endcase end
endfunction
function part_ok;
 input [7:0] typ;
 begin part_ok=typ==8'h0b||typ==8'h0c||typ==8'h1b||typ==8'h1c;end
endfunction
always @* begin
 spc_ok=1;spc_shift=0;
 case(spc) 1:spc_shift=0;2:spc_shift=1;4:spc_shift=2;8:spc_shift=3;
  16:spc_shift=4;32:spc_shift=5;64:spc_shift=6;128:spc_shift=7;default:spc_ok=0;endcase
end
always @(posedge clk) begin
 if(state==READ&&mode==M_FAT&&sd_valid) fat_cache[ix]<=sd_data;
 fat_q<=fat_cache[fat_byte_addr];
 checkpoint_q<=checkpoint[wanted_cluster[14:8]];
 page_q<=page_map[wanted_cluster[7:0]];
 if(state==CHAIN_RECORD) begin
  if(chain_index[7:0]==0) checkpoint[chain_index[14:8]]<=cluster;
  if(chain_index<256) page_map[chain_index[7:0]]<=cluster;
 end
 if(state==PAGE_FILL) page_map[fill_index]<=cluster;
end
// Break the directory decode from the wide size-register enable.
always @(posedge clk or posedge rst) begin
 if(rst) begin entry_accept<=0;entry_high_byte<=0;file_bytes<=0;end
 else begin
  entry_high_byte<=sd_data;
  entry_accept<=root_read_active&&sd_valid&&ix[4:0]==31&&entry_live&&entry_match&&
   !root_end&&!found&&(entry_attr&8'h18)==0&&entry_attr!=8'h0f;
  if(open_file&&(state==IDLE||state==FILE_IDLE||state==ERR)) file_bytes<=0;
  else if(entry_accept) file_bytes<={entry_high_byte,entry_size};
 end
end
always @(posedge clk or posedge rst) begin
 if(rst) begin
  state<=IDLE;return_state<=IDLE;offset_return<=ROOT_BEGIN;mode<=0;link_kind<=0;
  received<=0;sd_addr<=0;opened<=0;file_error<=0;error_code<=0;sector_end<=0;
  target_file<=0;fat_cache_valid<=0;fat_cache_tag<=0;fat_byte_addr<=0;fat_offset<=0;fat_byte_count<=0;
  wanted_cluster<=0;active_page<=0;fill_index<=0;fill_last<=0;
  spc<=0;fats<=0;reserved<=0;flags<=0;jump_ok<=0;bps_ok<=0;root_entries_zero<=0;total16_zero<=0;
  fat16_zero<=0;version_zero<=0;signature_ok<=0;total<=0;fat_size<=0;root_cluster<=0;
  mbr_lba<=0;mbr_size<=0;mbr_type<=0;mbr_found<=0;volume<=0;partition_sectors<=0;
  data_base<=0;volume_end<=0;cluster_count<=0;cluster_limit<=0;min_fat_sectors<=0;
  geometry_bad<=0;shift_left<=0;cluster_offset<=0;cluster_base<=0;
  spc_mask<=0;sector_in_cluster<=0;cluster<=0;fat_next<=0;first_cluster<=0;anchor<=0;
  power<=1;steps<=0;chain_index<=0;cluster_total<=0;count_work<=0;root_sectors<=0;
  found<=0;root_end<=0;entry_match<=0;entry_live<=0;entry_attr<=0;entry_cluster<=0;
  entry_size<=0;found_cluster<=0;request_armed<=1;requested_sector<=0;requested_spc_sector<=0;mapped_offset<=0;
 end else begin
  sector_end<=0;
  if(!sector_req) request_armed<=1;
  if(state==READ&&sd_valid) begin
   received<=received+1'b1;
   if(mode==M_BOOT||mode==M_VBR) begin
    case(ix)
     0:jump_ok<=sd_data==8'heb||sd_data==8'he9;11:bps_ok<=sd_data==0;12:bps_ok<=bps_ok&&sd_data==2;
     13:spc<=sd_data;14:reserved[7:0]<=sd_data;15:reserved[15:8]<=sd_data;16:fats<=sd_data;
     17:root_entries_zero<=sd_data==0;18:root_entries_zero<=root_entries_zero&&sd_data==0;
     19:total16_zero<=sd_data==0;20:total16_zero<=total16_zero&&sd_data==0;
     22:fat16_zero<=sd_data==0;23:fat16_zero<=fat16_zero&&sd_data==0;
     32:total[7:0]<=sd_data;33:total[15:8]<=sd_data;34:total[23:16]<=sd_data;35:total[31:24]<=sd_data;
     36:fat_size[7:0]<=sd_data;37:fat_size[15:8]<=sd_data;38:fat_size[23:16]<=sd_data;39:fat_size[31:24]<=sd_data;
     40:flags[7:0]<=sd_data;41:flags[15:8]<=sd_data;42:version_zero<=sd_data==0;43:version_zero<=version_zero&&sd_data==0;
     44:root_cluster[7:0]<=sd_data;45:root_cluster[15:8]<=sd_data;46:root_cluster[23:16]<=sd_data;47:root_cluster[27:24]<=sd_data[3:0];
     510:signature_ok<=sd_data==8'h55;511:signature_ok<=signature_ok&&sd_data==8'haa;
    endcase
    if(mode==M_BOOT&&ix>=446&&ix<510) case(partition_index[3:0])
     4:mbr_type<=sd_data;
     8:mbr_lba[7:0]<=sd_data;9:mbr_lba[15:8]<=sd_data;10:mbr_lba[23:16]<=sd_data;11:mbr_lba[31:24]<=sd_data;
     12:mbr_size[7:0]<=sd_data;13:mbr_size[15:8]<=sd_data;14:mbr_size[23:16]<=sd_data;
     15:if(!mbr_found&&part_ok(mbr_type)&&mbr_lba!=0) begin volume<=mbr_lba;partition_sectors<={sd_data,mbr_size[23:0]};mbr_found<=1;end
    endcase
   end
  end
  if(root_read_active&&sd_valid) begin
    case(ix[4:0])
     0:begin entry_match<=sd_data==target_char(0);entry_live<=sd_data!=0&&sd_data!=8'he5;if(sd_data==0)root_end<=1;end
     1,2,3,4,5,6,7,8,9,10:entry_match<=entry_match&&sd_data==target_char(ix[3:0]);
     11:entry_attr<=sd_data;
     20:entry_cluster[23:16]<=sd_data;21:entry_cluster[27:24]<=sd_data[3:0];
     26:entry_cluster[7:0]<=sd_data;27:entry_cluster[15:8]<=sd_data;
     28:entry_size[7:0]<=sd_data;29:entry_size[15:8]<=sd_data;30:entry_size[23:16]<=sd_data;
     31:if(entry_live&&entry_match&&!root_end&&!found&&(entry_attr&8'h18)==0&&entry_attr!=8'h0f) begin found<=1;found_cluster<=entry_cluster;end
    endcase
  end
  if(!sd_init_done) begin
   if(state!=IDLE) begin file_error<=1;error_code<=1;end
   opened<=0;fat_cache_valid<=0;state<=IDLE;
  end else if(open_file&&(state==IDLE||state==FILE_IDLE||state==ERR)) begin
   opened<=0;file_error<=0;error_code<=0;target_file<=file_index;fat_cache_valid<=0;
   sd_addr<=0;received<=0;mode<=M_BOOT;return_state<=BOOT;state<=READ;
   volume<=0;partition_sectors<=0;mbr_found<=0;found<=0;root_end<=0;root_sectors<=0;request_armed<=1;
   if(file_index<1||file_index>5) begin state<=ERR;file_error<=1;error_code<=4;end
  end else case(state)
   READ:if(sd_end) begin
    if(!((received==512&&!sd_valid)||(received==511&&sd_valid))) begin state<=ERR;file_error<=1;error_code<=1;end
    else begin
     if(mode==M_FAT) begin fat_cache_valid<=1;fat_cache_tag<=sd_addr;end
     state<=return_state;
    end
   end
   BOOT:begin
    if(!signature_ok) begin state<=ERR;file_error<=1;error_code<=2;end
    else if(jump_ok&&bps_ok&&fat16_zero&&root_entries_zero) begin volume<=0;partition_sectors<=0;state<=VBR;end
    else state<=MBR;
   end
   MBR:begin
    if(mbr_found) begin sd_addr<=volume;state<=READ;end
    else begin state<=ERR;file_error<=1;error_code<=2;end
    received<=0;mode<=M_VBR;return_state<=VBR;
   end
   VBR:begin
    if(!signature_ok||vbr_fields_bad) begin state<=ERR;file_error<=1;error_code<=3;end
    else state<=GEO1;
   end
   GEO1:begin
    if(overhead>=total||volume_end_wide[32]) begin state<=ERR;file_error<=1;error_code<=3;end
    else begin data_base<=volume+overhead[31:0];volume_end<=volume_end_wide[31:0];
     cluster_count<=total-overhead[31:0];shift_left<=spc_shift;spc_mask<=spc-1'b1;state<=GEO_SHIFT;end
   end
   GEO_SHIFT:if(shift_left!=0)begin cluster_count<=cluster_count>>1;shift_left<=shift_left-1'b1;end else state<=GEO2;
   GEO2:begin cluster_limit<=cluster_count+1'b1;min_fat_sectors<=(cluster_count+129)>>7;state<=GEO3;end
   GEO3:begin geometry_bad<=cluster_count<65525||cluster_count>32'h0fffffee||root_cluster<2||root_cluster>cluster_limit||fat_size<min_fat_sectors;state<=GEO_ACCEPT;end
   GEO_ACCEPT:begin
    if(geometry_bad)begin state<=ERR;file_error<=1;error_code<=3;end
    else begin cluster<=root_cluster;sector_in_cluster<=0;anchor<=root_cluster;power<=1;steps<=0;offset_return<=ROOT_BEGIN;state<=OFFSET_INIT;end
   end
   OFFSET_INIT:begin cluster_offset<={4'd0,cluster}-32'd2;shift_left<=spc_shift;state<=OFFSET_SHIFT;end
   OFFSET_SHIFT:if(shift_left!=0)begin cluster_offset<=cluster_offset<<1;shift_left<=shift_left-1'b1;end else state<=OFFSET_ADD;
   OFFSET_ADD:begin cluster_base<=data_base+cluster_offset;state<=offset_return;end
   ROOT_BEGIN:begin sd_addr<=cluster_base+sector_in_cluster;mode<=M_ROOT;received<=0;return_state<=ROOT_END;state<=READ;root_sectors<=root_sectors+1'b1;end
   ROOT_END:begin
    if(found)begin
     if(found_cluster<2||found_cluster>cluster_limit||file_bytes<54||file_bytes>MAX_FILE_BYTES)begin state<=ERR;file_error<=1;error_code<=5;end
     else begin cluster<=found_cluster;first_cluster<=found_cluster;count_work<=(file_bytes-1'b1)>>9;shift_left<=spc_shift;state<=COUNT_SHIFT;end
    end else if(root_end||root_sectors>=4096)begin state<=ERR;file_error<=1;error_code<=4;end
    else if(sector_in_cluster<spc_mask)begin sector_in_cluster<=sector_in_cluster+1'b1;state<=ROOT_BEGIN;end
    else begin link_kind<=ROOT_LINK;state<=FAT_BEGIN;end
   end
   COUNT_SHIFT:if(shift_left!=0)begin count_work<=count_work>>1;shift_left<=shift_left-1'b1;end else begin cluster_total<={1'b0,count_work}+16'd1;chain_index<=0;anchor<=first_cluster;power<=1;steps<=0;state<=CHAIN_RECORD;end
   CHAIN_RECORD:begin link_kind<=VALIDATE_LINK;state<=FAT_BEGIN;end
   FAT_BEGIN:begin sd_addr<=fat_base+(cluster>>7);fat_offset<={cluster[6:0],2'b0};fat_next<=0;state<=FAT_CHECK;end
   FAT_CHECK:begin
    if(fat_cache_valid&&fat_cache_tag==sd_addr)begin fat_byte_addr<=fat_offset;fat_byte_count<=0;state<=FAT_PREP;end
    else begin mode<=M_FAT;received<=0;return_state<=FAT_PREP;fat_byte_addr<=fat_offset;fat_byte_count<=0;state<=READ;end
   end
   FAT_PREP:state<=FAT_WAIT;
   FAT_WAIT:state<=FAT_BYTE;
   FAT_BYTE:begin
    case(fat_byte_count)0:fat_next[7:0]<=fat_q;1:fat_next[15:8]<=fat_q;2:fat_next[23:16]<=fat_q;3:fat_next[27:24]<=fat_q[3:0];endcase
    if(fat_byte_count==3)state<=FAT_CLASSIFY;
    else begin fat_byte_count<=fat_byte_count+1'b1;fat_byte_addr<=fat_byte_addr+1'b1;state<=FAT_PREP;end
   end
   FAT_CLASSIFY:state<=FAT_END;
   FAT_END:begin
    if(link_kind==VALIDATE_LINK&&chain_last)begin
     if(!fat_eoc)begin state<=ERR;file_error<=1;error_code<=6;end
     else begin opened<=1;active_page<=0;state<=FILE_IDLE;end
    end else if(link_kind==ROOT_LINK&&fat_eoc)begin state<=ERR;file_error<=1;error_code<=4;end
    else if(fat_bad)begin state<=ERR;file_error<=1;error_code<=6;end
    else begin
     cluster<=fat_next;
     if(steps+1'b1==power)begin anchor<=fat_next;steps<=0;if(!power[15])power<=power<<1;end else steps<=steps+1'b1;
     if(link_kind==ROOT_LINK)begin sector_in_cluster<=0;offset_return<=ROOT_BEGIN;state<=OFFSET_INIT;end
     else if(link_kind==VALIDATE_LINK)begin chain_index<=chain_index+1'b1;state<=CHAIN_RECORD;end
     else begin fill_index<=fill_index+1'b1;state<=PAGE_FILL;end
    end
   end
   FILE_IDLE:if(sector_req&&request_armed)begin requested_sector<=sector_index;request_armed<=0;state<=SEEK_INIT;end
   SEEK_INIT:begin
    if({1'b0,requested_sector}>last_file_sector)begin state<=ERR;opened<=0;file_error<=1;error_code<=5;end
    else begin wanted_cluster<=requested_sector;requested_spc_sector<=requested_sector[6:0]&spc_mask;shift_left<=spc_shift;state<=SEEK_SHIFT;end
   end
   SEEK_SHIFT:if(shift_left!=0)begin wanted_cluster<=wanted_cluster>>1;shift_left<=shift_left-1'b1;end else state<=PAGE_SELECT;
   PAGE_SELECT:if(wanted_cluster[14:8]==active_page)state<=MAP_WAIT;else state<=PAGE_WAIT;
   PAGE_WAIT:begin
    cluster<=checkpoint_q;fill_index<=0;anchor<=checkpoint_q;power<=1;steps<=0;
    fill_last<=cluster_total>{1'b0,wanted_cluster[14:8],8'hff}?8'hff:(cluster_total-1'b1);
    state<=PAGE_FILL;
   end
   PAGE_FILL:if(fill_index==fill_last)begin active_page<=wanted_cluster[14:8];state<=PAGE_READY;end else begin link_kind<=PAGE_LINK;state<=FAT_BEGIN;end
   PAGE_READY:state<=MAP_WAIT;
   MAP_WAIT:state<=MAP_INIT;
   MAP_INIT:begin mapped_offset<={4'd0,page_q}-32'd2;shift_left<=spc_shift;state<=MAP_SHIFT;end
   MAP_SHIFT:if(shift_left!=0)begin mapped_offset<=mapped_offset<<1;shift_left<=shift_left-1'b1;end else state<=MAP_ADD;
   MAP_ADD:begin sd_addr<=data_base+mapped_offset+requested_spc_sector;received<=0;state<=PIXEL_READ;end
   PIXEL_READ:begin
    if(sd_valid)received<=received+1'b1;
    if(sd_end)begin
     if(!((received==512&&!sd_valid)||(received==511&&sd_valid)))begin state<=ERR;opened<=0;file_error<=1;error_code<=1;end
     else begin sector_end<=1;state<=FILE_IDLE;end
    end
   end
  endcase
 end
end
endmodule
