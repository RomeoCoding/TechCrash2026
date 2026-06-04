// Speed Loopback Top Module — Dual-Channel SPI Edition
// FPGA generates 10,000 random bytes across TWO parallel SPI channels,
// 5,000 bytes per channel. Both channels operate simultaneously, cutting
// wall-time roughly in half vs single-channel: ~1.75 ms vs ~3.5 ms.
//
// Total speedup over 9600-baud UART baseline: ~6,000×.
//
// Protocol (per channel):
//   FPGA sends 4-byte header (per_channel LE = 5000) then 5000 LFSR bytes.
//   After CS_N deasserts, 300 µs gap, then FPGA clocks 1 dummy byte and
//   reads the channel's partial checksum on MISO.
//   FPGA compares (cs0 + cs1)[7:0] == sum[7:0].
//
// Channel 0 (ESP32 HSPI, IOMUX pins):
//   IO[2]=SCK, IO[3]=MOSI, IO[4]=MISO, IO[5]=CS_N
// Channel 1 (ESP32 VSPI, IOMUX pins):
//   IO[6]=SCK, IO[7]=MOSI, IO[8]=MISO, IO[9]=CS_N
//
// SW[9]   debug: in DONE show {cs0, cs1, expected} on HEX instead of timer
// KEY[0]  start / restart
// KEY[1]  reset (active low)
// HEX5-0  timer_ms (or debug checksums)
// LEDR[9] running, LEDR[0] pass, LEDR[1] fail

