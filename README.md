# XtraMAC

**XtraMAC: An Efficient MAC Architecture for Mixed-Precision LLM Inference on FPGA.**

A self-contained Verilog library of **49 fixed-mode MAC configurations** plus
**4 runtime-reconfigurable dual-mode MACs**, targeting Xilinx UltraScale+ FPGAs
(e.g. Alveo U55C). Each design:

- Uses **exactly 1 DSP48E2** via mantissa packing on the A-port.
- Provides **3 pipeline variants** (4 / 5 / 6 cycles total latency, II = 1).
- Follows **FTZ/DAZ + RN-even** semantics (NVIDIA / AMD-Xilinx FP IP convention).
- Has both an **iverilog testbench** (no DSP primitive needed) and a **Vivado xsim/synthesis** flow.

A companion website is in progress at [https://xtramac.com/](https://xtramac.com/) for
interactive design-space visualization and bundle downloads.

## Quickstart — pick a config and download the RTL

The fastest way to get an integration-ready bundle is via the IP picker scripts:

```bash
# Single-mode (49 fixed-datatype MACs)
python3 User_spec/generate_mac_bundle.py --list                  # browse available IDs
python3 User_spec/generate_mac_bundle.py 1                       # by ID → exports/<module>/
python3 User_spec/generate_mac_bundle.py "FP8e4m3*FP8e4m3+FP16"  # by spec string

# Mixed-mode (4 runtime-switchable MACs)
python3 User_spec_mixed/generate_mixed_mac_bundle.py --list
python3 User_spec_mixed/generate_mixed_mac_bundle.py 2
```

Each invocation drops `rtl/`, `tb/`, and a `manifest.json` into
`exports/<module>/` (or a custom destination), ready to be dropped into your
own Verilog project.

The rest of this README documents the full library layout for users who want
to dig deeper, run their own synthesis sweep, or extend the designs.

---

## 1. Directory Layout

```
XtraMAC/
├── LICENSE                          # Apache 2.0
├── README.md                        # this file
│
├── User_spec/                       # IP picker for fixed-mode MACs (49)
│   ├── generate_mac_bundle.py
│   └── library/{rtl,tb}/            # canonical sources used by the generator
│
├── User_spec_mixed/                 # IP picker for runtime-reconfigurable MACs
│   ├── generate_mixed_mac_bundle.py
│   └── library/{rtl,tb}/
│
├── common/            # dsp_usage.v       (DSP48E2 wrapper)
├── mac_cores/         # parameterized RTL primitives (mul/add/MAC)
│   ├── fp32/          #   FP32 adder, FP16/BF16 → FP32 multipliers
│   ├── fp16/          #   FP16 adder, multiplier, single-lane MAC
│   ├── bf16/          #   BF16 adder, multiplier
│   ├── fp8e4m3/       #   FP8 E4M3 adder, multiplier (4-lane)
│   ├── fp8e5m2/       #   FP8 E5M2 adder, multiplier (4-lane)
│   ├── int32/         #   INT8×INT8 → INT32 (2-lane)
│   └── mixed_precision/  # all cross-precision MAC cores (~50 .v + .vh)
│
├── mac_configs/       # one folder per config, each with:
│   ├── 1lane/<config>/{rtl/mac_4c.v,5c.v,6c.v, tb/tb_mac.v}
│   ├── 2lane/<config>/...
│   └── 4lane/<config>/...
│
├── runtime_reconfig/  # 4 dual-mode MACs that switch datatype at runtime
│   ├── a_bf16_int4_shared/   # BF16 ↔ INT4 (mode_int4)
│   ├── b_int8_bf16_dual/     # BF16 ↔ INT8 (mode_int8, dual add backends)
│   ├── c_fp8_bf16_dual/      # BF16 (2-lane) ↔ FP8e4m3 (4-lane)
│   ├── d_bf16_fp4_dual/      # BF16 ↔ FP4e2m1 (mode_fp4)
│   └── synth_results.csv     # post-synth LUT + post-route Fmax @ 2.222ns
│
└── verification/         # all scripts + result CSVs
    ├── run_one.sh         # run iverilog testbench for one config
    ├── run_one_synth.sh   # run Vivado synth+impl for one variant
    ├── dsp_usage_sim.v    # behavioural stub of dsp_usage for iverilog
    ├── synth_all.csv      # LUT/FF/DSP/Fmax of all 51 configs (450 MHz target)
    └── synth_500mhz.csv   # same metrics for 4 base configs (500 MHz target)
```

---

## 2. Choosing a Config

The directory name encodes the dataflow `<a_type>_<b_type>_<acc_type>` :

| `<config>` | `a` × `b` + `c` → `result` | Lane | Folder |
|---|---|---|---|
| `fp16_fp16_fp16` | FP16 × FP16 + FP16 → FP16 | 1 | `1lane/` |
| `fp16_fp16_fp32` | FP16 × FP16 + FP32 → FP32 | 1 | `1lane/` |
| `bf16_bf16_bf16` | BF16 × BF16 + BF16 → BF16 | 2 | `2lane/` |
| `bf16_bf16_fp32` | BF16 × BF16 + FP32 → FP32 | 2 | `2lane/` |
| `int8_int8_int32` | INT8 × INT8 + INT32 → INT32 | 2 | `2lane/` |
| `int_fp16_fp16` | INT(2..8) × FP16 + FP16 → FP16 | 2 | `2lane/` |
| `int_fp16_fp32` | INT(2..8) × FP16 + FP32 → FP32 | 2 | `2lane/` |
| `int_bf16_bf16` | INT(2..8) × BF16 + BF16 → BF16 | 2 | `2lane/` |
| `int_bf16_fp32` | INT(2..8) × BF16 + FP32 → FP32 | 2 | `2lane/` |
| `fp4eXmY_fp16_fp16` | FP4(E*M*) × FP16 + FP16 → FP16 | 2 | `2lane/` |
| `fp4eXmY_fp16_fp32` | FP4 × FP16 + FP32 → FP32 | 2 | `2lane/` |
| `fp4eXmY_bf16_bf16` | FP4 × BF16 + BF16 → BF16 | 2 | `2lane/` |
| `fp4eXmY_bf16_fp32` | FP4 × BF16 + FP32 → FP32 | 2 | `2lane/` |
| `fp8eXmY_fp16_fp16` | FP8(E4M3 / E5M2) × FP16 + FP16 → FP16 | 2 | `2lane/` |
| `fp8eXmY_fp16_fp32` | FP8 × FP16 + FP32 → FP32 | 2 | `2lane/` |
| `fp8eXmY_bf16_bf16` | FP8 × BF16 + BF16 → BF16 | 2 | `2lane/` |
| `fp8eXmY_bf16_fp32` | FP8 × BF16 + FP32 → FP32 | 2 | `2lane/` |
| `int4_fp8eXmY_fp8` | INT(2..4) × FP8 + FP8 → FP8 | 4 | `4lane/` |
| `int4_fp8eXmY_fp16` | INT(2..4) × FP8 + FP16 → FP16 | 4 | `4lane/` |
| `fp4eXmY_fp8eZmW_fp8` | FP4 × FP8 + FP8 → FP8 | 4 | `4lane/` |
| `fp4eXmY_fp8eZmW_fp16` | FP4 × FP8 + FP16 → FP16 | 4 | `4lane/` |
| `fp8eXmY_fp8eXmY_fp8` | FP8 × FP8 + FP8 → FP8 | 4 | `4lane/` |
| `fp8eXmY_fp8eXmY_fp16` | FP8 × FP8 + FP16 → FP16 | 4 | `4lane/` |
| `fp8eXmY_fp8eXmY_bf16` | FP8 × FP8 + BF16 → BF16 | 4 | `4lane/` |

(Where `e1m2 / e2m1 / e3m0` are FP4 layouts and `e4m3 / e5m2` are FP8 layouts.)

To list all configs: `ls mac_configs/{1,2,4}lane/`.

### Pipeline variants per config

| File | Latency (cycles) | (MUL_LAT, MID_STAGES, ADD_LAT) |
|---|---|---|
| `rtl/mac_4c.v` | 4 | (2, 0, 2) |
| `rtl/mac_5c.v` | 5 | (2, 0, 3) |
| `rtl/mac_6c.v` | 6 | (2, 1, 3) |

Higher latency → deeper pipelining → typically ~10–30 MHz higher Fmax.

---

## 3. Numerical Semantics

All cores follow the conventions used by NVIDIA A100/H100 Tensor Cores and AMD-Xilinx Floating-Point Operator IP:

- **FTZ on input** — subnormals are treated as zero on ingestion.
- **DAZ on output** — results below the smallest normal are flushed to zero.
- **NaN inputs** propagate as canonical qNaN
  (`FP32 = 0x7FC0_0000`, `FP16 = 0x7E00`, `FP8E4M3 = 0x79`).
- **Inf** is preserved with sign.
- **Conflict cases → qNaN**:
  - `∞ × 0`
  - `+∞ + (−∞)`
- **Formats without Inf encoding** (FP8 E4M3, FP4):
  all-ones exponent treated as **NaN**.
- **Integer → FP** conversion is **exact** for all valid INT(2..8b) values.
- **Accumulation**: round-to-nearest-even (RN-even) throughout.

---

## 4. Top-Level Module Interface

Each `mac_<lane>c.v` exports a clean port list. Examples:

```verilog
// 2-lane: INT × FP16 + FP32 → FP32
module int_fp16_fp32_mac_4c (
    input  wire        clk,
    input  wire [15:0] a_int,   // packed INT8 {hi, lo}
    input  wire [15:0] b16,     // shared FP16 multiplicand
    input  wire [63:0] c64,     // packed FP32 addends {hi, lo}
    output wire [63:0] result   // packed FP32 results {hi, lo}
);
```

```verilog
// 4-lane: FP8 × FP8 + FP16 → FP16
module fp8e4m3_fp8e4m3_fp16_mac_4c (
    input  wire        clk,
    input  wire [31:0] a32,     // 4 × FP8
    input  wire [31:0] b32,     // 4 × FP8
    input  wire [63:0] c64,     // 4 × FP16
    output wire [63:0] result   // 4 × FP16
);
```

Lane count = 1 / 2 / 4 lanes per cycle (sharing one DSP).

---

## 5. Running Simulation

Each config has a self-checking testbench at `mac_configs/<lane>/<config>/tb/tb_mac.v`. The TB instantiates 4c / 5c / 6c variants with the same inputs and verifies they produce **bit-exact identical** outputs (modulo pipeline shift).

You can pick **either** simulator below — both produce the same PASS/FAIL outcome.

### Option A — `iverilog` (lightweight, no Xilinx install needed)

`iverilog` is a free open-source simulator and does **not** support the
Xilinx `DSP48E2` primitive natively. The flow swaps in a tiny behavioural
multiplier (`verification/dsp_usage_sim.v`) at compile time so the testbench
still produces bit-exact-identical outputs to the real hardware. (Synthesis
still uses the real `DSP48E2` — only the simulator gets the stub.)

**Prerequisite**: `iverilog` (≥ 11) on the `PATH`. (Ubuntu: `sudo apt install iverilog`)

```bash
cd <repo>/verification

# Single config
bash ./run_one.sh 2lane int_fp16_fp32        # → RESULT=int_fp16_fp32 PASS

# All configs (parallel up to 16 jobs)
bash ./run_all.sh
```

Per-config logs land in `verification/logs/<lane>_<config>.log`.

### Option B — `xsim` (Vivado built-in, native `DSP48E2` model)

If you already have Vivado installed (you'll need it for synthesis anyway),
`xsim` ships with it and supports `DSP48E2` natively, so no behavioural stub
is needed. Useful when verifying tricky DSP-specific corner cases.

```bash
source <YOUR_XILINX_INSTALL>/Vitis/2022.2/settings64.sh   # or Vivado/...

cd <repo>/verification
LANE=2lane CFG=int_fp16_fp32

xvlog -sv ../common/dsp_usage.v $(find ../mac_cores -name '*.v') \
            ../mac_configs/$LANE/$CFG/rtl/*.v \
            ../mac_configs/$LANE/$CFG/tb/tb_mac.v
xvlog $XILINX_VIVADO/data/verilog/src/glbl.v
xelab -L unisims_ver -L secureip -timescale 1ns/1ps tb_mac glbl -snapshot s
xsim s -R | grep -E "RESULT|CMP="
```

The `runtime_reconfig/` testbenches use this same xsim flow (see their
top-level RTL — they pull in real `DSP48E2` directly).

---

## 6. Running Synthesis (Vivado)

Targets: `xcu55c-fsvh2892-2L-e`, `period = 2.222 ns` (450 MHz target).

**Prerequisite**: Vivado 2022.2 (or compatible) must be on the `PATH`.
Source the Xilinx environment script that ships with your install. For example:

```bash
# Adjust the path to match your Vivado install
source <YOUR_XILINX_INSTALL>/Vitis/2022.2/settings64.sh
# or
source <YOUR_XILINX_INSTALL>/Vivado/2022.2/settings64.sh
```

Then from any clone of this repo:

```bash
cd <repo>/verification

# Synth one variant (4c / 5c / 6c)
bash ./run_one_synth.sh 2lane int_fp16_fp32 4c

# Sweep all configs × all 3 variants
bash ./sweep_all.sh
```

The scripts auto-detect their own location (`ROOT="$(cd "$(dirname ...)/.." && pwd)"`),
so the repo can live anywhere on disk.

`run_one_synth.sh` honors three optional environment variables:

| Var | Default | Purpose |
|---|---|---|
| `PERIOD_NS` | `2.222` | Clock period in ns (e.g. `2.0` for a 500 MHz target). |
| `CSV_OUT` | `verification/synth_all.csv` | Where to append the result row. |
| `TAG` | (empty) | Suffix for the run directory under `verification/runs/` so a re-run with a different `PERIOD_NS` does not stomp the previous build. |

Example — sweep one config at 500 MHz target into a separate CSV:
```bash
PERIOD_NS=2.0 CSV_OUT=$PWD/synth_500mhz.csv TAG=_500 \
    bash ./run_one_synth.sh 1lane fp16_fp16_fp16 6c
```

Each run drops a project under `verification/runs/<lane>_<config>_<variant>/` and appends one row to `verification/synth_all.csv`:

```
OK|2lane|int_fp16_fp32|4c|int_fp16_fp32_mac_4c|1054|377|1|-1.866|244.62
^^ status / lane / config / variant / top / LUT / FF / DSP / WNS(ns) / Fmax(MHz)
```

---

## 7. Pre-computed Results

`verification/synth_all.csv` already contains LUT / FF / DSP / Fmax for every (lane, config, variant) — 51 configs × 3 variants = 153 rows.

Quick view of the 4c-variant headline numbers (4-cycle, fastest area):

| Group | Config | LUT | FF | DSP | Fmax (MHz) |
|---|---|---|---|---|---|
| Same precision | INT8×INT8+INT32 | 93 | 316 | 1 | 538 |
|  | FP16×FP16+FP16 | 215 | 150 | 1 | 320 |
|  | BF16×BF16+BF16 | 396 | 242 | 1 | 375 |
|  | FP16×FP16+FP32 | 542 | 184 | 1 | 270 |
|  | BF16×BF16+FP32 | 1119 | 396 | 1 | 209 |
| 2-lane × FP16 | INT×FP16+FP16 | 540 | 273 | 1 | 268 |
|  | INT×FP16+FP32 | 1054 | 377 | 1 | 245 |
|  | FP8e4m3×FP16+FP16 | 505 | 265 | 1 | 283 |
|  | FP8e4m3×FP16+FP32 | 1002 | 369 | 1 | 255 |
|  | FP8e5m2×FP16+FP32 | 974 | 371 | 1 | 262 |
|  | FP4×FP16+FP32 | 1001–1007 | 363–367 | 1 | 244–253 |
| 4-lane × FP8 | FP8×FP8+FP8 | 414–422 | 268–276 | 1 | 367–452 |
|  | FP8×FP8+FP16 | 769–810 | 468–472 | 1 | 275–290 |
|  | INT4×FP8+FP8 | 420–421 | 262–268 | 1 | 363–446 |
|  | INT4×FP8+FP16 | 788–823 | 456–462 | 1 | 289–290 |

All entries: **DSP = 1**. Numbers above are at the default 450 MHz target (period 2.222 ns).

### Pushing the clock harder (500 MHz target)

Re-running synthesis with `PERIOD_NS=2.0` (500 MHz target) lets Vivado work
the critical paths harder. Results captured in `verification/synth_500mhz.csv`
(12 rows, 4 base configs × 3 variants).

Best-of (achieved Fmax @ target that produced it):

| Config | 4c | 5c | 6c |
|---|---|---|---|
| FP16×FP16+FP16 → FP16 | 320.1@450MHz | 452.5@500MHz | **500.5@500MHz** |
| FP16×FP16+FP32 → FP32 | 270.1@450MHz | 276.1@500MHz | 276.2@500MHz |
| BF16×BF16+BF16 → BF16 | 374.7@450MHz | 409.0@500MHz | **495.3@500MHz** |
| BF16×BF16+FP32 → FP32 | 208.6@450MHz | 211.4@500MHz | 264.6@500MHz |

Takeaways:
- **6c hits ~500 MHz** on same-precision paths (BF16/BF16/BF16 and FP16/FP16/FP16) when targeted at 500 MHz.
- **5c also benefits** modestly from the tighter target.
- **4c stays at the 450 MHz target** — pushing harder can backfire (e.g. BF16+BF16 4c collapses from 375 → 192 MHz because the shallow pipeline cannot be split further).
- **+FP32 paths** are limited by the FP32 adder depth; tighter target only buys a few MHz, going past ~280 MHz needs a deeper variant (7c+).

---

## 8. Equivalence with v1 Reference RTL

The flat library under `mac_cores/` is **bit-exact equivalent** to the v1.0
RTL preserved verbatim under `User_spec/library/rtl/` (NVIDIA-style FTZ/DAZ
+ RN-even). The 4c wrapper of every config produces identical outputs to
its v1 counterpart on identical inputs (verified across all 51 configs
via `verification/run_all.sh`).

Typical LUT savings of the v2 flat library vs. the v1 RTL: **40–200 LUT
per config**, average ≈ 85 LUT, total ≈ 3400 LUT across 40 configs.
Sources of savings:

1. `fp32_add` / `fp16_add` instantiated with `SATURATE_ON_MAX = 0` and `INF_CANCELLATION_TO_NAN = 0`. These flags add corner-case logic that **violates** the stated RN-even requirement, so disabling them is both **smaller** and **more correct**.
2. Removed dead `overflow / underflow` comparators in compose path — for INT/FP4/FP8 × FP16 → FP32 the product exponent is provably bounded inside FP32 normal range.
3. Parameterized `LATENCY` on adders enables saving one register stage in the 4c variant.

---

## 9. Adding a New Config

1. Drop a new mac core under `mac_cores/mixed_precision/<your_config>_mac.v`
   following the pattern of e.g. `int_fp16_fp32_mac.v`:
   - decode each lane,
   - DSP-pack mantissas onto a 27-bit A port,
   - compose FP product per lane,
   - feed into `fp32_add` / `fp16_add` / etc.

2. Create `mac_configs/<lane>/<your_config>/rtl/mac_{4c,5c,6c}.v`
   that instantiate the core with the three (MUL_LAT, MID_STAGES, ADD_LAT) tuples.

3. Create `mac_configs/<lane>/<your_config>/tb/tb_mac.v` — copy a similar
   existing TB and adjust port widths.

4. Verify and synth:

   ```bash
   bash ./run_one.sh <lane> <your_config>
   bash ./run_one_synth.sh <lane> <your_config> 4c
   ```

---

## 10. Runtime-Reconfigurable Designs (`runtime_reconfig/`)

Four shared-DSP MACs that switch their datatype at runtime via a single mode bit:

| Folder | Top module | Mode 0 | Mode 1 |
|---|---|---|---|
| `a_bf16_int4_shared/` | `bf16_int4_shared_mac` | 2-lane BF16×BF16+BF16 | 2-lane INT4×BF16+BF16 |
| `b_int8_bf16_dual/`   | `int8_bf16_mac`        | 2-lane BF16×BF16+BF16 | 2-lane INT8×INT8+INT32 (sat-add) |
| `c_fp8_bf16_dual/`    | `fp8_bf16_dual_mac`    | 2-lane BF16×BF16+BF16 | 4-lane FP8e4m3×FP8e4m3+BF16 |
| `d_bf16_fp4_dual/`    | `bf16_fp4_dual_mac`    | 2-lane BF16×BF16+BF16 | 2-lane FP4e2m1×BF16+BF16 |

Each design ships with `mac_4c.v / mac_5c.v / mac_6c.v` wrappers and a unified
`tb/tb_mac.v` that verifies all three pipeline variants are bit-exact equivalent.

Pipeline parameterization mirrors the main library:

| Variant | (MUL_LAT, MID_STAGES, ADD_LAT) |
|---|---|
| 4c | original LUT-optimized RTL (kept verbatim from `*_orig4c` modules) |
| 5c | parameterized core with `bf16_add` LATENCY = 3 |
| 6c | parameterized core with MID_STAGES = 1 + LATENCY = 3 |

### Resource summary

`runtime_reconfig/synth_results.csv` reports:

- **LUT / FF / DSP** — post-synth utilization (matches the XtraMAC paper convention)
- **Fmax / WNS** — post-route timing at 2.222 ns target (450 MHz)

| Design | 4c LUT | 5c LUT | 6c LUT | 4c Fmax | 5c Fmax | 6c Fmax |
|---|---|---|---|---|---|---|
| A bf16_int4_shared | 434 | 472 | 463 | 296 | 392 | **460** |
| B int8_bf16_dual   | 569 | 628 | 693 | 286 | 364 | 399 |
| C fp8_bf16_dual    | 948 | 1100 | 995 | 273 | 373 | 375 |
| D bf16_fp4_dual    | 395 | 464 | 455 | 267 | 402 | **451** |

All 12 variants use exactly **1 DSP**.

---

## 11. Toolchain

- Simulation:
  - **Icarus Verilog (iverilog)** ≥ 11 — uses behavioural DSP stub (`verification/dsp_usage_sim.v`), free & lightweight
  - **`xsim`** (bundled with Vivado) — native `DSP48E2` model, no stub needed
- Synthesis: **Xilinx Vivado 2022.2** (other 2022/2023 versions should also work)
- Target part: `xcu55c-fsvh2892-2L-e` (Alveo U55C)
- Clock target: 450 MHz (period 2.222 ns)

### Environment setup (one-time per shell)

```bash
# 1) Install or locate iverilog (Ubuntu: sudo apt install iverilog)
which iverilog        # should print a path

# 2) Source your local Vivado settings script (path differs per install)
source <YOUR_XILINX_INSTALL>/Vitis/2022.2/settings64.sh
which vivado          # should print a path
```

The repo's scripts auto-detect their own location, so you can clone or extract
the folder anywhere on disk and run from inside it.
