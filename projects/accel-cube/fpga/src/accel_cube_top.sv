// ============================================================================
// Accel Cube — DE10-Lite FPGA Top
// ============================================================================
// Reads ADXL345 onboard accelerometer via SPI (Mode 3, 1 MHz).
// Initialises ADXL345: DATA_FORMAT=0x00 (±2g), POWER_CTL=0x08 (measure).
// Streams X/Y/Z raw bytes to ESP32 over UART (115200 baud, 10ms interval):
//   header 0xAA, ax0, ax1, ay0, ay1, az0, az1  (7 bytes per packet)
// LEDs show tilt direction. HEX1:0 = raw X byte (hex), HEX3:2 = raw Y byte.
// ============================================================================

module accel_cube_top (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output logic [9:0] LEDR,
    output logic [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire  [15:0] ARDUINO_IO,
    output wire        ARDUINO_RESET_N,
    // ADXL345 SPI (4-wire, Mode 3)
    output logic       GSENSOR_CS_N,
    output logic       GSENSOR_SCLK,
    output logic       GSENSOR_SDI,   // MOSI
    input  wire        GSENSOR_SDO,   // MISO
    input  wire  [2:1] GSENSOR_INT    // interrupts (unused)
);

    assign ARDUINO_RESET_N  = 1'b1;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_IO[0]    = 1'bz;   // RX input (not used here)

    // =========================================================================
    // UART TX  — 115200 baud, 8N1
    // ARDUINO_IO[1] = TX to ESP32 GPIO17
    // =========================================================================
    localparam integer CLKS_PER_BIT = 434;  // 50_000_000 / 115200

    logic uart_tx_line;
    assign ARDUINO_IO[1] = uart_tx_line;

    logic       uart_start, uart_done, uart_active;
    logic [7:0] uart_tx_byte, uart_data;
    logic [8:0] uart_cnt;
    logic [3:0] uart_bit;

    always_ff @(posedge MAX10_CLK1_50) begin
        uart_done <= 0;
        if (!uart_active) begin
            uart_tx_line <= 1;
            if (uart_start) begin
                uart_active  <= 1;
                uart_tx_line <= 0;           // start bit
                uart_data    <= uart_tx_byte;
                uart_bit     <= 0;
                uart_cnt     <= 0;
            end
        end else begin
            uart_cnt <= uart_cnt + 1;
            if (uart_cnt == CLKS_PER_BIT - 1) begin
                uart_cnt <= 0;
                uart_bit <= uart_bit + 1;
                case (uart_bit)
                    4'd0: uart_tx_line <= uart_data[0];
                    4'd1: uart_tx_line <= uart_data[1];
                    4'd2: uart_tx_line <= uart_data[2];
                    4'd3: uart_tx_line <= uart_data[3];
                    4'd4: uart_tx_line <= uart_data[4];
                    4'd5: uart_tx_line <= uart_data[5];
                    4'd6: uart_tx_line <= uart_data[6];
                    4'd7: uart_tx_line <= uart_data[7];
                    4'd8: uart_tx_line <= 1;             // stop bit
                    4'd9: begin uart_active <= 0; uart_done <= 1; end
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // SPI Master — Mode 3 (CPOL=1, CPHA=1), 1 MHz at 50 MHz clock
    // CLK_DIV = 25: half-period = 25 cycles → 1 MHz
    // =========================================================================
    localparam integer CLK_DIV = 25;

    logic       spi_start, spi_done, spi_active;
    logic [7:0] spi_tx, spi_rx, spi_rx_shift;
    logic [2:0] spi_bit_cnt;
    logic [5:0] spi_clk_cnt;

    always_ff @(posedge MAX10_CLK1_50) begin
        spi_done <= 0;
        if (!spi_active) begin
            GSENSOR_SCLK <= 1;   // idle high (CPOL=1)
            GSENSOR_SDI  <= 1;   // idle
            if (spi_start) begin
                spi_active  <= 1;
                spi_bit_cnt <= 0;
                spi_clk_cnt <= 0;
                GSENSOR_SDI <= spi_tx[7];   // pre-drive MSB
            end
        end else begin
            spi_clk_cnt <= spi_clk_cnt + 1;

            if (spi_clk_cnt == CLK_DIV - 1) begin
                // Falling edge — ADXL345 latches MOSI here
                GSENSOR_SCLK <= 0;

            end else if (spi_clk_cnt == 2*CLK_DIV - 1) begin
                // Rising edge — master samples MISO here
                GSENSOR_SCLK <= 1;
                spi_clk_cnt  <= 0;   // reset counter (overrides increment above)
                spi_rx_shift <= {spi_rx_shift[6:0], GSENSOR_SDO};

                if (spi_bit_cnt == 7) begin
                    spi_active <= 0;
                    spi_done   <= 1;
                    spi_rx     <= {spi_rx_shift[6:0], GSENSOR_SDO};
                end else begin
                    // Pre-drive next MOSI bit before next falling edge
                    GSENSOR_SDI <= spi_tx[6 - spi_bit_cnt];  // bit N+1
                    spi_bit_cnt <= spi_bit_cnt + 1;
                end
            end
        end
    end

    // =========================================================================
    // Main FSM — init → periodic read → UART TX
    // =========================================================================
    typedef enum logic [4:0] {
        S_INIT_WAIT,
        // Write DATA_FORMAT (addr 0x31, data 0x00)
        S_WR1_CS, S_WR1_ADDR, S_WR1_DATA, S_WR1_DECS,
        // Write POWER_CTL (addr 0x2D, data 0x08)
        S_WR2_CS, S_WR2_ADDR, S_WR2_DATA, S_WR2_DECS,
        // 10 ms sample interval
        S_POLL_WAIT,
        // Read 6 bytes: CS → cmd → X0 X1 Y0 Y1 Z0 Z1 → deassert
        S_RD_CS, S_RD_CMD,
        S_RD_X0, S_RD_X1, S_RD_Y0, S_RD_Y1, S_RD_Z0, S_RD_Z1,
        S_RD_DECS,
        // UART TX: header, ax0..az1
        S_TX_HDR, S_TX_X0, S_TX_X1, S_TX_Y0, S_TX_Y1, S_TX_Z0, S_TX_Z1
    } state_t;
    state_t state;

    logic [26:0] main_cnt;
    logic [7:0]  ax0, ax1, ay0, ay1, az0, az1;

    always_ff @(posedge MAX10_CLK1_50) begin
        spi_start  <= 0;
        uart_start <= 0;

        case (state)
            // ---- Power-up wait: 100 ms ----
            S_INIT_WAIT: begin
                GSENSOR_CS_N <= 1;
                main_cnt <= main_cnt + 1;
                if (main_cnt == 27'd5_000_000) begin
                    main_cnt <= 0;
                    state    <= S_WR1_CS;
                end
            end

            // ---- Write DATA_FORMAT = 0x00 (±2g, 10-bit) ----
            S_WR1_CS: begin
                GSENSOR_CS_N <= 0;
                spi_tx       <= 8'h31;   // write cmd for register 0x31
                spi_start    <= 1;
                state        <= S_WR1_ADDR;
            end
            S_WR1_ADDR: if (spi_done) begin
                spi_tx    <= 8'h00;      // DATA_FORMAT value
                spi_start <= 1;
                state     <= S_WR1_DATA;
            end
            S_WR1_DATA: if (spi_done) begin
                GSENSOR_CS_N <= 1;
                main_cnt     <= 0;
                state        <= S_WR1_DECS;
            end
            S_WR1_DECS: begin
                main_cnt <= main_cnt + 1;
                if (main_cnt == 100) begin main_cnt <= 0; state <= S_WR2_CS; end
            end

            // ---- Write POWER_CTL = 0x08 (measure mode) ----
            S_WR2_CS: begin
                GSENSOR_CS_N <= 0;
                spi_tx       <= 8'h2D;   // write cmd for register 0x2D
                spi_start    <= 1;
                state        <= S_WR2_ADDR;
            end
            S_WR2_ADDR: if (spi_done) begin
                spi_tx    <= 8'h08;      // POWER_CTL: measure=1
                spi_start <= 1;
                state     <= S_WR2_DATA;
            end
            S_WR2_DATA: if (spi_done) begin
                GSENSOR_CS_N <= 1;
                main_cnt     <= 0;
                state        <= S_WR2_DECS;
            end
            S_WR2_DECS: begin
                main_cnt <= main_cnt + 1;
                if (main_cnt == 100) begin main_cnt <= 0; state <= S_POLL_WAIT; end
            end

            // ---- 10 ms sample interval ----
            S_POLL_WAIT: begin
                main_cnt <= main_cnt + 1;
                if (main_cnt == 27'd500_000) begin
                    main_cnt <= 0;
                    state    <= S_RD_CS;
                end
            end

            // ---- SPI read: 0xF2 = R=1, MB=1, addr=0x32 ----
            S_RD_CS: begin
                GSENSOR_CS_N <= 0;
                spi_tx       <= 8'hF2;
                spi_start    <= 1;
                state        <= S_RD_CMD;
            end
            S_RD_CMD: if (spi_done) begin
                spi_tx <= 8'hFF; spi_start <= 1; state <= S_RD_X0;
            end
            S_RD_X0: if (spi_done) begin
                ax0 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1; state <= S_RD_X1;
            end
            S_RD_X1: if (spi_done) begin
                ax1 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1; state <= S_RD_Y0;
            end
            S_RD_Y0: if (spi_done) begin
                ay0 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1; state <= S_RD_Y1;
            end
            S_RD_Y1: if (spi_done) begin
                ay1 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1; state <= S_RD_Z0;
            end
            S_RD_Z0: if (spi_done) begin
                az0 <= spi_rx; spi_tx <= 8'hFF; spi_start <= 1; state <= S_RD_Z1;
            end
            S_RD_Z1: if (spi_done) begin
                az1          <= spi_rx;
                GSENSOR_CS_N <= 1;
                main_cnt     <= 0;
                state        <= S_RD_DECS;
            end
            S_RD_DECS: begin
                main_cnt <= main_cnt + 1;
                if (main_cnt == 100) begin main_cnt <= 0; state <= S_TX_HDR; end
            end

            // ---- UART TX: 7 bytes ----
            S_TX_HDR: begin
                uart_tx_byte <= 8'hAA;
                uart_start   <= 1;
                state        <= S_TX_X0;
            end
            S_TX_X0: if (uart_done) begin
                uart_tx_byte <= ax0; uart_start <= 1; state <= S_TX_X1;
            end
            S_TX_X1: if (uart_done) begin
                uart_tx_byte <= ax1; uart_start <= 1; state <= S_TX_Y0;
            end
            S_TX_Y0: if (uart_done) begin
                uart_tx_byte <= ay0; uart_start <= 1; state <= S_TX_Y1;
            end
            S_TX_Y1: if (uart_done) begin
                uart_tx_byte <= ay1; uart_start <= 1; state <= S_TX_Z0;
            end
            S_TX_Z0: if (uart_done) begin
                uart_tx_byte <= az0; uart_start <= 1; state <= S_TX_Z1;
            end
            S_TX_Z1: if (uart_done) begin
                uart_tx_byte <= az1; uart_start <= 1; state <= S_POLL_WAIT;
            end

            default: state <= S_INIT_WAIT;
        endcase
    end

    // =========================================================================
    // LED tilt indicators (sign bit of upper byte = ax1[7])
    // =========================================================================
    // In ±2g, 10-bit mode: upper 6 bits of ax1 are sign extension.
    // ax positive → tilted +X, ax negative → tilted -X
    assign LEDR[3:0] = 4'b0;
    assign LEDR[4]  = !ax1[7] && ax0[7];   // +X (MSB of low byte high, sign=0)
    assign LEDR[5]  =  ax1[7];             // -X
    assign LEDR[6]  = !ay1[7] && ay0[7];   // +Y
    assign LEDR[7]  =  ay1[7];             // -Y
    assign LEDR[8]  = !az1[7] && az0[7];   // +Z (face up)
    assign LEDR[9]  =  az1[7];             // -Z (face down)

    // =========================================================================
    // 7-segment: HEX1:0 = ax0 hex, HEX3:2 = ay0 hex
    // =========================================================================
    function automatic [7:0] hex7;
        input [3:0] d;
        case (d)
            4'h0: hex7 = 8'b1100_0000;
            4'h1: hex7 = 8'b1111_1001;
            4'h2: hex7 = 8'b1010_0100;
            4'h3: hex7 = 8'b1011_0000;
            4'h4: hex7 = 8'b1001_1001;
            4'h5: hex7 = 8'b1001_0010;
            4'h6: hex7 = 8'b1000_0010;
            4'h7: hex7 = 8'b1111_1000;
            4'h8: hex7 = 8'b1000_0000;
            4'h9: hex7 = 8'b1001_0000;
            4'hA: hex7 = 8'b1000_1000;
            4'hB: hex7 = 8'b1000_0011;
            4'hC: hex7 = 8'b1100_0110;
            4'hD: hex7 = 8'b1010_0001;
            4'hE: hex7 = 8'b1000_0110;
            4'hF: hex7 = 8'b1000_1110;
        endcase
    endfunction

    assign HEX0 = hex7(ax0[3:0]);
    assign HEX1 = hex7(ax0[7:4]);
    assign HEX2 = hex7(ay0[3:0]);
    assign HEX3 = hex7(ay0[7:4]);
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

endmodule
