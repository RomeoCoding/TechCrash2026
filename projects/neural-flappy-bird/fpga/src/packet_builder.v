// packet_builder.v — Framed UART packet assembler
// CrashTech VLSI 2026 — Neural Flappy Bird
// Frame format: [0x7E][CMD][LEN][PAYLOAD...][CHK]
// CHK = XOR of CMD, LEN, and all payload bytes.
`default_nettype none

module packet_builder #(parameter MAX_PAYLOAD = 50)(
    input              clk,
    input              rst_n,
    input  [7:0]       cmd,
    input  [7:0]       payload [0:MAX_PAYLOAD-1],
    input  [5:0]       len,         // 0–50
    input              send,        // 1-cycle trigger
    output             busy,

    // uart_tx interface
    output reg [7:0]   tx_byte,
    output reg         tx_send,
    input              tx_busy
);
    localparam S_IDLE     = 3'd0;
    localparam S_START    = 3'd1;   // send 0x7E
    localparam S_CMD      = 3'd2;   // send cmd
    localparam S_LEN      = 3'd3;   // send len
    localparam S_PAYLOAD  = 3'd4;   // send payload bytes
    localparam S_CHK      = 3'd5;   // send checksum

    reg [2:0]  state;
    reg [7:0]  r_cmd;
    reg [7:0]  r_payload [0:MAX_PAYLOAD-1];
    reg [5:0]  r_len;
    reg [5:0]  pay_idx;
    reg [7:0]  chk;

    assign busy = (state != S_IDLE);

    // Pre-compute checksum combinatorially from latched values
    // (updated when we latch inputs in S_IDLE)
    // Actually we compute chk incrementally: start with cmd^len, XOR each payload byte

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            tx_send <= 1'b0;
            tx_byte <= 8'd0;
            pay_idx <= 6'd0;
            chk     <= 8'd0;
            r_cmd   <= 8'd0;
            r_len   <= 6'd0;
        end else begin
            tx_send <= 1'b0;  // default: no send pulse

            case (state)
                S_IDLE: begin
                    if (send) begin
                        // Latch inputs
                        r_cmd <= cmd;
                        r_len <= len;
                        // Latch payload and compute checksum: cmd ^ len ^ payload[...]
                        chk <= cmd ^ len;
                        begin : latch_payload
                            integer i;
                            for (i = 0; i < MAX_PAYLOAD; i = i + 1)
                                r_payload[i] <= payload[i];
                        end
                        pay_idx <= 6'd0;
                        state   <= S_START;
                    end
                end

                S_START: begin
                    if (!tx_busy) begin
                        tx_byte <= 8'h7E;
                        tx_send <= 1'b1;
                        state   <= S_CMD;
                    end
                end

                S_CMD: begin
                    if (!tx_busy) begin
                        tx_byte <= r_cmd;
                        tx_send <= 1'b1;
                        state   <= S_LEN;
                    end
                end

                S_LEN: begin
                    if (!tx_busy) begin
                        tx_byte <= {2'b00, r_len};
                        tx_send <= 1'b1;
                        // XOR payload bytes into chk
                        begin : xor_payload
                            integer i;
                            reg [7:0] tmp;
                            tmp = r_cmd ^ {2'b00, r_len};
                            for (i = 0; i < MAX_PAYLOAD; i = i + 1)
                                if (i < r_len) tmp = tmp ^ r_payload[i];
                            chk <= tmp;
                        end
                        if (r_len == 6'd0)
                            state <= S_CHK;
                        else begin
                            pay_idx <= 6'd0;
                            state   <= S_PAYLOAD;
                        end
                    end
                end

                S_PAYLOAD: begin
                    if (!tx_busy) begin
                        tx_byte <= r_payload[pay_idx];
                        tx_send <= 1'b1;
                        if (pay_idx == r_len - 1) begin
                            state <= S_CHK;
                        end else begin
                            pay_idx <= pay_idx + 6'd1;
                        end
                    end
                end

                S_CHK: begin
                    if (!tx_busy) begin
                        tx_byte <= chk;
                        tx_send <= 1'b1;
                        state   <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
