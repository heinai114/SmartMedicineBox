// Selected root TEST.WAV / ASCEND.WAV repeats after actual PCM completion.
module tf_wav_player #(parameter TRACK_BITS=2,parameter FIVE_SCENE_MODE=0,parameter FIFO_A=12,parameter PREFILL=1024,parameter BMI_REPEAT_MODE=0,parameter SCENE_REPEAT_MODE=0,parameter MUSIC_SUPPORT=0,
    parameter SHARED_GEOMETRY=0,parameter PAUSE_SUPPORT=0,parameter CONFIG_ENABLE=0,parameter CONFIG_TIMEOUT=500_000_000,parameter PCM_CLK_HZ=25_000_000,parameter SAMPLE_RATE=48_000)(
    input clk,input pcm_clk,input rst,input loop_enable,input play_request,input stop_request,input [TRACK_BITS-1:0] track_select,
    input bmi_repeat_enable,
    input sd_init_done,output sd_req,output [31:0] sd_addr,
    input [7:0] sd_data,input sd_valid,input sd_end,input sd_error,
    output busy,output reg [7:0] error_code,
    output pcm_valid,output [23:0] pcm_left,output [23:0] pcm_right,
    output [15:0] underflows,output underflow_seen,
    output [TRACK_BITS-1:0] pcm_track,output pcm_sample_taken,output pcm_playing,
    output config_done,config_valid,output [2:0] config_status,
    output config_write,output [3:0] config_index,output [35:0] config_data,
    output [31:0] config_lba,output config_lba_valid,input pause_request,output paused_ack,
 input geometry_ready,input [31:0] geometry_fat,geometry_data,
 input [27:0] geometry_root,geometry_limit,input [6:0] geometry_mask,input [2:0] geometry_shift
);
localparam [TRACK_BITS-1:0] CONFIG_FILE=17;
localparam IDLE=0,CANCEL=1,FLUSH=2,STREAM=3,DRAIN=4;
reg [2:0] state;
reg pending,flush_toggle,play_enable,start_pulse;reg pause_seen,resume_saved;
reg pending_repeat;
reg flush_retry;
reg loop_seen;
reg [TRACK_BITS-1:0] selected_track;
wire file_busy,file_error,file_done,file_valid,file_ready,wav_file_ready;
wire config_active,config_start,config_cancel,config_ready;
wire [7:0] file_data;
wire [31:0] file_bytes;
wire [3:0] file_error_code,wav_error_code;
wire wav_done,wav_error,sample_valid,sample_ready,sample_last;
wire [15:0] sample;
wire full,empty,pop;
wire [FIFO_A:0] used;
wire [16:0] fifo_data;
wire flush_ack,done_toggle;
(* async_reg="true",syn_preserve=1 *) reg [1:0] ack_sync;
(* async_reg="true",syn_preserve=1 *) reg [2:0] done_sync;
generate if(CONFIG_ENABLE)begin:g_config_boot
 med_config_boot #(.TIMEOUT(CONFIG_TIMEOUT)) u_boot(.clk(clk),.rst(rst),.sd_init_done(sd_init_done),
  .file_busy(file_busy),.file_done(file_done),.file_error(file_error),.file_error_code(file_error_code),
  .file_valid(file_valid),.file_data(file_data),.boot_active(config_active),.boot_done(config_done),
  .start(config_start),.cancel(config_cancel),.config_ready(config_ready),.plan_valid(config_valid),.status(config_status),
  .config_write(config_write),.config_index(config_index),.config_data(config_data));
end else begin:g_no_config
 assign config_active=0;assign config_start=0;assign config_cancel=0;assign config_ready=0;
 assign config_done=1;assign config_valid=0;assign config_status=0;
 assign config_write=0;assign config_index=0;assign config_data=0;
