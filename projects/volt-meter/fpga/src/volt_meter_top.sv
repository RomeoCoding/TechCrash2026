// CrashTech VLSI-2026 -- Challenge 1: Volt-Meter (FPGA side)
// Receives "X.XX\n" from ESP32 at 9600 baud on ARDUINO_IO[0].
// Displays X.XX on HEX3..HEX1 (DP after integer digit).
// LED bar LEDR[9:0] proportional to 0-3.30 V.
module volt_meter_top (
    input  logic        MAX10_CLK1_50,
    input  logic [1:0]  KEY,
    input  logic [9:0]  SW,
    output logic [9:0]  LEDR,
    output logic [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire  [15:0] ARDUINO_IO,
    output logic        ARDUINO_RESET_N
);
    assign ARDUINO_RESET_N  = 1'b1;
    assign ARDUINO_IO[15:0] = 16'bz;  // all Hi-Z; [0] used as input

    localparam CLK_HZ  = 50_000_000;
    localparam BAUD    = 9_600;
    localparam BIT_CLK = CLK_HZ / BAUD;  // 5208
    localparam HALF    = BIT_CLK / 2;    // 2604

    logic uart_rx_meta, uart_rx;
    always_ff @(posedge MAX10_CLK1_50) begin
        uart_rx_meta <= ARDUINO_IO[0];
        uart_rx      <= uart_rx_meta;
    end

    typedef enum logic [1:0] { RX_IDLE, RX_START, RX_DATA, RX_STOP } rx_state_t;
    rx_state_t   rx_state;
    logic [12:0] rx_baud_cnt;
    logic [2:0]  rx_bit_idx;
    logic [7:0]  rx_shift;
    logic        rx_valid;
    logic [7:0]  rx_byte;

    always_ff @(posedge MAX10_CLK1_50) begin
        rx_valid <= 1'b0;
        case (rx_state)
            RX_IDLE:  if (!uart_rx) begin
                          rx_baud_cnt <= 13'd0; rx_state <= RX_START;
                      end
            RX_START: if (rx_baud_cnt == HALF[12:0]) begin
                          if (!uart_rx) begin
                              rx_baud_cnt <= 13'd0; rx_bit_idx <= 3'd0; rx_state <= RX_DATA;
                          end else rx_state <= RX_IDLE;
                      end else rx_baud_cnt <= rx_baud_cnt + 1'b1;
            RX_DATA:  if (rx_baud_cnt == BIT_CLK[12:0] - 1'b1) begin
                          rx_shift    <= {uart_rx, rx_shift[7:1]};
                          rx_baud_cnt <= 13'd0;
                          if (rx_bit_idx == 3'd7) begin rx_bit_idx <= 3'd0; rx_state <= RX_STOP; end
                          else rx_bit_idx <= rx_bit_idx + 1'b1;
                      end else rx_baud_cnt <= rx_baud_cnt + 1'b1;
            RX_STOP:  if (rx_baud_cnt == HALF[12:0]) begin
                          rx_byte <= rx_shift; rx_valid <= 1'b1; rx_state <= RX_IDLE;
                      end else rx_baud_cnt <= rx_baud_cnt + 1'b1;
        endcase
    end

    // Parse "X.XX\n" -> BCD digits
    logic [1:0] parse_state;
    logic [3:0] dig_int, dig_tens, dig_ones;

    always_ff @(posedge MAX10_CLK1_50) begin
        if (rx_valid) begin
            case (parse_state)
                2'd0: if (rx_byte >= 8'h30 && rx_byte <= 8'h33) begin
                          dig_int <= rx_byte[3:0]; parse_state <= 2'd1;
                      end
                2'd1: if (rx_byte == 8'h2E) parse_state <= 2'd2;
                      else                  parse_state <= 2'd0;
                2'd2: if (rx_byte >= 8'h30 && rx_byte <= 8'h39) begin
                          dig_tens <= rx_byte[3:0]; parse_state <= 2'd3;
                      end else parse_state <= 2'd0;
                2'd3: begin
                          if (rx_byte >= 8'h30 && rx_byte <= 8'h39)
                              dig_ones <= rx_byte[3:0];
                          parse_state <= 2'd0;
                      end
            endcase
        end
    end

    function automatic logic [7:0] seg7(input logic [3:0] d, input logic dp);
        logic [7:0] s;
        case (d)
            4'd0: s = 8'hC0; 4'd1: s = 8'hF9; 4'd2: s = 8'hA4;
            4'd3: s = 8'hB0; 4'd4: s = 8'h99; 4'd5: s = 8'h92;
            4'd6: s = 8'h82; 4'd7: s = 8'hF8; 4'd8: s = 8'h80;
            4'd9: s = 8'h90; default: s = 8'hFF;
        endcase
        if (dp) s[7] = 1'b0;
        return s;
    endfunction

    assign HEX5 = 8'hFF; assign HEX4 = 8'hFF;
    assign HEX3 = seg7(dig_int,  1'b1);
    assign HEX2 = seg7(dig_tens, 1'b0);
    assign HEX1 = seg7(dig_ones, 1'b0);
    assign HEX0 = 8'hFF;

    // LED bar: 10 equal steps over 0-3.30 V
    logic [9:0] val_cv;
    assign val_cv = ({6'b0,dig_int}*10'd100)+({6'b0,dig_tens}*10'd10)+{6'b0,dig_ones};

    assign LEDR[0] = (val_cv >= 10'd33);
    assign LEDR[1] = (val_cv >= 10'd66);
    assign LEDR[2] = (val_cv >= 10'd99);
    assign LEDR[3] = (val_cv >= 10'd132);
    assign LEDR[4] = (val_cv >= 10'd165);
    assign LEDR[5] = (val_cv >= 10'd198);
    assign LEDR[6] = (val_cv >= 10'd231);
    assign LEDR[7] = (val_cv >= 10'd264);
    assign LEDR[8] = (val_cv >= 10'd297);
    assign LEDR[9] = (val_cv >= 10'd330);

endmodule
