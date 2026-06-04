// ============================================================
// CrashTech VLSI-2026 -- Challenge 5: FPGA Volt-Meter
// ============================================================
// Reads analog voltage via the MAX 10 internal ADC (Arduino A0),
// displays it on the 7-segment displays as X.XX,
// drives a 10-LED bar graph proportional to voltage,
// and streams "V=X.XX\n" to the ESP32 over UART at 9600 baud.
//
// ARDUINO_IO[1] = UART TX (to ESP32 GPIO16 / RX2)
// Arduino A0    = ADC input  (potentiometer wiper, 0–3.3 V)
//
// HEX0 = hundredths digit  (rightmost)
// HEX1 = tenths digit      (with decimal point lit)
// HEX2 = ones digit        (leftmost, shows 0–3)
// HEX3..HEX5 = blank
//
// LEDR[9:0] = bar graph  (0 V → 0 LEDs, 3.3 V → 10 LEDs)
//
// 9600 baud, 8N1, 50 MHz system clock
// ============================================================

module fpga_voltmeter_top (
    input           MAX10_CLK1_50,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n = KEY[0];

    // ---- Arduino Header IO ----
    wire uart_tx_out;
    assign ARDUINO_IO[1]    = uart_tx_out;
    assign ARDUINO_IO[0]    = 1'bz;        // unused RX (tri-state)
    assign ARDUINO_IO[15:2] = 14'bz;

    // ================================================================
    //  ADC Wrapper — reads A0 via MAX 10 internal ADC
    //  (see adc_wrapper.sv for Quartus IP instantiation instructions)
    // ================================================================
    wire [11:0] adc_raw;     // 12-bit result: 0 = 0 V, 4095 = 3.3 V
    wire        adc_valid;   // 1-cycle pulse when new sample is ready

    adc_wrapper u_adc (
        .clk       (clk),
        .rst_n     (rst_n),
        .adc_raw   (adc_raw),
        .adc_valid (adc_valid)
    );

    // ================================================================
    //  Voltage conversion: millivolts = raw * 3300 / 4095
    //  Use integer arithmetic (no floating point in hardware)
    //    raw * 3300 fits in 24 bits (4095 * 3300 = 13,513,500 < 2^24)
    // ================================================================
    reg [11:0] adc_latch;    // stable ADC value, updated on adc_valid
    reg [23:0] millivolts;   // 0 .. 3300

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_latch   <= 12'd0;
            millivolts  <= 24'd0;
        end else if (adc_valid) begin
            adc_latch  <= adc_raw;
            // Multiply then divide — synthesiser infers multiplier
            millivolts <= (adc_raw * 24'd3300) / 24'd4095;
        end
    end

    // ================================================================
    //  Digit extraction
    //    ones      =  millivolts / 1000        (0..3)
    //    tenths    = (millivolts / 100) % 10   (0..9)
    //    hundredths= (millivolts / 10 ) % 10   (0..9)
    // ================================================================
    wire [3:0] dig_ones       = millivolts / 24'd1000;
    wire [3:0] dig_tenths     = (millivolts / 24'd100) % 24'd10;
    wire [3:0] dig_hundredths = (millivolts / 24'd10)  % 24'd10;

    // ================================================================
    //  7-segment decoder (active-low, {DP,G,F,E,D,C,B,A})
    //  seg7_nodp  — no decimal point  (DP bit = 1 → off)
    //  seg7_withdp — decimal point ON (DP bit = 0 → on)
    // ================================================================
    function [7:0] seg7_nodp;
        input [3:0] d;
        case (d)
            4'd0: seg7_nodp = 8'b1100_0000;
            4'd1: seg7_nodp = 8'b1111_1001;
            4'd2: seg7_nodp = 8'b1010_0100;
            4'd3: seg7_nodp = 8'b1011_0000;
            4'd4: seg7_nodp = 8'b1001_1001;
            4'd5: seg7_nodp = 8'b1001_0010;
            4'd6: seg7_nodp = 8'b1000_0010;
            4'd7: seg7_nodp = 8'b1111_1000;
            4'd8: seg7_nodp = 8'b1000_0000;
            4'd9: seg7_nodp = 8'b1001_0000;
            default: seg7_nodp = 8'b1111_1111;  // blank
        endcase
    endfunction

    function [7:0] seg7_withdp;
        input [3:0] d;
        begin
            // Same as seg7_nodp but with DP bit (bit 7) cleared → ON
            seg7_withdp = seg7_nodp(d) & 8'b0111_1111;
        end
    endfunction

    // Display layout:  HEX2=ones  HEX1=tenths(DP)  HEX0=hundredths
    assign HEX0 = seg7_nodp(dig_hundredths);
    assign HEX1 = seg7_withdp(dig_tenths);     // decimal point ON here
    assign HEX2 = seg7_nodp(dig_ones);
    assign HEX3 = 8'hFF;    // blank
    assign HEX4 = 8'hFF;    // blank
    assign HEX5 = 8'hFF;    // blank

    // ================================================================
    //  LED bar graph — proportional to millivolts
    //  Each LED lights when millivolts >= threshold[i]
    //    threshold[i] = (i+1) * 330  →  330, 660, 990, … 3300 mV
    // ================================================================
    genvar i;
    generate
        for (i = 0; i < 10; i = i + 1) begin : led_bar
            assign LEDR[i] = (millivolts >= ((i + 1) * 24'd330)) ? 1'b1 : 1'b0;
        end
    endgenerate

    // ================================================================
    //  UART TX — 9600 baud 8N1
    //  Instantiates the shared uart_tx module from the project
    // ================================================================
    localparam CLK_FREQ = 50_000_000;
    localparam BAUD     = 9600;

    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_busy;

    uart_tx #(
        .CLK_FREQ (CLK_FREQ),
        .BAUD     (BAUD)
    ) u_uart_tx (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_start (tx_start),
        .tx_data  (tx_data),
        .tx_busy  (tx_busy),
        .tx_out   (uart_tx_out)
    );

    // ================================================================
    //  UART TX dispatcher
    //  Sends "V=X.XX\n" (7 bytes) whenever a new ADC sample arrives
    //  and the bus is free.
    //
    //  Byte sequence index:
    //    0 → 'V'
    //    1 → '='
    //    2 → ones     ASCII digit
    //    3 → '.'
    //    4 → tenths   ASCII digit
    //    5 → hundredths ASCII digit
    //    6 → '\n'
    // ================================================================
    reg [2:0]  txd_state;
    localparam TXD_IDLE  = 3'd0,
               TXD_V     = 3'd1,
               TXD_EQ    = 3'd2,
               TXD_ONES  = 3'd3,
               TXD_DOT   = 3'd4,
               TXD_TENTH = 3'd5,
               TXD_HUND  = 3'd6,
               TXD_NL    = 3'd7;

    // Snapshot the digits when we decide to send, so they stay stable
    reg [3:0] snap_ones, snap_tenths, snap_hundredths;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txd_state      <= TXD_IDLE;
            tx_start       <= 1'b0;
            tx_data        <= 8'd0;
            snap_ones      <= 4'd0;
            snap_tenths    <= 4'd0;
            snap_hundredths<= 4'd0;
        end else begin
            tx_start <= 1'b0;   // default: no new byte this cycle

            case (txd_state)
                // Wait for a fresh ADC sample (and bus idle)
                TXD_IDLE: begin
                    if (adc_valid && !tx_busy) begin
                        snap_ones       <= dig_ones;
                        snap_tenths     <= dig_tenths;
                        snap_hundredths <= dig_hundredths;
                        txd_state       <= TXD_V;
                    end
                end

                // Send 'V'
                TXD_V: if (!tx_busy) begin
                    tx_data  <= 8'h56;  // 'V'
                    tx_start <= 1'b1;
                    txd_state<= TXD_EQ;
                end

                // Send '='
                TXD_EQ: if (!tx_busy && !tx_start) begin
                    tx_data  <= 8'h3D;  // '='
                    tx_start <= 1'b1;
                    txd_state<= TXD_ONES;
                end

                // Send ones digit (ASCII)
                TXD_ONES: if (!tx_busy && !tx_start) begin
                    tx_data  <= snap_ones + 8'h30;
                    tx_start <= 1'b1;
                    txd_state<= TXD_DOT;
                end

                // Send '.'
                TXD_DOT: if (!tx_busy && !tx_start) begin
                    tx_data  <= 8'h2E;  // '.'
                    tx_start <= 1'b1;
                    txd_state<= TXD_TENTH;
                end

                // Send tenths digit
                TXD_TENTH: if (!tx_busy && !tx_start) begin
                    tx_data  <= snap_tenths + 8'h30;
                    tx_start <= 1'b1;
                    txd_state<= TXD_HUND;
                end

                // Send hundredths digit
                TXD_HUND: if (!tx_busy && !tx_start) begin
                    tx_data  <= snap_hundredths + 8'h30;
                    tx_start <= 1'b1;
                    txd_state<= TXD_NL;
                end

                // Send '\n'
                TXD_NL: if (!tx_busy && !tx_start) begin
                    tx_data  <= 8'h0A;  // '\n'
                    tx_start <= 1'b1;
                    txd_state<= TXD_IDLE;
                end

                default: txd_state <= TXD_IDLE;
            endcase
        end
    end

endmodule
