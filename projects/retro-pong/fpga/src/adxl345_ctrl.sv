// ADXL345 Accelerometer Controller
// Performs power-on initialisation via SPI, then reads X/Y/Z at SAMPLE_HZ.
// Output: signed 16-bit raw values + 1-cycle data_valid pulse.
//
// ADXL345 register map used:
//   0x2C  BW_RATE       → 0x0A  (100 Hz output data rate)
//   0x2D  POWER_CTL     → 0x08  (measurement mode)
//   0x31  DATA_FORMAT   → 0x0B  (±16 g full-resolution, right-justify)
//   0x32..0x37          DATAX0..DATAZ1 (burst-read 6 bytes)
//
// SPI command byte encoding (ADXL345 spec §SPI):
//   bit 7 : R/W    (1 = read, 0 = write)
//   bit 6 : MB     (1 = multi-byte)
//   bit 5:0: register address

module adxl345_ctrl #(
    parameter CLK_FREQ  = 50_000_000,
    parameter SAMPLE_HZ = 50         // sensor polling rate (≤ 100)
)(
    input              clk,
    input              rst_n,

    output reg signed [15:0] accel_x,   // raw 16-bit signed (3.9 mg/LSB @ ±16 g)
    output reg signed [15:0] accel_y,
    output reg signed [15:0] accel_z,
    output reg               data_valid, // 1-cycle pulse when new XYZ available

    // SPI pins — connect directly to DE10-Lite GSENSOR_* top-level ports
    output        sclk,
    output        mosi,
    input         miso,
    output        cs_n
);

    // ── SPI master instance ─────────────────────────────────────────────────
    reg  [7:0]  spi_cmd;
    reg  [47:0] spi_tx;
    reg  [2:0]  spi_n;
    reg         spi_start;
    wire        spi_busy;
    wire        spi_done;
    wire [47:0] spi_rx;

    spi_master #(
        .CLK_FREQ    (CLK_FREQ),
        .SPI_CLK_FREQ(1_000_000)
    ) u_spi (
        .clk       (clk),
        .rst_n     (rst_n),
        .cmd_byte  (spi_cmd),
        .tx_data   (spi_tx),
        .data_bytes(spi_n),
        .start     (spi_start),
        .busy      (spi_busy),
        .done      (spi_done),
        .rx_data   (spi_rx),
        .sclk      (sclk),
        .mosi      (mosi),
        .miso      (miso),
        .cs_n      (cs_n)
    );

    // ── State machine ───────────────────────────────────────────────────────
    localparam STARTUP        = 4'd0;
    localparam INIT_0_START   = 4'd1;   // standby (POWER_CTL = 0x00)
    localparam INIT_0_WAIT    = 4'd2;
    localparam INIT_1_START   = 4'd3;   // DATA_FORMAT = 0x0B
    localparam INIT_1_WAIT    = 4'd4;
    localparam INIT_2_START   = 4'd5;   // BW_RATE = 0x0A (100 Hz)
    localparam INIT_2_WAIT    = 4'd6;
    localparam INIT_3_START   = 4'd7;   // measure (POWER_CTL = 0x08)
    localparam INIT_3_WAIT    = 4'd8;
    localparam SAMPLE_WAIT    = 4'd9;
    localparam READ_START     = 4'd10;
    localparam READ_WAIT      = 4'd11;

    // 10 ms startup delay to let ADXL345 boot before first SPI transaction
    localparam STARTUP_CYCLES = CLK_FREQ / 100;          // 500 000 @ 50 MHz
    localparam SAMPLE_CYCLES  = CLK_FREQ / SAMPLE_HZ;    // 1 000 000 @ 50 Hz

    reg [3:0]  state;
    reg [31:0] delay_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= STARTUP;
            delay_cnt  <= STARTUP_CYCLES - 1;
            spi_start  <= 1'b0;
            spi_cmd    <= 8'h00;
            spi_tx     <= 48'd0;
            spi_n      <= 3'd0;
            data_valid <= 1'b0;
            accel_x    <= 16'd0;
            accel_y    <= 16'd0;
            accel_z    <= 16'd0;
        end else begin
            spi_start  <= 1'b0;
            data_valid <= 1'b0;

            case (state)

                // ── Wait ≥ 10 ms after reset before touching SPI ──────────
                STARTUP: begin
                    if (delay_cnt == 0)
                        state <= INIT_0_START;
                    else
                        delay_cnt <= delay_cnt - 1;
                end

                // ── Write POWER_CTL = 0x00 (standby / reset defaults) ────
                INIT_0_START: begin
                    spi_cmd   <= 8'h2D;          // addr 0x2D, write
                    spi_tx    <= {40'd0, 8'h00};
                    spi_n     <= 3'd1;
                    spi_start <= 1'b1;
                    state     <= INIT_0_WAIT;
                end
                INIT_0_WAIT: if (spi_done) state <= INIT_1_START;

                // ── Write DATA_FORMAT = 0x0B (±16 g, full-resolution) ────
                INIT_1_START: begin
                    spi_cmd   <= 8'h31;
                    spi_tx    <= {40'd0, 8'h0B};
                    spi_n     <= 3'd1;
                    spi_start <= 1'b1;
                    state     <= INIT_1_WAIT;
                end
                INIT_1_WAIT: if (spi_done) state <= INIT_2_START;

                // ── Write BW_RATE = 0x0A (100 Hz ODR) ───────────────────
                INIT_2_START: begin
                    spi_cmd   <= 8'h2C;
                    spi_tx    <= {40'd0, 8'h0A};
                    spi_n     <= 3'd1;
                    spi_start <= 1'b1;
                    state     <= INIT_2_WAIT;
                end
                INIT_2_WAIT: if (spi_done) state <= INIT_3_START;

                // ── Write POWER_CTL = 0x08 (enter measurement mode) ──────
                INIT_3_START: begin
                    spi_cmd   <= 8'h2D;
                    spi_tx    <= {40'd0, 8'h08};
                    spi_n     <= 3'd1;
                    spi_start <= 1'b1;
                    state     <= INIT_3_WAIT;
                end
                INIT_3_WAIT: begin
                    if (spi_done) begin
                        delay_cnt <= SAMPLE_CYCLES - 1;
                        state     <= SAMPLE_WAIT;
                    end
                end

                // ── Inter-sample gap ────────────────────────────────────
                SAMPLE_WAIT: begin
                    if (delay_cnt == 0)
                        state <= READ_START;
                    else
                        delay_cnt <= delay_cnt - 1;
                end

                // ── Burst read DATAX0–DATAZ1 (6 bytes, registers 0x32–0x37)
                READ_START: begin
                    // cmd: R=1, MB=1, addr=0x32 → 0b11_110010 = 0xF2
                    spi_cmd   <= 8'hF2;
                    spi_tx    <= 48'd0;  // dummy writes while reading
                    spi_n     <= 3'd6;
                    spi_start <= 1'b1;
                    state     <= READ_WAIT;
                end

                READ_WAIT: begin
                    if (spi_done) begin
                        // spi_rx byte order matches ADXL345 burst (DATAX0 first):
                        //   spi_rx[7:0]   = DATAX0 (xL)
                        //   spi_rx[15:8]  = DATAX1 (xH)
                        //   spi_rx[23:16] = DATAY0 (yL)
                        //   spi_rx[31:24] = DATAY1 (yH)
                        //   spi_rx[39:32] = DATAZ0 (zL)
                        //   spi_rx[47:40] = DATAZ1 (zH)
                        accel_x    <= spi_rx[15:0];
                        accel_y    <= spi_rx[31:16];
                        accel_z    <= spi_rx[47:32];
                        data_valid <= 1'b1;
                        delay_cnt  <= SAMPLE_CYCLES - 1;
                        state      <= SAMPLE_WAIT;
                    end
                end

                default: state <= STARTUP;
            endcase
        end
    end

endmodule
