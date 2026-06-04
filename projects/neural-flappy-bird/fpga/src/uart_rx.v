// uart_rx.v — 8-N-1 UART Receiver
// CrashTech VLSI 2026 — Neural Flappy Bird
// Mid-bit sampling, 3-consecutive-low noise filter on start bit.
`default_nettype none

module uart_rx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 115_200
)(
    input            clk,
    input            rst_n,
    input            rx,
    output reg [7:0] data_out,
    output reg       valid       // 1-cycle pulse when byte ready
);
    localparam BAUD_DIV = CLK_FREQ / BAUD;      // 434
    localparam HALF_DIV = BAUD_DIV / 2;         // 217

    // 2-stage synchronizer for rx input
    reg [1:0] rx_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rx_sync <= 2'b11;
        else        rx_sync <= {rx_sync[0], rx};

    wire rx_s = rx_sync[1];  // synchronized & stable rx

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]  state;
    reg [9:0]  baud_cnt;
    reg [2:0]  bit_cnt;
    reg [7:0]  shreg;
    reg [1:0]  noise_cnt;   // consecutive-low counter for start-bit noise filter

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            valid     <= 1'b0;
            baud_cnt  <= 10'd0;
            bit_cnt   <= 3'd0;
            shreg     <= 8'd0;
            noise_cnt <= 2'd0;
        end else begin
            valid <= 1'b0;
            case (state)
                // ── IDLE: require 3 consecutive rx=0 samples ────────────────
                S_IDLE: begin
                    if (!rx_s) begin
                        if (noise_cnt == 2'd2) begin
                            state     <= S_START;
                            baud_cnt  <= 10'd0;
                            noise_cnt <= 2'd0;
                        end else begin
                            noise_cnt <= noise_cnt + 2'd1;
                        end
                    end else begin
                        noise_cnt <= 2'd0;
                    end
                end

                // ── START: wait HALF_DIV cycles then verify mid-start-bit ───
                S_START: begin
                    if (baud_cnt == HALF_DIV - 1) begin
                        baud_cnt <= 10'd0;
                        if (!rx_s) begin
                            // Still low at mid-point → valid start bit
                            state   <= S_DATA;
                            bit_cnt <= 3'd0;
                        end else begin
                            state <= S_IDLE;   // false start
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 10'd1;
                    end
                end

                // ── DATA: sample at mid-bit (BAUD_DIV cycles per bit) ───────
                S_DATA: begin
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt <= 10'd0;
                        shreg    <= {rx_s, shreg[7:1]};  // LSB-first: shift right
                        if (bit_cnt == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 3'd1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 10'd1;
                    end
                end

                // ── STOP: verify stop bit, emit valid ────────────────────────
                S_STOP: begin
                    if (baud_cnt == BAUD_DIV - 1) begin
                        state    <= S_IDLE;
                        baud_cnt <= 10'd0;
                        if (rx_s) begin   // valid stop bit (high)
                            data_out <= shreg;
                            valid    <= 1'b1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 10'd1;
                    end
                end
            endcase
        end
    end
endmodule
`default_nettype wire
