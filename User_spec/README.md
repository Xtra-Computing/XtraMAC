## User-Specified MAC Bundle Generator

Use `generate_mac_bundle.py` to copy a ready-to-build RTL + testbench bundle for any
of the supported MAC data-type combinations. All required source files already live
under `User_spec/library`, so you can move this folder elsewhere and the script will
continue to work offline. It automatically pulls the right helper modules
(`fp16_add.v`, `bf16_mac.v`, `dsp48e2_mac.v`, etc.) and matching self-checking
testbenches for each top-level MAC.

### Quick start

```bash
cd <repo>/User_spec

# Inspect the available combinations (IDs + specs)
python3 generate_mac_bundle.py --list

# Example 1: request the BF16*BF16+BF16 MAC by ID
python3 generate_mac_bundle.py 1

# Example 1b: same request but drop files into ./bf16_bundle directly
python3 generate_mac_bundle.py 1 ./bf16_bundle

# Example 2: bundle the FP8(E4M3) * FP8(E4M3) + FP8 MAC by spec string
python3 generate_mac_bundle.py "FP8e4m3*FP8e4m3+FP8e4m3"
```

Each invocation creates `User_spec/exports/<module>/` with:

- `rtl/` – the requested top-level module plus every required helper file
- `tb/` – the matching self-checking testbench
- `manifest.json` – provenance information (requested spec, module, file list)

Use `./generate_mac_bundle.py <spec> <path>` shorthand (e.g. `python3 generate_mac_bundle.py 1 ./bf16`)
or pass `--dest <path>` to redirect the output somewhere else (default is
`./User_spec/exports`), and `--force` to overwrite an existing bundle for the same
module.

Specification strings are case-insensitive and may include spaces; for example,
`"int8 * FP16 + FP32"` resolves to `int8_fp16_32_mac`. You can also pass the
module name itself (e.g. `fp16_mac` or `int8_fp16_32_mac`) or the numeric ID shown by
`--list`. Run `--list` at any time to see the canonical strings and descriptions.

### Supported MAC combinations

The current database covers exactly these 20 data-type mixes (IDs correspond to
`--list` output):

1. Dual-lane BF16 × BF16 + BF16
2. Dual-lane BF16 × BF16 + FP32
3. FP16 × FP16 + FP16
4. FP16 × FP16 + FP32
5. FP12 × FP12 + FP12
6. FP9 × FP9 + FP9
7. FP8(E4M3) × FP8(E4M3) + FP8
8. FP8(E4M3) lanes × FP16 + FP16
9. FP8(E4M3) lanes × FP16 + FP32
10. FP8(E4M3) lanes × BF16 + BF16
11. FP8(E4M3) lanes × BF16 + FP32
12. FP8(E5M2) × FP8(E5M2) + FP8
13. FP8(E5M2) lanes × FP16 + FP16
14. FP8(E5M2) lanes × FP16 + FP32
15. FP8(E5M2) lanes × BF16 + BF16
16. FP8(E5M2) lanes × BF16 + FP32
17. INT8 lanes × FP16 + FP16
18. INT8 lanes × FP16 + FP32
19. INT8 lanes × BF16 + BF16
20. INT8 lanes × BF16 + FP32
21. FP8(E4M3) × FP8(E4M3) + FP16
22. FP8(E5M2) × FP8(E5M2) + FP16
23. FP4(E1M2) × FP8(E4M3) + FP8(E4M3)
24. FP4(E2M1) × FP8(E4M3) + FP8(E4M3)
25. FP4(E3M0) × FP8(E4M3) + FP8(E4M3)
26. FP4(E1M2) × FP8(E4M3) + FP16
27. FP4(E2M1) × FP8(E4M3) + FP16
28. FP4(E3M0) × FP8(E4M3) + FP16
29. FP4(E1M2) × FP8(E5M2) + FP8(E5M2)
30. FP4(E2M1) × FP8(E5M2) + FP8(E5M2)
31. FP4(E3M0) × FP8(E5M2) + FP8(E5M2)
32. FP4(E1M2) × FP8(E5M2) + FP16
33. FP4(E2M1) × FP8(E5M2) + FP16
34. FP4(E3M0) × FP8(E5M2) + FP16
35. FP4(E2M1) × FP16 + FP16
36. FP4(E2M1) × BF16 + BF16
37. INT4 lanes × FP8(E4M3) + FP8(E4M3)
38. INT4 lanes × FP8(E4M3) + FP16
39. INT4 lanes × FP8(E5M2) + FP8(E5M2)
40. INT4 lanes × FP8(E5M2) + FP16
41. FP4(E3M0) × FP16 + FP16
42. FP4(E1M2) × FP16 + FP16
43. FP4(E3M0) × BF16 + BF16
44. FP4(E1M2) × BF16 + BF16
