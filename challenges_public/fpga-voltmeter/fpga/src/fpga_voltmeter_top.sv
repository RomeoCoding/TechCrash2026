// ============================================================
// Challenge 5: FPGA Volt-Meter
// CrashTech VLSI-2026, DE10-Lite (MAX 10)
//
// Reads Arduino A0 via MAX10 internal ADC (CH1, 12-bit).
// Displays voltage as X.XX on HEX5..HEX3 (with decimal point).
// LED bar graph LEDR[9:0] proportional to voltage.
// Sends "X.XX\n" over UART at 9600 baud to ESP32 every 100 ms.
//
// WIRING (FPGA <-> ESP32):
//   ARDUINO_IO[1] (PIN_AB6)  -> ESP32 GPIO17 (RX)
//   Arduino GND              -> ESP32 GND
//   Analog voltage source    -> Arduino A0 header pin (0-3.3V)
//
// ADC note: modular_adc_core requires MAX10 target in Quartus.
// Clock divided to ~1.56 MHz (50 MHz / 32) for ADC sequencer.
// ============================================================

module fpga_voltmeter_top (
    input           MAX10_CLK1_50,
    input   [1:0]   KEY,
    input   [9:0]   SW,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n = KEY[0];

    // ---- Arduino Header IO ----
    wire uart_tx_out;
    assign ARDUINO_IO[0]    = 1'bz;        // not used (RX if needed later)
    assign ARDUINO_IO[1]    = uart_tx_out; // UART TX to ESP32 GPIO17
    assign ARDUINO_IO[15:2] = 14'bz;

    // ================================================================
    //  ADC clock divider: 50 MHz / 32 = ~1.56 MHz (within 10 MHz max)
    // ================================================================
    reg [4:0] adc_clk_div;
    reg       adc_clk_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_clk_div <= 0;
            adc_clk_r   <= 0;
        end else begin
            adc_clk_div <= adc_clk_div + 1;
            if (adc_clk_div == 5'd15)
                adc_clk_r <= ~adc_clk_r;
        end
    end
    wire adc_clk = adc_clk_r;

    // ================================================================
    //  MAX10 Modular ADC Core
    //  CH1 = Arduino header A0 (0-3.3 V)
    // ================================================================
    wire [11:0] adc_raw;
    wire        adc_valid;
    wire        adc_eoc;

    // Continuous conversion on CH1
    modular_adc_core u_adc (
        .clock   (adc_clk),
        .reset_n (rst_n),
        .chsel   (5'd1),    // CH1 = Arduino A0
        .soc     (1'b1),    // always restart conversion
        .tsen    (1'b0),
        .dout    (adc_raw),
        .valid   (adc_valid),
        .eoc     (adc_eoc)
    );

    // ================================================================
    //  Voltage calculation (registered to avoid long comb chain)
    //  volt_mv = adc_raw * 3300 / 4096
    //           ≈ (adc_raw * 3300) >> 12
    //  Range: 0-3299 mV
    // ================================================================
    reg [11:0] adc_latch;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) adc_latch <= 12'd0;
        else if (adc_valid) adc_latch <= adc_raw;
    end

    // 12-bit * 12-bit = 24-bit; take upper 12 bits = >> 12
    wire [23:0] volt_raw = adc_latch * 24'd3300;
    wire [11:0] volt_mv  = volt_raw[23:12];   // 0-3299

    // BCD breakdown: X.XX
    wire [3:0] d_int  = volt_mv / 12'd1000;           // 0-3
    wire [3:0] d_tens = (volt_mv % 12'd1000) / 12'd100; // 0-9
    wire [3:0] d_ones = (volt_mv % 12'd100)  / 12'd10;  // 0-9

    // Register BCD for clean display and UART
    reg [3:0] r_int, r_tens, r_ones;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin r_int <= 0; r_tens <= 0; r_ones <= 0; end
        else begin r_int <= d_int; r_tens <= d_tens; r_ones <= d_ones; end
    end

    // ================================================================
    //  7-segment decoder (active-low segments + decimal point)
    //  bit[7] = decimal point (0 = ON)
    // ================================================================
    function [6:0] seg7_digit;
        input [3:0] d;
        case (d)
            4'd0: seg7_digit = 7'b100_0000;
            4'd1: seg7_digit = 7'b111_1001;
            4'd2: seg7_digit = 7'b010_0100;
            4'd3: seg7_digit = 7'b011_0000;
            4'd4: seg7_digit = 7'b001_1001;
            4'd5: seg7_digit = 7'b001_0010;
            4'd6: seg7_digit = 7'b000_0010;
            4'd7: seg7_digit = 7'b111_1000;
            4'd8: seg7_digit = 7'b000_0000;
            4'd9: seg7_digit = 7'b001_0000;
            default: seg7_digit = 7'b111_1111; // blank
        endcase
    endfunction

    // HEX5 = integer digit WITH decimal point ON (bit7=0)
    assign HEX5 = {1'b0, seg7_digit(r_int)};   // "X."
    assign HEX4 = {1'b1, seg7_digit(r_tens)};  // first decimal digit
    assign HEX3 = {1'b1, seg7_digit(r_ones)};  // second decimal digit
    assign HEX2 = 8'hFF;  // blank
    assign HEX1 = 8'hFF;  // blank
    assign HEX0 = 8'hFF;  // blank

    // ================================================================
    //  LED bar graph: LEDR[i] ON when volt_mv > i * 330 mV
    //  Full scale: 10 LEDs at 3.30 V
    // ================================================================
    genvar gi;
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : led_bar
            assign LEDR[gi] = (volt_mv > (gi * 330)) ? 1'b1 : 1'b0;
        end
    endgenerate

    // ================================================================
    //  UART TX: send "X.XX\n" every 100 ms (5_000_000 clocks @ 50 MHz)
    //  9600 baud -> 5208 clocks/bit
    // ================================================================
    localparam CLKS_PER_BIT = 13'd5208;
    localparam TX_INTERVAL  = 26'd5_000_000;

    reg [25:0] tx_timer;
    reg        send_trigger;
    reg [3:0]  snap_int, snap_tens, snap_ones;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_timer     <= 0;
            send_trigger <= 0;
        end else begin
            send_trigger <= 0;
            if (tx_timer == TX_INTERVAL - 1) begin
                tx_timer     <= 0;
                send_trigger <= 1;
                snap_int     <= r_int;
                snap_tens    <= r_tens;
                snap_ones    <= r_ones;
            end else
                tx_timer <= tx_timer + 1;
        end
    end

    // --- Low-level UART TX byte engine ---
    reg [12:0] tx_clk_cnt;
    reg [3:0]  tx_bit_idx;
    reg [9:0]  tx_shift;
    reg        tx_busy;
    reg        tx_out_reg;
    reg        tx_start;
    reg [7:0]  tx_data;

    assign uart_tx_out = tx_out_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_busy <= 0; tx_out_reg <= 1; tx_clk_cnt <= 0; tx_bit_idx <= 0;
        end else if (!tx_busy && tx_start) begin
            tx_shift   <= {1'b1, tx_data, 1'b0}; // stop, data[7:0], start
            tx_busy    <= 1;
            tx_bit_idx <= 0;
            tx_clk_cnt <= 0;
            tx_out_reg <= 0;  // start bit
        end else if (tx_busy) begin
            if (tx_clk_cnt == CLKS_PER_BIT - 1) begin
                tx_clk_cnt <= 0;
                tx_bit_idx <= tx_bit_idx + 1;
                if (tx_bit_idx < 9)
                    tx_out_reg <= tx_shift[tx_bit_idx + 1];
                else begin
                    tx_busy    <= 0;
                    tx_out_reg <= 1;
                end
            end else
                tx_clk_cnt <= tx_clk_cnt + 1;
        end
    end

    // --- TX dispatch FSM: send "X.XX\n" (5 bytes) ---
    reg [2:0] txd_state;
    localparam TXD_IDLE=3'd0, TXD_INT=3'd1, TXD_DOT=3'd2,
               TXD_F1=3'd3,   TXD_F2=3'd4,  TXD_NL=3'd5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txd_state <= TXD_IDLE;
            tx_start  <= 0;
            tx_data   <= 0;
        end else begin
            tx_start <= 0;
            case (txd_state)
                TXD_IDLE: if (send_trigger) txd_state <= TXD_INT;

                TXD_INT: if (!tx_busy && !tx_start) begin
                    tx_data   <= {4'h3, snap_int};  // ASCII '0'-'3'
                    tx_start  <= 1;
                    txd_state <= TXD_DOT;
                end

                TXD_DOT: if (!tx_busy && !tx_start) begin
                    tx_data   <= 8'h2E;  // '.'
                    tx_start  <= 1;
                    txd_state <= TXD_F1;
                end

                TXD_F1: if (!tx_busy && !tx_start) begin
                    tx_data   <= {4'h3, snap_tens};  // ASCII '0'-'9'
                    tx_start  <= 1;
                    txd_state <= TXD_F2;
                end

                TXD_F2: if (!tx_busy && !tx_start) begin
                    tx_data   <= {4'h3, snap_ones};  // ASCII '0'-'9'
                    tx_start  <= 1;
                    txd_state <= TXD_NL;
                end

                TXD_NL: if (!tx_busy && !tx_start) begin
                    tx_data   <= 8'h0A;  // '\n'
                    tx_start  <= 1;
                    txd_state <= TXD_IDLE;
                end

                default: txd_state <= TXD_IDLE;
            endcase
        end
    end

endmodule
