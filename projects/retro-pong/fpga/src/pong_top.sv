// ============================================================================
// pong_top.sv — DE10-Lite FPGA (Challenge 8: PC Retro Game)
// ============================================================================
// Based on accel_cube_top.sv. Reads ADXL345 via SPI, packs tilt + KEY + SW
// into an 11-byte UART packet and streams to ESP32 at 115200 baud, 62.5 Hz.
//
// Packet:  0xAA  ax0 ax1  ay0 ay1  az0 az1  key_byte  sw_lo  sw_hi  0x55
// Indices:  [0]  [1] [2]  [3] [4]  [5] [6]    [7]      [8]    [9]   [10]
//
// ay (signed 16-bit, little-endian) is the P1 paddle axis:
//   board flat   → ay ≈ 0   → paddle centred
//   tilt forward → ay > 0   → paddle moves down
//   tilt back    → ay < 0   → paddle moves up
//
// key_byte: bit0=KEY[0] pressed, bit1=KEY[1] pressed (active-HIGH after inversion)
// sw_lo:    SW[7:0]
// sw_hi:    {6'b0, SW[9:8]}
//
// LEDR[9:0]: 10-LED bar showing P1 tilt position
// HEX5:4   = "P1",  HEX3:0 = "----"
//
// UART TX: ARDUINO_IO[1] → ESP32_P1 GPIO16 (RX2)  @ 115200 8N1
// ============================================================================

