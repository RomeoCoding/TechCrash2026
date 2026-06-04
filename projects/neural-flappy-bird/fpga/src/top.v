// top.v — Neural Flappy Bird top-level for DE10-Lite
// CrashTech VLSI 2026
//
// Milestones 1 & 3:
//   M1: Button flap → FLAP packet, SW[3:0] difficulty → DIFFICULTY packet,
//       SCORE_UPDATE reception → HEX1 display, MODE packet on startup.
//   M3: SW[9]=1 → inference mode: receive GAME_STATE, run nn_inference,
//       send INFER_RESULT; receive LOAD_WEIGHTS → update weight_store.
//
// UART: GPIO_0[0]=TX (FPGA→ESP32), GPIO_0[1]=RX (ESP32→FPGA), 115200 baud
`default_nettype none

module neural_flappy_bird_top (
    input           MAX10_CLK1_50,
    input   [9:0]   SW,
    input   [1:0]   KEY,
    output  [9:0]   LEDR,
    output  [7:0]   HEX0,
    output  [7:0]   HEX1,
    output  [7:0]   HEX2,
    output  [7:0]   HEX3,
    output  [7:0]   HEX4,
    output  [7:0]   HEX5,
    inout   [15:0]  ARDUINO_IO,
    inout           ARDUINO_RESET_N,
    // GPIO_0 UART (challenge-specified, overrides Arduino default)
    output          GPIO_0_TX,   // GPIO_0[0]: FPGA TX → ESP32 RX
    input           GPIO_0_RX    // GPIO_0[1]: ESP32 TX → FPGA RX
);
    // ── System ───────────────────────────────────────────────────────────
    wire clk   = MAX10_CLK1_50;
    wire rst_n;   // synchronous reset from POR (no external reset button)

    // Power-on reset: hold reset for ~262144 cycles (~5 ms at 50 MHz)
    reg [17:0] por_cnt = 18'd0;
    assign rst_n = por_cnt[17];
    always @(posedge clk)
        if (!por_cnt[17]) por_cnt <= por_cnt + 18'd1;

    // Tie Arduino header to high-Z (unused in this challenge)
    assign ARDUINO_IO     = 16'hzzzz;
    assign ARDUINO_RESET_N = 1'bz;

    // Unused HEX displays → blank (active-low, all segments off = 7'b1111111)
    assign HEX2 = 8'hFF;
    assign HEX3 = 8'hFF;
    assign HEX4 = 8'hFF;
    assign HEX5 = 8'hFF;

    // ── UART TX/RX ───────────────────────────────────────────────────────
    wire       uart_tx_line, uart_tx_busy;
    reg  [7:0] uart_tx_data;
    reg        uart_tx_send;

    uart_tx #(.CLK_FREQ(50_000_000), .BAUD(115_200)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .data_in(uart_tx_data), .send(uart_tx_send),
        .tx(uart_tx_line), .busy(uart_tx_busy)
    );
    assign GPIO_0_TX = uart_tx_line;

    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;

    uart_rx #(.CLK_FREQ(50_000_000), .BAUD(115_200)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .rx(GPIO_0_RX),
        .data_out(uart_rx_data), .valid(uart_rx_valid)
    );

    // ── Debounced KEY[0] ─────────────────────────────────────────────────
    wire btn_press;
    debounce #(.STABLE_CYCLES(2500)) u_dbnc (
        .clk(clk), .rst_n(rst_n),
        .btn_in(KEY[0]), .btn_press(btn_press)
    );

    // ── 7-Segment Displays ───────────────────────────────────────────────
    wire [6:0] hex0_seg, hex1_seg;
    seven_seg u_hex0 (.digit(SW[3:0]),  .seg(hex0_seg));

    reg [3:0] score_nibble;   // upper nibble of received score
    seven_seg u_hex1 (.digit(score_nibble), .seg(hex1_seg));

    assign HEX0 = {1'b1, hex0_seg};   // DP off (bit 7 = 1)
    assign HEX1 = {1'b1, hex1_seg};

    // ── Packet Parser ────────────────────────────────────────────────────
    wire [7:0]  pkt_cmd;
    wire [7:0]  pkt_payload [0:49];
    wire [5:0]  pkt_len;
    wire        pkt_valid;

    packet_parser #(.MAX_PAYLOAD(50)) u_parser (
        .clk(clk), .rst_n(rst_n),
        .rx_byte(uart_rx_data), .rx_valid(uart_rx_valid),
        .cmd(pkt_cmd), .payload(pkt_payload), .pkt_len(pkt_len),
        .pkt_valid(pkt_valid)
    );

    // ── Packet Builder ───────────────────────────────────────────────────
    reg  [7:0]  pb_cmd;
    reg  [7:0]  pb_payload [0:49];
    reg  [5:0]  pb_len;
    reg         pb_send;
    wire        pb_busy;
    wire [7:0]  pb_tx_byte;
    wire        pb_tx_send;

    packet_builder #(.MAX_PAYLOAD(50)) u_builder (
        .clk(clk), .rst_n(rst_n),
        .cmd(pb_cmd), .payload(pb_payload), .len(pb_len),
        .send(pb_send), .busy(pb_busy),
        .tx_byte(pb_tx_byte), .tx_send(pb_tx_send),
        .tx_busy(uart_tx_busy)
    );

    // Connect builder output to uart_tx input
    always @(*) begin
        uart_tx_data = pb_tx_byte;
        uart_tx_send = pb_tx_send;
    end

    // ── Weight Store ─────────────────────────────────────────────────────
    reg         ws_wr_en;
    reg  [4:0]  ws_wr_addr;
    reg  [15:0] ws_wr_data;
    wire signed [15:0] weights [0:24];

    weight_store u_ws (
        .clk(clk), .rst_n(rst_n),
        .wr_en(ws_wr_en), .wr_addr(ws_wr_addr), .wr_data(ws_wr_data),
        .w(weights)
    );

    // ── Neural Network Inference ─────────────────────────────────────────
    reg  signed [15:0] nn_in0, nn_in1, nn_in2, nn_in3;
    reg         nn_start;
    wire        nn_flap, nn_done;

    nn_inference u_nn (
        .clk(clk), .rst_n(rst_n),
        .in0(nn_in0), .in1(nn_in1), .in2(nn_in2), .in3(nn_in3),
        .w(weights),
        .start(nn_start), .flap(nn_flap), .done(nn_done)
    );

    // ── Mode Register ────────────────────────────────────────────────────
    // SW[9]=0: manual/training as set by ESP32
    // SW[9]=1: always inference
    reg [1:0]  current_mode;    // 0=manual, 1=training, 2=inference
    reg        sw9_prev;

    // ── Difficulty Change Detection ──────────────────────────────────────
    reg [3:0] diff_prev;

    // ── Packet-send request arbitration ─────────────────────────────────
    // One-hot pending flags; higher index = higher priority for clarity
    reg pend_flap;
    reg pend_diff;
    reg pend_mode;
    reg pend_infer;
    reg [7:0] pend_mode_val;
    reg [3:0] pend_diff_val;
    reg [7:0] pend_infer_val;

    // ── Weight-loading state machine ─────────────────────────────────────
    reg [5:0]  wload_idx;   // index into 50-byte LOAD_WEIGHTS payload (2 bytes/weight)
    reg        wload_busy;

    // ── Boot startup ──────────────────────────────────────────────────────
    reg startup_done;

    // ── Main state machine ───────────────────────────────────────────────
    localparam SEND_IDLE  = 3'd0;
    localparam SEND_FLAP  = 3'd1;
    localparam SEND_DIFF  = 3'd2;
    localparam SEND_MODE  = 3'd3;
    localparam SEND_INFER = 3'd4;

    reg [2:0] send_state;

    // ── Packet-send helper ───────────────────────────────────────────────
    // (combinatorial setup of pb_* then assert pb_send for 1 cycle)
    integer idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_mode  <= 2'd0;
            sw9_prev      <= 1'b0;
            diff_prev     <= 4'd0;
            pend_flap     <= 1'b0;
            pend_diff     <= 1'b0;
            pend_mode     <= 1'b1;   // send MODE=manual on startup
            pend_infer    <= 1'b0;
            pend_mode_val <= 8'h00;  // manual
            pend_diff_val <= 4'd0;
            pend_infer_val<= 8'h00;
            startup_done  <= 1'b0;
            send_state    <= SEND_IDLE;
            pb_send       <= 1'b0;
            nn_start      <= 1'b0;
            ws_wr_en      <= 1'b0;
            wload_idx     <= 6'd0;
            wload_busy    <= 1'b0;
            score_nibble  <= 4'd0;
            nn_in0        <= 16'sd0;
            nn_in1        <= 16'sd0;
            nn_in2        <= 16'sd0;
            nn_in3        <= 16'sd0;
        end else begin
            pb_send  <= 1'b0;
            nn_start <= 1'b0;
            ws_wr_en <= 1'b0;

            // ── SW[9] mode transition ────────────────────────────────────
            sw9_prev <= SW[9];
            if (SW[9] != sw9_prev) begin
                if (SW[9]) begin
                    current_mode  <= 2'd2;
                    pend_mode     <= 1'b1;
                    pend_mode_val <= 8'h02;
                end else begin
                    current_mode  <= 2'd0;
                    pend_mode     <= 1'b1;
                    pend_mode_val <= 8'h00;
                end
            end

            // ── Difficulty change ────────────────────────────────────────
            diff_prev <= SW[3:0];
            if (SW[3:0] != diff_prev) begin
                pend_diff     <= 1'b1;
                pend_diff_val <= SW[3:0];
            end

            // ── Button press → FLAP ──────────────────────────────────────
            if (btn_press && current_mode == 2'd0)
                pend_flap <= 1'b1;

            // ── Received packet processing ───────────────────────────────
            if (pkt_valid) begin
                case (pkt_cmd)
                    8'h11: begin   // GAME_STATE (8 bytes = 4 × int16_t Q8.8)
                        if (SW[9]) begin   // only process in inference mode
                            nn_in0 <= {pkt_payload[0], pkt_payload[1]};
                            nn_in1 <= {pkt_payload[2], pkt_payload[3]};
                            nn_in2 <= {pkt_payload[4], pkt_payload[5]};
                            nn_in3 <= {pkt_payload[6], pkt_payload[7]};
                            nn_start <= 1'b1;
                        end
                    end
                    8'h12: begin   // LOAD_WEIGHTS (50 bytes = 25 × int16_t)
                        // Immediately write all 25 weights from payload
                        wload_idx  <= 6'd0;
                        wload_busy <= 1'b1;
                    end
                    8'h13: begin   // SCORE_UPDATE (2 bytes uint16_t big-endian)
                        score_nibble <= pkt_payload[1][7:4]; // upper nibble of LSB
                    end
                    // ESP32 can set mode if SW[9]=0
                    8'h03: begin
                        if (!SW[9]) begin
                            current_mode <= pkt_payload[0][1:0];
                        end
                    end
                    default: ;
                endcase
            end

            // ── Sequential weight loading (from last LOAD_WEIGHTS packet) ─
            if (wload_busy) begin
                // Each weight is 2 bytes: payload[idx*2] = MSB, payload[idx*2+1] = LSB
                ws_wr_en   <= 1'b1;
                ws_wr_addr <= wload_idx[4:0];
                ws_wr_data <= {pkt_payload[wload_idx * 2], pkt_payload[wload_idx * 2 + 1]};
                if (wload_idx == 6'd24) begin
                    wload_busy <= 1'b0;
                    wload_idx  <= 6'd0;
                end else begin
                    wload_idx <= wload_idx + 6'd1;
                end
            end

            // ── nn_done → send INFER_RESULT ──────────────────────────────
            if (nn_done) begin
                pend_infer     <= 1'b1;
                pend_infer_val <= {7'd0, nn_flap};
            end

            // ── Packet send arbitration (priority: infer > mode > diff > flap)
            case (send_state)
                SEND_IDLE: begin
                    if (!pb_busy) begin
                        if (pend_infer) begin
                            // INFER_RESULT: CMD=0x04, LEN=1, payload=[result]
                            pb_cmd        <= 8'h04;
                            pb_len        <= 6'd1;
                            pb_payload[0] <= pend_infer_val;
                            pb_send       <= 1'b1;
                            pend_infer    <= 1'b0;
                        end else if (pend_mode) begin
                            // MODE: CMD=0x03, LEN=1
                            pb_cmd        <= 8'h03;
                            pb_len        <= 6'd1;
                            pb_payload[0] <= pend_mode_val;
                            pb_send       <= 1'b1;
                            pend_mode     <= 1'b0;
                        end else if (pend_diff) begin
                            // DIFFICULTY: CMD=0x02, LEN=1
                            pb_cmd        <= 8'h02;
                            pb_len        <= 6'd1;
                            pb_payload[0] <= {4'd0, pend_diff_val};
                            pb_send       <= 1'b1;
                            pend_diff     <= 1'b0;
                        end else if (pend_flap) begin
                            // FLAP: CMD=0x01, LEN=0
                            pb_cmd        <= 8'h01;
                            pb_len        <= 6'd0;
                            pb_send       <= 1'b1;
                            pend_flap     <= 1'b0;
                        end
                    end
                end
                default: send_state <= SEND_IDLE;
            endcase
        end
    end

    // ── LED Assignments ──────────────────────────────────────────────────
    // LEDR[0]: training mode active
    // LEDR[1]: FPGA inference mode active (SW[9]=1)
    assign LEDR[0] = (current_mode == 2'd1);   // training
    assign LEDR[1] = SW[9];                    // inference
    assign LEDR[9:2] = 8'd0;

endmodule
`default_nettype wire
