// Frame-latched eased envelope. Next image is preloaded before request.
// Twenty frames per leg: 40 motion frames plus the existing black/FIFO wait.
module video_fade_controller #(
    parameter integer WAIT_FRAMES = 2
)(
    input wire clk,
    input wire rst,
    input wire vs,
    input wire request_async,
    output reg [8:0] gain,
    // 0: fade, 1: center box, 2: blinds, 3: diagonal, 4: checker tiles.
    output wire [2:0] effect,
    output wire at_black,
    output wire idle
);
    localparam FULL=3'd0, DOWN=3'd1, BLACK=3'd2, SETTLE=3'd3, UP=3'd4;
    reg [2:0] phase;
    reg [7:0] wait_count;
    reg [4:0] leg_frame;
    reg vs_d;
    // Free-running pseudorandom state, sampled only when a transition starts.
    reg [15:0] random_state;
    reg [4:0] used_effects;
    reg [4:0] effect_hot;
    wire round_full = &used_effects;
    // Inside a round, the previous choice is already marked used. Only the
    // new-round boundary needs a separate exclusion, directly from one-hot FFs.
    wire [4:0] allowed = round_full ? ~effect_hot : ~used_effects;
    assign effect = {effect_hot[4],effect_hot[2]|effect_hot[3],effect_hot[1]|effect_hot[3]};
    function [4:0] choose_mask;
        input [2:0] start;
        input [4:0] available;
        reg [4:0] after_start,search;
        begin
            // Prefer allowed indices at/above the draw; otherwise wrap to the
            // lowest allowed index. A thermometer mask avoids modulo adders.
            after_start = available & (5'b11111 << start);
            search = |after_start ? after_start : available;
            choose_mask[0] = search[0];
            choose_mask[1] = !(|search[0:0]) && search[1];
            choose_mask[2] = !(|search[1:0]) && search[2];
            choose_mask[3] = !(|search[2:0]) && search[3];
            choose_mask[4] = !(|search[3:0]) && search[4];
        end
    endfunction
    // Fold eight possible LFSR draws to five legal starting indices. No
    // divider, lookup RAM or extra draw registers are needed.
    wire [2:0] random_start = random_state[2:0] < 5 ? random_state[2:0] : random_state[2:0]-3'd5;
    wire [4:0] next_choice = choose_mask(random_start,allowed);
    (* syn_preserve=1, async_reg="true" *) reg [1:0] request_sync;
    wire frame_start = vs & ~vs_d;
    // round(256 * (3*t*t - 2*t*t*t)), t=frame/20. Constant lookup
    // avoids a multiplier/divider and eases both ends of each motion leg.
    function [8:0] eased_gain;
        input [4:0] frame;
        begin
            case (frame)
                 0: eased_gain=0;    1: eased_gain=2;
                 2: eased_gain=7;    3: eased_gain=16;
                 4: eased_gain=27;   5: eased_gain=40;
                 6: eased_gain=55;   7: eased_gain=72;
                 8: eased_gain=90;   9: eased_gain=109;
                10: eased_gain=128; 11: eased_gain=147;
                12: eased_gain=166; 13: eased_gain=184;
                14: eased_gain=201; 15: eased_gain=216;
                16: eased_gain=229; 17: eased_gain=240;
                18: eased_gain=249; 19: eased_gain=254;
                default: eased_gain=256;
            endcase
        end
    endfunction
    assign at_black = phase == BLACK;
    assign idle = phase == FULL;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            request_sync <= 2'b00;
            vs_d <= 1'b0;
            phase <= FULL;
            gain <= 9'd256;
            wait_count <= 8'd0;
            leg_frame <= 5'd0;
            random_state <= 16'hACE1;
            used_effects <= 5'b00000;
            effect_hot <= 5'b00001;
        end else begin
            random_state <= {random_state[14:0],random_state[15]^random_state[13]^random_state[12]^random_state[10]};
            request_sync <= {request_sync[0], request_async};
            vs_d <= vs;
            // Constant gain throughout an active frame avoids half-screen steps.
            if (frame_start) begin
                case (phase)
                    FULL: if (request_sync[1]) begin
                        phase <= DOWN;
                        leg_frame <= 5'd0;
                        effect_hot <= next_choice;
                        used_effects <= (round_full ? 5'd0 : used_effects) | next_choice;
                    end
                    DOWN: begin
                        if (leg_frame == 19) begin
                            gain <= 9'd0;
                            phase <= BLACK;
                        end else begin
                            gain <= 9'd256 - eased_gain(leg_frame + 5'd1);
                            leg_frame <= leg_frame + 5'd1;
                        end
                    end
                    BLACK: if (!request_sync[1]) begin
                        wait_count <= 8'd0;
                        leg_frame <= 5'd0;
                        phase <= SETTLE;
                    end
                    // Allow the frame reader to latch the newly committed
                    // buffer and refill its FIFO before any pixel is revealed.
                    SETTLE: begin
                        if (wait_count >= WAIT_FRAMES-1) phase <= UP;
                        else wait_count <= wait_count + 8'd1;
                    end
                    UP: begin
                        if (leg_frame == 19) begin
                            gain <= 9'd256;
                            phase <= FULL;
                        end else begin
                            gain <= eased_gain(leg_frame + 5'd1);
                            leg_frame <= leg_frame + 5'd1;
                        end
                    end
                    default: begin phase <= FULL; gain <= 9'd256; end
                endcase
            end
        end
    end
endmodule
