// uart_tx.v — 8-N-1 UART Transmitter
// CrashTech VLSI 2026 — Neural Flappy Bird
`default_nettype none

module uart_tx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD     = 115_200
)(
    input        clk,
    input        rst_n,
    input  [7:0] data_in,
    input        send,       // 1-cycle pulse to start transmission
    output reg   tx,         // UART TX line (idles high)
    output       busy        // high from send pulse until stop bit completes
);
    localparam BAUD_DIV = CLK_FREQ / BAUD;  // 434 at 50 MHz / 115200

    reg [9:0]  shift;      // {stop(1), data[7:0], start(0)}
    reg [9:0]  baud_cnt;
    reg [3:0]  bit_cnt;
    reg        active;

    assign busy = active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx       <= 1'b1;
            active   <= 1'b0;
            baud_cnt <= 10'd0;
            bit_cnt  <= 4'd0;
            shift    <= 10'h3FF;
        end else if (!active) begin
            tx <= 1'b1;
            if (send) begin
                // shift[9]=stop(1), shift[8:1]=data, shift[0]=start(0)
                shift    <= {1'b1, data_in, 1'b0};
                active   <= 1'b1;
                baud_cnt <= 10'd0;
                bit_cnt  <= 4'd0;
            end
        end else begin
            tx <= shift[0];
            if (baud_cnt == BAUD_DIV - 1) begin
                baud_cnt <= 10'd0;
                if (bit_cnt == 4'd9) begin
                    // Stop bit done
                    active <= 1'b0;
                end else begin
                    shift   <= {1'b1, shift[9:1]};  // right-shift, fill MSB with 1
                    bit_cnt <= bit_cnt + 4'd1;
                end
            end else begin
                baud_cnt <= baud_cnt + 10'd1;
            end
        end
    end
endmodule
`default_nettype wire