module speed_loopback_top(
    input         MAX10_CLK1_50,
    input  [1:0]  KEY,
    input  [9:0]  SW,
    output [9:0]  LEDR,
    output [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  [15:0] ARDUINO_IO
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n  = KEY[1];

    // ---- Edge detect KEY[0] (active-low button) ----
    reg key0_r, key0_rr;
    always @(posedge clk) begin
        key0_r  <= KEY[0];
        key0_rr <= key0_r;
    end
    wire start_pulse = key0_rr & ~key0_r;   // falling edge

    // ---- Data counts ----
    // 10,000 total bytes split evenly: 5,000 per channel
    wire [31:0] total_count = 32'd10_000;
    wire [31:0] per_channel = 32'd5_000;

    // ---- LFSR-16 (x^16 + x^15 + x^13 + x^4 + 1) ----
    reg  [15:0] lfsr;
    wire        lfsr_fb     = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];
    // One-step lookahead for ch1
    wire [15:0] lfsr_1      = {lfsr[14:0], lfsr_fb};
    wire        lfsr_1_fb   = lfsr_1[15] ^ lfsr_1[14] ^ lfsr_1[12] ^ lfsr_1[3];
    // Two-step lookahead: next state after both channels take a byte
    wire [15:0] lfsr_2      = {lfsr_1[14:0], lfsr_1_fb};

    // ---- Checksum accumulator ----
    reg [31:0] sum;

    // =========================================================================
    // Channel 0 — HSPI (ARDUINO_IO[2..5])
    // =========================================================================
    reg        tx0_start;
    reg  [7:0] tx0_data;
    wire       tx0_busy;
    wire [7:0] rx0_data;
    wire       rx0_valid;
    wire       spi0_sck, spi0_mosi, spi0_cs_n;

    // 1-flop MISO sync (2-flop would be 1 SPI cycle late at CLK_DIV=1)
    reg miso0_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) miso0_r <= 1'b1;
        else        miso0_r <= ARDUINO_IO[4];
    end

    spi_loopback_io #(
        .CLK_FREQ  (50_000_000),
        .CLK_DIV   (1),          // SCK = 25 MHz
        .GAP_CYCLES(15000)       // 300 µs gap for ESP32 to compute checksum
    ) u_spi0 (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_start (tx0_start),
        .tx_data  (tx0_data),
        .tx_busy  (tx0_busy),
        .rx_data  (rx0_data),
        .rx_valid (rx0_valid),
        .sck      (spi0_sck),
        .mosi     (spi0_mosi),
        .miso     (miso0_r),
        .cs_n     (spi0_cs_n)
    );

    // =========================================================================
    // Channel 1 — VSPI (ARDUINO_IO[6..9])
    // =========================================================================
    reg        tx1_start;
    reg  [7:0] tx1_data;
    wire       tx1_busy;
    wire [7:0] rx1_data;
    wire       rx1_valid;
    wire       spi1_sck, spi1_mosi, spi1_cs_n;

    reg miso1_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) miso1_r <= 1'b1;
        else        miso1_r <= ARDUINO_IO[8];
    end

    spi_loopback_io #(
        .CLK_FREQ  (50_000_000),
        .CLK_DIV   (1),
        .GAP_CYCLES(15000)
    ) u_spi1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .tx_start (tx1_start),
        .tx_data  (tx1_data),
        .tx_busy  (tx1_busy),
        .rx_data  (rx1_data),
        .rx_valid (rx1_valid),
        .sck      (spi1_sck),
        .mosi     (spi1_mosi),
        .miso     (miso1_r),
        .cs_n     (spi1_cs_n)
    );

    // ---- Arduino Header IO ----
    assign ARDUINO_IO[0]     = 1'bz;
    assign ARDUINO_IO[1]     = 1'bz;
    assign ARDUINO_IO[2]     = spi0_sck;    // ch0 SCK
    assign ARDUINO_IO[3]     = spi0_mosi;   // ch0 MOSI
    assign ARDUINO_IO[4]     = 1'bz;        // ch0 MISO (input)
    assign ARDUINO_IO[5]     = spi0_cs_n;   // ch0 CS_N
    assign ARDUINO_IO[6]     = spi1_sck;    // ch1 SCK
    assign ARDUINO_IO[7]     = spi1_mosi;   // ch1 MOSI
    assign ARDUINO_IO[8]     = 1'bz;        // ch1 MISO (input)
    assign ARDUINO_IO[9]     = spi1_cs_n;   // ch1 CS_N
    assign ARDUINO_IO[15:10] = {6{1'bz}};

    // ---- Millisecond timer ----
    reg [31:0] timer_ms;
    reg [15:0] timer_pre;
    reg        timer_running, timer_reset;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer_ms  <= 0;
            timer_pre <= 0;
        end else if (timer_reset) begin
            timer_ms  <= 0;
            timer_pre <= 0;
        end else if (timer_running) begin
            if (timer_pre == 16'd49_999) begin
                timer_pre <= 0;
                timer_ms  <= timer_ms + 1;
            end else
                timer_pre <= timer_pre + 1;
        end
    end

    // ---- State machine ----
    localparam S_IDLE = 3'd0,
               S_HDR  = 3'd1,
               S_DATA = 3'd2,
               S_WAIT = 3'd3,
               S_DONE = 3'd4;

    reg [2:0]  state;
    reg [31:0] send_count;         // total bytes sent (increments by 2 per step)
    reg [1:0]  hdr_idx;
    reg        pass;
    reg [7:0]  rx0_checksum, rx1_checksum;
    reg        got_rx0, got_rx1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            lfsr          <= 16'hACE1;
            sum           <= 0;
            send_count    <= 0;
            hdr_idx       <= 0;
            pass          <= 0;
            rx0_checksum  <= 0;
            rx1_checksum  <= 0;
            got_rx0       <= 0;
            got_rx1       <= 0;
            tx0_start     <= 0;
            tx1_start     <= 0;
            timer_running <= 0;
            timer_reset   <= 0;
        end else begin
            tx0_start   <= 0;       // default: one-cycle pulse
            tx1_start   <= 0;
            timer_reset <= 0;

            // ---- Start / Restart ----
            if (start_pulse && (state == S_IDLE || state == S_DONE)) begin
                state         <= S_HDR;
                lfsr          <= 16'hACE1;
                sum           <= 0;
                send_count    <= 0;
                hdr_idx       <= 0;
                pass          <= 0;
                got_rx0       <= 0;
                got_rx1       <= 0;
                timer_reset   <= 1;
                timer_running <= 1;
            end else begin
                case (state)
                    S_IDLE: ;   // wait for start_pulse

                    // Send 4-byte header (per_channel LE) to BOTH channels simultaneously.
                    // Both spi_loopback_io instances step in lockstep because tx_start
                    // is pulsed on the same clock cycle for both.
                    S_HDR: begin
                        if (!tx0_busy && !tx1_busy && !tx0_start && !tx1_start) begin
                            case (hdr_idx)
                                2'd0: begin tx0_data <= per_channel[7:0];   tx1_data <= per_channel[7:0];   end
                                2'd1: begin tx0_data <= per_channel[15:8];  tx1_data <= per_channel[15:8];  end
                                2'd2: begin tx0_data <= per_channel[23:16]; tx1_data <= per_channel[23:16]; end
                                2'd3: begin tx0_data <= per_channel[31:24]; tx1_data <= per_channel[31:24]; end
                            endcase
                            tx0_start <= 1;
                            tx1_start <= 1;
                            if (hdr_idx == 2'd3) state <= S_DATA;
                            hdr_idx <= hdr_idx + 1;
                        end
                    end

                    // Send 5,000 LFSR bytes to each channel simultaneously.
                    // Ch0 gets lfsr[7:0], ch1 gets lfsr_1[7:0] (next step).
                    // LFSR advances 2 steps per iteration; send_count += 2.
                    S_DATA: begin
                        if (!tx0_busy && !tx1_busy && !tx0_start && !tx1_start) begin
                            if (send_count < total_count) begin
                                tx0_data   <= lfsr[7:0];
                                tx1_data   <= lfsr_1[7:0];
                                tx0_start  <= 1;
                                tx1_start  <= 1;
                                sum        <= sum + {24'd0, lfsr[7:0]} + {24'd0, lfsr_1[7:0]};
                                lfsr       <= lfsr_2;
                                send_count <= send_count + 32'd2;
                            end else begin
                                state <= S_WAIT;
                            end
                        end
                    end

                    // spi_loopback_io handles the CS_N deassert, gap, and checksum
                    // read automatically. Wait for both rx_valid pulses.
                    S_WAIT: begin
                        if (rx0_valid) begin
                            rx0_checksum <= rx0_data;
                            got_rx0      <= 1;
                        end
                        if (rx1_valid) begin
                            rx1_checksum <= rx1_data;
                            got_rx1      <= 1;
                        end
                        // Both checksums latched one cycle after their rx_valid pulses
                        if (got_rx0 && got_rx1) begin
                            timer_running <= 0;
                            pass          <= ((rx0_checksum + rx1_checksum) == sum[7:0]);
                            state         <= S_DONE;
                        end
                    end

                    S_DONE: ;   // wait for start_pulse
                    default: state <= S_IDLE;
                endcase
            end
        end
    end

    // ---- Display mux ----
    reg [23:0] disp;
    always @(*) begin
        case (state)
            S_IDLE:  disp = total_count[23:0];
            S_HDR:   disp = 24'd0;
            S_DATA:  disp = send_count[23:0];
            S_WAIT:  disp = send_count[23:0];
            S_DONE:  disp = SW[9] ? {rx1_checksum, rx0_checksum, sum[7:0]}
                                  : timer_ms[23:0];
            default: disp = 24'd0;
        endcase
    end

    seven_segment seg0(.value(disp[3:0]),   .segments(HEX0));
    seven_segment seg1(.value(disp[7:4]),   .segments(HEX1));
    seven_segment seg2(.value(disp[11:8]),  .segments(HEX2));
    seven_segment seg3(.value(disp[15:12]), .segments(HEX3));
    seven_segment seg4(.value(disp[19:16]), .segments(HEX4));
    seven_segment seg5(.value(disp[23:20]), .segments(HEX5));

    // ---- LEDs ----
    assign LEDR[9]   = timer_running;
    assign LEDR[8]   = (state == S_DONE);
    assign LEDR[7:2] = 6'd0;
    assign LEDR[1]   = (state == S_DONE) & ~pass;
    assign LEDR[0]   = (state == S_DONE) &  pass;

endmodule
