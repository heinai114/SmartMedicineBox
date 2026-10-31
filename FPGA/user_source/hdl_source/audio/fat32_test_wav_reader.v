// Read-only FAT32 selected root TEST.WAV / ASCEND.WAV (8.3).
// Supports MBR primary FAT32 partitions
// and unpartitioned FAT32, fragmented file/root chains, active FAT selection.
// A single synchronous sector cache is reused; output bytes obey backpressure.
module fat32_test_wav_reader #(parameter FILE_BITS=2,parameter MAX_FILE_BYTES=16_777_216,parameter CONFIG_SUPPORT=0,parameter SHARED_GEOMETRY=0)(
    input clk,input rst,input start,input cancel,input sd_init_done,input [FILE_BITS-1:0] file_select,
    output busy,output error,output done,output reg [3:0] error_code,
    output reg [31:0] file_bytes,output reg [31:0] config_lba,output reg config_lba_valid,
    output valid,output [7:0] data,input ready,
    output req,output reg [31:0] addr,input [7:0] sd_data,
    input sd_valid,input sd_end,input sd_error,
 input geometry_ready,input [31:0] geometry_fat,geometry_data,
 input [27:0] geometry_root,geometry_limit,input [6:0] geometry_mask,input [2:0] geometry_shift
);
localparam IDLE=0,READ=1,BOOT=2,MBR=3,VBR=4,GEO1=5,GEO2=6,GEO3=7,
    ROOT_BEGIN=8,ROOT_END=9,FAT_BEGIN=10,FAT_END=11,FILE_BEGIN=12,
    FILE_END=13,BPREP=14,BWAIT=15,BYTE=16,NEXT_SECTOR=17,DONE=18,ERR=19,GEO_ACCEPT=20,
    GEO_SHIFT=21,OFFSET_INIT=22,OFFSET_SHIFT=23,OFFSET_ADD=24,CONFIG_ROOT_SETTLE=25;
