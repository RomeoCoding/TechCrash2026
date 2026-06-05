// =============================================================================
// spi_master.v  —  SPI Mode 0 (CPOL=0, CPHA=0) Master
// Drop-in replacement for uart_tx + uart_rx in speed_loopback_top.sv
// =============================================================================
//
// TARGET SCK FREQUENCY:
//   Formula: SCK = CLK_FREQ / (2 * (CLK_DIV + 1))
//     The +1 accounts for the one cycle consumed by S_SEND_BYTE per half-period;
//     S_WAIT_CLK adds (CLK_DIV) extra cycles, giving total half-period = CLK_DIV+1.
//
//   50 MHz system clock   CLK_DIV=1  ->  12.5 MHz SCK  [safe default]
//                         CLK_DIV=2  ->   8.33 MHz SCK  [conservative bringup]
//   100 MHz system clock  CLK_DIV=1  ->  25.0 MHz SCK  [via PLL — competition target]
//                         CLK_DIV=2  ->  16.7 MHz SCK
//
//   Note: 25 MHz requires a PLL outputting 100 MHz.  The Quartus PLL wizard
//   (IP Catalog → ALTPLL) generates this in < 2 minutes for MAX 10.
//
// ─── How to wire into speed_loopback_top.sv (NO top-level changes needed) ────
//
//   Replace the uart_tx + uart_rx instantiations with:
//
//     spi_master #(.CLK_DIV(1), .GAP_CYCLES(5000), .MIN_GAP(500)) u_spi (
//         .clk(clk),              .rst_n(rst_n),
//         // TX — same signals the top-level already drives
//         .tx_start(tx_start),    .tx_data(tx_data),     .tx_busy(tx_busy),
//         // RX — same signals the top-level S_WAIT state already reads
//         .rx_data(rx_data),      .rx_valid(rx_valid),
//         // SPI pins wired to DE10-Lite Arduino header (matches main.cpp)
//         .sck (sck_wire),        // → ARDUINO_IO[13] → ESP32 GPIO18 (VSPI CLK)
//         .mosi(mosi_wire),       // → ARDUINO_IO[11] → ESP32 GPIO23 (VSPI MOSI)
//         .miso(ARDUINO_IO[12]),  // ← ARDUINO_IO[12] ← ESP32 GPIO19 (VSPI MISO)
//         .cs_n(cs_n_wire),       // → ARDUINO_IO[10] → ESP32 GPIO5  (VSPI CS)
//         // Handshake from ESP32 GPIO4; tie 1'b0 if not wired (uses GAP_CYCLES fallback)
//         .ready_for_rx(ARDUINO_IO[2])  // ← ESP32 GPIO4
//     );
//
//   Also add/replace ARDUINO_IO assignments in top.sv:
//     wire sck_wire, mosi_wire, cs_n_wire;
//     assign ARDUINO_IO[13] = sck_wire;    // SCK  output
//     assign ARDUINO_IO[11] = mosi_wire;   // MOSI output
//     assign ARDUINO_IO[10] = cs_n_wire;   // CS_N output
//     assign ARDUINO_IO[12] = 1'bz;        // MISO input
//     assign ARDUINO_IO[2]  = 1'bz;        // ready_for_rx input
//     assign ARDUINO_IO[15:14] = 2'bzz;
//     assign ARDUINO_IO[9:3]   = 7'bzzzzzzz;
//     assign ARDUINO_IO[1:0]   = 2'bzz;
//
// ─── State machine overview ───────────────────────────────────────────────────
//
//  IDLE  ──(tx_start)──>  WAIT_CLK  ──(half-period)──>  SEND_BYTE
//                                                            │
//                          <──(half-period)──  WAIT_CLK  <──┤  (mid-byte)
//                                                            │
//                                             NEXT_BYTE  <──┘  (byte done)
//                                                 │
//                       ┌─────────────────────────┤
//                       │ TX: more bytes?          │ TX: no more bytes
//                       │    load next → WAIT_CLK  │    → RECEIVE_CHECKSUM
//                       │ RX: latch + rx_valid     │
//                       └────────────> IDLE        │
//                                                  ▼
//                                        RECEIVE_CHECKSUM
//                                        (CS_N=1 gap, then CS_N=0 + rx_mode=1
//                                         → WAIT_CLK → SEND_BYTE to clock MISO)
//
// =============================================================================

