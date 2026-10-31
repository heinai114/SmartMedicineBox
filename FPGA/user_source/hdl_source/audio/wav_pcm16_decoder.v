// Streaming RIFF parser; supports PCM tag 1 / mono / 48k / 16-bit only.
// Chunk boundaries, padding and data length are validated against RIFF/file.
module wav_pcm16_decoder(
    input clk,input rst,input start,input cancel,input [31:0] file_bytes,
    input valid,input [7:0] data,output ready,
    output sample_valid,input sample_ready,output reg [15:0] sample,
    output reg sample_last,output done,output error,output reg [3:0] error_code
);
localparam IDLE=0,RIFF=1,CHDR=2,BODY=3,PAD=4,LO=5,HI=6,OUT=7,DONE=8,ERR=9,BOUNDS=10,CHECK=11;
reg [3:0] state;
reg [24:0] pos,remaining;
reg [31:0] riff_len,chunk_len;
reg [32:0] riff_end,chunk_bound;
reg [4:0] body_index;
reg riff_ok,chunk_data,chunk_fmt;
reg [3:0] index;
reg fmt_seen,fmt_ok,pad_after,is_fmt;
// Supported fmt fields are constants. Compare each byte as it arrives,
// rather than retaining 128 bits solely for a later equality comparison.
reg fmt_match;
function [7:0] expected_fmt_byte;
 input [4:0] n;
 begin case(n)
  0,2:expected_fmt_byte=8'd1;
  4:expected_fmt_byte=8'h80;5:expected_fmt_byte=8'hbb;
  8:expected_fmt_byte=8'h00;9:expected_fmt_byte=8'h77;10:expected_fmt_byte=8'h01;
  12:expected_fmt_byte=8'd2;14:expected_fmt_byte=8'd16;
  default:expected_fmt_byte=0;
 endcase end
endfunction
reg [7:0] low;
function [7:0] riff_char;
 input [3:0] n;
 begin case(n) 0:riff_char="R";1:riff_char="I";2,3:riff_char="F";
  8:riff_char="W";9:riff_char="A";10:riff_char="V";11:riff_char="E";
  default:riff_char=0;endcase end
endfunction
function [7:0] data_char;
 input [1:0] n;
 begin case(n) 0:data_char="d";1,3:data_char="a";2:data_char="t";endcase end
endfunction
function [7:0] fmt_char;
 input [1:0] n;
 begin case(n) 0:fmt_char="f";1:fmt_char="m";2:fmt_char="t";3:fmt_char=" ";endcase end
endfunction
assign ready=state==RIFF||state==CHDR||state==BODY||state==PAD||state==LO||state==HI;
assign sample_valid=state==OUT;
assign done=state==DONE;
assign error=state==ERR;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE;pos<=0;riff_len<=0;chunk_len<=0;riff_ok<=1;chunk_data<=0;chunk_fmt<=0;
        riff_end<=0;chunk_bound<=0;
        body_index<=0;remaining<=0;index<=0;fmt_seen<=0;fmt_ok<=0;pad_after<=0;is_fmt<=0;
        fmt_match<=0;low<=0;
        sample<=0;sample_last<=0;error_code<=0;
    end else if(cancel) state<=IDLE;
    else if(start) begin
        state<=RIFF;index<=0;pos<=0;fmt_seen<=0;fmt_ok<=0;error_code<=0;
        riff_ok<=1;riff_len<=0;chunk_len<=0;
    end else if(state==BOUNDS) begin
        chunk_bound<={8'd0,pos}+{1'b0,chunk_len}+chunk_len[0];state<=CHECK;
    end else if(state==CHECK) begin
        if(chunk_bound>riff_end) begin state<=ERR;error_code<=2;end
        else if(chunk_data) begin
            if(!fmt_seen||!fmt_ok||chunk_len==0||chunk_len[0]) begin state<=ERR;error_code<=3;end
            else begin remaining<=chunk_len;state<=LO;end
        end else if(chunk_fmt && (fmt_seen||chunk_len<16)) begin state<=ERR;error_code<=4;end
        else begin
            is_fmt<=chunk_fmt;fmt_match<=1;body_index<=0;remaining<=chunk_len;pad_after<=chunk_len[0];
            if(chunk_len==0) state<=CHDR;else state<=BODY;
        end
    end else if(state==OUT && sample_ready) begin
        if(sample_last) state<=DONE;else state<=LO;
    end else if(valid&&ready) begin
        pos<=pos+1'b1;
        case(state)
        RIFF: begin
            if(index==8) riff_end<={1'b0,riff_len}+33'd8;
            if(index>=4&&index<8) riff_len<={data,riff_len[31:8]};
            else riff_ok<=riff_ok&&data==riff_char(index);
            if(index==11) begin
                if(!riff_ok || data!="E" ||
                   riff_len<36 || riff_end>{1'b0,file_bytes}) begin state<=ERR;error_code<=1;end
                else begin state<=CHDR;index<=0;end
            end else index<=index+1'b1;
        end
        CHDR: begin
            if(index==0) begin chunk_data<=data=="d";chunk_fmt<=data=="f";end
            else if(index<4) begin
                chunk_data<=chunk_data&&data==data_char(index[1:0]);
                chunk_fmt<=chunk_fmt&&data==fmt_char(index[1:0]);
            end else chunk_len<={data,chunk_len[31:8]};
            if(index==7) begin
                index<=0;state<=BOUNDS;
            end else index<=index+1'b1;
        end
        BODY: begin
            if(is_fmt) begin
                if(body_index<16) fmt_match<=fmt_match && data==expected_fmt_byte(body_index);
                if(body_index==15) begin
                    fmt_seen<=1;fmt_ok<=fmt_match && data==expected_fmt_byte(15);
                end
            end
            if(body_index<16) body_index<=body_index+1'b1;
            remaining<=remaining-1'b1;
            if(remaining==1) begin state<=pad_after?PAD:CHDR;index<=0;end
        end
        PAD:begin state<=CHDR;index<=0;end
        LO:begin low<=data;state<=HI;end
        HI:begin sample<={data,low};sample_last<=remaining==2;remaining<=remaining-2;state<=OUT;end
        endcase
    end
end
endmodule
