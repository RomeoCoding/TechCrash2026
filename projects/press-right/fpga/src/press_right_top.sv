// CrashTech VLSI-2026 -- Challenge 4: Press Right (FPGA side)
module press_right_top (
    input  logic        MAX10_CLK1_50,
    input  logic [1:0]  KEY,
    input  logic [9:0]  SW,
    output logic [9:0]  LEDR,
    output logic [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire  [15:0] ARDUINO_IO,
    output logic        ARDUINO_RESET_N
);
    assign ARDUINO_RESET_N  = 1'b1;
    assign ARDUINO_IO[15:2] = {14{1'bz}};
    assign ARDUINO_IO[0]    = 1'bz;

    localparam CLK_HZ    = 50_000_000;
    localparam BAUD      = 9_600;
    localparam BIT_CLK   = CLK_HZ / BAUD;
    localparam TICK_10MS = 500_000;

    logic k0_s0, k0_s1, k0_s2;
    logic key_fall;
    logic [20:0] deb_cnt;
    logic        deb_busy;

    always_ff @(posedge MAX10_CLK1_50) begin
        k0_s0 <= KEY[0]; k0_s1 <= k0_s0; k0_s2 <= k0_s1;
    end

    always_ff @(posedge MAX10_CLK1_50) begin
        key_fall <= 1'b0;
        if (deb_busy) begin
            if (deb_cnt == 21'd0) deb_busy <= 1'b0;
            else                  deb_cnt  <= deb_cnt - 1'b1;
        end else if (k0_s2 && !k0_s1) begin
            key_fall <= 1'b1;
            deb_busy <= 1'b1;
            deb_cnt  <= 21'd1_000_000;
        end
    end

    typedef enum logic [1:0] { ST_IDLE, ST_RUNNING, ST_STOPPED } state_t;
    state_t state;

    logic [3:0] d0, d1, d2, d3;
    logic [3:0] s0, s1, s2, s3;
    logic [18:0] tick_cnt;
    logic        tick;

    always_ff @(posedge MAX10_CLK1_50) begin
        tick <= 1'b0;
        case (state)
            ST_IDLE: begin
                d0 <= 4'd0; d1 <= 4'd0; d2 <= 4'd0; d3 <= 4'd0;
                tick_cnt <= 19'd0;
                if (key_fall) state <= ST_RUNNING;
            end
            ST_RUNNING: begin
                if (tick_cnt == TICK_10MS[18:0] - 1'b1) begin
                    tick_cnt <= 19'd0; tick <= 1'b1;
                end else tick_cnt <= tick_cnt + 1'b1;
                if (tick) begin
                    if (!(d3==4'd9 && d2==4'd9 && d1==4'd9 && d0==4'd9)) begin
                        if      (d0 < 4'd9) d0 <= d0 + 1'b1;
                        else begin d0 <= 4'd0;
                            if      (d1 < 4'd9) d1 <= d1 + 1'b1;
                            else begin d1 <= 4'd0;
                                if (d2 < 4'd9) d2 <= d2 + 1'b1;
                                else begin d2 <= 4'd0; d3 <= d3 + 1'b1; end
                            end
                        end
                    end
                end
                if (key_fall) begin
                    s3 <= d3; s2 <= d2; s1 <= d1; s0 <= d0;
                    state <= ST_STOPPED;
                end
            end
            ST_STOPPED: if (key_fall) state <= ST_IDLE;
        endcase
    end

    logic prev_stopped, send_req;
    always_ff @(posedge MAX10_CLK1_50) begin
        send_req     <= 1'b0;
        prev_stopped <= (state == ST_STOPPED);
        if (!prev_stopped && (state == ST_STOPPED)) send_req <= 1'b1;
    end

    typedef enum logic [1:0] { TX_IDLE, TX_START, TX_DATA, TX_STOP } tx_state_t;
    tx_state_t   tx_state;
    logic [12:0] tx_bit_cnt;
    logic [2:0]  tx_bit_idx;
    logic [7:0]  tx_shift;
    logic [7:0]  tx_buf [0:4];
    logic [2:0]  tx_byte_idx;
    logic        uart_tx_reg;
    assign ARDUINO_IO[1] = uart_tx_reg;

    always_ff @(posedge MAX10_CLK1_50) begin
        case (tx_state)
            TX_IDLE: begin
                uart_tx_reg <= 1'b1;
                if (send_req) begin
                    tx_buf[0] <= 8'h30 + {4'b0, s3};
                    tx_buf[1] <= 8'h30 + {4'b0, s2};
                    tx_buf[2] <= 8'h30 + {4'b0, s1};
                    tx_buf[3] <= 8'h30 + {4'b0, s0};
                    tx_buf[4] <= 8'h0A;
                    tx_shift    <= 8'h30 + {4'b0, s3};
                    tx_byte_idx <= 3'd0; tx_bit_cnt <= 13'd0; tx_bit_idx <= 3'd0;
                    tx_state    <= TX_START;
                end
            end
            TX_START: begin
                uart_tx_reg <= 1'b0;
                if (tx_bit_cnt == BIT_CLK[12:0] - 1'b1) begin
                    tx_bit_cnt <= 13'd0; tx_bit_idx <= 3'd0; tx_state <= TX_DATA;
                end else tx_bit_cnt <= tx_bit_cnt + 1'b1;
            end
            TX_DATA: begin
                uart_tx_reg <= tx_shift[0];
                if (tx_bit_cnt == BIT_CLK[12:0] - 1'b1) begin
                    tx_shift <= {1'b0, tx_shift[7:1]}; tx_bit_cnt <= 13'd0;
                    if (tx_bit_idx == 3'd7) tx_state   <= TX_STOP;
                    else                    tx_bit_idx <= tx_bit_idx + 1'b1;
                end else tx_bit_cnt <= tx_bit_cnt + 1'b1;
            end
            TX_STOP: begin
                uart_tx_reg <= 1'b1;
                if (tx_bit_cnt == BIT_CLK[12:0] - 1'b1) begin
                    tx_bit_cnt <= 13'd0;
                    if (tx_byte_idx == 3'd4) tx_state <= TX_IDLE;
                    else begin
                        tx_byte_idx <= tx_byte_idx + 1'b1;
                        tx_shift    <= tx_buf[tx_byte_idx + 1];
                        tx_state    <= TX_START;
                    end
                end else tx_bit_cnt <= tx_bit_cnt + 1'b1;
            end
        endcase
    end

    function automatic logic [7:0] seg7(input logic [3:0] d);
        case (d)
            4'd0: return 8'hC0; 4'd1: return 8'hF9; 4'd2: return 8'hA4;
            4'd3: return 8'hB0; 4'd4: return 8'h99; 4'd5: return 8'h92;
            4'd6: return 8'h82; 4'd7: return 8'hF8; 4'd8: return 8'h80;
            4'd9: return 8'h90; default: return 8'hFF;
        endcase
    endfunction

    logic [3:0] disp3, disp2, disp1, disp0;
    always_comb
        if (state == ST_STOPPED) {disp3,disp2,disp1,disp0} = {s3,s2,s1,s0};
        else                     {disp3,disp2,disp1,disp0} = {d3,d2,d1,d0};

    assign HEX5 = 8'hFF; assign HEX4 = 8'hFF;
    assign HEX3 = seg7(disp3); assign HEX2 = seg7(disp2);
    assign HEX1 = seg7(disp1); assign HEX0 = seg7(disp0);

    logic [13:0] val_bin, err;
    assign val_bin = (14'(s3)*14'd1000)+(14'(s2)*14'd100)+(14'(s1)*14'd10)+14'(s0);
    assign err     = (val_bin >= 14'd1000) ? val_bin - 14'd1000 : 14'd1000 - val_bin;

    always_comb begin
        case (state)
            ST_IDLE:    LEDR = 10'b0;
            ST_RUNNING: LEDR = 10'b1111111111;
            ST_STOPPED:
                if      (err==14'd0)  LEDR=10'b1111111111;
                else if (err<=14'd10) LEDR=10'b0111111111;
                else if (err<=14'd20) LEDR=10'b0011111111;
                else if (err<=14'd30) LEDR=10'b0001111111;
                else if (err<=14'd40) LEDR=10'b0000111111;
                else if (err<=14'd50) LEDR=10'b0000011111;
                else if (err<=14'd60) LEDR=10'b0000001111;
                else if (err<=14'd70) LEDR=10'b0000000111;
                else if (err<=14'd80) LEDR=10'b0000000011;
                else if (err<=14'd90) LEDR=10'b0000000001;
                else                  LEDR=10'b0;
            default: LEDR = 10'b0;
        endcase
    end
endmodule