module spi_master #(
    // SCK = CLK_FREQ / (2 * (CLK_DIV + 1)).
    // CLK_DIV=1 @ 50 MHz → 12.5 MHz.  CLK_DIV=1 @ 100 MHz (PLL) → 25 MHz.
    parameter CLK_DIV    = 1,

    // Hard fallback: maximum CS_N-high cycles before forcing RX phase start,
    // used when ready_for_rx is not wired or never asserts.
    // ESP32 needs ~50 µs total after CS_N deasserts:
    //   interrupt detection  ~5 µs
    //   checksum (IRAM)     ~40 µs
    //   spi_slave_queue_trans ~5 µs
    // 5000 cycles @ 50 MHz = 100 µs — safe margin with or without PLL.
    // Do NOT reduce below 2500 (50 µs); the checksum will not be ready.
    parameter GAP_CYCLES = 5000,

    // Minimum CS_N-high cycles before ready_for_rx is honoured.
    // 500 cycles @ 50 MHz = 10 µs — long enough to debounce GPIO glitches
    // that can appear on the ready_for_rx line when CS_N transitions.
    parameter MIN_GAP    = 500
)(
    input  wire       clk,
    input  wire       rst_n,     // Active-low asynchronous reset

    // -------------------------------------------------------------------------
    // TX interface  —  identical to uart_tx in speed_loopback_top.sv.
    // The top-level S_HDR and S_DATA states already guard sends with:
    //     if (!tx_busy && !tx_start) begin ... tx_start <= 1; ... end
    // No top-level changes required.
    // -------------------------------------------------------------------------
    input  wire       tx_start,  // 1-cycle pulse; tx_data valid this cycle
    input  wire [7:0] tx_data,   // Byte to transmit
    output reg        tx_busy,   // High from byte-start until byte-complete

    // -------------------------------------------------------------------------
    // RX interface  —  identical to uart_rx in speed_loopback_top.sv.
    // The top-level S_WAIT state already handles:
    //     if (rx_valid) begin rx_checksum <= rx_data; pass <= (rx_data == sum[7:0]); end
    // No top-level changes required.
    // -------------------------------------------------------------------------
    output reg  [7:0] rx_data,   // Received checksum byte
    output reg        rx_valid,  // 1-cycle pulse when rx_data is valid

    // -------------------------------------------------------------------------
    // SPI physical pins
    // -------------------------------------------------------------------------
    output reg        sck,       // SPI clock (idle LOW for Mode 0)
    output reg        mosi,      // Master Out Slave In
    input  wire       miso,      // Master In Slave Out  (checksum byte from ESP32)
    output reg        cs_n,      // Chip Select, active-low

    // -------------------------------------------------------------------------
    // Optional handshake from ESP32.
    // Assert high when the ESP32 has finished computing the checksum and loaded
    // it into its SPI TX shift register, allowing an early exit from the gap.
    // Tie to 1'b0 if not wired; GAP_CYCLES fallback applies automatically.
    // -------------------------------------------------------------------------
    input  wire       ready_for_rx
);

    // =========================================================================
    // Derived constant — kept as a localparam so synthesis sees a literal.
    // Width is 8 bits, supporting CLK_DIV from 1 (25 MHz) up to 255 (~98 kHz).
    // =========================================================================
    localparam [7:0] SCK_HALF = CLK_DIV;

    // =========================================================================
    // State encoding — names exactly as specified
    // =========================================================================
    localparam [2:0]
        S_IDLE             = 3'd0,
        S_SEND_BYTE        = 3'd1,
        S_WAIT_CLK         = 3'd2,
        S_NEXT_BYTE        = 3'd3,
        S_RECEIVE_CHECKSUM = 3'd4;

    reg [2:0] state;

    // =========================================================================
    // Internal registers
    // =========================================================================

    // TX shift register — loaded with tx_data, shifted left MSB-first each
    // falling SCK edge.  shift_reg[7] is always the bit currently on MOSI.
    reg [7:0] shift_reg;

    // RX shift register — built MSB-first by OR-ing MISO on each SCK rising
    // edge: rx_shift <= {rx_shift[6:0], miso}.  Latched into rx_data at end.
    reg [7:0] rx_shift;

    // Bit counter: 7 (first/MSB) down to 0 (last/LSB).
    reg [2:0] bit_cnt;

    // Half-period counter: counts 0 .. SCK_HALF-1 in S_WAIT_CLK.
    reg [7:0] sck_cnt;

    // SCK phase flag:
    //   0 = currently in the LOW half  → next edge transition = RISE
    //   1 = currently in the HIGH half → next edge transition = FALL
    reg sck_phase;

    // Mode flag shared across S_SEND_BYTE / S_NEXT_BYTE:
    //   0 = TX burst (serialising tx_data bytes via MOSI)
    //   1 = RX phase (sampling checksum byte via MISO)
    reg rx_mode;

    // Idle-cycle counter in S_NEXT_BYTE (TX path).
    // Gives the top-level registered state machine time to react to tx_busy
    // falling and assert tx_start for the next byte.  5 cycles of patience
    // covers the two-cycle pipeline delay of a registered FSM at any frequency.
    reg [2:0] idle_cnt;

    // CS_N-high gap counter in S_RECEIVE_CHECKSUM.
    // 18 bits supports GAP_CYCLES up to 262143 (~5 ms @ 50 MHz).
    reg [17:0] gap_cnt;


    // =========================================================================
    // Main FSM
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cs_n      <= 1'b1;
            sck       <= 1'b0;
            mosi      <= 1'b0;
            tx_busy   <= 1'b0;
            rx_valid  <= 1'b0;
            rx_data   <= 8'h00;
            sck_cnt   <= 8'd0;
            gap_cnt   <= 18'd0;
            idle_cnt  <= 3'd0;
            bit_cnt   <= 3'd7;
            sck_phase <= 1'b0;
            rx_mode   <= 1'b0;
            shift_reg <= 8'h00;
            rx_shift  <= 8'h00;
        end else begin
            rx_valid <= 1'b0;   // rx_valid is a one-cycle pulse; clear every cycle

            case (state)

                // =============================================================
                // IDLE
                // CS_N=1, SCK=0, all outputs quiet.
                //
                // Waits for tx_start from the top-level's S_HDR state (4-byte
                // header: N=10000 little-endian) or S_DATA state (10000 LFSR
                // data bytes).  Both use the same tx_start/tx_data mechanism.
                //
                // On tx_start:
                //   1. Load the first byte into shift_reg.
                //   2. Pre-drive MOSI with the MSB BEFORE asserting CS_N or
                //      toggling SCK — SPI Mode 0 requires data valid before
                //      the first rising edge.
                //   3. Assert CS_N (active-low), set tx_busy, begin timing
                //      the first SCK LOW half-period in S_WAIT_CLK.
                // =============================================================
                S_IDLE: begin
                    cs_n     <= 1'b1;
                    sck      <= 1'b0;
                    tx_busy  <= 1'b0;
                    rx_mode  <= 1'b0;

                    if (tx_start) begin
                        shift_reg <= tx_data;
                        mosi      <= tx_data[7];  // pre-drive MSB (Mode 0 requirement)
                        cs_n      <= 1'b0;
                        tx_busy   <= 1'b1;
                        bit_cnt   <= 3'd7;
                        sck_cnt   <= 8'd0;
                        sck_phase <= 1'b0;        // LOW half comes first
                        state     <= S_WAIT_CLK;
                    end
                end

                // =============================================================
                // WAIT_CLK
                // Counts one SCK half-period (SCK_HALF system clock cycles)
                // before transitioning to S_SEND_BYTE to toggle the SCK edge.
                //
                // Entered from:
                //   IDLE / NEXT_BYTE   — to time the LOW half before the first
                //                        rising edge of a new byte.
                //   SEND_BYTE          — immediately after each edge toggle, to
                //                        time the opposite half-period.
                //
                // With CLK_DIV=1, SCK_HALF=1: this state lasts exactly ONE
                // system clock cycle before proceeding to SEND_BYTE.
                // With CLK_DIV=2, SCK_HALF=2: two system cycles per half, etc.
                // =============================================================
                S_WAIT_CLK: begin
                    if (sck_cnt == SCK_HALF - 8'd1) begin
                        sck_cnt <= 8'd0;
                        state   <= S_SEND_BYTE;
                    end else begin
                        sck_cnt <= sck_cnt + 8'd1;
                    end
                end

                // =============================================================
                // SEND_BYTE
                // Performs one SCK edge transition (rising or falling) and
                // handles all bit-level serialisation / deserialisation.
                //
                // ── Rising edge  (sck_phase was 0, now becomes 1) ────────────
                //   Assert SCK high.
                //   If in RX mode: capture MISO into rx_shift MSB-first.
                //     rx_shift <= {rx_shift[6:0], miso}
                //   Return to S_WAIT_CLK to count the HIGH half-period.
                //
                // ── Falling edge (sck_phase was 1, now becomes 0) ────────────
                //   De-assert SCK low.
                //   If last bit (bit_cnt==0): byte complete → S_NEXT_BYTE.
                //   Else: advance to next bit (MSB-first):
                //     shift_reg <= {shift_reg[6:0], 1'b0}  (shift left)
                //     mosi      <= shift_reg[6]             (next bit, read BEFORE shift)
                //     bit_cnt   <= bit_cnt - 1
                //   Return to S_WAIT_CLK for the LOW half-period of the next bit.
                //
                // Non-blocking assignment note: because all RHS expressions are
                // evaluated using the register values BEFORE the clock edge,
                // `shift_reg[6]` here reads the current pre-shift value, which
                // is the correct next bit to drive onto MOSI.
                // =============================================================
                S_SEND_BYTE: begin
                    sck_phase <= ~sck_phase;

                    if (!sck_phase) begin
                        // ── Rising edge ───────────────────────────────────
                        sck <= 1'b1;
                        if (rx_mode) begin
                            // ESP32 drives its checksum onto MISO before SCK
                            // rises (also Mode 0). Capture MSB first.
                            rx_shift <= {rx_shift[6:0], miso};
                        end
                        sck_cnt <= 8'd0;
                        state   <= S_WAIT_CLK;  // count HIGH half before falling edge

                    end else begin
                        // ── Falling edge ──────────────────────────────────
                        sck <= 1'b0;

                        if (bit_cnt == 3'd0) begin
                            // All 8 bits clocked — byte is complete
                            state <= S_NEXT_BYTE;
                        end else begin
                            // Drive next bit onto MOSI before the next rise
                            shift_reg <= {shift_reg[6:0], 1'b0};
                            mosi      <= shift_reg[6]; // next bit (pre-shift value)
                            bit_cnt   <= bit_cnt - 3'd1;
                            sck_cnt   <= 8'd0;
                            state     <= S_WAIT_CLK;
                        end
                    end
                end

                // =============================================================
                // NEXT_BYTE
                // Called once after every complete 8-bit transfer.
                //
                // ── TX mode (rx_mode=0) ───────────────────────────────────────
                // De-assert tx_busy for one or more cycles so the top-level FSM
                // (which is also registered) can react and pulse tx_start.
                //
                // Pipeline timing at 50 MHz / CLK_DIV=1:
                //   Cycle 0  : Enter NEXT_BYTE. tx_busy scheduled to 0.
                //   Cycle 1  : tx_busy=0 visible externally. Top-level sees
                //              (!tx_busy && !tx_start) and schedules tx_start=1.
                //   Cycle 2  : tx_start=1 visible here. Load next byte.
                //
                // idle_cnt counts up to 5 to tolerate any top-level latency.
                // If tx_start never arrives (all bytes sent), the top-level
                // has moved to S_WAIT; we detect the timeout and proceed to
                // S_RECEIVE_CHECKSUM.
                //
                // ── RX mode (rx_mode=1) ──────────────────────────────────────
                // rx_shift holds the complete checksum byte. Deassert CS_N,
                // latch rx_data, pulse rx_valid for one cycle.
                // Top-level S_WAIT catches: if (rx_valid) { compare rx_data }
                // → IDLE.
                // =============================================================
                S_NEXT_BYTE: begin
                    if (rx_mode) begin
                        // ── Checksum byte fully received ──────────────────
                        cs_n     <= 1'b1;
                        sck      <= 1'b0;
                        rx_data  <= rx_shift;
                        rx_valid <= 1'b1;   // top-level S_WAIT polls this
                        state    <= S_IDLE;

                    end else begin
                        // ── TX byte done: wait for top-level to supply next ──
                        tx_busy <= 1'b0;

                        if (tx_start) begin
                            // Next byte ready: load and continue TX burst.
                            // CS_N stays asserted — no gap between data bytes.
                            shift_reg <= tx_data;
                            mosi      <= tx_data[7]; // pre-drive MSB
                            bit_cnt   <= 3'd7;
                            sck_cnt   <= 8'd0;
                            sck_phase <= 1'b0;
                            tx_busy   <= 1'b1;
                            idle_cnt  <= 3'd0;
                            state     <= S_WAIT_CLK;

                        end else if (idle_cnt == 3'd5) begin
                            // 5 idle cycles with no tx_start: all 10,000+
                            // header bytes sent. Deassert CS_N and proceed
                            // to receive the checksum from the ESP32.
                            cs_n     <= 1'b1;
                            sck      <= 1'b0;
                            mosi     <= 1'b0;
                            gap_cnt  <= 18'd0;
                            idle_cnt <= 3'd0;
                            state    <= S_RECEIVE_CHECKSUM;

                        end else begin
                            idle_cnt <= idle_cnt + 3'd1;
                        end
                    end
                end

                // =============================================================
                // RECEIVE_CHECKSUM
                // Two sub-phases controlled by the gap_cnt counter:
                //
                // ── Phase 1: CS_N=1 gap ───────────────────────────────────────
                // Hold CS_N high for at least MIN_GAP cycles, then:
                //   • Early exit if ready_for_rx is asserted (ESP32 handshake).
                //   • Hard timeout after GAP_CYCLES (fallback if not wired).
                // This gives the ESP32 time to compute sum[7:0] over 10,000
                // bytes and load it into its SPI TX shift register.
                //
                // ── Phase 2: Start RX ─────────────────────────────────────────
                // Assert CS_N, drive MOSI=0 (dummy — we only care about MISO),
                // set rx_mode=1 so S_SEND_BYTE samples MISO on rising edges,
                // reset rx_shift, configure bit_cnt=7, hand off to S_WAIT_CLK.
                // S_SEND_BYTE × 8 bits → S_NEXT_BYTE (rx_mode=1) → latch + done.
                //
                // HOW IT HOOKS IN:
                //   After the last LFSR byte, the top-level S_DATA transitions
                //   to S_WAIT (no tx_start pulse). S_NEXT_BYTE times out here.
                //   When rx_valid fires, S_WAIT compares rx_data to sum[7:0]
                //   and sets pass/fail — no changes needed to that logic.
                // =============================================================
                S_RECEIVE_CHECKSUM: begin
                    // Exit gap when: (MIN_GAP elapsed AND ESP32 says ready)
                    //            OR  hard timeout (GAP_CYCLES elapsed)
                    if ((gap_cnt >= MIN_GAP && ready_for_rx) ||
                        (gap_cnt == GAP_CYCLES - 1)) begin

                        // Begin clocking the checksum byte in from MISO
                        cs_n      <= 1'b0;
                        mosi      <= 1'b0;   // dummy output during RX
                        bit_cnt   <= 3'd7;
                        sck_cnt   <= 8'd0;
                        sck_phase <= 1'b0;
                        rx_shift  <= 8'h00;
                        rx_mode   <= 1'b1;
                        state     <= S_WAIT_CLK;

                    end else begin
                        gap_cnt <= gap_cnt + 18'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
