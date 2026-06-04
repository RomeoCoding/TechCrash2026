"""
FP8 E4M3 IEEE-compliant reference model and test vector generator.

Format: 1 sign | 4 exponent | 3 mantissa
  - Bias = 7
  - Exponent 0000: denormals (implicit leading 0)
  - Exponent 0001..1110: normals (implicit leading 1)
  - Exponent 1111, mantissa 111: NaN
  - Exponent 1111, mantissa 000..110: max finite values (NO infinity in E4M3)
  - Max value: 1.110 * 2^(15-7) = 1.75 * 256 = 448
  - Min normal: 1.000 * 2^(1-7) = 2^-6 = 0.015625
  - Min denorm: 0.001 * 2^(1-7) = 2^-9 = 0.001953125

Rounding: Round-to-nearest-even (IEEE default)
"""

import struct
import random
import os

# ─── FP8 E4M3 constants ───
SIGN_BITS = 1
EXP_BITS = 4
MAN_BITS = 3
BIAS = 7
MAX_EXP = (1 << EXP_BITS) - 1  # 15
NAN_VAL = 0x7F  # 0_1111_111
NEG_NAN_VAL = 0xFF  # 1_1111_111

def fp8_to_float(x):
    """Convert 8-bit FP8 E4M3 integer to Python float."""
    x = x & 0xFF
    sign = (x >> 7) & 1
    exp = (x >> 3) & 0xF
    man = x & 0x7

    # NaN
    if exp == MAX_EXP and man == 0x7:
        return float('nan')

    # Zero
    if exp == 0 and man == 0:
        return (-1.0)**sign * 0.0

    # Denormal
    if exp == 0:
        value = (man / 8.0) * (2.0 ** (1 - BIAS))
    else:
        # Normal (including exp=15 with man != 7)
        value = (1.0 + man / 8.0) * (2.0 ** (exp - BIAS))

    return (-1.0)**sign * value


def float_to_fp8(f):
    """Convert Python float to 8-bit FP8 E4M3 with round-to-nearest-even."""
    import math

    # NaN
    if math.isnan(f):
        return NAN_VAL

    # Sign
    sign = 0
    if f < 0:
        sign = 1
        f = -f
    elif f == 0.0:
        # Preserve sign of zero
        if math.copysign(1.0, f) < 0:
            sign = 1
        return (sign << 7)

    # Infinity or overflow → clamp to max finite
    # E4M3 has no infinity, so overflow saturates to max
    max_val = 1.75 * (2.0 ** (MAX_EXP - BIAS))  # 1.110 * 2^8 = 448
    if math.isinf(f) or f > max_val:
        # Return max finite: S_1111_110
        return (sign << 7) | (MAX_EXP << 3) | 0x6

    # Find exponent
    if f >= 2.0 ** (1 - BIAS):
        # Normal range
        exp_unbiased = math.floor(math.log2(f))
        # Clamp exponent
        if exp_unbiased > MAX_EXP - BIAS:
            exp_unbiased = MAX_EXP - BIAS
        exp_biased = exp_unbiased + BIAS

        # Mantissa (remove implicit 1)
        significand = f / (2.0 ** exp_unbiased) - 1.0
        # significand is in [0, 1)

        # Scale to mantissa bits + guard/round/sticky
        man_scaled = significand * 8.0  # 3 mantissa bits

        # Round to nearest even
        man_int = int(man_scaled)
        frac = man_scaled - man_int

        if frac > 0.5:
            man_int += 1
        elif frac == 0.5:
            # Round to even
            if man_int & 1:
                man_int += 1

        # Handle mantissa overflow (carry into exponent)
        if man_int >= 8:
            man_int = 0
            exp_biased += 1

        # Check if exponent overflow after rounding
        if exp_biased >= MAX_EXP:
            # Check if this would be NaN (exp=15, man=7)
            if exp_biased == MAX_EXP and man_int == 7:
                # Saturate to max finite instead of NaN
                man_int = 6
            elif exp_biased > MAX_EXP:
                # Saturate to max finite
                return (sign << 7) | (MAX_EXP << 3) | 0x6

        return (sign << 7) | (exp_biased << 3) | (man_int & 0x7)
    else:
        # Denormal range
        # f = man/8 * 2^(1-BIAS)
        man_scaled = f / (2.0 ** (1 - BIAS)) * 8.0

        man_int = int(man_scaled)
        frac = man_scaled - man_int

        if frac > 0.5:
            man_int += 1
        elif frac == 0.5:
            if man_int & 1:
                man_int += 1

        # If rounds up to 8, becomes smallest normal
        if man_int >= 8:
            return (sign << 7) | (1 << 3) | 0  # exp=1, man=0

        if man_int == 0:
            return (sign << 7)  # zero

        return (sign << 7) | (0 << 3) | (man_int & 0x7)


