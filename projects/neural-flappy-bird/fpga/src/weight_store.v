// weight_store.v — Register file for 25 signed 16-bit neural network weights
// CrashTech VLSI 2026 — Neural Flappy Bird
`default_nettype none

module weight_store(
    input                    clk,
    input                    rst_n,
    input                    wr_en,
    input  [4:0]             wr_addr,    // 0–24
    input  [15:0]            wr_data,
    output reg signed [15:0] w [0:24]
);
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 25; i = i + 1)
                w[i] <= 16'sd0;
        end else begin
            if (wr_en)
                w[wr_addr] <= wr_data;
        end
    end
endmodule
`default_nettype wire