localparam M_BOOT=0,M_VBR=1,M_ROOT=2,M_FAT=3,M_FILE=4;
reg [4:0] state,return_state;
reg [2:0] mode;
reg [9:0] received;
wire [8:0] ix=received[8:0];
reg [7:0] cache [0:511];
reg [8:0] byte_index;
reg [7:0] cache_q;
reg [7:0] spc,fats;
reg [15:0] reserved,flags;
reg jump_ok,bps_ok,root_entries_zero,total16_zero,fat16_zero,version_zero,signature_ok;
reg [31:0] total,fat_size;
reg [27:0] local_root_cluster;
// Stream the four primary entries through one register set, retaining only
// the first usable FAT32 partition. No four-way 72-bit register/mux bank.
reg [31:0] mbr_lba,mbr_size;reg [7:0] mbr_type;reg mbr_found;
wire [8:0] partition_index=ix-9'd446;
reg [31:0] volume,partition_bytes_sectors,local_fat_base,local_data_base,volume_end,cluster_count;
reg [31:0] local_cluster_limit,min_fat_sectors;
wire [31:0] fat_base=SHARED_GEOMETRY?geometry_fat:local_fat_base;
wire [31:0] data_base=SHARED_GEOMETRY?geometry_data:local_data_base;
wire [31:0] cluster_limit=SHARED_GEOMETRY?{4'd0,geometry_limit}:local_cluster_limit;
wire [27:0] root_cluster=SHARED_GEOMETRY?geometry_root:local_root_cluster;
wire [6:0] spc_mask=SHARED_GEOMETRY?geometry_mask:local_spc_mask;
wire [2:0] spc_shift=SHARED_GEOMETRY?geometry_shift:local_spc_shift;
reg geometry_bad;
// Geometry and a cluster's base address change only while no sector is in
// flight. A single-bit iterative shifter replaces two wide barrel shifters.
reg [2:0] shift_left;
reg [31:0] cluster_offset,cluster_base;
reg [4:0] offset_return;
reg [32:0] overhead,volume_end_wide;
reg [6:0] local_spc_mask;reg [2:0] local_spc_shift;reg spc_ok;
reg [27:0] cluster,fat_next;
reg [6:0] sector_in_cluster;
reg [24:0] file_pos;
reg [24:0] file_last_pos;
reg [8:0] fat_offset;
reg fat_for_file;
reg [27:0] anchor;
reg [15:0] power,steps;
reg [12:0] root_sectors;
reg found,root_end,entry_match,entry_live;
reg [FILE_BITS-1:0] target_file;
wire [7:0] expected_name_char;
reg entry_accept;
(* syn_preserve=1 *)reg found_cluster_bad,bpb_fields_ok,partition_fits;
always @(posedge clk or posedge rst)begin
 if(rst)begin found_cluster_bad<=0;bpb_fields_ok<=0;partition_fits<=0;end
 else begin
  if(state==READ&&sd_valid&&mode==M_ROOT&&ix[4:0]==31&&!found)found_cluster_bad<=entry_cluster<2||entry_cluster>cluster_limit;
  bpb_fields_ok<=jump_ok&&bps_ok&&spc_ok&&reserved!=0&&(fats==1||fats==2)&&root_entries_zero&&total16_zero&&fat16_zero&&version_zero&&fat_size!=0&&total!=0&&!(flags[7]&&flags[3:0]>=fats);
  if(state==BOOT&&jump_ok&&bps_ok&&fat16_zero&&root_entries_zero)partition_fits<=1;
  else partition_fits<=partition_bytes_sectors==0||total<=partition_bytes_sectors;
 end
end
reg [7:0] entry_high_byte;
reg [7:0] entry_attr;
reg [27:0] entry_cluster,found_cluster;
reg [23:0] entry_size;
assign busy=state!=IDLE&&state!=DONE&&state!=ERR;
assign error=state==ERR;assign done=state==DONE;
assign req=state==READ;
assign valid=state==BYTE&&!cancel;
assign data=cache_q;
function [7:0] target_char;
    input [3:0] n;
    begin
        if(CONFIG_SUPPORT&&target_file==17)case(n)
            0:target_char="M";1:target_char="E";2:target_char="D";
            3:target_char="C";4:target_char="F";5:target_char="G";
            8:target_char="B";9:target_char="I";10:target_char="N";default:target_char=" ";endcase
        else if(target_file>=18&&target_file<=20) case(n)
            0:target_char="M";1:target_char="U";2:target_char="S";3:target_char="I";
            4:target_char="C";5:target_char="0";6:target_char="1"+(target_file-18);
            8:target_char="W";9:target_char="A";10:target_char="V";default:target_char=" ";endcase
        else if(target_file>=12&&target_file<=16) case(n)
            0:target_char="E";1:target_char="X";2:target_char="T";3:target_char="0";4:target_char="1"+(target_file-12);
            8:target_char="W";9:target_char="A";10:target_char="V";default:target_char=" ";endcase
        else if(target_file>=7&&target_file<=11) case(n)
            0:target_char="D";1:target_char="E";2:target_char="P";3:target_char="0";4:target_char="1"+(target_file-7);
            8:target_char="W";9:target_char="A";10:target_char="V";default:target_char=" ";endcase
        else if(target_file>=3) case(n)
            0:target_char="A";1:target_char="U";2:target_char="D";3:target_char="0";4:target_char="1"+(target_file-3);
            8:target_char="W";9:target_char="A";10:target_char="V";default:target_char=" ";endcase
        else if(target_file==2) case(n)
            0:target_char="B";1:target_char="M";2:target_char="I";
            8:target_char="W";9:target_char="A";10:target_char="V";default:target_char=" ";endcase
        else if(target_file==1) case(n)
            0:target_char="A";1:target_char="S";2:target_char="C";3:target_char="E";
            4:target_char="N";5:target_char="D";8:target_char="W";9:target_char="A";
            10:target_char="V";default:target_char=" ";endcase
        else case(n) 0:target_char="T";1:target_char="E";2:target_char="S";3:target_char="T";
            8:target_char="W";9:target_char="A";10:target_char="V";default:target_char=" ";endcase
    end
endfunction
// The next directory-byte offset is known after each valid byte. Precompute
// its name character so the100MHz received counter does not feed both the
// enlarged filename decode and the entry-match feedback in one clock.
// ROOT_BEGIN preloads byte0; gaps keep the current byte, and offset31 wraps.
wire [3:0] name_index=state==ROOT_BEGIN ? 4'd0 :
    (state==READ&&mode==M_ROOT&&sd_valid ? ix[3:0]+4'd1 : ix[3:0]);
wire [11:0] name_address={{(8-FILE_BITS){1'b0}},target_file,name_index};
EG_LOGIC_BRAM #(.DATA_WIDTH_A(8),.ADDR_WIDTH_A(12),.DATA_DEPTH_A(4096),
 .DATA_WIDTH_B(8),.ADDR_WIDTH_B(12),.DATA_DEPTH_B(4096),.MODE("SP"),
 .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),
 .DEBUGGABLE("NO"),.PACKABLE("NO"),
 .INIT_FILE(CONFIG_SUPPORT ? "audio_filename_config.dat" : "audio_filename.dat"),.FILL_ALL("NONE"))u_filename(
 .dia(8'd0),.dib(8'd0),.addra(name_address),.addrb(12'd0),
 .cea(1'b1),.ceb(1'b0),.ocea(1'b1),.oceb(1'b0),.clka(clk),.clkb(1'b0),
 .wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(expected_name_char),.dob());
// Directory acceptance is registered separately from the 32-bit file-size
// enable. The full sector ends before ROOT_END uses the captured size, even
// when the accepted directory entry is the last entry in the sector.
always @(posedge clk or posedge rst) begin
    if(rst) begin entry_accept<=0;entry_high_byte<=0;file_bytes<=0;end
    else begin
        entry_high_byte<=sd_data;
        entry_accept<=state==READ&&sd_valid&&mode==M_ROOT&&ix[4:0]==31&&
            entry_live&&entry_match&&!root_end&&!found&&(entry_attr&8'h18)==0&&entry_attr!=8'h0f;
        if(start&&!busy&&sd_init_done) file_bytes<=0;
        else if(entry_accept) file_bytes<={entry_high_byte,entry_size[23:0]};
    end
end
function part_ok;
    input [7:0] typ;
    begin part_ok=typ==8'h0b||typ==8'h0c||typ==8'h1b||typ==8'h1c;end
endfunction
always @* begin
    spc_ok=1;local_spc_shift=0;
    case(spc) 1:local_spc_shift=0;2:local_spc_shift=1;4:local_spc_shift=2;8:local_spc_shift=3;
        16:local_spc_shift=4;32:local_spc_shift=5;64:local_spc_shift=6;128:local_spc_shift=7;default:spc_ok=0;endcase
end
always @(posedge clk) begin
    if(state==READ&&sd_valid) cache[ix]<=sd_data;
    cache_q<=cache[byte_index];
end
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE;return_state<=IDLE;mode<=0;received<=0;byte_index<=0;addr<=0;
        jump_ok<=0;spc<=0;fats<=0;bps_ok<=0;reserved<=0;root_entries_zero<=0;total16_zero<=0;fat16_zero<=0;
        flags<=0;version_zero<=0;signature_ok<=0;total<=0;fat_size<=0;local_root_cluster<=0;
        volume<=0;partition_bytes_sectors<=0;local_fat_base<=0;local_data_base<=0;volume_end<=0;
        local_cluster_limit<=0;min_fat_sectors<=0;file_last_pos<=0;
        geometry_bad<=0;
        shift_left<=0;cluster_offset<=0;cluster_base<=0;offset_return<=ROOT_BEGIN;
        overhead<=0;volume_end_wide<=0;cluster_count<=0;local_spc_mask<=0;
        cluster<=0;sector_in_cluster<=0;file_pos<=0;fat_next<=0;fat_offset<=0;fat_for_file<=0;
        anchor<=0;power<=1;steps<=0;root_sectors<=0;found<=0;root_end<=0;
        entry_match<=0;entry_live<=0;entry_attr<=0;entry_cluster<=0;entry_size<=0;found_cluster<=0;
        error_code<=0;target_file<=0;config_lba<=0;config_lba_valid<=0;
        mbr_lba<=0;mbr_size<=0;mbr_type<=0;mbr_found<=0;
    end else begin
        if(state==READ&&sd_valid) begin
            received<=received+1'b1;
            if(!SHARED_GEOMETRY&&(mode==M_BOOT||mode==M_VBR)) begin
                case(ix)
                0:jump_ok<=sd_data==8'heb||sd_data==8'he9;11:bps_ok<=sd_data==0;12:bps_ok<=bps_ok && sd_data==2;
                13:spc<=sd_data;14:reserved[7:0]<=sd_data;15:reserved[15:8]<=sd_data;16:fats<=sd_data;
                17:root_entries_zero<=sd_data==0;18:root_entries_zero<=root_entries_zero && sd_data==0;
                19:total16_zero<=sd_data==0;20:total16_zero<=total16_zero && sd_data==0;
                22:fat16_zero<=sd_data==0;23:fat16_zero<=fat16_zero && sd_data==0;
                32:total[7:0]<=sd_data;33:total[15:8]<=sd_data;34:total[23:16]<=sd_data;35:total[31:24]<=sd_data;
                36:fat_size[7:0]<=sd_data;37:fat_size[15:8]<=sd_data;38:fat_size[23:16]<=sd_data;39:fat_size[31:24]<=sd_data;
                40:flags[7:0]<=sd_data;41:flags[15:8]<=sd_data;42:version_zero<=sd_data==0;43:version_zero<=version_zero && sd_data==0;
                44:local_root_cluster[7:0]<=sd_data;45:local_root_cluster[15:8]<=sd_data;46:local_root_cluster[23:16]<=sd_data;47:local_root_cluster[27:24]<=sd_data[3:0];
                510:signature_ok<=sd_data==8'h55;511:signature_ok<=signature_ok && sd_data==8'haa;
                endcase
                if(mode==M_BOOT&&ix>=446&&ix<510) case(partition_index[3:0])
                    4:mbr_type<=sd_data;
                    8:mbr_lba[7:0]<=sd_data;9:mbr_lba[15:8]<=sd_data;
                    10:mbr_lba[23:16]<=sd_data;11:mbr_lba[31:24]<=sd_data;
                    12:mbr_size[7:0]<=sd_data;13:mbr_size[15:8]<=sd_data;
                    14:mbr_size[23:16]<=sd_data;
                    15:if(!mbr_found&&part_ok(mbr_type)&&mbr_lba!=0) begin
                        volume<=mbr_lba;partition_bytes_sectors<={sd_data,mbr_size[23:0]};mbr_found<=1;
                    end
                endcase
            end else if(mode==M_ROOT) begin
                case(ix[4:0])
                0:begin
                    entry_match<=sd_data==expected_name_char;entry_live<=sd_data!=0&&sd_data!=8'he5;
                    if(sd_data==0) root_end<=1;
                end
                1,2,3,4,5,6,7,8,9,10:entry_match<=entry_match&&sd_data==expected_name_char;
                11:entry_attr<=sd_data;
                20:entry_cluster[23:16]<=sd_data;21:entry_cluster[27:24]<=sd_data[3:0];
                26:entry_cluster[7:0]<=sd_data;27:entry_cluster[15:8]<=sd_data;
                28:entry_size[7:0]<=sd_data;29:entry_size[15:8]<=sd_data;30:entry_size[23:16]<=sd_data;
                31:if(entry_live&&entry_match&&!root_end&&!found&&(entry_attr&8'h18)==0&&entry_attr!=8'h0f) begin
                    found<=1;found_cluster<=entry_cluster&32'h0fffffff;
                end
                endcase
            end else if(mode==M_FAT) begin
                if(ix==fat_offset) fat_next[7:0]<=sd_data;
                if(ix==fat_offset+1) fat_next[15:8]<=sd_data;
                if(ix==fat_offset+2) fat_next[23:16]<=sd_data;
                if(ix==fat_offset+3) fat_next[27:24]<=sd_data[3:0];
            end
        end
        if(cancel) begin
            // Never cancel a physical sector halfway through a transaction.
            if(state!=READ||sd_end||sd_error||!sd_init_done) state<=IDLE;
        end else if(sd_error) begin state<=ERR;error_code<=1;end
        else if(start&&!busy&&sd_init_done) begin
            addr<=0;received<=0;mode<=M_BOOT;return_state<=BOOT;state<=READ;
            volume<=0;partition_bytes_sectors<=0;found<=0;root_end<=0;root_sectors<=0;
            file_pos<=0;error_code<=0;target_file<=file_select;
            mbr_found<=0;
            if(CONFIG_SUPPORT&&file_select==17)begin config_lba<=0;config_lba_valid<=0;end
            if(SHARED_GEOMETRY)begin
                if(!geometry_ready)begin state<=ERR;error_code<=3;end
                else begin
                    cluster<=root_cluster;sector_in_cluster<=0;anchor<=root_cluster;power<=1;steps<=0;
                    offset_return<=ROOT_BEGIN;state<=OFFSET_INIT;
                end
            end
        end else case(state)
        READ:if(sd_end) begin
            if(!((received==512&&!sd_valid)||(received==511&&sd_valid))) begin state<=ERR;error_code<=1;end
            // Only the new configuration transaction adds this wait. Its
            // last directory entry may share the last valid byte with END;
            // let the existing registered file-size acceptance complete.
            else if(CONFIG_SUPPORT&&target_file==17&&return_state==ROOT_END)state<=CONFIG_ROOT_SETTLE;
            else state<=return_state;
        end
        BOOT:if(!SHARED_GEOMETRY)begin
            if(!signature_ok) begin state<=ERR;error_code<=2;end
            else if(jump_ok&&bps_ok&&fat16_zero&&root_entries_zero) begin
                volume<=0;partition_bytes_sectors<=0;state<=VBR;
            end
            else state<=MBR;
        end
        MBR:if(!SHARED_GEOMETRY)begin
            if(mbr_found) begin addr<=volume;state<=READ;end
            else begin state<=ERR;error_code<=2;end
            received<=0;mode<=M_VBR;return_state<=VBR;
        end
        VBR:if(!SHARED_GEOMETRY)begin
            if(!signature_ok||!bpb_fields_ok||!partition_fits) begin state<=ERR;error_code<=3;end
            else begin
                overhead<={17'd0,reserved}+({1'b0,fat_size}<<(fats==2));
                volume_end_wide<={1'b0,volume}+{1'b0,total};state<=GEO1;
            end
        end
        GEO1:if(!SHARED_GEOMETRY)begin
            if(overhead>=total||volume_end_wide[32]) begin state<=ERR;error_code<=3;end
            else begin
                local_data_base<=volume+overhead[31:0];volume_end<=volume_end_wide[31:0];
                local_fat_base<=volume+reserved+((flags[7]&&flags[0])?fat_size:32'd0);
                cluster_count<=total-overhead[31:0];shift_left<=local_spc_shift;
                local_spc_mask<=spc-1'b1;state<=GEO_SHIFT;
            end
        end
        GEO_SHIFT:if(!SHARED_GEOMETRY)begin
            if(shift_left!=0) begin cluster_count<=cluster_count>>1;shift_left<=shift_left-1'b1;end
            else state<=GEO2;
        end
        GEO2:if(!SHARED_GEOMETRY)begin
            local_cluster_limit<=cluster_count+1'b1;
            min_fat_sectors<=(cluster_count+129)>>7;
            state<=GEO3;
        end
        GEO3:if(!SHARED_GEOMETRY)begin
            geometry_bad<=cluster_count<65525||cluster_count>32'h0fffffee||local_root_cluster[27:0]<2||
               local_root_cluster[27:0]>local_cluster_limit||fat_size<min_fat_sectors;
            state<=GEO_ACCEPT;
        end
        GEO_ACCEPT:if(!SHARED_GEOMETRY)begin
            if(geometry_bad) begin state<=ERR;error_code<=3;end
            else begin
                cluster<=local_root_cluster&32'h0fffffff;sector_in_cluster<=0;
                anchor<=local_root_cluster&32'h0fffffff;power<=1;steps<=0;
                offset_return<=ROOT_BEGIN;state<=OFFSET_INIT;
            end
        end
        OFFSET_INIT:begin cluster_offset<={4'd0,cluster}-32'd2;shift_left<=spc_shift;state<=OFFSET_SHIFT;end
        OFFSET_SHIFT:begin
            if(shift_left!=0) begin cluster_offset<=cluster_offset<<1;shift_left<=shift_left-1'b1;end
            else state<=OFFSET_ADD;
        end
        OFFSET_ADD:begin cluster_base<=data_base+cluster_offset;state<=offset_return;end
        ROOT_BEGIN:begin
            addr<=cluster_base+sector_in_cluster;
            mode<=M_ROOT;received<=0;return_state<=ROOT_END;state<=READ;
            root_sectors<=root_sectors+1'b1;
        end
        CONFIG_ROOT_SETTLE:state<=ROOT_END;
        ROOT_END:begin
            if(found) begin
                if(found_cluster_bad||file_bytes<44||file_bytes>MAX_FILE_BYTES||(CONFIG_SUPPORT&&target_file==17&&file_bytes!=512)) begin state<=ERR;error_code<=5;end
                else begin cluster<=found_cluster;sector_in_cluster<=0;file_pos<=0;byte_index<=0;
                    file_last_pos<=file_bytes-1'b1;anchor<=found_cluster;power<=1;steps<=0;
                    offset_return<=FILE_BEGIN;state<=OFFSET_INIT;end
            end else if(root_end||root_sectors>=4096) begin state<=ERR;error_code<=4;end
            else if(sector_in_cluster<spc_mask) begin sector_in_cluster<=sector_in_cluster+1'b1;state<=ROOT_BEGIN;end
            else begin fat_for_file<=0;state<=FAT_BEGIN;end
        end
        FAT_BEGIN:begin
            addr<=fat_base+(cluster>>7);fat_offset<={cluster[6:0],2'b0};fat_next<=0;
            mode<=M_FAT;received<=0;return_state<=FAT_END;state<=READ;
        end
        FAT_END:begin
            if(fat_next>=32'h0ffffff8&&!fat_for_file) begin state<=ERR;error_code<=4;end
            else if(fat_next<2||fat_next>cluster_limit||fat_next>=32'h0ffffff0||fat_next==anchor) begin state<=ERR;error_code<=6;end
            else begin
                cluster<=fat_next;sector_in_cluster<=0;
                if(steps+1'b1==power) begin anchor<=fat_next;steps<=0;if(!power[15]) power<=power<<1;end
                else steps<=steps+1'b1;
                offset_return<=fat_for_file?FILE_BEGIN:ROOT_BEGIN;state<=OFFSET_INIT;
            end
        end
        FILE_BEGIN:begin
            if(CONFIG_SUPPORT&&target_file==17&&file_pos==0)begin
                config_lba<=cluster_base+sector_in_cluster;config_lba_valid<=file_bytes==512;
            end
            addr<=cluster_base+sector_in_cluster;
            mode<=M_FILE;received<=0;return_state<=FILE_END;state<=READ;
        end
        FILE_END:begin byte_index<=0;state<=BPREP;end
        BPREP:state<=BWAIT;
        BWAIT:state<=BYTE;
        BYTE:if(ready) begin
            file_pos<=file_pos+1'b1;
            if(file_pos==file_last_pos) state<=DONE;
            else if(byte_index==511) state<=NEXT_SECTOR;
            else begin byte_index<=byte_index+1'b1;state<=BPREP;end
        end
        NEXT_SECTOR:begin
            if(sector_in_cluster<spc_mask) begin sector_in_cluster<=sector_in_cluster+1'b1;state<=FILE_BEGIN;end
            else begin fat_for_file<=1;state<=FAT_BEGIN;end
        end
        endcase
    end
end
endmodule
