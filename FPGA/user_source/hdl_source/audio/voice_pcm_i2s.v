// Retains the existing project's 12.288 MHz / 256 sample cadence and I2S
// framing. Idle/underflow is a zero sample; clocks never stop.
module voice_pcm_i2s(
    input clk,input rst,input play_async,input flush_async,
    output reg flush_ack,output reg done_toggle,
    input empty,input [16:0] fifo_data,output fifo_pop,
    output reg bclk,output reg lrck,output reg dout,
    output reg [15:0] underflows,output reg underflow_seen,
    output reg sample_strobe,output reg [23:0] sample_debug
);
(* async_reg="true",syn_preserve=1 *) reg [1:0] play_sync,flush_sync;
reg play_seen,flushing,running,last_pending;
reg [3:0] settle;
reg [5:0] bit_count;
reg [63:0] shifter;
reg [23:0] pair_sample;
wire boundary=bclk && bit_count==63 && lrck;
wire flush_needed=flush_sync[1]!=flush_ack;
assign fifo_pop=(!empty) && (flushing || (boundary&&running&&!last_pending&&!flush_needed));
wire [23:0] next_sample=(running&&!empty&&!last_pending&&!flush_needed&&!flushing) ? {fifo_data[15:0],8'b0}:24'd0;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        play_sync<=0;flush_sync<=0;flush_ack<=0;done_toggle<=0;
        play_seen<=0;flushing<=0;running<=0;last_pending<=0;settle<=0;
        bit_count<=0;shifter<=0;pair_sample<=0;bclk<=0;lrck<=0;dout<=0;
        underflows<=0;underflow_seen<=0;sample_strobe<=0;sample_debug<=0;
    end else begin
        play_sync<={play_sync[0],play_async};flush_sync<={flush_sync[0],flush_async};
        play_seen<=play_sync[1];sample_strobe<=0;
        if(flush_needed&&!flushing) begin
            flushing<=1;settle<=0;running<=0;last_pending<=0;
        end else if(flushing) begin
            if(settle<8) settle<=settle+1'b1;
            else if(empty) begin flushing<=0;flush_ack<=flush_sync[1];end
        end else if(play_sync[1]&&!play_seen&&!flush_needed) begin
            running<=1;last_pending<=0;
        end
        bclk<=~bclk;
        if(bclk) begin
            dout<=shifter[63];shifter<={shifter[62:0],1'b0};
            if(bit_count==63) begin
                bit_count<=0;
                if(!lrck) begin lrck<=1;shifter<={pair_sample,40'd0};end
                else begin
                    lrck<=0;pair_sample<=next_sample;shifter<={next_sample,40'd0};
                    sample_strobe<=1;sample_debug<=next_sample;
                    if(running&&!flush_needed&&!flushing) begin
                        if(last_pending) begin running<=0;last_pending<=0;done_toggle<=~done_toggle;end
                        else if(empty) begin underflow_seen<=1;if(underflows!=16'hffff) underflows<=underflows+1'b1;end
                        else if(fifo_data[16]) last_pending<=1;
                    end
                end
            end else bit_count<=bit_count+1'b1;
        end
    end
end
endmodule
