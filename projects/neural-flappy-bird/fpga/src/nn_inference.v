// nn_inference.v — Fixed-point neural network inference engine
// CrashTech VLSI 2026 — Neural Flappy Bird
//
// Architecture: 4-input → 4-hidden (ReLU) → 1-output (sign)
// Arithmetic: Q8.8 fixed-point, 32-bit accumulators
//
// Reference (ground-truth):
//   hidden j: acc32 = SUM(w[j*4+i]*in[i]) + (B1[j]<<8), acc32>>>=8, ReLU
//   output:   acc32 = SUM(w[20+j]*h[j])   + (B2   <<8), acc32>>>=8, flap=~sign
//
// Single-multiplier sequential FSM:
//   IDLE → HIDDEN (sub 0..4 per neuron × 4 neurons = 20 cycles)
//        → OUTPUT (sub 0..4 = 5 cycles) → DONE (1 cycle) → IDLE
//
// Weight canonical order w[0:24]:
//   [0-3]  W1[0][0-3], [4-7] W1[1][0-3], [8-11] W1[2][0-3], [12-15] W1[3][0-3]
//   [16-19] B1[0-3],   [20-23] W2[0][0-3], [24] B2[0]
`default_nettype none

module nn_inference(
    input              clk,
    input              rst_n,
    input  signed [15:0] in0, in1, in2, in3,   // Q8.8 normalized inputs
    input  signed [15:0] w [0:24],              // Q8.8 weights (canonical order)
    input              start,                   // 1-cycle pulse
    output reg         flap,
    output reg         done                     // 1-cycle pulse when result ready
);
    localparam S_IDLE    = 2'd0;
    localparam S_HIDDEN  = 2'd1;
    localparam S_OUTPUT  = 2'd2;
    localparam S_DONE    = 2'd3;

    reg [1:0]  state;
    reg [2:0]  sub;      // sub-step within current neuron: 0..4
    reg [1:0]  n_idx;    // current hidden neuron: 0..3

    reg signed [31:0] acc;         // 32-bit accumulator (Q16.16 before final >>8)
    reg signed [15:0] h [0:3];     // post-ReLU hidden values (Q8.8)

    // Input array
    wire signed [15:0] in_arr [0:3];
    assign in_arr[0] = in0;
    assign in_arr[1] = in1;
    assign in_arr[2] = in2;
    assign in_arr[3] = in3;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done  <= 1'b0;
            flap  <= 1'b0;
            sub   <= 3'd0;
            n_idx <= 2'd0;
            acc   <= 32'sd0;
            for (i = 0; i < 4; i = i + 1)
                h[i] <= 16'sd0;
        end else begin
            done <= 1'b0;

            case (state)
                // ── IDLE ────────────────────────────────────────────────────
                S_IDLE: begin
                    if (start) begin
                        state <= S_HIDDEN;
                        sub   <= 3'd0;
                        n_idx <= 2'd0;
                        acc   <= 32'sd0;
                    end
                end

                // ── HIDDEN: 5 sub-steps per neuron, 4 neurons ───────────────
                //  sub=0: acc = sign_extend(B1[n]) << 8  (bias pre-load)
                //  sub=1: acc += W1[n][0] * in0
                //  sub=2: acc += W1[n][1] * in1
                //  sub=3: acc += W1[n][2] * in2
                //  sub=4: acc += W1[n][3] * in3, normalize, ReLU → h[n]
                S_HIDDEN: begin
                    case (sub)
                        3'd0: begin
                            // Bias: sign-extend w[16+n] then shift left 8
                            acc <= {{8{w[5'd16 + {3'b000,n_idx}][15]}},
                                      w[5'd16 + {3'b000,n_idx}], 8'h00};
                            sub <= 3'd1;
                        end
                        3'd1: begin
                            acc <= acc + ($signed(w[{n_idx,2'b00}        ]) * $signed(in_arr[0]));
                            sub <= 3'd2;
                        end
                        3'd2: begin
                            acc <= acc + ($signed(w[{n_idx,2'b00} + 5'd1]) * $signed(in_arr[1]));
                            sub <= 3'd3;
                        end
                        3'd3: begin
                            acc <= acc + ($signed(w[{n_idx,2'b00} + 5'd2]) * $signed(in_arr[2]));
                            sub <= 3'd4;
                        end
                        3'd4: begin
                            begin : h_calc
                                reg signed [31:0] fa;
                                reg signed [31:0] sh;
                                fa = acc + ($signed(w[{n_idx,2'b00} + 5'd3]) * $signed(in_arr[3]));
                                sh = fa >>> 8;
                                h[n_idx] <= sh[31] ? 16'sd0 : sh[15:0];  // ReLU
                            end
                            sub <= 3'd0;
                            acc <= 32'sd0;
                            if (n_idx == 2'd3)
                                state <= S_OUTPUT;
                            else
                                n_idx <= n_idx + 2'd1;
                        end
                        default: sub <= 3'd0;
                    endcase
                end

                // ── OUTPUT: bias + 4 MACs ────────────────────────────────────
                //  sub=0: acc = sign_extend(B2) << 8
                //  sub=1..4: acc += W2[0][j-1] * h[j-1]
                //  after sub=4: acc >>>=8, flap=~sign
                S_OUTPUT: begin
                    case (sub)
                        3'd0: begin
                            acc <= {{8{w[24][15]}}, w[24], 8'h00};
                            sub <= 3'd1;
                        end
                        3'd1: begin
                            acc <= acc + ($signed(w[20]) * $signed(h[0]));
                            sub <= 3'd2;
                        end
                        3'd2: begin
                            acc <= acc + ($signed(w[21]) * $signed(h[1]));
                            sub <= 3'd3;
                        end
                        3'd3: begin
                            acc <= acc + ($signed(w[22]) * $signed(h[2]));
                            sub <= 3'd4;
                        end
                        3'd4: begin
                            begin : out_calc
                                reg signed [31:0] fa;
                                fa   = acc + ($signed(w[23]) * $signed(h[3]));
                                fa   = fa >>> 8;
                                flap <= ~fa[31];  // flap if result is positive
                            end
                            state <= S_DONE;
                        end
                        default: state <= S_IDLE;
                    endcase
                end

                // ── DONE: emit done pulse, return to IDLE ────────────────────
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
