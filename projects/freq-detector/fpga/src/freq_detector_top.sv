// ============================================================================
// Frequency Detector — DE10-Lite FPGA Top
// ============================================================================
// Receives 256 signed bytes from ESP32 at 115200 baud (8 kHz sample frame).
// Counts zero-crossings (sign-bit transitions) across the 256-sample window.
// freq_hz = zc_count * 8000 / 512  =  zc_count * 125 / 8
//
// Display:
//   HEX3..0  : frequency in Hz (0000-9999)
//   SW[9]=1  : debug — show raw zero-crossing count instead
//   LEDR[9:0]: thermometer bar proportional to frequency band
//              LEDR[n] on when freq >= 100 + (n+1)*190
//              (100->off, ~290->1 LED, ~480->2 LEDs, ... ~2000->10 LEDs)
// ============================================================================

module freq_detector_top (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output logic [9:0] LEDR,
    output logic [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire  [15:0] ARDUINO_IO,
    output wire        ARDUINO_RESET_N
);

    assign ARDUINO_RESET_N = 1'b1;

    // ARDUINO_IO[0] is UART RX from ESP32 (input); drive others as Z
    assign ARDUINO_IO[15:1] = 15'bz;

    // Double-flop synchroniser for the async RX line
    logic rx_raw, rx_s1, rx_s2;
    assign rx_raw = ARDUINO_IO[0];

    always_ff @(posedge MAX10_CLK1_50) begin
        rx_s1 <= rx_raw;
        rx_s2 <= rx_s1;
    end

    // =========================================================================
    // Inline UART RX — 115200 baud, 50 MHz clock
    // CLKS_PER_BIT = 50_000_000 / 115200 = 434
    // CLKS_HALF    = 217  (sample in middle of first data bit)
    // =========================================================================
    localparam integer CLKS_PER_BIT = 434;
    localparam integer CLKS_HALF    = 217;

    typedef enum logic [1:0] { RX_IDLE, RX_START, RX_DATA, RX_STOP } rx_state_t;
    rx_state_t rx_state;

    logic [8:0] rx_cnt;      // max 434 — needs 9 bits
    logic [2:0] rx_bit_idx;
    logic [7:0] rx_shift;
    logic       rx_valid;    // 1-cycle pulse when byte is ready
    logic [7:0] rx_byte;

    always_ff @(posedge MAX10_CLK1_50) begin
        rx_valid <= 1'b0;

        case (rx_state)
            RX_IDLE: begin
                if (!rx_s2) begin                  // falling edge = start bit
                    rx_cnt   <= CLKS_HALF[8:0] - 9'd1;
                    rx_state <= RX_START;
                end
            end

            RX_START: begin
                if (rx_cnt == '0) begin
                    if (!rx_s2) begin              // still low: valid start bit
                        rx_cnt     <= CLKS_PER_BIT[8:0] - 9'd1;
                        rx_bit_idx <= 3'd0;
                        rx_state   <= RX_DATA;
                    end else
                        rx_state <= RX_IDLE;       // glitch — abort
                end else
                    rx_cnt <= rx_cnt - 9'd1;
            end

            RX_DATA: begin
                if (rx_cnt == '0) begin
                    rx_shift   <= {rx_s2, rx_shift[7:1]}; // LSB first
                    rx_cnt     <= CLKS_PER_BIT[8:0] - 9'd1;
                    if (rx_bit_idx == 3'd7)
                        rx_state <= RX_STOP;
                    else
                        rx_bit_idx <= rx_bit_idx + 3'd1;
                end else
                    rx_cnt <= rx_cnt - 9'd1;
            end

            RX_STOP: begin
                if (rx_cnt == '0) begin
                    if (rx_s2) begin               // stop bit high — valid byte
                        rx_byte  <= rx_shift;
                        rx_valid <= 1'b1;
                    end
                    rx_state <= RX_IDLE;
                end else
                    rx_cnt <= rx_cnt - 9'd1;
            end

            default: rx_state <= RX_IDLE;
        endcase
    end

    // =========================================================================
    // Streaming zero-crossing detector + frequency calculator
    // =========================================================================
    logic [7:0]  byte_count;    // 0..255 within current frame
    logic [7:0]  zc_accum;      // zero crossings accumulating this frame
    logic        last_sign;     // sign bit of previous byte
    logic [7:0]  zc_latch;      // ZC count captured at end of frame
    logic [13:0] freq_display;  // latched frequency in Hz

    always_ff @(posedge MAX10_CLK1_50) begin
        if (rx_valid) begin
            // Count sign-bit transitions (zero crossings)
            if (rx_byte[7] != last_sign)
                zc_accum <= zc_accum + 8'd1;
            last_sign <= rx_byte[7];

            if (byte_count == 8'd255) begin
                // End of 256-sample frame — compute frequency
                // freq = zc_accum * 8000 / 512 = zc_accum * 125 >> 3
                zc_latch      <= zc_accum;
                freq_display  <= (14'(zc_accum) * 14'd125) >> 3;
                zc_accum      <= 8'd0;
                byte_count    <= 8'd0;
            end else begin
                byte_count <= byte_count + 8'd1;
            end
        end
    end

    // =========================================================================
    // BCD decomposition for display
    // =========================================================================
    logic [13:0] disp_val;
    logic [3:0]  d3, d2, d1, d0;

    // SW[9]=1: show raw zero-crossing count (debug); SW[9]=0: show freq Hz
    assign disp_val = SW[9] ? {6'b0, zc_latch} : freq_display;

    always_comb begin
        d3 = 4'(disp_val / 14'd1000);
        d2 = 4'((disp_val % 14'd1000) / 14'd100);
        d1 = 4'((disp_val % 14'd100)  / 14'd10);
        d0 = 4'(disp_val % 14'd10);
    end

    // =========================================================================
    // 7-segment encoder (active-low, bit[7]=DP unused = 1)
    // =========================================================================
    function automatic [7:0] seg7;
        input [3:0] digit;
        case (digit)
            4'd0: seg7 = 8'b1100_0000;
            4'd1: seg7 = 8'b1111_1001;
            4'd2: seg7 = 8'b1010_0100;
            4'd3: seg7 = 8'b1011_0000;
            4'd4: seg7 = 8'b1001_1001;
            4'd5: seg7 = 8'b1001_0010;
            4'd6: seg7 = 8'b1000_0010;
            4'd7: seg7 = 8'b1111_1000;
            4'd8: seg7 = 8'b1000_0000;
            4'd9: seg7 = 8'b1001_0000;
            default: seg7 = 8'b1111_1111;
        endcase
    endfunction

    assign HEX3 = seg7(d3);
    assign HEX2 = seg7(d2);
    assign HEX1 = seg7(d1);
    assign HEX0 = seg7(d0);
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    // =========================================================================
    // LED thermometer bar — thresholds at 290, 480, 670, ..., 2000 Hz
    // =========================================================================
    genvar i;
    generate
        for (i = 0; i < 10; i++) begin : led_gen
            assign LEDR[i] = (freq_display >= 14'(100 + (i + 1) * 190)) ? 1'b1 : 1'b0;
        end
    endgenerate

endmodule
