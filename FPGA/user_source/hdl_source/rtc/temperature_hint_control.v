// Read-only, frame-published temperature hints. The source is DS3231 chip
// temperature, not an outdoor weather measurement. No RTC/EEPROM writes.
module temperature_hint_control #(
    parameter integer SHOW_FRAMES=300,
    parameter [19:0] HOT_ENTER=20'h03000,HOT_CLEAR=20'h02800,
    parameter [19:0] COLD_ENTER=20'h01500,COLD_CLEAR=20'h01700
)(
    input clk,rst,frame_tick,
    input [19:0] temperature_bcd,
    input temperature_negative,temperature_valid,blocked,
    output reg [1:0] visible_kind
);
localparam [1:0] NORMAL=0,HOT=1,COLD=2;
localparam COUNT_BITS=SHOW_FRAMES>0?$clog2(SHOW_FRAMES+1):1;
reg [1:0] regime,next_regime;
reg [COUNT_BITS-1:0] remaining;
always @* begin
    next_regime=regime;
    if(temperature_valid)begin
        case(regime)
            HOT:begin
                if(temperature_negative||temperature_bcd<=COLD_ENTER)next_regime=COLD;
                else if(temperature_bcd<=HOT_CLEAR)next_regime=NORMAL;
            end
            COLD:begin
                if(!temperature_negative&&temperature_bcd>=HOT_ENTER)next_regime=HOT;
                else if(!temperature_negative&&temperature_bcd>=COLD_CLEAR)next_regime=NORMAL;
            end
            default:begin
                if(temperature_negative||temperature_bcd<=COLD_ENTER)next_regime=COLD;
                else if(temperature_bcd>=HOT_ENTER)next_regime=HOT;
            end
        endcase
    end
end
always @(posedge clk or posedge rst)begin
    if(rst)begin regime<=NORMAL;remaining<=0;visible_kind<=NORMAL;end
    else if(frame_tick)begin
        if(next_regime!=regime)begin
            regime<=next_regime;
            remaining<=next_regime==NORMAL?0:SHOW_FRAMES;
            visible_kind<=NORMAL;
        end else if(!temperature_valid||blocked)begin
            // Retain the episode and remaining visible time. A temporary
            // read fault cannot fabricate 0C or rearm the same episode.
            visible_kind<=NORMAL;
        end else if(remaining!=0)begin
            visible_kind<=regime;
            remaining<=remaining-1'b1;
        end else visible_kind<=NORMAL;
    end
end
endmodule
