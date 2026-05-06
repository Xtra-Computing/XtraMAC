#!/usr/bin/env python3
"""
Generate per-config testbenches for all MAC configs.

TB strategy:
  1. Instantiate the 3 variants (_mac_4c, _mac_5c, _mac_6c) in parallel.
  2. Apply 512 random input vectors (identical to all 3 variants).
  3. Apply zeros for many cycles and observe when each variant's output goes
     back to all-zero: that gives the measured latency.
  4. Bit-exact compare: y5 versus y4 delayed by (EXP5-EXP4) cycles; same for y6.
  5. PASS iff measured latencies == expected AND bit-exact comparisons pass.

Expected latencies encoded in wrapper names: 4/5/6 normally.
Override: int8_int8_int32 has no ADD_LAT param in its core, so its _4c and _5c
wrappers use identical params -> documented expected latencies are 3/3/4.

Output: mac_configs/<lane>/<config>/tb/tb_mac.v
"""
import os
import re

import os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG_ROOT = os.path.join(ROOT, "mac_configs")

RE_MODULE = re.compile(r"^module\s+(\w+)\s*\(", re.M)
RE_PORT   = re.compile(r"^\s*(input|output)\s+wire\s*(\[[^\]]*\])?\s*(\w+)\s*[,)]", re.M)


def parse_wrapper(path):
    with open(path) as f:
        src = f.read()
    mname = RE_MODULE.search(src).group(1)
    inputs, outputs = [], []
    for m in RE_PORT.finditer(src):
        direction, width, name = m.group(1), m.group(2), m.group(3)
        if name == "clk":
            continue
        (inputs if direction == "input" else outputs).append((name, width or ""))
    return mname, inputs, outputs


def width_bits(w):
    m = re.match(r"\[\s*(\d+)\s*:\s*0\s*\]", w)
    if m:
        return int(m.group(1)) + 1
    return 1


def sv_width_decl(w):
    return w if w else ""


# (exp4, exp5, exp6)
EXPECTED_LAT_OVERRIDES = {
    "int8_int8_int32": (3, 3, 4),
}


