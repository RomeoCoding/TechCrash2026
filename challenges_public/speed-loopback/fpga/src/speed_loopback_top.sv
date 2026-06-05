// Speed Loopback Top — Single UART @ 115200 baud
// Minimal solution that clears the 4x bar (target < 2,600 ms).
//
// Protocol (matches the challenge spec):
//   FPGA sends 4-byte header: N = 10,000 as 32-bit little-endian (0x00002710)
//   FPGA sends N pseudo-random LFSR bytes
//   ESP32 computes sum = (b0 + b1 + ... + b9999) & 0xFF
//   ESP32 sends back 1 byte: the checksum
//   FPGA stops the timer and compares against its own sum[7:0]
//
// Expected wall time at 115200 baud 8N1: ~870 ms (~12x baseline). PASS.
//
// Wiring (DE10-Lite Arduino header <-> ESP32, standard kit pinout):
//   ARDUINO_IO[1]  FPGA TX  -> ESP32 GPIO17 (UART2 RX)
//   ARDUINO_IO[0]  FPGA RX  <- ESP32 GPIO16 (UART2 TX)
//   GND            common ground
//
// Controls:
//   KEY[0]  start / restart (falling edge)
//   KEY[1]  reset (active low)
//   SW[9]   debug: in DONE show {rx_checksum, sum[7:0]} instead of timer
//   HEX5-0  timer_ms (or debug checksums)
//   LEDR[9] running, LEDR[0] pass, LEDR[1] fail

module speed_loopback_top(
    input         MAX10_CLK1_50,
    input  [1:0]  KEY,
    input  [9:0]  SW,
    output [9:0]  LEDR,
    output [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  [15:0] ARDUINO_IO
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n = KEY[1];

    localparam CLK_FREQ = 50_000_000;
    localparam BAUD     = 115_200;

    // ---- Edge detect KEY[0] (active-low button) ----
    reg key0_r, key0_rr;
    always @(posedge clk) begin
        key0_r  <= KEY[0];
        key0_rr <= key0_r;
    end
    wire start_pulse = key0_rr & ~key0_r;   // falling edge

    // ---- Data count (fixed infrastructure: 10,000 bytes) ----
    wire [31:0] total_count = 32'd10_000;

    // ---- LFSR-16 (x^16 + x^15 + x^13 + x^4 + 1) ----
    reg  [15:0] lfsr;
    wire        lfsr_fb   = lfsr[15] ^ lfsr[14] ^ lfsr[12] ^ lfsr[3];
    wire [15:0] lfsr_next = {lfsr[14:0], lfsr_fb};

    // ---- Checksum accumulator ----
    reg [31:0] sum;

    // ---- UART TX ----
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_busy;
    wire       tx_out;

    uart_tx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .tx_start(tx_start), .tx_data(tx_data),
        .tx_busy(tx_busy), .tx_out(tx_out)
    );

    // ---- UART RX ----
    wire [7:0] rx_data;
    wire       rx_valid;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .rx_in(ARDUINO_IO[0]),
        .rx_data(rx_data), .rx_valid(rx_valid)
    );

    // ---- Arduino header IO ----
    assign ARDUINO_IO[1]     = tx_out;     // FPGA TX -> ESP32 RX
    assign ARDUINO_IO[0]     = 1'bz;       // FPGA RX <- ESP32 TX (input)
    assign ARDUINO_IO[15:2]  = {14{1'bz}};

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
    reg [31:0] send_count;
    reg [1:0]  hdr_idx;
    reg        pass;
    reg [7:0]  rx_checksum;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            lfsr          <= 16'hACE1;
            sum           <= 0;
            send_count    <= 0;
            hdr_idx       <= 0;
            pass          <= 0;
            rx_checksum   <= 0;
            tx_start      <= 0;
            timer_running <= 0;
            timer_reset   <= 0;
        end else begin
            tx_start    <= 0;       // default: one-cycle pulse
            timer_reset <= 0;

            // ---- Start / Restart ----
            if (start_pulse && (state == S_IDLE || state == S_DONE)) begin
                state         <= S_HDR;
                lfsr          <= 16'hACE1;
                sum           <= 0;
                send_count    <= 0;
                hdr_idx       <= 0;
                pass          <= 0;
                timer_reset   <= 1;
                timer_running <= 1;
            end else begin
                case (state)
                    S_IDLE: ;   // wait for start_pulse

                    // Send 4-byte header: N (10000) little-endian.
                    S_HDR: begin
                        if (!tx_busy && !tx_start) begin
                            case (hdr_idx)
                                2'd0: tx_data <= total_count[7:0];
                                2'd1: tx_data <= total_count[15:8];
                                2'd2: tx_data <= total_count[23:16];
                                2'd3: tx_data <= total_count[31:24];
                            endcase
                            tx_start <= 1;
                            if (hdr_idx == 2'd3) state <= S_DATA;
                            hdr_idx <= hdr_idx + 1;
                        end
                    end

                    // Send 10,000 LFSR bytes, accumulating checksum.
                    S_DATA: begin
                        if (!tx_busy && !tx_start) begin
                            if (send_count < total_count) begin
                                tx_data    <= lfsr[7:0];
                                tx_start   <= 1;
                                sum        <= sum + {24'd0, lfsr[7:0]};
                                lfsr       <= lfsr_next;
                                send_count <= send_count + 32'd1;
                            end else begin
                                state <= S_WAIT;
                            end
                        end
                    end

                    // Wait for the 1-byte checksum reply.
                    S_WAIT: begin
                        if (rx_valid) begin
                            rx_checksum   <= rx_data;
                            timer_running <= 0;
                            pass          <= (rx_data == sum[7:0]);
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
            S_DONE:  disp = SW[9] ? {8'd0, rx_checksum, sum[7:0]}
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