end endgenerate
assign file_ready=config_active?config_ready:wav_file_ready;
assign busy=state!=IDLE||pending||(PAUSE_SUPPORT&&pause_request);
assign paused_ack=PAUSE_SUPPORT&&pause_request&&state==IDLE&&!file_busy&&!pending&&!play_enable&&ack_sync[1]==flush_toggle;
wire cancel_file=state==CANCEL||wav_done||wav_error;
assign sample_ready=state==STREAM&&!full;
// Byte positions are 25 bits in both reader and decoder. Keep the upper
// limit strictly below 2^25, so all accepted lengths fit without wraparound.
fat32_test_wav_reader #(.MAX_FILE_BYTES(MUSIC_SUPPORT?33_554_431:16_777_216),.FILE_BITS(TRACK_BITS),.CONFIG_SUPPORT(CONFIG_ENABLE),.SHARED_GEOMETRY(SHARED_GEOMETRY)) u_file(
    .clk(clk),.rst(rst),.start(config_active?config_start:start_pulse),.cancel(config_active?config_cancel:cancel_file),.file_select(config_active?CONFIG_FILE:selected_track),.sd_init_done(sd_init_done),
    .busy(file_busy),.error(file_error),.done(file_done),.error_code(file_error_code),.file_bytes(file_bytes),.config_lba(config_lba),.config_lba_valid(config_lba_valid),
    .valid(file_valid),.data(file_data),.ready(file_ready),.req(sd_req),.addr(sd_addr),
    .sd_data(sd_data),.sd_valid(sd_valid),.sd_end(sd_end),.sd_error(sd_error),
 .geometry_ready(geometry_ready),.geometry_fat(geometry_fat),.geometry_data(geometry_data),
 .geometry_root(geometry_root),.geometry_limit(geometry_limit),.geometry_mask(geometry_mask),.geometry_shift(geometry_shift)
);
wav_pcm16_decoder u_wav(
    .clk(clk),.rst(rst),.start(start_pulse),.cancel(state==CANCEL),.file_bytes(file_bytes),
    .valid(file_valid&&!config_active),.data(file_data),.ready(wav_file_ready),.sample_valid(sample_valid),
    .sample_ready(sample_ready),.sample(sample),.sample_last(sample_last),
    .done(wav_done),.error(wav_error),.error_code(wav_error_code)
);
voice_async_fifo #(.A(FIFO_A)) u_fifo(
    .rst(rst),.wclk(clk),.wen(sample_valid&&sample_ready),.wdata({sample_last,sample}),
    .full(full),.used(used),.rclk(pcm_clk),.ren(pop),.empty(empty),.rdata(fifo_data)
);
voice_pcm_output #(.TRACK_BITS(TRACK_BITS),.CLK_FREQ_HZ(PCM_CLK_HZ),.SAMPLE_RATE(SAMPLE_RATE)) u_pcm(
    .clk(pcm_clk),.rst(rst),.play_async(play_enable),.flush_async(flush_toggle),.flush_ack(flush_ack),
    .done_toggle(done_toggle),.empty(empty),.fifo_data(fifo_data),.fifo_pop(pop),
    .pcm_valid(pcm_valid),.pcm_left(pcm_left),.pcm_right(pcm_right),
    .underflows(underflows),.underflow_seen(underflow_seen),.sample_taken(pcm_sample_taken),.last_taken(),
    .track_async(selected_track),.pcm_track(pcm_track),.play_active(pcm_playing)
);
always @(posedge clk or posedge rst) begin
    if(rst) begin
        state<=IDLE;pending<=0;pending_repeat<=0;flush_retry<=0;flush_toggle<=0;play_enable<=0;start_pulse<=0;
        ack_sync<=0;done_sync<=0;error_code<=0;loop_seen<=0;selected_track<=0;pause_seen<=0;resume_saved<=0;
    end else begin
        loop_seen<=loop_enable;pause_seen<=PAUSE_SUPPORT&&pause_request;
        ack_sync<={ack_sync[0],flush_ack};done_sync<={done_sync[1:0],done_toggle};start_pulse<=0;
        if(config_active)begin state<=IDLE;pending<=0;pending_repeat<=0;play_enable<=0;end
        else if(PAUSE_SUPPORT&&pause_request&&!pause_seen)begin
            resume_saved<=state!=IDLE||pending||play_enable||track_select!=0;
            pending<=0;pending_repeat<=0;play_enable<=0;
            flush_retry<=state==FLUSH;state<=state==FLUSH?FLUSH:CANCEL;
        end else if(PAUSE_SUPPORT&&!pause_request&&pause_seen)begin
            selected_track<=track_select;pending<=resume_saved;pending_repeat<=0;play_enable<=0;state<=CANCEL;
        end else if(PAUSE_SUPPORT&&pause_request)begin
            // Finish the physical read and any old flush before acknowledging silence.
            case(state)
             CANCEL:if(!file_busy)begin flush_toggle<=~flush_toggle;state<=FLUSH;end
             FLUSH:if(ack_sync[1]==flush_toggle)begin
                if(flush_retry)begin flush_retry<=0;state<=CANCEL;end
                else begin pending<=0;play_enable<=0;state<=IDLE;end
             end
             default:;
            endcase
        end else if(play_request||stop_request||(loop_seen&&!loop_enable)) begin
            pending<=play_request&&!stop_request;pending_repeat<=0;play_enable<=0;
            // Never toggle an outstanding flush back to the acknowledged
            // value. Complete it first, then issue a fresh flush for this
            // request; this also re-latches bundled track metadata safely.
            flush_retry<=state==FLUSH;state<=state==FLUSH?FLUSH:CANCEL;
            if(play_request&&!stop_request) begin error_code<=0;selected_track<=track_select;end
        end else if(track_select!=selected_track) begin
            // Finish any in-flight physical sector, stop the PCM consumer and
            // flush its old FIFO before starting the newly selected file.
            selected_track<=track_select;pending<=loop_enable;pending_repeat<=0;
            error_code<=0;play_enable<=0;
            flush_retry<=state==FLUSH;state<=state==FLUSH?FLUSH:CANCEL;
        end else case(state)
        // Errors remain visible and wait for reset or explicit retry; do not
        // repeatedly hammer the same malformed/missing file in a tight loop.
        IDLE:if(loop_enable&&error_code==0) begin pending<=1;pending_repeat<=0;state<=CANCEL;end
        CANCEL:if(!file_busy) begin flush_toggle<=~flush_toggle;state<=FLUSH;end
        FLUSH:if(ack_sync[1]==flush_toggle) begin
            // Mode changes may withdraw a queued repeat during remount/flush,
            // but never cancel a narration already playing. Explicit play is
            // independent of this permission. Stop cannot cause an IDLE retry.
            if(flush_retry) begin flush_retry<=0;state<=CANCEL;end
            else if(pending_repeat&&!bmi_repeat_enable) begin pending<=0;pending_repeat<=0;state<=IDLE;end
            else if(pending&&sd_init_done) begin pending<=0;pending_repeat<=0;start_pulse<=1;state<=STREAM;end
            else if(!pending) state<=IDLE;
        end
        STREAM:begin
            if(file_error||wav_error||(file_done&&file_ready)) begin
                error_code<=file_error?{4'h1,file_error_code}:(wav_error?{4'h2,wav_error_code}:8'h27);
                pending<=0;pending_repeat<=0;play_enable<=0;state<=CANCEL;
            end else begin
                if(used>=PREFILL||wav_done) play_enable<=1;
                if(wav_done) state<=DRAIN;
            end
        end
        DRAIN:if(done_sync[2]!=done_sync[1]) begin
            play_enable<=0;
            pending<=loop_enable||(((BMI_REPEAT_MODE&&selected_track==2'd2)||(SCENE_REPEAT_MODE&&(FIVE_SCENE_MODE ? (selected_track>=2&&selected_track<=16) : selected_track[1])))&&bmi_repeat_enable);
            pending_repeat<=((BMI_REPEAT_MODE&&selected_track==2'd2)||(SCENE_REPEAT_MODE&&(FIVE_SCENE_MODE ? (selected_track>=2&&selected_track<=16) : selected_track[1])))&&bmi_repeat_enable;
            state<=CANCEL;
        end
        endcase
    end
end
endmodule
