// packet_parser.v — Framed UART packet parser
// CrashTech VLSI 2026 — Neural Flappy Bird
// Frame format: [0x7E][CMD][LEN][PAYLOAD...][CHK]
// CHK = XOR of CMD, LEN, and all payload bytes.
// 50 ms timeout resets parser if packet is incomplete.
`default_nettype none

module packet_parser #(parameter MAX_PAYLOAD = 50)(
    input              clk,
    input              rst_n,
    input  [7:0]       rx_byte,
    input              rx_valid,
    output reg [7:0]   cmd,
    output reg [7:0]   payload [0:MAX_PAYLOAD-1],
    output reg [5:0]   pkt_len,
    output reg         pkt_valid   // 1-cycle pulse on valid complete packet
);
    // 50 ms timeout at 50 MHz = 2,500,000 cycles
    localparam TIMEOUT_CYCLES = 2_500_000;

    localparam S_WAIT_START   = 3'd0;
    localparam S_WAIT_CMD     = 3'd1;
    localparam S_WAIT_LEN     = 3'd2;
    localparam S_READ_PAYLOAD = 3'd3;
    localparam S_VALIDATE_CHK = 3'd4;

    reg [2:0]  state;
    reg [7:0]  r_cmd;
    reg [7:0]  r_len;
    reg [7:0]  r_payload [0:MAX_PAYLOAD-1];
    reg [5:0]  pay_idx;
    reg [7:0]  chk_acc;     // running XOR checksum

    // Timeout counter
    reg [21:0] timeout_cnt;  // 22 bits covers 4,194,303 > 2,500,000

    // Reset parser to WAIT_START
    task reset_parser;
        begin
            state       <= S_WAIT_START;
            timeout_cnt <= 22'd0;
            pkt_valid   <= 1'b0;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_WAIT_START;
            pkt_valid   <= 1'b0;
            timeout_cnt <= 22'd0;
            pay_idx     <= 6'd0;
            r_cmd       <= 8'd0;
            r_len       <= 8'd0;
            chk_acc     <= 8'd0;
        end else begin
            pkt_valid <= 1'b0;

            // Timeout: if in middle of packet and no byte for 50 ms → reset
            if (state != S_WAIT_START) begin
                if (timeout_cnt == TIMEOUT_CYCLES - 1) begin
                    state       <= S_WAIT_START;
                    timeout_cnt <= 22'd0;
                end else begin
                    timeout_cnt <= timeout_cnt + 22'd1;
                end
            end else begin
                timeout_cnt <= 22'd0;
            end

            if (rx_valid) begin
                // Any incoming byte resets timeout
                timeout_cnt <= 22'd0;

                case (state)
                    S_WAIT_START: begin
                        if (rx_byte == 8'h7E)
                            state <= S_WAIT_CMD;
                    end

                    S_WAIT_CMD: begin
                        r_cmd   <= rx_byte;
                        chk_acc <= rx_byte;   // start checksum with CMD
                        state   <= S_WAIT_LEN;
                    end

                    S_WAIT_LEN: begin
                        r_len   <= rx_byte;
                        chk_acc <= chk_acc ^ rx_byte;  // XOR with LEN
                        pay_idx <= 6'd0;
                        if (rx_byte == 8'd0)
                            state <= S_VALIDATE_CHK;
                        else
                            state <= S_READ_PAYLOAD;
                    end

                    S_READ_PAYLOAD: begin
                        r_payload[pay_idx] <= rx_byte;
                        chk_acc            <= chk_acc ^ rx_byte;
                        if (pay_idx == r_len - 1)
                            state <= S_VALIDATE_CHK;
                        else
                            pay_idx <= pay_idx + 6'd1;
                    end

                    S_VALIDATE_CHK: begin
                        state <= S_WAIT_START;
                        if (rx_byte == chk_acc) begin
                            // Valid packet — latch outputs
                            cmd       <= r_cmd;
                            pkt_len   <= r_len[5:0];
                            begin : copy_payload
                                integer i;
                                for (i = 0; i < MAX_PAYLOAD; i = i + 1)
                                    payload[i] <= r_payload[i];
                            end
                            pkt_valid <= 1'b1;
                        end
                        // Invalid checksum: silently discard
                    end

                    default: state <= S_WAIT_START;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
