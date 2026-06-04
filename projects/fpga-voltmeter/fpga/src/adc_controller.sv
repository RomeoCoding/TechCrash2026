// ============================================================
// adc_controller.sv — Drives Qsys adc_system (altera_modular_adc, CORE_VAR=0)
// CrashTech VLSI-2026 — fpga-voltmeter challenge
//
// Actual register map (verified from altera_modular_adc source, Quartus 17.1):
//
//   sequencer_csr  (1-bit address, no waitrequest):
//     addr 0  command  [0]=RUN  [3:1]=mode (000=continuous, 001=single)
//
//   sample_store_csr  (7-bit address, 2-cycle RAM read latency, no waitrequest):
//     addr 0x00  slot-0 result [11:0]  (CH1 baked-in via seq_order_slot_1=1)
//     addr 0x40  IER  [0]=e_eop
//     addr 0x41  ISR  [0]=s_eop  (write 1 to clear)
//
// Flow: assert RUN=1 once → wait for first conversion → poll slot 0 at ~100 Hz
// Note: adc_pll_locked_export must be tied 1'b1 by top-level (no PLL in design).
// ============================================================

module adc_controller (
    input  wire        clk,
    input  wire        rst_n,

    output reg  [11:0] result,        // latched 12-bit ADC result
    output reg         valid,         // 1-cycle pulse when result is updated

    // Sequencer CSR — 1-bit address, no waitrequest
    output reg         seq_address,
    output reg         seq_read,
    output reg  [31:0] seq_writedata,
    output reg         seq_write,
    input  wire [31:0] seq_readdata,

    // Sample store CSR — 7-bit address, 2-cycle read latency, no waitrequest
    output reg   [6:0] ss_address,
    output reg         ss_read,
    output reg  [31:0] ss_writedata,
    output reg         ss_write,
    input  wire [31:0] ss_readdata
);

    localparam [2:0]
        S_INIT       = 3'd0,  // write RUN=1 (continuous) to sequencer_csr addr 0
        S_WAIT_FIRST = 3'd1,  // wait ~100 us for first conversion
        S_READ_RD    = 3'd2,  // assert ss_read, ss_address=0
        S_READ_L1    = 3'd3,  // wait cycle 1 of 2-cycle RAM read latency
        S_LATCH      = 3'd4,  // cycle 2: capture ss_readdata[11:0], pulse valid
        S_DELAY      = 3'd5;  // 10 ms inter-sample delay (~100 Hz)

    reg [2:0]  state;
    reg [19:0] delay_cnt;

    localparam INIT_WAIT    = 20'd5_000;    // ~100 us @ 50 MHz
    localparam DELAY_CYCLES = 20'd500_000;  // 10 ms  @ 50 MHz

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_INIT;
            seq_address   <= 1'b0;
            seq_read      <= 1'b0;
            seq_write     <= 1'b0;
            seq_writedata <= 32'h0;
            ss_address    <= 7'h0;
            ss_read       <= 1'b0;
            ss_write      <= 1'b0;
            ss_writedata  <= 32'h0;
            result        <= 12'h0;
            valid         <= 1'b0;
            delay_cnt     <= 20'h0;
        end else begin
            // Default: deassert all one-cycle strobes each cycle
            valid     <= 1'b0;
            seq_write <= 1'b0;
            seq_read  <= 1'b0;
            ss_write  <= 1'b0;
            ss_read   <= 1'b0;

            case (state)

                // ---- Start ADC in continuous mode ----
                S_INIT: begin
                    seq_address   <= 1'b0;
                    seq_writedata <= 32'h1;  // mode[3:1]=000 (continuous), RUN[0]=1
                    seq_write     <= 1'b1;
                    delay_cnt     <= 20'd0;
                    state         <= S_WAIT_FIRST;
                end

                // ---- Wait for first conversion result ----
                S_WAIT_FIRST: begin
                    if (delay_cnt == INIT_WAIT - 20'd1) begin
                        delay_cnt <= 20'd0;
                        state     <= S_READ_RD;
                    end else
                        delay_cnt <= delay_cnt + 20'd1;
                end

                // ---- Initiate Avalon read on sample_store addr 0 ----
                S_READ_RD: begin
                    ss_address <= 7'h0;  // slot 0 → CH1 result
                    ss_read    <= 1'b1;
                    state      <= S_READ_L1;
                end

                // ---- Latency cycle 1 (RAM output registered once) ----
                S_READ_L1: begin
                    state <= S_LATCH;
                end

                // ---- Latency cycle 2: readdata valid ----
                S_LATCH: begin
                    result    <= ss_readdata[11:0];  // word = {4'h0, adc[11:0]}
                    valid     <= 1'b1;
                    delay_cnt <= 20'd0;
                    state     <= S_DELAY;
                end

                // ---- Inter-sample delay then re-read ----
                S_DELAY: begin
                    if (delay_cnt == DELAY_CYCLES - 20'd1)
                        state <= S_READ_RD;
                    else
                        delay_cnt <= delay_cnt + 20'd1;
                end

                default: state <= S_INIT;
            endcase
        end
    end

endmodule