def gen_tb(cfg_dir, cfg_name, lane):
    rtl_dir = os.path.join(cfg_dir, "rtl")
    w4 = os.path.join(rtl_dir, "mac_4c.v")
    w5 = os.path.join(rtl_dir, "mac_5c.v")
    w6 = os.path.join(rtl_dir, "mac_6c.v")

    m4, ins4, outs4 = parse_wrapper(w4)
    m5, _, _ = parse_wrapper(w5)
    m6, _, _ = parse_wrapper(w6)
    out_name, out_w = outs4[0]
    out_bits = width_bits(out_w)

    exp4, exp5, exp6 = EXPECTED_LAT_OVERRIDES.get(cfg_name, (4, 5, 6))
    d5 = exp5 - exp4
    d6 = exp6 - exp4

    # Expression for y4_aligned_for_5 / y4_aligned_for_6
    def aligned(delta):
        if delta == 0:
            return "y4"
        return f"y4_dly[{delta-1}]"

    y4_for_5 = aligned(d5)
    y4_for_6 = aligned(d6)

    tb_path = os.path.join(cfg_dir, "tb", "tb_mac.v")
    os.makedirs(os.path.dirname(tb_path), exist_ok=True)

    port_block = ".clk(clk)"
    for nm, _ in ins4:
        port_block += f", .{nm}({nm})"

    L = []
    L.append("`timescale 1ns/1ps")
    L.append("`default_nettype none")
    L.append("// =============================================================")
    L.append(f"// Auto-generated TB for {cfg_name} (lane={lane})")
    L.append(f"// Expected latencies: 4c={exp4}, 5c={exp5}, 6c={exp6}" +
             (" (override)" if cfg_name in EXPECTED_LAT_OVERRIDES else ""))
    L.append("// =============================================================")
    L.append("module tb_mac;")
    L.append("  localparam integer N        = 512;")
    L.append("  localparam integer WARMUP   = 16;")
    L.append(f"  localparam integer EXP4 = {exp4};")
    L.append(f"  localparam integer EXP5 = {exp5};")
    L.append(f"  localparam integer EXP6 = {exp6};")
    L.append("  localparam integer MAXLAT   = 16;")
    L.append("")
    L.append("  reg clk;")
    L.append("  initial clk = 1'b0;")
    L.append("  always #5 clk = ~clk;")
    L.append("")
    for nm, w in ins4:
        L.append(f"  reg  {sv_width_decl(w)} {nm};")
    L.append(f"  wire {sv_width_decl(out_w)} y4, y5, y6;")
    L.append("")
    L.append(f"  {m4} u4 ({port_block}, .{out_name}(y4));")
    L.append(f"  {m5} u5 ({port_block}, .{out_name}(y5));")
    L.append(f"  {m6} u6 ({port_block}, .{out_name}(y6));")
    L.append("")
    L.append(f"  // Delay line of y4: y4_dly[0]=y4 one cycle ago, y4_dly[k]=y4 (k+1) cycles ago.")
    L.append(f"  reg  {sv_width_decl(out_w)} y4_dly [0:MAXLAT-1];")
    L.append("  integer dki;")
    L.append("  always @(posedge clk) begin")
    L.append("    y4_dly[0] <= y4;")
    L.append("    for (dki = 1; dki < MAXLAT; dki = dki + 1) y4_dly[dki] <= y4_dly[dki-1];")
    L.append("  end")
    L.append("")
    L.append(f"  wire {sv_width_decl(out_w)} y4_for_5 = {y4_for_5};")
    L.append(f"  wire {sv_width_decl(out_w)} y4_for_6 = {y4_for_6};")
    L.append("")
    L.append("  integer i;")
    L.append("  integer errors_5 = 0;")
    L.append("  integer errors_6 = 0;")
    L.append("  integer compared = 0;")
    L.append("  integer pc = 0;  // posedge counter (for latency measure)")
    L.append("  always @(posedge clk) pc <= pc + 1;")
    L.append("")
    L.append("  // Latency measurement state")
    L.append("  integer drain_start_pc = -1;")
    L.append("  integer y4_zero_pc = -1;")
    L.append("  integer y5_zero_pc = -1;")
    L.append("  integer y6_zero_pc = -1;")
    L.append("  integer lat4_m = -1, lat5_m = -1, lat6_m = -1;")
    L.append(f"  wire [{out_bits-1}:0] ZERO = {out_bits}'d0;")
    L.append("")
    L.append("  reg [31:0] r0, r1, r2, r3;")
    L.append("  initial begin")
    for nm, _ in ins4:
        L.append(f"    {nm} = 0;")
    L.append("    @(negedge clk);")
    L.append("")
    L.append("    // Phase 1: random stimulus + bit-exact comparisons")
    L.append("    for (i = 0; i < N; i = i + 1) begin")
    L.append("      r0 = $random; r1 = $random; r2 = $random; r3 = $random;")
    for idx, (nm, w) in enumerate(ins4):
        bits = width_bits(w)
        src = f"r{idx % 4}"
        nxt = f"r{(idx+1) % 4}"
        if bits >= 64:
            L.append(f"      {nm} = {{r0, r1, r2, r3}};")
        elif bits >= 32:
            L.append(f"      {nm} = {{{src}, {nxt}}};")
        else:
            L.append(f"      {nm} = {src}[{bits-1}:0];")
    L.append("      @(posedge clk);")
    L.append("      #1;")
    L.append("      if (i >= WARMUP) begin")
    L.append("        if (y5 !== y4_for_5) errors_5 = errors_5 + 1;")
    L.append("        if (y6 !== y4_for_6) errors_6 = errors_6 + 1;")
    L.append("        compared = compared + 1;")
    L.append("      end")
    L.append("    end")
    L.append("")
    L.append("    // Phase 2: zero input, measure when each variant's output becomes zero.")
    for nm, _ in ins4:
        L.append(f"    {nm} = 0;")
    L.append("    drain_start_pc = pc;  // this is the posedge count *before* next posedge")
    L.append("    @(posedge clk);")
    L.append("    // Record: drain_start_pc was the posedge count *after* the last nonzero")
    L.append("    // input cycle completed. Now first posedge with zero input has just fired.")
    L.append("    for (i = 0; i < 4*MAXLAT; i = i + 1) begin")
    L.append("      #1;")
    L.append("      if (y4_zero_pc < 0 && y4 === ZERO) y4_zero_pc = pc;")
    L.append("      if (y5_zero_pc < 0 && y5 === ZERO) y5_zero_pc = pc;")
    L.append("      if (y6_zero_pc < 0 && y6 === ZERO) y6_zero_pc = pc;")
    L.append("      @(posedge clk);")
    L.append("    end")
    L.append("")
    L.append("    if (y4_zero_pc >= 0) lat4_m = y4_zero_pc - drain_start_pc;")
    L.append("    if (y5_zero_pc >= 0) lat5_m = y5_zero_pc - drain_start_pc;")
    L.append("    if (y6_zero_pc >= 0) lat6_m = y6_zero_pc - drain_start_pc;")
    L.append("")
    L.append(f'    $display("CONFIG={cfg_name} LANE={lane} EXP=%0d,%0d,%0d MEAS=%0d,%0d,%0d CMP=%0d ERR5=%0d ERR6=%0d",')
    L.append("             EXP4, EXP5, EXP6, lat4_m, lat5_m, lat6_m,")
    L.append("             compared, errors_5, errors_6);")
    L.append("")
    L.append("    if (lat4_m == EXP4 && lat5_m == EXP5 && lat6_m == EXP6 &&")
    L.append("        errors_5 == 0 && errors_6 == 0)")
    L.append(f'      $display("RESULT={cfg_name} PASS");')
    L.append("    else")
    L.append(f'      $display("RESULT={cfg_name} FAIL");')
    L.append("    $finish;")
    L.append("  end")
    L.append("")
    L.append("  // Watchdog")
    L.append("  initial begin")
    L.append("    #2000000;")
    L.append(f'    $display("RESULT={cfg_name} FAIL (timeout)");')
    L.append("    $finish;")
    L.append("  end")
    L.append("")
    L.append("endmodule")
    L.append("`default_nettype wire")

    with open(tb_path, "w") as f:
        f.write("\n".join(L) + "\n")


def main():
    configs = []
    for lane in ("1lane", "2lane", "4lane"):
        d = os.path.join(CFG_ROOT, lane)
        if not os.path.isdir(d):
            continue
        for cname in sorted(os.listdir(d)):
            cdir = os.path.join(d, cname)
            if os.path.isdir(os.path.join(cdir, "rtl")):
                configs.append((lane, cname, cdir))
    print(f"Found {len(configs)} configs")
    for lane, cname, cdir in configs:
        gen_tb(cdir, cname, lane)


if __name__ == "__main__":
    main()