def fp8_add(a_int, b_int):
    """Add two FP8 E4M3 values (given as 8-bit ints). Returns 8-bit int result."""
    a_float = fp8_to_float(a_int)
    b_float = fp8_to_float(b_int)

    import math

    # NaN propagation
    if math.isnan(a_float) or math.isnan(b_float):
        return NAN_VAL

    result_float = a_float + b_float
    return float_to_fp8(result_float)


def verify_model():
    """Run sanity checks on the FP8 model."""
    print("=== FP8 E4M3 Model Verification ===")

    # Zero + Zero = Zero
    assert fp8_add(0x00, 0x00) == 0x00, "0+0 failed"

    # 1.0 + 1.0 = 2.0
    # 1.0 = 0_0111_000 = 0x38
    # 2.0 = 0_1000_000 = 0x40
    one = float_to_fp8(1.0)
    two = float_to_fp8(2.0)
    assert one == 0x38, f"1.0 encoding wrong: {one:#04x}"
    assert two == 0x40, f"2.0 encoding wrong: {two:#04x}"
    assert fp8_add(one, one) == two, f"1+1 != 2: got {fp8_add(one, one):#04x}"

    # 1.0 + (-1.0) = 0
    neg_one = float_to_fp8(-1.0)
    assert neg_one == 0xB8, f"-1.0 encoding wrong: {neg_one:#04x}"
    assert fp8_add(one, neg_one) == 0x00, f"1+(-1) != 0: got {fp8_add(one, neg_one):#04x}"

    # Max + Max should saturate
    max_pos = 0x7E  # 0_1111_110 = 448
    result = fp8_add(max_pos, max_pos)
    assert result == 0x7E, f"max+max should saturate: got {result:#04x}"

    # NaN + anything = NaN
    assert fp8_add(NAN_VAL, one) == NAN_VAL, "NaN propagation failed"
    assert fp8_add(one, NAN_VAL) == NAN_VAL, "NaN propagation failed"

    # Denormal + Denormal
    # 0.001 * 2^-6 + 0.001 * 2^-6 = 0.010 * 2^-6
    d1 = 0x01  # 0_0000_001 = smallest denorm
    d2 = fp8_add(d1, d1)
    assert d2 == 0x02, f"denorm+denorm: got {d2:#04x}, expected 0x02"

    # Round trip all 256 values
    for i in range(256):
        f = fp8_to_float(i)
        if not (f != f):  # skip NaN (NaN != NaN)
            back = float_to_fp8(f)
            # Allow negative zero to map to positive zero
            if i == 0x80:
                assert back == 0x00 or back == 0x80
            else:
                assert back == i, f"Round trip failed for {i:#04x}: float={f}, back={back:#04x}"

    print("All verification checks PASSED")
    print(f"  1.0 = 0x{one:02X}")
    print(f"  2.0 = 0x{two:02X}")
    print(f" -1.0 = 0x{neg_one:02X}")
    print(f"  max = 0x7E = {fp8_to_float(0x7E)}")
    print(f"  min denorm = 0x01 = {fp8_to_float(0x01)}")
    print()


def generate_test_vectors(num_vectors=4096):
    """Generate test vectors with good coverage."""
    vectors = []

    # ─── Edge cases (first ~200 vectors) ───
    edge_values = [
        0x00,  # +0
        0x80,  # -0
        0x01,  # smallest positive denorm
        0x07,  # largest denorm
        0x08,  # smallest normal
        0x38,  # 1.0
        0x40,  # 2.0
        0x48,  # 3.0
        0x7E,  # max positive (448)
        0x7F,  # NaN
        0x81,  # smallest negative denorm
        0x87,  # largest negative denorm
        0x88,  # smallest negative normal
        0xB8,  # -1.0
        0xFE,  # max negative (-448)
        0xFF,  # -NaN
    ]

    # All pairs of edge values
    for a in edge_values:
        for b in edge_values:
            vectors.append((a, b))

    # ─── Denormal exhaustive (denorm + denorm, denorm + small normal) ───
    denorms = list(range(0x01, 0x08)) + list(range(0x81, 0x88))
    small_normals = list(range(0x08, 0x10)) + list(range(0x88, 0x90))
    for a in denorms:
        for b in denorms[:4]:
            vectors.append((a, b))
    for a in denorms:
        for b in small_normals[:4]:
            vectors.append((a, b))

    # ─── Cancellation cases (a + (-a) variants) ───
    for i in range(1, 128):
        if i != 0x7F:  # skip NaN
            neg = i | 0x80
            vectors.append((i, neg))  # should give zero
            # Near cancellation
            if i > 1:
                vectors.append((i, (i-1) | 0x80))

    # ─── Overflow cases ───
    large_vals = list(range(0x70, 0x7F))  # large positives
    for a in large_vals:
        for b in large_vals:
            vectors.append((a, b))

    # ─── Random vectors to fill remaining ───
    random.seed(42)  # Reproducible
    while len(vectors) < num_vectors:
        a = random.randint(0, 255)
        b = random.randint(0, 255)
        vectors.append((a, b))

    # Trim to exact count
    vectors = vectors[:num_vectors]

    # Compute expected results
    test_data = []
    for a, b in vectors:
        expected = fp8_add(a, b)
        test_data.append((a, b, expected))

    return test_data


