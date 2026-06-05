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

    // Combinational: ZC count including the current byte's contribution.
    // Using a wire avoids conflicting non-blocking assignments when byte_count==255
    // (last ZC of a frame would otherwise be overridden by the zc_accum<=8'd0 reset).
    wire [7:0] zc_next = (rx_byte[7] != last_sign) ? zc_accum + 8'd1 : zc_accum;

    always_ff @(posedge MAX10_CLK1_50) begin
        if (rx_valid) begin
            last_sign <= rx_byte[7];

            if (byte_count == 8'd255) begin
                // End of 256-sample frame — capture final ZC count, compute frequency
                // freq = zc_next * 8000 / 512 = zc_next * 125 >> 3
                // Add 4 before >> 3 to round instead of truncate
                zc_latch     <= zc_next;
                freq_display <= ((14'(zc_next) * 14'd125) + 14'd4) >> 3;
                zc_accum     <= 8'd0;
                byte_count   <= 8'd0;
            end else begin
                zc_accum   <= zc_next;
                byte_count <= byte_count + 8'd1;
            end
        end
    end

    // =========================================================================
    // BCD decomposition for display
    // =========================================================================
    logic [3:0] d3, d2, d1, d0;
    logic [3:0] z1, z0;   // zc_latch tens and units for debug HEX5/4

    always_comb begin
        d3 = 4'(freq_display / 14'd1000);
        d2 = 4'((freq_display % 14'd1000) / 14'd100);
        d1 = 4'((freq_display % 14'd100)  / 14'd10);
        d0 = 4'(freq_display % 14'd10);
        z1 = 4'(zc_latch / 8'd10);
        z0 = 4'(zc_latch % 8'd10);
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

    // HEX3..0 always show frequency Hz
    assign HEX3 = seg7(d3);
    assign HEX2 = seg7(d2);
    assign HEX1 = seg7(d1);
    assign HEX0 = seg7(d0);
    // SW[9]=1: HEX5/4 show raw ZC count (debug internals); SW[9]=0: blank
    assign HEX5 = SW[9] ? seg7(z1)  : 8'hFF;
    assign HEX4 = SW[9] ? seg7(z0)  : 8'hFF;

    // =========================================================================
    // LED animated bar — thermometer fill + top LED blinks at freq-band rate
    //
    // Frequency bands (190 Hz each, 10 bands from 100 to 2000 Hz):
    //   band 0: 100-289 Hz  → 1 LED
    //   band 1: 290-479 Hz  → 2 LEDs
    //   ...
    //   band 9: 1910-2000Hz → 10 LEDs
    //
    // The highest lit LED blinks at a rate derived from the band index so that
    // higher frequencies produce a visibly faster pulse (creative requirement).
    // Blink dividers: band0=25M clocks (~2Hz), band9=2.5M clocks (~20Hz).
    // =========================================================================
    logic [3:0] led_count;   // number of LEDs that should be on (1..10, 0=none)

    always_comb begin
        casez (1'b1)
            (freq_display >= 14'd1810): led_count = 4'd10;
            (freq_display >= 14'd1620): led_count = 4'd9;
            (freq_display >= 14'd1430): led_count = 4'd8;
            (freq_display >= 14'd1240): led_count = 4'd7;
            (freq_display >= 14'd1050): led_count = 4'd6;
            (freq_display >= 14'd860):  led_count = 4'd5;
            (freq_display >= 14'd670):  led_count = 4'd4;
            (freq_display >= 14'd480):  led_count = 4'd3;
            (freq_display >= 14'd290):  led_count = 4'd2;
            (freq_display >= 14'd100):  led_count = 4'd1;
            default:                    led_count = 4'd0;
        endcase
    end

    // Blink counter — 25 bits handles up to 25M clocks at 50 MHz = 0.5s period
    logic [24:0] blink_cnt;
    logic        blink_bit;

    // Divide 50 MHz by a band-dependent amount:
    // band 0 (slowest) → use bit[23] of counter (~3 Hz toggle = ~6 Hz blink)
    // band 9 (fastest) → use bit[19] of counter (~48 Hz toggle = ~96 Hz blink)
    // We pick bit index = 23 - led_count, clamped to [19..23]
    always_ff @(posedge MAX10_CLK1_50)
        blink_cnt <= blink_cnt + 25'd1;

    always_comb begin
        case (led_count)
            4'd10:   blink_bit = blink_cnt[18];
            4'd9:    blink_bit = blink_cnt[19];
            4'd8:    blink_bit = blink_cnt[20];
            4'd7:    blink_bit = blink_cnt[20];
            4'd6:    blink_bit = blink_cnt[21];
            4'd5:    blink_bit = blink_cnt[21];
            4'd4:    blink_bit = blink_cnt[22];
            4'd3:    blink_bit = blink_cnt[22];
            4'd2:    blink_bit = blink_cnt[23];
            4'd1:    blink_bit = blink_cnt[23];
            default: blink_bit = 1'b0;
        endcase
    end

    // Build LED output: solid fill for LEDs below top, blink on top LED
    always_comb begin
        LEDR = 10'b0;
        for (int j = 0; j < 10; j++) begin
            if (led_count > 4'(j + 1))
                LEDR[j] = 1'b1;              // solid on — below top
            else if (led_count == 4'(j + 1))
                LEDR[j] = blink_bit;         // top LED blinks at band rate
            else
                LEDR[j] = 1'b0;
        end
    end

endmodule
