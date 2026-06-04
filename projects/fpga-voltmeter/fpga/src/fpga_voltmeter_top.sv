// ============================================================
// fpga_voltmeter_top.sv — FPGA-side voltmeter using MAX10 internal ADC
// CrashTech VLSI-2026 — fpga-voltmeter challenge
//
// Hardware: DE10-Lite, MAX 10 (10M50DAF484C7G), 50 MHz
// ADC input: JP2 header pin — CH1 fixed in Qsys (seq_order_slot_1=1)
//
// Display: 7-segment shows voltage as "X.XXX" (volts, 3 decimal places)
//   HEX5: blank
//   HEX4: integer volt digit (0-2) + decimal point ON
//   HEX3: tenths digit
//   HEX2: hundredths digit
//   HEX1: thousandths digit
//   HEX0: blank
//
// LEDR[9:0]: thermometer bar graph — grows with voltage
// SW[0]: hold HIGH to freeze display (read hold)
//
// Prerequisite: adc_system/ generated via create_adc_qsys.tcl + qsys-generate
// ============================================================

module fpga_voltmeter_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout   [15:0]  ARDUINO_IO,
    output          ARDUINO_RESET_N
);

    wire clk   = MAX10_CLK1_50;
    wire rst_n = KEY[0];  // active-low reset

    assign ARDUINO_RESET_N  = 1'b1;
    // IO[1] = UART TX to ESP32; IO[0] and IO[15:2] = Hi-Z
    assign ARDUINO_IO[15:2] = 14'bz;
    assign ARDUINO_IO[0]    = 1'bz;

    // ================================================================
    //  ADC interface wires
    //  sequencer_csr: 1-bit addr, no waitrequest
    //  sample_store_csr: 7-bit addr, 2-cycle read latency, no waitrequest
    // ================================================================
    wire        seq_address;
    wire        seq_read;
    wire [31:0] seq_writedata;
    wire        seq_write;
    wire [31:0] seq_readdata;

    wire  [6:0] ss_address;
    wire        ss_read;
    wire [31:0] ss_readdata;
    wire        ss_write;
    wire [31:0] ss_writedata;

    wire [11:0] adc_result;
    wire        adc_valid;

    // ----------------------------------------------------------------
    //  Qsys-generated ADC system (created by create_adc_qsys.tcl)
    //  Port names match adc_system/synthesis/adc_system.v exactly.
    //  adc_pll_locked_export is tied HIGH — clock is stable oscillator,
    //  no PLL; control FSM checks this before starting conversion.
    // ----------------------------------------------------------------
    adc_system u_adc_system (
        .clk_clk               (clk),
        .reset_reset_n         (rst_n),
        // Sequencer CSR (start/stop ADC)
        .adc_address           (seq_address),
        .adc_read              (seq_read),
        .adc_readdata          (seq_readdata),
        .adc_write             (seq_write),
        .adc_writedata         (seq_writedata),
        // Sample store CSR (result readback)
        .ss_address            (ss_address),
        .ss_read               (ss_read),
        .ss_readdata           (ss_readdata),
        .ss_write              (ss_write),
        .ss_writedata          (ss_writedata),
        // PLL locked — tie HIGH (direct oscillator, no PLL)
        .adc_pll_locked_export (1'b1)
    );

    // ----------------------------------------------------------------
    //  ADC controller FSM
    // ----------------------------------------------------------------
    adc_controller u_adc_ctrl (
        .clk          (clk),
        .rst_n        (rst_n),
        .result       (adc_result),
        .valid        (adc_valid),
        .seq_address  (seq_address),
        .seq_read     (seq_read),
        .seq_writedata(seq_writedata),
        .seq_write    (seq_write),
        .seq_readdata (seq_readdata),
        .ss_address   (ss_address),
        .ss_read      (ss_read),
        .ss_writedata (ss_writedata),
        .ss_write     (ss_write),
        .ss_readdata  (ss_readdata)
    );

    // ================================================================
    //  Voltage computation: mv = adc_result * 2500 / 4096
    //  MAX10 ADC internal reference = 2.500 V  →  LSB = 0.610 mV
    // ================================================================
    wire [23:0] mv_wide = ({12'b0, adc_result} * 24'd2500) >> 12;
    wire [11:0] mv_raw  = mv_wide[11:0];

    // Latch on valid pulse; hold display when SW[0] is HIGH
    reg [11:0] mv_display;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mv_display <= 12'h0;
        else if (adc_valid && !SW[0])
            mv_display <= mv_raw;
    end

    // ================================================================
    //  BCD conversion
    // ================================================================
    wire [3:0] bcd3, bcd2, bcd1, bcd0;

    mv_to_bcd u_bcd (
        .mv_in (mv_display),
        .bcd3  (bcd3),
        .bcd2  (bcd2),
        .bcd1  (bcd1),
        .bcd0  (bcd0)
    );

    // ================================================================
    //  7-segment decoder (active-low, bit[7]=dp: 0=ON, 1=OFF)
    // ================================================================
    function automatic [7:0] seg7;
        input [3:0] d;
        case (d)
            4'd0: seg7 = 8'b1100_0000;
            4'd1: seg7 = 8'b1111_1001;
            4'd2: seg7 = 8'b1010_0100;
            4'd3: seg7 = 8'b1011_0000;
            4'd4: seg7 = 8'b1001_1001;
            4'd5: seg7 = 8'b1001_0010;
            4'd6: seg7 = 8'b1000_0010;
            4'd7: seg7 = 8'b1111_1000;
            4'd8: seg7 = 8'b1000_0000;
            4'd9: seg7 = 8'b1001_0000;
            default: seg7 = 8'b1111_1111;  // blank
        endcase
    endfunction

    // Display: "X.XXX" (voltage in volts) across HEX4..HEX1
    assign HEX5 = 8'hFF;                        // blank
    assign HEX4 = seg7(bcd3) & 8'b0111_1111;   // integer digit + dp ON
    assign HEX3 = seg7(bcd2);                   // tenths
    assign HEX2 = seg7(bcd1);                   // hundredths
    assign HEX1 = seg7(bcd0);                   // thousandths
    assign HEX0 = 8'hFF;                        // blank

    // ================================================================
    //  LEDR thermometer bar graph (uses latched adc_result)
    //  LED[i] ON when top 4 bits of result >= i  → 10 levels
    // ================================================================
    genvar gi;
    generate
        for (gi = 0; gi < 10; gi = gi + 1) begin : bar_gen
            assign LEDR[gi] = (adc_result[11:8] >= gi[3:0]);
        end
    endgenerate

    // ================================================================
    //  UART TX — send "X.XXX\n" to ESP32 at 9600 baud on ARDUINO_IO[1]
    //  1-cycle delay on valid so mv_display/bcd* have settled
    // ================================================================
    localparam TX_BIT_CLK = 50_000_000 / 9_600;  // 5208

    reg adc_valid_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) adc_valid_d <= 1'b0;
        else        adc_valid_d <= adc_valid && !SW[0];
    end

    typedef enum logic [1:0] { UTX_IDLE, UTX_START, UTX_DATA, UTX_STOP } utx_state_t;
    utx_state_t  utx_state;
    reg          uart_tx_out;
    reg [7:0]    utx_buf [0:5];
    reg [2:0]    utx_byte_idx;
    reg [2:0]    utx_bit_idx;
    reg [12:0]   utx_cnt;

    assign ARDUINO_IO[1] = uart_tx_out;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            utx_state    <= UTX_IDLE;
            uart_tx_out  <= 1'b1;
            utx_byte_idx <= 3'd0;
            utx_bit_idx  <= 3'd0;
            utx_cnt      <= 13'd0;
        end else begin
            case (utx_state)
                UTX_IDLE: begin
                    uart_tx_out <= 1'b1;
                    if (adc_valid_d) begin
                        utx_buf[0] <= 8'h30 + {4'b0, bcd3};
                        utx_buf[1] <= 8'h2E;
                        utx_buf[2] <= 8'h30 + {4'b0, bcd2};
                        utx_buf[3] <= 8'h30 + {4'b0, bcd1};
                        utx_buf[4] <= 8'h30 + {4'b0, bcd0};
                        utx_buf[5] <= 8'h0A;
                        utx_byte_idx <= 3'd0;
                        utx_bit_idx  <= 3'd0;
                        utx_cnt      <= 13'd0;
                        utx_state    <= UTX_START;
                    end
                end
                UTX_START: begin
                    uart_tx_out <= 1'b0;
                    if (utx_cnt == TX_BIT_CLK[12:0] - 1'b1) begin
                        utx_cnt     <= 13'd0;
                        utx_bit_idx <= 3'd0;
                        utx_state   <= UTX_DATA;
                    end else
                        utx_cnt <= utx_cnt + 1'b1;
                end
                UTX_DATA: begin
                    uart_tx_out <= utx_buf[utx_byte_idx][utx_bit_idx];
                    if (utx_cnt == TX_BIT_CLK[12:0] - 1'b1) begin
                        utx_cnt <= 13'd0;
                        if (utx_bit_idx == 3'd7)
                            utx_state <= UTX_STOP;
                        else
                            utx_bit_idx <= utx_bit_idx + 1'b1;
                    end else
                        utx_cnt <= utx_cnt + 1'b1;
                end
                UTX_STOP: begin
                    uart_tx_out <= 1'b1;
                    if (utx_cnt == TX_BIT_CLK[12:0] - 1'b1) begin
                        utx_cnt <= 13'd0;
                        if (utx_byte_idx == 3'd5)
                            utx_state <= UTX_IDLE;
                        else begin
                            utx_byte_idx <= utx_byte_idx + 1'b1;
                            utx_bit_idx  <= 3'd0;
                            utx_state    <= UTX_START;
                        end
                    end else
                        utx_cnt <= utx_cnt + 1'b1;
                end
            endcase
        end
    end

endmodule
