// Project-owned direct PCM output in the video clock domain. Exactly 48000
// sample enables per 25000000 clocks, using 520/521-cycle intervals. There is
// no generated audio clock, I2S serialization or dependence on audio MCLK.
module voice_pcm_output #(parameter TRACK_BITS=2,parameter CLK_FREQ_HZ=25_000_000,parameter SAMPLE_RATE=48_000)(
    input clk,input rst,input play_async,input flush_async,
    output reg flush_ack,output reg done_toggle,
    input empty,input [16:0] fifo_data,output fifo_pop,
    output reg pcm_valid,output reg [23:0] pcm_left,output reg [23:0] pcm_right,
    output reg [15:0] underflows,output reg underflow_seen,
    output reg sample_taken,output reg last_taken,
    input [TRACK_BITS-1:0] track_async,output reg [TRACK_BITS-1:0] pcm_track,output play_active
);
localparam PHASE_BITS=$clog2(CLK_FREQ_HZ+1);
localparam [PHASE_BITS-1:0] TICK_LIMIT=CLK_FREQ_HZ-SAMPLE_RATE;
reg [PHASE_BITS-1:0] phase;
wire sample_tick=phase>=TICK_LIMIT;
(* async_reg="true",syn_preserve=1 *) reg [1:0] play_sync,flush_sync;
reg play_seen,flushing,running,last_pending;
reg [3:0] settle;
wire flush_needed=flush_sync[1]!=flush_ack;
wire take_sample=sample_tick&&running&&!empty&&!last_pending&&!flush_needed&&!flushing;
assign fifo_pop=(!empty)&&(flushing||take_sample);
assign play_active=running&&!flush_needed&&!flushing;
always @(posedge clk or posedge rst) begin
    if(rst) begin
        phase<=0;pcm_valid<=0;pcm_left<=0;pcm_right<=0;sample_taken<=0;last_taken<=0;
        play_sync<=0;flush_sync<=0;flush_ack<=0;done_toggle<=0;
        play_seen<=0;flushing<=0;running<=0;last_pending<=0;settle<=0;
        underflows<=0;underflow_seen<=0;pcm_track<=0;
    end else begin
        if(sample_tick) phase<=phase-TICK_LIMIT;
        else phase<=phase+SAMPLE_RATE;
        pcm_valid<=sample_tick;sample_taken<=take_sample;last_taken<=take_sample&&fifo_data[16];
        play_sync<={play_sync[0],play_async};flush_sync<={flush_sync[0],flush_async};play_seen<=play_sync[1];
        if(flush_needed&&!flushing) begin
            flushing<=1;settle<=0;running<=0;last_pending<=0;
        end else if(flushing) begin
            if(settle<8) settle<=settle+1'b1;
            else if(empty) begin
                // Bundled track is held throughout sector cancellation and
                // flush/settle; writer cannot start until this ACK returns.
                flushing<=0;flush_ack<=flush_sync[1];pcm_track<=track_async;
            end
        end else if(!play_sync[1]&&play_seen) begin running<=0;last_pending<=0;end
        else if(play_sync[1]&&!play_seen&&!flush_needed) begin running<=1;last_pending<=0;end
        // Emit valid zero samples at the same cadence when idle, at EOF or on
        // underflow. The existing Q15 volume and HDMI ACR consume this stream.
        if(sample_tick) begin
            pcm_left<=take_sample?{fifo_data[15:0],8'b0}:24'd0;
            pcm_right<=take_sample?{fifo_data[15:0],8'b0}:24'd0;
            if(running&&!flush_needed&&!flushing) begin
                if(last_pending) begin running<=0;last_pending<=0;done_toggle<=~done_toggle;end
                else if(empty) begin underflow_seen<=1;if(underflows!=16'hffff) underflows<=underflows+1'b1;end
                else if(fifo_data[16]) last_pending<=1;
            end
        end
    end
end
endmodule
