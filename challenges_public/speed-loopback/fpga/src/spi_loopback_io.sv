// =============================================================================
// spi_loopback_io.sv
// SPI Mode 0 master — drop-in replacement for uart_tx + uart_rx
// =============================================================================
// Interfaces:
//   TX: tx_start (1-cycle pulse), tx_data[7:0], tx_busy
//   RX: rx_data[7:0], rx_valid (1-cycle pulse)
//   Pins: sck, mosi, miso, cs_n
//
// Protocol:
//   1. TX phase  — CS_N low, stream all bytes (header + data) via MOSI at SCK_FREQ
//   2. Auto-gap  — CS_N high until ready_for_rx or GAP_CYCLES timeout
//   3. RX phase  — CS_N low, clock 8 dummy bits and read checksum byte from MISO
//   4. rx_valid pulsed; module returns to IDLE
//
// SCK freq = CLK_FREQ / (2 × CLK_DIV) = 50 MHz / 6 = 8.33 MHz (safe for ESP32 DMA slave)
// =============================================================================

module spi_loopback_io #(
    parameter CLK_FREQ  = 50_000_000,
    parameter CLK_DIV   = 3,       // SCK half-period in clk cycles → 8.33 MHz
    parameter GAP_CYCLES = 50000,  // fallback timeout if ready_for_rx is not wired
    parameter MIN_GAP_CYCLES = 500 // minimum CS_N high time before honoring ready_for_rx
)(
    input  wire       clk,
    input  wire       rst_n,

    // --- TX interface (same as uart_tx) ---
    input  wire       tx_start,
    input  wire [7:0] tx_data,
    output reg        tx_busy,

    // --- RX interface (same as uart_rx) ---
    output reg  [7:0] rx_data,
    output reg        rx_valid,

    // --- SPI physical pins ---
    output reg        sck,
    output reg        mosi,
    input  wire       miso,
    input  wire       ready_for_rx,
    output reg        cs_n
);

    // -------------------------------------------------------------------------
    // State encoding
    // -------------------------------------------------------------------------
    localparam [2:0]
        S_IDLE     = 3'd0,  // CS_N=1, waiting for tx_start
        S_TX_BYTE  = 3'd1,  // Shifting out one byte
        S_INTER    = 3'd2,  // Brief inter-byte window, tx_busy=0
        S_DEASSERT = 3'd3,  // Deassert CS_N, prepare gap
        S_GAP      = 3'd4,  // GAP_CYCLES wait before checksum read
        S_RX_BYTE  = 3'd5,  // Clocking in checksum byte (8 bits, MOSI=0)
        S_DONE     = 3'd6;  // Pulse rx_valid, return to IDLE

    reg [2:0]  state;

    // SPI shift / counters
    reg [7:0]  shift_reg;   // TX shift register
    reg [7:0]  rx_shift;    // RX shift register
    reg [2:0]  bit_cnt;     // Counts bits 7..0 (MSB first)
    reg [7:0]  sck_cnt;     // Counts 0..CLK_DIV-1 for each SCK half (8 bits supports CLK_DIV up to 255)
    reg [16:0] gap_cnt;     // Counts GAP_CYCLES (needs 17 bits for up to 131071)
    reg [2:0]  idle_cnt;    // Counts cycles without tx_start in S_INTER

    // Precomputed half-period constant (synthesis-friendly)
    localparam SCK_HALF = CLK_DIV;

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            cs_n     <= 1'b1;
            sck      <= 1'b0;
            mosi     <= 1'b0;
            tx_busy  <= 1'b0;
            rx_valid <= 1'b0;
            rx_data  <= 8'h00;
            sck_cnt  <= 8'd0;
            gap_cnt  <= 17'd0;
            idle_cnt <= 3'd0;
            bit_cnt  <= 3'd7;
            shift_reg<= 8'h00;
            rx_shift <= 8'h00;
        end else begin
            rx_valid <= 1'b0;   // default one-cycle pulse

            case (state)

                // ---------------------------------------------------------
                // IDLE: CS_N=1, SCK=0. Wait for first tx_start.
                // ---------------------------------------------------------
                S_IDLE: begin
                    cs_n    <= 1'b1;
                    sck     <= 1'b0;
                    tx_busy <= 1'b0;
                    if (tx_start) begin
                        // Load first byte, assert CS_N, pre-drive MOSI
                        shift_reg <= tx_data;
                        mosi      <= tx_data[7];   // pre-drive MSB before first SCK rise
                        cs_n      <= 1'b0;
                        tx_busy   <= 1'b1;
                        bit_cnt   <= 3'd7;
                        sck_cnt   <= 3'd0;
                        state     <= S_TX_BYTE;
                    end
                end

                // ---------------------------------------------------------
                // TX_BYTE: Shift out 8 bits, MSB first, Mode 0
                //   - MOSI stable (pre-driven or after falling edge)
                //   - SCK rises after SCK_HALF cycles: ESP32 samples MOSI
                //   - SCK falls after another SCK_HALF: shift next bit
                // ---------------------------------------------------------
                S_TX_BYTE: begin
                    sck_cnt <= sck_cnt + 8'd1;
                    if (sck_cnt == SCK_HALF - 8'd1) begin
                        sck_cnt <= 8'd0;
                        if (!sck) begin
                            // Rising edge: ESP32 samples MOSI here
                            sck <= 1'b1;
                        end else begin
                            // Falling edge
                            sck <= 1'b0;
                            if (bit_cnt == 3'd0) begin
                                // Last bit just clocked — byte complete
                                // tx_busy goes low; enter inter-byte gap
                                tx_busy  <= 1'b0;
                                idle_cnt <= 3'd0;
                                state    <= S_INTER;
                            end else begin
                                // Shift in next bit, pre-drive MOSI
                                shift_reg <= {shift_reg[6:0], 1'b0};
                                bit_cnt   <= bit_cnt - 3'd1;
                                mosi      <= shift_reg[6];   // next bit = [6] after shift
                            end
                        end
                    end
                end

                // ---------------------------------------------------------
                // INTER: tx_busy=0, CS_N stays LOW.
                // State machine has ~5 cycles to pulse tx_start for next byte.
                // If tx_start arrives → load and continue TX.
                // If no tx_start after 5 cycles → all bytes done, deassert CS_N.
                // ---------------------------------------------------------
                S_INTER: begin
                    if (tx_start) begin
                        // Next byte ready: pre-drive MOSI and continue
                        shift_reg <= tx_data;
                        mosi      <= tx_data[7];
                        bit_cnt   <= 3'd7;
                        sck_cnt   <= 8'd0;
                        tx_busy   <= 1'b1;
                        idle_cnt  <= 3'd0;
                        state     <= S_TX_BYTE;
                    end else if (idle_cnt == 3'd5) begin
                        // No more bytes — move to deassert CS_N
                        state <= S_DEASSERT;
                    end else begin
                        idle_cnt <= idle_cnt + 3'd1;
                    end
                end

                // ---------------------------------------------------------
                // DEASSERT: Raise CS_N, clear SCK, start gap timer.
                // ---------------------------------------------------------
                S_DEASSERT: begin
                    cs_n    <= 1'b1;
                    sck     <= 1'b0;
                    gap_cnt <= 17'd0;
                    state   <= S_GAP;
                end

                // ---------------------------------------------------------
                // GAP: Hold CS_N=1 until ESP32 reports checksum transaction ready.
                // GAP_CYCLES remains as a fallback timeout for old/disconnected wiring.
                // ---------------------------------------------------------
                S_GAP: begin
                    if (((gap_cnt >= MIN_GAP_CYCLES[16:0]) && ready_for_rx) ||
                        (gap_cnt == GAP_CYCLES[16:0] - 17'd1)) begin
                        // Begin checksum receive: assert CS_N, drive MOSI=0
                        cs_n    <= 1'b0;
                        mosi    <= 1'b0;
                        bit_cnt <= 3'd7;
                        sck_cnt <= 8'd0;
                        rx_shift<= 8'h00;
                        state   <= S_RX_BYTE;
                    end else begin
                        gap_cnt <= gap_cnt + 17'd1;
                    end
                end

                // ---------------------------------------------------------
                // RX_BYTE: Clock 8 dummy bits (MOSI=0), sample MISO on
                //          each SCK rising edge (Mode 0).
                // ---------------------------------------------------------
                S_RX_BYTE: begin
                    sck_cnt <= sck_cnt + 8'd1;
                    if (sck_cnt == SCK_HALF - 8'd1) begin
                        sck_cnt <= 8'd0;
                        if (!sck) begin
                            // Rising edge: sample MISO (ESP32 drives checksum)
                            sck      <= 1'b1;
                            rx_shift <= {rx_shift[6:0], miso};
                        end else begin
                            // Falling edge
                            sck <= 1'b0;
                            if (bit_cnt == 3'd0) begin
                                // All 8 bits received
                                state <= S_DONE;
                            end else begin
                                bit_cnt <= bit_cnt - 3'd1;
                            end
                        end
                    end
                end

                // ---------------------------------------------------------
                // DONE: Deassert CS_N, present received byte, pulse rx_valid.
                // ---------------------------------------------------------
                S_DONE: begin
                    cs_n     <= 1'b1;
                    sck      <= 1'b0;
                    rx_data  <= rx_shift;
                    rx_valid <= 1'b1;
                    state    <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
