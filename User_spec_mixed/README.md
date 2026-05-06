## Mixed-Mode MAC Bundle Generator

This folder mirrors the dual-mode MACs from `runtime_reconfig/a_bf16_int4_shared`
(BF16/INT4) and `runtime_reconfig/b_int8_bf16_dual` (BF16/INT8). All
RTL/testbench sources are copied into `User_spec_mixed/library`, so you can
move this folder elsewhere and still bundle the designs.

Run `generate_mixed_mac_bundle.py` to copy the requested RTL + TB bundle.

```bash
cd <repo>/User_spec_mixed

# List available bundles (ID + description)
python3 generate_mixed_mac_bundle.py --list

# Example: copy the BF16/INT4 shared MAC into ./exports (default)
python3 generate_mixed_mac_bundle.py 1

# Example: copy the INT8/BF16 shared MAC into ~/tmp/mixed_mac
python3 generate_mixed_mac_bundle.py 2 --dest ~/tmp/mixed_mac
```

Each bundle contains:

- `rtl/` – top module plus all dependent RTL files (mappers, adders, DSP wrappers)
- `tb/`  – the corresponding self-checking testbench
- `manifest.json` – provenance information (requested spec, files included)

### Supported bundles

1. `bf16_int4_shared_mac`: two-lane BF16×BF16+BF16 or INT4×BF16+BF16 (mode-controlled)
2. `int8_bf16_mac`: INT8×INT8 with INT32 accumulation, or BF16×BF16 + BF16 (mode-controlled)
3. `fp8_bf16_dual_mac`: FP8(E4M3)×FP8(E4M3) widened to BF16, or native BF16×BF16 (mode-controlled)
4. `bf16_fp4_dual_mac`: BF16×BF16 or FP4(E2M1) inputs widened to BF16 and accumulated
