// ============================================================================
// fp8_uart_tx.v - small 8N1 UART transmitter for FP8 HIL telemetry
// ============================================================================

module fp8_uart_tx_8n1 #(
    parameter integer CLK_HZ = 25000000,
    parameter integer BAUD   = 9600
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       valid,
    output reg        tx,
    output reg        busy
);

    localparam integer CLKS_PER_BIT = CLK_HZ / BAUD;

    localparam TX_IDLE  = 2'd0;
    localparam TX_START = 2'd1;
    localparam TX_DATA  = 2'd2;
    localparam TX_STOP  = 2'd3;

    reg [1:0]  state;
    reg [15:0] clk_count;
    reg [2:0]  bit_index;
    reg [7:0]  shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= TX_IDLE;
            tx        <= 1'b1;
            busy      <= 1'b0;
            clk_count <= 16'd0;
            bit_index <= 3'd0;
            shift_reg <= 8'd0;
        end else begin
            case (state)
                TX_IDLE: begin
                    tx        <= 1'b1;
                    busy      <= 1'b0;
                    clk_count <= 16'd0;
                    bit_index <= 3'd0;
                    if (valid) begin
                        busy      <= 1'b1;
                        shift_reg <= data;
                        tx        <= 1'b0;
                        state     <= TX_START;
                    end
                end

                TX_START: begin
                    busy <= 1'b1;
                    tx   <= 1'b0;
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 16'd0;
                        tx        <= shift_reg[0];
                        state     <= TX_DATA;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                TX_DATA: begin
                    busy <= 1'b1;
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 16'd0;
                        if (bit_index == 3'd7) begin
                            bit_index <= 3'd0;
                            tx        <= 1'b1;
                            state     <= TX_STOP;
                        end else begin
                            bit_index <= bit_index + 3'd1;
                            tx        <= shift_reg[bit_index + 3'd1];
                        end
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                TX_STOP: begin
                    busy <= 1'b1;
                    tx   <= 1'b1;
                    if (clk_count == CLKS_PER_BIT - 1) begin
                        clk_count <= 16'd0;
                        state     <= TX_IDLE;
                    end else begin
                        clk_count <= clk_count + 16'd1;
                    end
                end

                default: begin
                    state <= TX_IDLE;
                end
            endcase
        end
    end

endmodule

module fp8_telemetry_tx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       finished,
    input  wire [11:0] fail_count,
    input  wire [3:0] us_d5,
    input  wire [3:0] us_d4,
    input  wire [3:0] us_d3,
    input  wire [3:0] us_d2,
    input  wire [3:0] us_d1,
    input  wire [3:0] us_d0,
    output wire       tx,
    output wire       active
);

    localparam PASS_LEN = 5'd13; // "US,000000,OK\n"
    localparam FAIL_LEN = 5'd15; // "US,000000,FAIL\n"

    reg        finished_d;
    reg        sending;
    reg [4:0]  index;
    reg        latched_fail;
    reg [23:0] latched_digits;
    reg [7:0]  tx_data;
    reg        tx_valid;
    wire       tx_busy;
    wire [4:0] message_len = latched_fail ? FAIL_LEN : PASS_LEN;

    assign active = sending | tx_busy;

    fp8_uart_tx_8n1 uart_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .data  (tx_data),
        .valid (tx_valid),
        .tx    (tx),
        .busy  (tx_busy)
    );

    function [7:0] bcd_ascii;
        input [3:0] digit;
        begin
            bcd_ascii = 8'h30 + {4'd0, digit};
        end
    endfunction

    function [7:0] message_byte;
        input [4:0]  pos;
        input        is_fail;
        input [23:0] digits;
        begin
            case (pos)
                5'd0:  message_byte = "U";
                5'd1:  message_byte = "S";
                5'd2:  message_byte = ",";
                5'd3:  message_byte = bcd_ascii(digits[23:20]);
                5'd4:  message_byte = bcd_ascii(digits[19:16]);
                5'd5:  message_byte = bcd_ascii(digits[15:12]);
                5'd6:  message_byte = bcd_ascii(digits[11:8]);
                5'd7:  message_byte = bcd_ascii(digits[7:4]);
                5'd8:  message_byte = bcd_ascii(digits[3:0]);
                5'd9:  message_byte = ",";
                5'd10: message_byte = is_fail ? "F" : "O";
                5'd11: message_byte = is_fail ? "A" : "K";
                5'd12: message_byte = is_fail ? "I" : 8'h0A;
                5'd13: message_byte = is_fail ? "L" : 8'h0A;
                default: message_byte = 8'h0A;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            finished_d      <= 1'b0;
            sending         <= 1'b0;
            index           <= 5'd0;
            latched_fail    <= 1'b0;
            latched_digits  <= 24'd0;
            tx_data         <= 8'd0;
            tx_valid        <= 1'b0;
        end else begin
            finished_d <= finished;
            tx_valid   <= 1'b0;

            if (finished && !finished_d && !sending && !tx_busy) begin
                sending        <= 1'b1;
                index          <= 5'd0;
                latched_fail   <= (fail_count != 12'd0);
                latched_digits <= {us_d5, us_d4, us_d3, us_d2, us_d1, us_d0};
            end else if (sending && !tx_busy) begin
                tx_data  <= message_byte(index, latched_fail, latched_digits);
                tx_valid <= 1'b1;
                if (index == message_len - 5'd1) begin
                    sending <= 1'b0;
                    index   <= 5'd0;
                end else begin
                    index <= index + 5'd1;
                end
            end
        end
    end

endmodule