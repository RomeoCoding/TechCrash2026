// ============================================================================
// fp8_lut.v — 65536 × 8-bit pre-computed FP8 E4M3 addition lookup table
// ============================================================================
// Uses altsyncram megafunction to guarantee M9K block-RAM inference on MAX10.
// Behavioral $readmemh inference fails for MAX10 in Quartus 17.1 when the
// init file is in HEX format; altsyncram with a MIF file is the reliable path.
//
// Address: {a[7:0], b[7:0]} — all 65536 fp8_add(a,b) combinations.
// Output:  q — registered (1-cycle latency, M9K OUTDATA_REG=CLOCK0).
//
// Resource: 65536×8 = 512 Kbits ≈ 57 M9K blocks. MAX10-50K has 144 → fits.
// Critical path: M9K CLK-to-Q ~2 ns → closes timing at 200 MHz.
// ============================================================================

module fp8_lut (
    input  wire        clock,
    input  wire [15:0] address,
    output wire [7:0]  q
);

    altsyncram altsyncram_component (
        .clock0          (clock),
        .address_a       (address),
        .q_a             (q),
        // Unused ports
        .aclr0           (1'b0),
        .aclr1           (1'b0),
        .address_b       (1'b1),
        .addressstall_a  (1'b0),
        .addressstall_b  (1'b0),
        .byteena_a       (1'b1),
        .byteena_b       (1'b1),
        .clock1          (1'b1),
        .clocken0        (1'b1),
        .clocken1        (1'b1),
        .clocken2        (1'b1),
        .clocken3        (1'b1),
        .data_a          (8'b0),
        .data_b          (1'b1),
        .eccstatus       (),
        .q_b             (),
        .rden_a          (1'b1),
        .rden_b          (1'b1),
        .wren_a          (1'b0),
        .wren_b          (1'b0)
    );

    defparam
        altsyncram_component.address_aclr_a         = "NONE",
        altsyncram_component.clock_enable_input_a   = "BYPASS",
        altsyncram_component.clock_enable_output_a  = "BYPASS",
        altsyncram_component.init_file              = "mem/fp8_lut.mif",
        altsyncram_component.intended_device_family = "MAX 10",
        altsyncram_component.lpm_hint               = "ENABLE_RUNTIME_MOD=NO",
        altsyncram_component.lpm_type               = "altsyncram",
        altsyncram_component.numwords_a             = 65536,
        altsyncram_component.operation_mode         = "ROM",
        altsyncram_component.outdata_aclr_a         = "NONE",
        altsyncram_component.outdata_reg_a          = "CLOCK0",
        altsyncram_component.widthad_a              = 16,
        altsyncram_component.width_a                = 8,
        altsyncram_component.width_byteena_a        = 1;

endmodule
