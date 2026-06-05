// ============================================================================
// pong_top.sv — DE10-Lite FPGA (Retro Pong)
// Uses proven spi_master + adxl345_ctrl modules from accelerometer-3d-cube.
//
// Packet: 0xAA ax0 ax1 ay0 ay1 az0 az1 key_byte sw_lo sw_hi 0x55  (11 bytes)
// UART TX: ARDUINO_IO[1] → ESP32_P1 GPIO16 @ 115200 8N1, ~62 Hz
// ============================================================================

module pong_top (
    input  wire        MAX10_CLK1_50,
    input  wire [1:0]  KEY,
    input  wire [9:0]  SW,
    output logic [9:0] LEDR,
    output logic [7:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire [15:0] ARDUINO_IO,
    output wire        ARDUINO_RESET_N,
    output wire        GSENSOR_CS_N,
    output wire        GSENSOR_SCLK,
    output wire        GSENSOR_SDI,
    input  wire        GSENSOR_SDO,
    input  wire [2:1]  GSENSOR_INT
);

    assign ARDUINO_RESET_N  = 1'b1;
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_IO[0]    = 1'bz;

    // =========================================================================
    // Reset — hold low for 16 cycles then release
    // =========================================================================
    logic [3:0] rst_cnt = 0;
    logic       rst_n   = 0;
    always_ff @(posedge MAX10_CLK1_50) begin
        if (!rst_n) begin
            if (rst_cnt == 4'hF) rst_n <= 1'b1;
            else rst_cnt <= rst_cnt + 1;
        end
    end

    // =========================================================================
    // ADXL345 — proven module from accelerometer-3d-cube challenge
    // =========================================================================
    wire signed [15:0] accel_x, accel_y, accel_z;
    wire               data_valid;

    adxl345_ctrl #(
        .CLK_FREQ (50_000_000),
        .SAMPLE_HZ(62)
    ) u_accel (
        .clk       (MAX10_CLK1_50),
        .rst_n     (rst_n),
        .accel_x   (accel_x),
        .accel_y   (accel_y),
        .accel_z   (accel_z),
        .data_valid(data_valid),
        .sclk      (GSENSOR_SCLK),
        .mosi      (GSENSOR_SDI),
        .miso      (GSENSOR_SDO),
        .cs_n      (GSENSOR_CS_N)
    );

    // =========================================================================
    // Latch accel data and KEY/SW on each valid sample
    // =========================================================================
    logic [7:0] ax0, ax1, ay0, ay1, az0, az1;
    logic [7:0] key_latch, swl_latch, swh_latch;

    wire [7:0] key_byte = {6'b0, ~KEY[1], ~KEY[0]};

    always_ff @(posedge MAX10_CLK1_50) begin
        if (data_valid) begin
            ax0 <= accel_x[7:0];
            ax1 <= accel_x[15:8];
            ay0 <= accel_y[7:0];
            ay1 <= accel_y[15:8];
            az0 <= accel_z[7:0];
            az1 <= accel_z[15:8];
            key_latch <= key_byte;
            swl_latch <= SW[7:0];
            swh_latch <= {6'b0, SW[9:8]};
        end
    end

    // =========================================================================
    // UART TX — 115200 baud, 8N1
    // =========================================================================
    localparam CLKS_PER_BIT = 434;

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
                uart_tx_line <= 0;
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
                    4'd8: uart_tx_line <= 1;
                    4'd9: begin uart_active <= 0; uart_done <= 1; end
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // TX FSM — send 11-byte packet when data_valid fires
    // =========================================================================
    typedef enum logic [3:0] {
        TX_IDLE,
        TX_HDR, TX_X0, TX_X1, TX_Y0, TX_Y1, TX_Z0, TX_Z1,
        TX_KEY, TX_SWL, TX_SWH, TX_END, TX_END_WAIT
    } tx_state_t;

    tx_state_t tx_state;

    always_ff @(posedge MAX10_CLK1_50) begin
        uart_start <= 0;

        case (tx_state)
            TX_IDLE: if (data_valid) begin
                uart_tx_byte <= 8'hAA;
                uart_start   <= 1;
                tx_state     <= TX_HDR;
            end
            TX_HDR:  if (uart_done) begin uart_tx_byte <= ax0;      uart_start <= 1; tx_state <= TX_X0;  end
            TX_X0:   if (uart_done) begin uart_tx_byte <= ax1;      uart_start <= 1; tx_state <= TX_X1;  end
            TX_X1:   if (uart_done) begin uart_tx_byte <= ay0;      uart_start <= 1; tx_state <= TX_Y0;  end
            TX_Y0:   if (uart_done) begin uart_tx_byte <= ay1;      uart_start <= 1; tx_state <= TX_Y1;  end
            TX_Y1:   if (uart_done) begin uart_tx_byte <= az0;      uart_start <= 1; tx_state <= TX_Z0;  end
            TX_Z0:   if (uart_done) begin uart_tx_byte <= az1;      uart_start <= 1; tx_state <= TX_Z1;  end
            TX_Z1:   if (uart_done) begin uart_tx_byte <= key_latch; uart_start <= 1; tx_state <= TX_KEY; end
            TX_KEY:  if (uart_done) begin uart_tx_byte <= swl_latch; uart_start <= 1; tx_state <= TX_SWL; end
            TX_SWL:  if (uart_done) begin uart_tx_byte <= swh_latch; uart_start <= 1; tx_state <= TX_SWH; end
            TX_SWH:  if (uart_done) begin uart_tx_byte <= 8'h55;    uart_start <= 1; tx_state <= TX_END; end
            TX_END:  if (uart_done) tx_state <= TX_END_WAIT;
            TX_END_WAIT: if (!uart_active) tx_state <= TX_IDLE;
            default: tx_state <= TX_IDLE;
        endcase
    end

    // =========================================================================
    // LEDR — tilt bar driven by accel_y
    // =========================================================================
    wire signed [15:0] ay_s     = accel_y;
    wire signed [15:0] ay_clamp =
        (ay_s >  16'sd200) ?  16'sd200 :
        (ay_s < -16'sd200) ? -16'sd200 : ay_s;
    wire [15:0] bar_raw = ay_clamp + 16'sd200;
    wire  [3:0] bar_idx =
        (bar_raw >= 16'd360) ? 4'd9 :
        (bar_raw >= 16'd320) ? 4'd8 :
        (bar_raw >= 16'd280) ? 4'd7 :
        (bar_raw >= 16'd240) ? 4'd6 :
        (bar_raw >= 16'd200) ? 4'd5 :
        (bar_raw >= 16'd160) ? 4'd4 :
        (bar_raw >= 16'd120) ? 4'd3 :
        (bar_raw >= 16'd80)  ? 4'd2 :
        (bar_raw >= 16'd40)  ? 4'd1 : 4'd0;

    genvar gi;
    generate
        for (gi = 0; gi < 10; gi++) begin : led_bar
            assign LEDR[gi] = (gi[3:0] <= bar_idx);
        end
    endgenerate

    // =========================================================================
    // HEX — "P1----"
    // =========================================================================
    assign HEX5 = 8'b1000_1100;
    assign HEX4 = 8'b1111_1001;
    assign HEX3 = 8'b1011_1111;
    assign HEX2 = 8'b1011_1111;
    assign HEX1 = 8'b1011_1111;
    assign HEX0 = 8'b1011_1111;

endmodule
