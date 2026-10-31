// KEY4: a debounced release after a short press pulses image autoplay;
// one continuous long press toggles the audio file exactly once.
module voice_key_select #(
    parameter CLK_FREQ_HZ=100_000_000,
    parameter DEBOUNCE_MS=20, parameter HOLD_MS=1000, parameter SHORT_MS=40,
    parameter LAYERED_MODE=0
)(input clk,input rst,input key_n,input next_key_n,
    output short_key_n,output reg track_select,
    output reg detail_request,output filtered_next_key_n);
localparam TICK_CYCLES=CLK_FREQ_HZ/1000;
localparam TICK_BITS=$clog2(TICK_CYCLES+1);
localparam DEBOUNCE_BITS=$clog2(DEBOUNCE_MS+1);
localparam HOLD_BITS=$clog2(HOLD_MS+1);
localparam SHORT_BITS=$clog2(SHORT_MS+1);
(* async_reg="true",syn_preserve=1 *) reg [1:0] key_sync;
(* async_reg="true",syn_preserve=1 *) reg [1:0] next_sync;
reg [TICK_BITS-1:0] tick_count;
reg [DEBOUNCE_BITS-1:0] stable_count;
reg [HOLD_BITS-1:0] held_ms;
reg [SHORT_BITS-1:0] short_left;
reg stable_key,pressed,long_sent;
reg chord;
// KEY4-first chord is recognised before KEY2's separate 20ms debounce.
// Suppress both release orders until both buttons have returned high.
assign filtered_next_key_n=LAYERED_MODE ?
    (next_sync[1]||!key_sync[1]||!stable_key||pressed||chord) : next_key_n;
assign short_key_n=(short_left==0);
always @(posedge clk or posedge rst) begin
    if(rst) begin
        key_sync<=2'b11;tick_count<=0;stable_count<=0;
        stable_key<=1;pressed<=0;long_sent<=0;held_ms<=0;
        short_left<=0;track_select<=0;detail_request<=0;next_sync<=2'b11;chord<=0;
    end else begin
        key_sync<={key_sync[0],key_n};
        next_sync<={next_sync[0],next_key_n};detail_request<=0;
        if(tick_count==TICK_CYCLES-1) begin
            tick_count<=0;
            if(key_sync[1]==stable_key) stable_count<=0;
            else if(stable_count==DEBOUNCE_MS-1) begin
                stable_key<=key_sync[1];stable_count<=0;
            end else stable_count<=stable_count+1'b1;
            if(short_left!=0) short_left<=short_left-1'b1;
            if(LAYERED_MODE&&pressed&&!next_sync[1]&&!chord&&!long_sent) begin
                chord<=1;held_ms<=0;
            end
            if(chord&&stable_key&&next_sync[1]) chord<=0;
            if(!pressed&&!stable_key) begin
                pressed<=1;long_sent<=0;held_ms<=0;
                if(LAYERED_MODE&&!next_sync[1])chord<=1;
            end else if(pressed) begin
                if(stable_key) begin
                    pressed<=0;
                    if(!long_sent&&!chord&&(!LAYERED_MODE||!track_select)) short_left<=SHORT_MS;
                end else if(!long_sent) begin
                    if(LAYERED_MODE&&!next_sync[1]&&!chord) held_ms<=0;
                    else if(chord&&next_sync[1]) held_ms<=0;
                    else if(held_ms==HOLD_MS-1) begin
                        if(!LAYERED_MODE||chord)track_select<=~track_select;
                        else if(!track_select)detail_request<=1;
                        long_sent<=1;
                    end else held_ms<=held_ms+1'b1;
                end
            end
        end else tick_count<=tick_count+1'b1;
    end
end
endmodule
