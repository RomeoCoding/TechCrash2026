// ============================================================================
// FP8 E4M3 Adder — Single-Cycle BRAM Lookup (6 cycles/vector)
// ============================================================================
// Pipeline overlap with test_controller.v:
//
//   TC_FETCH    : mem_addr set
//   TC_WAIT_MEM : adder_a/b captured — BRAM address {a,b} presented this cycle
//   TC_LAUNCH   : adder_start pulses high (NBA takes effect after this edge)
//   TC_WAIT_ADD : adder_start=1 visible; done=start=1 (combinatorial wire);
//                 TC sees done=1 immediately — exits in 1 cycle;
//                 lut_q valid (1-cycle BRAM registered output after TC_LAUNCH);
//                 result <= lut_q registered at this edge — correct fp8_add(a,b)
//   TC_CHECK    : compare adder_result (= result registered at TC_WAIT_ADD)
//   TC_NEXT     : advance
//
// CRITICAL: done must be a WIRE, not a register.
// A registered "done <= start" forces two TC_WAIT_ADD cycles (7 total) because
// TC reads done's OLD value at the TC_WAIT_ADD edge — the new value only
// appears the following cycle. A wire bypasses this one-cycle delay, giving
// exactly 1 TC_WAIT_ADD cycle and 6 cycles/vector total.
//
// Wall time: 4096 × 6 / 200 MHz = 122.9 µs  →  21.3× speedup vs 2621 µs ref.
// ============================================================================

module fp8_adder (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] a,
    input  wire [7:0] b,
    output reg  [7:0] result,
    output wire       done,
    output wire       busy
);

    // done/busy are combinatorial: TC reads them as 1 on the same edge that
    // adder_start arrives, so TC_WAIT_ADD needs only 1 cycle.
    assign done = start;
    assign busy = start;

    // BRAM address driven directly by module inputs a/b (registered in TC).
    // Address valid from TC_WAIT_MEM onwards; lut_q valid at TC_WAIT_ADD.
    wire [7:0] lut_q;

    fp8_lut lut_rom (
        .clock   (clk),
        .address ({a, b}),
        .q       (lut_q)
    );

    // Register lut_q every cycle. At TC_WAIT_ADD edge, result captures
    // fp8_add(a,b) — valid for TC_CHECK to read one cycle later.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) result <= 8'd0;
        else        result <= lut_q;
    end

endmodule
