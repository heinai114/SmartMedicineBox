// S1 toggles music; S2 selects the next song while music is selected.
// A held command/ACK mailbox transfers selection and song as one bundle.
// Reminder ownership temporarily suspends playback, retaining the selection.
module music_mode_control(
    input ui_clk,input audio_clk,input rst,
    input key_valid,input [3:0] key_code,input ui_blocked,
    input scene_owned,
    output reg selected_ui,output active_audio,output [4:0] track_audio
);
reg [1:0] song_ui;
reg [2:0] command_ui;
reg request_ui,ack_audio;
reg [2:0] applied_audio;
reg [1:0] settle;
(* async_reg="true",syn_preserve=1 *) reg [1:0] ack_sync,request_sync;
always @(posedge ui_clk or posedge rst)begin
    if(rst)begin
        selected_ui<=0;song_ui<=0;command_ui<=0;request_ui<=0;ack_sync<=0;
    end else begin
        ack_sync<={ack_sync[0],ack_audio};
        if(key_valid&&!ui_blocked)begin
            if(key_code==4'd0)selected_ui<=~selected_ui;
            else if(key_code==4'd1&&selected_ui)song_ui<=song_ui==2?2'd0:song_ui+1'b1;
        end
        // Coalesce fast keys; never modify a bundle while its ACK is pending.
        if(ack_sync[1]==request_ui&&command_ui!={selected_ui,song_ui})begin
            command_ui<={selected_ui,song_ui};request_ui<=~request_ui;
        end
    end
end
always @(posedge audio_clk or posedge rst)begin
    if(rst)begin request_sync<=0;settle<=0;ack_audio<=0;applied_audio<=0;end
    else begin
        request_sync<={request_sync[0],request_ui};
        if(request_sync[1]==ack_audio)settle<=0;
        else if(settle==3)begin
            applied_audio<=command_ui;ack_audio<=request_sync[1];settle<=0;
        end else settle<=settle+1'b1;
    end
end
assign active_audio=applied_audio[2]&&!scene_owned;
assign track_audio=5'd18+{3'd0,applied_audio[1:0]};
endmodule