def write_mif(filename, data, width=8, depth=None):
    """Write Quartus .mif (Memory Initialization File)."""
    if depth is None:
        depth = len(data)

    with open(filename, 'w') as f:
        f.write(f"WIDTH={width};\n")
        f.write(f"DEPTH={depth};\n")
        f.write(f"ADDRESS_RADIX=HEX;\n")
        f.write(f"DATA_RADIX=HEX;\n")
        f.write(f"CONTENT BEGIN\n")
        for addr, val in enumerate(data):
            f.write(f"  {addr:04X} : {val:02X};\n")
        # Fill remaining with zeros if needed
        if len(data) < depth:
            f.write(f"  [{len(data):04X}..{depth-1:04X}] : 00;\n")
        f.write(f"END;\n")


def write_hex(filename, data, depth=4096):
    """Write $readmemh-compatible hex file (one value per line, zero-padded to depth)."""
    with open(filename, 'w') as f:
        for val in data:
            f.write(f"{val:02X}\n")
        # Pad remaining with zeros
        for _ in range(depth - len(data)):
            f.write("00\n")


def main():
    # Verify model correctness
    verify_model()

    # Generate test vectors
    NUM_VECTORS = 4096
    print(f"Generating {NUM_VECTORS} test vectors...")
    test_data = generate_test_vectors(NUM_VECTORS)

    # Statistics
    nan_count = sum(1 for _, _, e in test_data if e == NAN_VAL or e == NEG_NAN_VAL)
    zero_count = sum(1 for _, _, e in test_data if e == 0x00 or e == 0x80)
    sat_count = sum(1 for _, _, e in test_data if e == 0x7E or e == 0xFE)
    print(f"  NaN results: {nan_count}")
    print(f"  Zero results: {zero_count}")
    print(f"  Saturated results: {sat_count}")
    print(f"  Normal results: {NUM_VECTORS - nan_count - zero_count - sat_count}")

    # Write .mif files
    mem_dir = os.path.join(os.path.dirname(__file__), '..', 'fpga', 'mem')
    os.makedirs(mem_dir, exist_ok=True)

    a_data = [a for a, _, _ in test_data]
    b_data = [b for _, b, _ in test_data]
    exp_data = [e for _, _, e in test_data]

    write_mif(os.path.join(mem_dir, 'mem_a.mif'), a_data, width=8, depth=4096)
    write_mif(os.path.join(mem_dir, 'mem_b.mif'), b_data, width=8, depth=4096)
    write_mif(os.path.join(mem_dir, 'mem_expected.mif'), exp_data, width=8, depth=4096)

    write_hex(os.path.join(mem_dir, 'mem_a.hex'), a_data, depth=4096)
    write_hex(os.path.join(mem_dir, 'mem_b.hex'), b_data, depth=4096)
    write_hex(os.path.join(mem_dir, 'mem_expected.hex'), exp_data, depth=4096)

    print(f"\nWrote .mif and .hex files to {mem_dir}/")
    print(f"  mem_a.mif/.hex        ({NUM_VECTORS} operand A values)")
    print(f"  mem_b.mif/.hex        ({NUM_VECTORS} operand B values)")
    print(f"  mem_expected.mif/.hex ({NUM_VECTORS} expected results)")

    # Also write a combined CSV for human inspection
    csv_path = os.path.join(os.path.dirname(__file__), 'test_vectors.csv')
    with open(csv_path, 'w') as f:
        f.write("index,a_hex,b_hex,expected_hex,a_float,b_float,expected_float\n")
        for i, (a, b, e) in enumerate(test_data[:100]):  # First 100 for inspection
            af = fp8_to_float(a)
            bf = fp8_to_float(b)
            ef = fp8_to_float(e)
            f.write(f"{i},0x{a:02X},0x{b:02X},0x{e:02X},{af},{bf},{ef}\n")

    print(f"  test_vectors.csv (first 100 for inspection)")
    print("\nDone!")


if __name__ == '__main__':
    main()
