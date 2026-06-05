// SPI Master — Mode 3 (CPOL=1, CPHA=1): clock idles high, data shifted on
// falling edge, sampled on rising edge.  MSB first.
// Transfers: 1 command byte + 0..6 data bytes in a single CS-asserted burst.

module spi_master #(
    parameter CLK_FREQ     = 50_000_000,
    parameter SPI_CLK_FREQ = 1_000_000   // ≤ 5 MHz for ADXL345 4-wire SPI
)(
    input              clk,
    input              rst_n,

    // Transaction interface — hold cmd_byte / tx_data / data_bytes stable
    // for the entire transfer (they are sampled continuously during S_XFER).
    input      [7:0]   cmd_byte,    // address/command byte (sent first)
    input      [47:0]  tx_data,     // data bytes 0-5: tx_data[7:0] first
    input      [2:0]   data_bytes,  // number of payload bytes after cmd (0-6)
    input              start,       // 1-cycle pulse to begin
    output reg         busy,
    output reg         done,        // 1-cycle pulse when CS deasserted
    output reg [47:0]  rx_data,     // captured payload bytes, same packing

    // SPI pins
    output reg         sclk,
    output reg         mosi,
    input              miso,
    output reg         cs_n
);

    // HALF_PERIOD = half the SPI clock period in system clock ticks
    localparam HALF_PERIOD = CLK_FREQ / (2 * SPI_CLK_FREQ);  // 25 @ 50 MHz / 1 MHz

    localparam S_IDLE = 2'd0;
    localparam S_XFER = 2'd1;
    localparam S_END  = 2'd2;

    reg [1:0]  state;
    reg [15:0] cnt;          // half-period down-counter
    reg [2:0]  bit_idx;      // current bit position within byte (7 = MSB)
    reg [3:0]  byte_idx;     // 0 = cmd byte, 1..total_bytes-1 = data bytes
    reg [3:0]  total_bytes;  // byte_idx ceiling = data_bytes + 1
    reg [7:0]  tx_shift;     // shift register for outgoing bits
    reg [7:0]  rx_shift;     // shift register for incoming bits

    // Select which byte to load into tx_shift when advancing to the next byte.
    // byte_idx is the OLD (pre-increment) value when this is used.
    // byte_idx 0 done → load tx_data[7:0], byte_idx 1 done → tx_data[15:8], …
    function automatic [7:0] next_tx_byte;
        input [3:0] idx;   // old byte_idx (0 = just finished cmd)
        input [47:0] d;
        case (idx)
            4'd0: next_tx_byte = d[7:0];
            4'd1: next_tx_byte = d[15:8];
            4'd2: next_tx_byte = d[23:16];
            4'd3: next_tx_byte = d[31:24];
            4'd4: next_tx_byte = d[39:32];
            4'd5: next_tx_byte = d[47:40];
            default: next_tx_byte = 8'h00;
        endcase
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            sclk        <= 1'b1;
            mosi        <= 1'b0;
            cs_n        <= 1'b1;
            busy        <= 1'b0;
            done        <= 1'b0;
            cnt         <= 0;
            bit_idx     <= 7;
            byte_idx    <= 0;
            total_bytes <= 0;
            rx_data     <= 0;
            rx_shift    <= 0;
            tx_shift    <= 0;
        end else begin
            done <= 1'b0;   // default: one-cycle pulse only

            case (state)

                // ── Idle: wait for start pulse ───────────────────────────
                S_IDLE: begin
                    sclk <= 1'b1;
                    cs_n <= 1'b1;
                    if (start && !busy) begin
                        busy        <= 1'b1;
                        cs_n        <= 1'b0;              // assert CS
                        tx_shift    <= cmd_byte;          // first byte to send
                        byte_idx    <= 0;
                        bit_idx     <= 7;
                        total_bytes <= {1'b0, data_bytes} + 4'd1;
                        cnt         <= HALF_PERIOD - 1;
                        state       <= S_XFER;
                    end
                end

                // ── Transfer: toggle SCLK, drive / sample bits ───────────
                S_XFER: begin
                    if (cnt == 0) begin
                        cnt <= HALF_PERIOD - 1;

                        if (sclk) begin
                            // ─ Falling edge: drive MOSI with next bit ────
                            sclk     <= 1'b0;
                            mosi     <= tx_shift[7];
                            tx_shift <= {tx_shift[6:0], 1'b0};

                        end else begin
                            // ─ Rising edge: sample MISO ──────────────────
                            sclk <= 1'b1;

                            if (bit_idx == 0) begin
                                // Byte complete — store received byte (skip cmd byte)
                                if (byte_idx > 0)
                                    rx_data[((byte_idx - 1) * 8) +: 8] <=
                                        {rx_shift[6:0], miso};

                                if (byte_idx == total_bytes - 1) begin
                                    // All bytes done — hold then deassert CS
                                    cnt   <= HALF_PERIOD - 1;
                                    state <= S_END;
                                end else begin
                                    // Load next byte and continue
                                    tx_shift <= next_tx_byte(byte_idx, tx_data);
                                    byte_idx <= byte_idx + 1;
                                    bit_idx  <= 7;
                                end

                            end else begin
                                rx_shift <= {rx_shift[6:0], miso};
                                bit_idx  <= bit_idx - 1;
                            end
                        end

                    end else begin
                        cnt <= cnt - 1;
                    end
                end

                // ── End: deassert CS after hold time ────────────────────
                S_END: begin
                    if (cnt == 0) begin
                        cs_n  <= 1'b1;
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        cnt <= cnt - 1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