module pong_top (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,              // active low on DE10-Lite
    input  wire [9:0]  SW,
    output logic [9:0] LEDR,
    output logic [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire  [15:0] ARDUINO_IO,
    output wire        ARDUINO_RESET_N,
    // ADXL345 SPI (4-wire, Mode 3, CPOL=1 CPHA=1)
    output logic       GSENSOR_CS_N,
    output logic       GSENSOR_SCLK,
    output logic       GSENSOR_SDI,     // MOSI
    input  wire        GSENSOR_SDO,     // MISO
    input  wire  [2:1] GSENSOR_INT      // interrupts (unused)
);

    assign ARDUINO_RESET_N  = 1'b1;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_IO[0]    = 1'bz;     // not used

    // =========================================================================
    // UART TX — 115200 baud, 8N1, 50 MHz clock
    // CLKS_PER_BIT = 50_000_000 / 115_200 = 434
    // =========================================================================
    localparam integer CLKS_PER_BIT = 434;

    logic       uart_tx_line;
    assign ARDUINO_IO[1] = uart_tx_line;

    logic       uart_start;   // pulse: set for 1 cycle to start TX
    logic       uart_done;    // pulse: set for 1 cycle when TX complete
    logic       uart_active;
    logic [7:0] uart_tx_byte; // byte to transmit (latch when uart_start=1)
    logic [7:0] uart_data;    // latched copy
    logic [8:0] uart_cnt;     // bit-period counter
    logic [3:0] uart_bit;     // 0-9 (8 data + 1 stop)

    always_ff @(posedge MAX10_CLK1_50) begin
        uart_done <= 1'b0;
        if (!uart_active) begin
            uart_tx_line <= 1'b1;                  // idle high
            if (uart_start) begin
                uart_active  <= 1'b1;
                uart_tx_line <= 1'b0;              // start bit
                uart_data    <= uart_tx_byte;
                uart_bit     <= 4'd0;
                uart_cnt     <= 9'd0;
            end
        end else begin
            uart_cnt <= uart_cnt + 1'b1;
            if (uart_cnt == CLKS_PER_BIT - 1) begin
                uart_cnt <= 9'd0;
                uart_bit <= uart_bit + 1'b1;
                case (uart_bit)
                    4'd0: uart_tx_line <= uart_data[0];
                    4'd1: uart_tx_line <= uart_data[1];
                    4'd2: uart_tx_line <= uart_data[2];
                    4'd3: uart_tx_line <= uart_data[3];
                    4'd4: uart_tx_line <= uart_data[4];
                    4'd5: uart_tx_line <= uart_data[5];
                    4'd6: uart_tx_line <= uart_data[6];
                    4'd7: uart_tx_line <= uart_data[7];
                    4'd8: uart_tx_line <= 1'b1;        // stop bit
                    4'd9: begin
                        uart_active <= 1'b0;
                        uart_done   <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // SPI Master — Mode 3 (CPOL=1, CPHA=1), ~1 MHz
    // Half-period = CLK_DIV = 25 cycles → 1 MHz at 50 MHz
    // =========================================================================
    localparam integer CLK_DIV = 25;

    logic       spi_start;     // pulse
    logic       spi_done;      // pulse
    logic       spi_active;
    logic [7:0] spi_tx;        // byte to send
    logic [7:0] spi_rx;        // byte received
    logic [7:0] spi_rx_shift;
    logic [2:0] spi_bit_cnt;
    logic [5:0] spi_clk_cnt;

    always_ff @(posedge MAX10_CLK1_50) begin
        spi_done <= 1'b0;
        if (!spi_active) begin
            GSENSOR_SCLK <= 1'b1;      // idle high (CPOL=1)
            GSENSOR_SDI  <= 1'b1;
            if (spi_start) begin
                spi_active  <= 1'b1;
                spi_bit_cnt <= 3'd0;
                spi_clk_cnt <= 6'd0;
                GSENSOR_SDI <= spi_tx[7];  // pre-drive MSB
            end
        end else begin
            spi_clk_cnt <= spi_clk_cnt + 1'b1;
            if (spi_clk_cnt == CLK_DIV - 1) begin
                // falling edge — ADXL345 latches MOSI
                GSENSOR_SCLK <= 1'b0;
            end else if (spi_clk_cnt == 2*CLK_DIV - 1) begin
                // rising edge — master samples MISO
                GSENSOR_SCLK <= 1'b1;
                spi_clk_cnt  <= 6'd0;
                spi_rx_shift <= {spi_rx_shift[6:0], GSENSOR_SDO};
                if (spi_bit_cnt == 3'd7) begin
                    spi_active <= 1'b0;
                    spi_done   <= 1'b1;
                    spi_rx     <= {spi_rx_shift[6:0], GSENSOR_SDO};
                end else begin
                    GSENSOR_SDI <= spi_tx[6 - spi_bit_cnt];  // next MOSI bit
                    spi_bit_cnt <= spi_bit_cnt + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Main FSM — init → poll → UART TX (11 bytes)
    // =========================================================================
    typedef enum logic [4:0] {
        S_INIT_WAIT,
        // Write DATA_FORMAT = 0x00 (±2g, 10-bit)
        S_WR1_CS, S_WR1_ADDR, S_WR1_DATA, S_WR1_DECS,
        // Write POWER_CTL = 0x08 (measure)
        S_WR2_CS, S_WR2_ADDR, S_WR2_DATA, S_WR2_DECS,
        // 16 ms sample interval
        S_POLL_WAIT,
        // SPI burst read: reg 0x32, 6 bytes (X0 X1 Y0 Y1 Z0 Z1)
        S_RD_CS, S_RD_CMD,
        S_RD_X0, S_RD_X1, S_RD_Y0, S_RD_Y1, S_RD_Z0, S_RD_Z1,
        S_RD_DECS,
        // UART TX: 11 bytes
        S_TX_HDR,
        S_TX_X0, S_TX_X1, S_TX_Y0, S_TX_Y1, S_TX_Z0, S_TX_Z1,
        S_TX_KEY, S_TX_SWL, S_TX_SWH, S_TX_END, S_TX_END_WAIT
    } state_t;
    // 31 states — fits in logic [4:0] (max 32)
    state_t state;

    logic [26:0] main_cnt;
    logic [7:0]  ax0, ax1, ay0, ay1, az0, az1;

    // KEY[n] is active-low on DE10-Lite; invert so 1 = pressed
    wire [7:0] key_byte = {6'b0, ~KEY[1], ~KEY[0]};

    always_ff @(posedge MAX10_CLK1_50) begin
        // default: clear one-shot signals each cycle
        spi_start  <= 1'b0;
        uart_start <= 1'b0;

        case (state)

            // ------------------------------------------------------------------
            // Power-up wait: 100 ms (5_000_000 cycles @ 50 MHz)
            // ------------------------------------------------------------------
            S_INIT_WAIT: begin
                GSENSOR_CS_N <= 1'b1;
                main_cnt <= main_cnt + 1'b1;
                if (main_cnt == 27'd5_000_000) begin
                    main_cnt <= 27'd0;
                    state    <= S_WR1_CS;
                end
            end

            // ------------------------------------------------------------------
            // Write DATA_FORMAT (reg 0x31 = 0x00 → ±2g, 10-bit)
            // ------------------------------------------------------------------
            S_WR1_CS: begin
                GSENSOR_CS_N <= 1'b0;
                spi_tx       <= 8'h31;    // write, addr 0x31
                spi_start    <= 1'b1;
                state        <= S_WR1_ADDR;
            end
            S_WR1_ADDR: if (spi_done) begin
                spi_tx    <= 8'h00;       // DATA_FORMAT value
                spi_start <= 1'b1;
                state     <= S_WR1_DATA;
            end
            S_WR1_DATA: if (spi_done) begin
                GSENSOR_CS_N <= 1'b1;
                main_cnt     <= 27'd0;
                state        <= S_WR1_DECS;
            end
            S_WR1_DECS: begin
                main_cnt <= main_cnt + 1'b1;
                if (main_cnt == 27'd100) begin
                    main_cnt <= 27'd0;
                    state    <= S_WR2_CS;
                end
            end

            // ------------------------------------------------------------------
            // Write POWER_CTL (reg 0x2D = 0x08 → measure mode)
            // ------------------------------------------------------------------
            S_WR2_CS: begin
                GSENSOR_CS_N <= 1'b0;
                spi_tx       <= 8'h2D;    // write, addr 0x2D
                spi_start    <= 1'b1;
                state        <= S_WR2_ADDR;
            end
            S_WR2_ADDR: if (spi_done) begin
                spi_tx    <= 8'h08;       // POWER_CTL: measure=1
                spi_start <= 1'b1;
                state     <= S_WR2_DATA;
            end
            S_WR2_DATA: if (spi_done) begin
                GSENSOR_CS_N <= 1'b1;
                main_cnt     <= 27'd0;
                state        <= S_WR2_DECS;
            end
            S_WR2_DECS: begin
                main_cnt <= main_cnt + 1'b1;
                if (main_cnt == 27'd100) begin
                    main_cnt <= 27'd0;
                    state    <= S_POLL_WAIT;
                end
            end

            // ------------------------------------------------------------------
            // 16 ms sample interval: 800_000 cycles @ 50 MHz
            // ------------------------------------------------------------------
            S_POLL_WAIT: begin
                main_cnt <= main_cnt + 1'b1;
                if (main_cnt == 27'd800_000) begin
                    main_cnt <= 27'd0;
                    state    <= S_RD_CS;
                end
            end

            // ------------------------------------------------------------------
            // SPI burst read: cmd 0xF2 = R(1) MB(1) addr(0x32)
            // reads X0 X1 Y0 Y1 Z0 Z1 in one CS assertion
            // ------------------------------------------------------------------
            S_RD_CS: begin
                GSENSOR_CS_N <= 1'b0;
                spi_tx       <= 8'hF2;    // 0xF2 = read | multi-byte | 0x32
                spi_start    <= 1'b1;
                state        <= S_RD_CMD;
            end
            S_RD_CMD: if (spi_done) begin
                spi_tx <= 8'hFF; spi_start <= 1'b1; state <= S_RD_X0;
            end
            S_RD_X0: if (spi_done) begin
                ax0 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1'b1; state <= S_RD_X1;
            end
            S_RD_X1: if (spi_done) begin
                ax1 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1'b1; state <= S_RD_Y0;
            end
            S_RD_Y0: if (spi_done) begin
                ay0 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1'b1; state <= S_RD_Y1;
            end
            S_RD_Y1: if (spi_done) begin
                ay1 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1'b1; state <= S_RD_Z0;
            end
            S_RD_Z0: if (spi_done) begin
                az0 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1'b1; state <= S_RD_Z1;
            end
            S_RD_Z1: if (spi_done) begin
                az1          <= spi_rx;
                GSENSOR_CS_N <= 1'b1;
                main_cnt     <= 27'd0;
                state        <= S_RD_DECS;
            end
            // Brief deassert gap before TX
            S_RD_DECS: begin
                main_cnt <= main_cnt + 1'b1;
                if (main_cnt == 27'd100) begin
                    main_cnt <= 27'd0;
                    state    <= S_TX_HDR;
                end
            end

            // ------------------------------------------------------------------
            // UART TX: 11 bytes
            // Pattern: set uart_tx_byte + uart_start, advance state.
            // Next state waits for uart_done (previous byte finished) before
            // loading the next byte. S_TX_END_WAIT waits for 0x55 to finish.
            // ------------------------------------------------------------------
            S_TX_HDR: begin
                uart_tx_byte <= 8'hAA;
                uart_start   <= 1'b1;
                state        <= S_TX_X0;
            end
            S_TX_X0: if (uart_done) begin
                uart_tx_byte <= ax0;      uart_start <= 1'b1; state <= S_TX_X1;
            end
            S_TX_X1: if (uart_done) begin
                uart_tx_byte <= ax1;      uart_start <= 1'b1; state <= S_TX_Y0;
            end
            S_TX_Y0: if (uart_done) begin
                uart_tx_byte <= ay0;      uart_start <= 1'b1; state <= S_TX_Y1;
            end
            S_TX_Y1: if (uart_done) begin
                uart_tx_byte <= ay1;      uart_start <= 1'b1; state <= S_TX_Z0;
            end
            S_TX_Z0: if (uart_done) begin
                uart_tx_byte <= az0;      uart_start <= 1'b1; state <= S_TX_Z1;
            end
            S_TX_Z1: if (uart_done) begin
                uart_tx_byte <= az1;      uart_start <= 1'b1; state <= S_TX_KEY;
            end
            S_TX_KEY: if (uart_done) begin
                uart_tx_byte <= key_byte; uart_start <= 1'b1; state <= S_TX_SWL;
            end
            S_TX_SWL: if (uart_done) begin
                uart_tx_byte <= SW[7:0];           uart_start <= 1'b1; state <= S_TX_SWH;
            end
            S_TX_SWH: if (uart_done) begin
                uart_tx_byte <= {6'b0, SW[9:8]};   uart_start <= 1'b1; state <= S_TX_END;
            end
            S_TX_END: if (uart_done) begin
                uart_tx_byte <= 8'h55;    uart_start <= 1'b1; state <= S_TX_END_WAIT;
            end
            S_TX_END_WAIT: if (uart_done) begin
                state <= S_POLL_WAIT;     // 0x55 fully sent, wait for next poll
            end

            default: state <= S_INIT_WAIT;
        endcase
    end

    // =========================================================================
    // LEDR[9:0] — 10-LED tilt bar (ay position)
    // ADXL345 ±2g, 10-bit: typical range ±200 counts for ±45° tilt
    // Map ay ∈ [-200, +200] → bar_idx ∈ [0, 9]
    // =========================================================================
    wire signed [15:0] ay_signed  = {ay1, ay0};
    wire signed [15:0] ay_clamped =
        (ay_signed >  16'sd200) ?  16'sd200 :
        (ay_signed < -16'sd200) ? -16'sd200 : ay_signed;

    // bar_raw: unsigned 0..400
    wire [15:0] bar_raw = ay_clamped + 16'sd200;

    // Map to 0..9 with even 40-count steps
    wire [3:0] bar_idx =
        (bar_raw >= 16'd360) ? 4'd9 :
        (bar_raw >= 16'd320) ? 4'd8 :
        (bar_raw >= 16'd280) ? 4'd7 :
        (bar_raw >= 16'd240) ? 4'd6 :
        (bar_raw >= 16'd200) ? 4'd5 :
        (bar_raw >= 16'd160) ? 4'd4 :
        (bar_raw >= 16'd120) ? 4'd3 :
        (bar_raw >= 16'd80)  ? 4'd2 :
        (bar_raw >= 16'd40)  ? 4'd1 : 4'd0;

    // Fill LEDs 0..bar_idx (bar grows from bottom)
    genvar gi;
    generate
        for (gi = 0; gi < 10; gi++) begin : led_bar
            assign LEDR[gi] = (gi[3:0] <= bar_idx);
        end
    endgenerate

    // =========================================================================
    // HEX display — active-low 7-segment
    // Segment map: bit0=a(top) b c d e f bit6=g(mid) bit7=dp
    // HEX5="P"  HEX4="1"  HEX3..0="-"
    // P = a,b,e,f,g ON  → bits a=0,b=0,c=1,d=1,e=0,f=0,g=0,dp=1 = 8'b1000_1100
    // 1 = b,c ON        → 8'b1111_1001
    // - = g ON          → 8'b1011_1111
    // =========================================================================
    assign HEX5 = 8'b1000_1100;   // "P"
    assign HEX4 = 8'b1111_1001;   // "1"
    assign HEX3 = 8'b1011_1111;   // "-"
    assign HEX2 = 8'b1011_1111;   // "-"
    assign HEX1 = 8'b1011_1111;   // "-"
    assign HEX0 = 8'b1011_1111;   // "-"

endmodule
