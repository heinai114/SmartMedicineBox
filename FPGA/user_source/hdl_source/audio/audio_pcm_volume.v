// Project-owned signed 24-bit stereo PCM gain in the receiver's clock domain.
// 0..10 is 0..100%; Q15 unity is exact. Gain slews per stereo sample while
// audio valid continues even at mute, preserving the HDMI/ACR sample cadence.
module audio_pcm_volume #(
    parameter integer GAIN_STEP = 32
)(
    input I_clk, input I_rst, input [3:0] I_volume_level,
    input I_valid, input [23:0] I_left, input [23:0] I_right,
    output reg O_valid, output reg [23:0] O_left, output reg [23:0] O_right
);
function [15:0] volume_gain;
    input [3:0] level;
    begin
        case (level)
            0: volume_gain=16'd0;
            1: volume_gain=16'd3277;
            2: volume_gain=16'd6554;
            3: volume_gain=16'd9830;
            4: volume_gain=16'd13107;
            5: volume_gain=16'd16384;
            6: volume_gain=16'd19661;
            7: volume_gain=16'd22938;
            8: volume_gain=16'd26214;
            9: volume_gain=16'd29491;
            default: volume_gain=16'd32768;
        endcase
    end
endfunction
wire [15:0] target_gain = volume_gain(I_volume_level);
reg [15:0] current_gain;
reg signed [40:0] left_product, right_product;
reg valid_product;
function [23:0] rounded_sample;
    input signed [40:0] product;
    reg [40:0] magnitude, rounded;
    reg signed [40:0] signed_result;
    begin
        magnitude = product[40] ? -product : product;
        rounded = (magnitude + 41'd16384) >> 15;
        signed_result = product[40] ? -$signed(rounded) : $signed(rounded);
        rounded_sample = signed_result[23:0];
    end
endfunction
always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        current_gain <= 16'd32768;
        valid_product <= 0; left_product <= 0; right_product <= 0;
        O_valid <= 0; O_left <= 0; O_right <= 0;
    end else begin
        valid_product <= I_valid;
        if (I_valid) begin
            if (current_gain < target_gain)
                current_gain <= target_gain-current_gain > GAIN_STEP ? current_gain+GAIN_STEP : target_gain;
            else if (current_gain > target_gain)
                current_gain <= current_gain-target_gain > GAIN_STEP ? current_gain-GAIN_STEP : target_gain;
            left_product <= $signed(I_left) * $signed({1'b0,current_gain});
            right_product <= $signed(I_right) * $signed({1'b0,current_gain});
        end
        O_valid <= valid_product;
        O_left <= valid_product ? rounded_sample(left_product) : 24'd0;
        O_right <= valid_product ? rounded_sample(right_product) : 24'd0;
    end
end
endmodule
