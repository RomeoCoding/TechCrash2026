// debounce.v — Counter-based button debouncer
// CrashTech VLSI 2026 — Neural Flappy Bird
// Emits a 1-cycle pulse on validated active-low button press.
`default_nettype none

module debounce #(parameter STABLE_CYCLES = 2500)(
    input  clk,
    input  rst_n,
    input  btn_in,       // active-low raw input (0 = pressed)
    output btn_press     // 1-cycle pulse on validated press (falling edge of clean)
);
    // 2-stage synchronizer
    reg [1:0] sync_r;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sync_r <= 2'b11;
        else        sync_r <= {sync_r[0], btn_in};

    wire btn_s = sync_r[1];  // synchronized input

    reg [12:0] cnt;          // counter: 13 bits covers up to 8191 ≥ STABLE_CYCLES
    reg        clean;        // debounced state (active-low: 0 = pressed)
    reg        clean_prev;

    // Pulse when clean goes from 1 → 0 (button pressed)
    assign btn_press = clean_prev & ~clean;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt        <= 13'd0;
            clean      <= 1'b1;
            clean_prev <= 1'b1;
        end else begin
            clean_prev <= clean;
            if (btn_s == clean) begin
                cnt <= 13'd0;          // input matches current state → reset
            end else begin
                if (cnt == STABLE_CYCLES - 1) begin
                    clean <= btn_s;    // stable for STABLE_CYCLES → accept change
                    cnt   <= 13'd0;
                end else begin
                    cnt <= cnt + 13'd1;
                end
            end
        end
    end
endmodule
`default_nettype wire
