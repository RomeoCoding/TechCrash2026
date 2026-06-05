// flappy_m1_top.v — Neural Flappy Bird, Milestone 1 (minimal)
// CrashTech VLSI 2026
//
// FPGA acts as game controller + difficulty controller for the ESP32.
//   KEY[0]  : flap button (active-low on DE10-Lite). On each valid press the
//             FPGA sends a FLAP byte to the ESP32 over UART.
//   SW[3:0] : difficulty 0..15. The value is shown on HEX0 and sent to the
//             ESP32 over UART whenever it changes (and once at startup).
//   KEY[1]  : active-low reset.
//
// UART protocol (FPGA -> ESP32, single bytes, 115200 8-N-1):
//   0x46 ('F')        = FLAP
//   0xD0 .. 0xDF      = difficulty 0..15  (high nibble 0xD, low nibble = value)
//
// LEDR[3:0] mirror SW[3:0] (visual sanity), LEDR[9] blinks on each TX.
`default_nettype none

module flappy_m1_top (
    input  wire        MAX10_CLK1_50,   // 50 MHz
    input  wire [1:0]  KEY,             // active-low push buttons
    input  wire [9:0]  SW,
    output wire [9:0]  LEDR,
    output wire [7:0]  HEX0,
    output wire        GPIO_0_TX        // FPGA UART TX  -> ESP32 RX (GPIO16)
);
    wire clk   = MAX10_CLK1_50;
    wire rst_n = KEY[1];                // KEY[1] = reset (active-low)

    // ── Protocol constants ───────────────────────────────────────────────────
    localparam [7:0] BYTE_FLAP = 8'h46; // 'F'
    localparam [3:0] DIFF_TAG  = 4'hD;  // difficulty high-nibble tag

    // ─────────────────────────────────────────────────────────────────────────
    // Input synchronizers
    // ─────────────────────────────────────────────────────────────────────────
    reg [1:0] key0_sync;
    reg [3:0] sw_sync_a, sw_sync_b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            key0_sync <= 2'b11;
            sw_sync_a <= 4'd0;
            sw_sync_b <= 4'd0;
        end else begin
            key0_sync <= {key0_sync[0], KEY[0]};
            sw_sync_a <= SW[3:0];
            sw_sync_b <= sw_sync_a;
        end
    end
    wire key0_s = key0_sync[1];
    wire [3:0] diff_val = sw_sync_b;

    // ─────────────────────────────────────────────────────────────────────────
    // KEY[0] debounce (~5 ms) + falling-edge detect -> flap_pulse
    // ─────────────────────────────────────────────────────────────────────────
    localparam integer DB_LIMIT = 250_000;   // 5 ms @ 50 MHz
    reg [17:0] db_cnt;
    reg        key0_db;       // debounced level (1 = released, 0 = pressed)
    reg        key0_db_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            db_cnt       <= 18'd0;
            key0_db      <= 1'b1;
            key0_db_prev <= 1'b1;
        end else begin
            key0_db_prev <= key0_db;
            if (key0_s != key0_db) begin
                if (db_cnt == DB_LIMIT - 1) begin
                    key0_db <= key0_s;
                    db_cnt  <= 18'd0;
                end else begin
                    db_cnt <= db_cnt + 18'd1;
                end
            end else begin
                db_cnt <= 18'd0;
            end
        end
    end
    // falling edge (released -> pressed) = one valid flap
    wire flap_pulse = (key0_db_prev == 1'b1) && (key0_db == 1'b0);

    // ─────────────────────────────────────────────────────────────────────────
    // Difficulty-change detect -> diff_pulse (also fire once at startup)
    // ─────────────────────────────────────────────────────────────────────────
    reg [3:0] diff_prev;
    reg       started;
    reg       diff_pulse;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            diff_prev  <= 4'hF;     // force a mismatch -> initial send
            started    <= 1'b0;
            diff_pulse <= 1'b0;
        end else begin
            diff_pulse <= 1'b0;
            if (!started) begin
                started    <= 1'b1;
                diff_prev  <= diff_val;
                diff_pulse <= 1'b1;          // send difficulty once at startup
            end else if (diff_val != diff_prev) begin
                diff_prev  <= diff_val;
                diff_pulse <= 1'b1;
            end
        end
    end

    // ─────────────────────────────────────────────────────────────────────────
    // TX arbiter: queue flap + difficulty, send one byte at a time.
    // Flap takes priority. Difficulty change is latched until sent.
    // ─────────────────────────────────────────────────────────────────────────
    reg        flap_pend;
    reg        diff_pend;
    reg [7:0]  tx_data;
    reg        tx_send;
    wire       tx_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flap_pend <= 1'b0;
            diff_pend <= 1'b0;
            tx_send   <= 1'b0;
            tx_data   <= 8'd0;
        end else begin
            tx_send <= 1'b0;

            if (flap_pulse) flap_pend <= 1'b1;
            if (diff_pulse) diff_pend <= 1'b1;

            if (!tx_busy && !tx_send) begin
                if (flap_pend) begin
                    tx_data   <= BYTE_FLAP;
                    tx_send   <= 1'b1;
                    flap_pend <= 1'b0;
                end else if (diff_pend) begin
                    tx_data   <= {DIFF_TAG, diff_val};
                    tx_send   <= 1'b1;
                    diff_pend <= 1'b0;
                end
            end
        end
    end

    uart_tx #(.CLK_FREQ(50_000_000), .BAUD(115_200)) u_tx (
        .clk     (clk),
        .rst_n   (rst_n),
        .data_in (tx_data),
        .send    (tx_send),
        .tx      (GPIO_0_TX),
        .busy    (tx_busy)
    );

    // ─────────────────────────────────────────────────────────────────────────
    // 7-segment display of difficulty on HEX0 (active-low segments)
    // ─────────────────────────────────────────────────────────────────────────
    seg7 u_seg0 (.val(diff_val), .seg(HEX0));

    // ─────────────────────────────────────────────────────────────────────────
    // LEDs: mirror difficulty, blink LEDR[9] briefly on each TX
    // ─────────────────────────────────────────────────────────────────────────
    reg [22:0] tx_blink;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            tx_blink <= 23'd0;
        else if (tx_send)      tx_blink <= 23'h7FFFFF;     // ~0.17 s
        else if (|tx_blink)    tx_blink <= tx_blink - 23'd1;
    end

    assign LEDR[3:0] = diff_val;
    assign LEDR[8:4] = 5'd0;
    assign LEDR[9]   = |tx_blink;

endmodule


// ── 7-segment decoder (DE10-Lite HEX is active-low, segment[7]=DP) ───────────
module seg7 (
    input  wire [3:0] val,
    output reg  [7:0] seg     // {DP, g, f, e, d, c, b, a}, active-low
);
    always @(*) begin
        case (val)
            4'h0: seg = 8'b11000000;
            4'h1: seg = 8'b11111001;
            4'h2: seg = 8'b10100100;
            4'h3: seg = 8'b10110000;
            4'h4: seg = 8'b10011001;
            4'h5: seg = 8'b10010010;
            4'h6: seg = 8'b10000010;
            4'h7: seg = 8'b11111000;
            4'h8: seg = 8'b10000000;
            4'h9: seg = 8'b10010000;
            4'hA: seg = 8'b10001000;
            4'hB: seg = 8'b10000011;
            4'hC: seg = 8'b11000110;
            4'hD: seg = 8'b10100001;
            4'hE: seg = 8'b10000110;
            4'hF: seg = 8'b10001110;
        endcase
    end
endmodule
`default_nettype wire
