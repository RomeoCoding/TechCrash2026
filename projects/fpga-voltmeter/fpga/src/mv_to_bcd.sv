// ============================================================
// mv_to_bcd.sv — millivolts (0-2500) → 4 BCD digits
// CrashTech VLSI-2026 — fpga-voltmeter challenge
//
// Combinational. Quartus synthesizes constant-divisor % and /
// into shift-and-multiply logic — no actual dividers used.
// Max input: 2500 mV (2.5V full-scale, MAX10 internal ADC ref)
// ============================================================

module mv_to_bcd (
    input  wire [11:0] mv_in,   // millivolts, range 0-2500

    output wire  [3:0] bcd3,    // thousands digit (0-2)
    output wire  [3:0] bcd2,    // hundreds  digit (0-9)
    output wire  [3:0] bcd1,    // tens      digit (0-9)
    output wire  [3:0] bcd0     // ones      digit (0-9)
);

    // Constant division synthesizes as multiply-by-reciprocal in Quartus.
    // For mv_in <= 2500, all outputs fit in 4 bits (max bcd3=2, bcd2-0<=9).
    wire [11:0] d3 = mv_in / 12'd1000;
    wire [11:0] d2 = (mv_in % 12'd1000) / 12'd100;
    wire [11:0] d1 = (mv_in % 12'd100)  / 12'd10;
    wire [11:0] d0 =  mv_in % 12'd10;

    assign bcd3 = d3[3:0];
    assign bcd2 = d2[3:0];
    assign bcd1 = d1[3:0];
    assign bcd0 = d0[3:0];

endmodule
