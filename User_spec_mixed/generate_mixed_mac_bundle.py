#!/usr/bin/env python3
"""
Bundle generator for mixed-precision MAC designs (see `runtime_reconfig/`).

Copies the requested RTL + testbench files from User_spec_mixed/library into
an exports directory (or user-specified folder).
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Dict, List

SCRIPT_DIR = Path(__file__).resolve().parent
LIB_RTL = SCRIPT_DIR / "library" / "rtl"
LIB_TB = SCRIPT_DIR / "library" / "tb"
DEFAULT_DEST = SCRIPT_DIR / "exports"


def entry(entry_id: int, module: str, description: str, specs: List[str],
          rtl_files: List[str], tb_files: List[str]) -> Dict[str, object]:
    return {
        "id": entry_id,
        "module": module,
        "description": description,
        "specs": specs,
        "rtl": rtl_files,
        "tb": tb_files,
    }


DATABASE = [
    entry(
        entry_id=1,
        module="bf16_int4_shared_mac",
        description="Dual-mode BF16×BF16 or INT4×BF16 MAC with shared DSP",
        specs=["bf16_int4_shared", "bf16*bf16/int4*bf16", "int4_bf16_mac"],
        rtl_files=[
            "bf16_int4_shared_mac.v",
            "bf16_mac.v",
            "bf16_add.v",
            "dsp48e2_mac.v",
        ],
        tb_files=["tb_bf16_int4_shared_mac.v"],
    ),
    entry(
        entry_id=2,
        module="int8_bf16_mac",
        description="Dual-mode INT8×INT8 (INT16 accumulate) / BF16×BF16 MAC",
        specs=["int8_bf16_shared", "int8*int8/bf16*bf16", "int8_bf16_mac"],
        rtl_files=[
            "int8_bf16_mac.v",
            "mac_mapper_int8.v",
            "mac_mapper_bf16.v",
            "mac_postproc_int8.v",
            "mac_postproc_bf16.v",
            "int8_add.v",
            "bf16_add.v",
            "bf16_mac.v",
            "dsp_usage.v",
        ],
        tb_files=["tb_int8_bf16_mac.v"],
    ),
    entry(
        entry_id=3,
        module="fp8_bf16_dual_mac",
        description="Dual-mode FP8(E4M3) × FP8(E4M3) or BF16 × BF16 MAC",
        specs=["fp8_bf16_dual", "fp8*fp8/bf16*bf16", "fp8_bf16_mac"],
        rtl_files=[
            "fp8_bf16_dual_mac.v",
            "fp8_mac_s1_prep.v",
            "fp8_mac_postproc.v",
            "fp8e4m3_bf16_mac.v",
            "bf16_mac.v",
            "bf16_add.v",
            "dsp48e2_mac.v",
        ],
        tb_files=["tb_fp8_bf16_dual_mac.v"],
    ),
    entry(
        entry_id=4,
        module="bf16_fp4_dual_mac",
        description="Dual-mode BF16×BF16 or FP4(E2M1)×BF16 MAC",
        specs=["bf16_fp4_dual", "fp4*bf16", "bf16_fp4_mac"],
        rtl_files=[
            "bf16_fp4_dual_mac.v",
            "fp4e2m1_bf16_mac.v",
            "bf16_mac.v",
            "bf16_add.v",
            "dsp48e2_mac.v",
        ],
        tb_files=["bf16_fp4_dual_mac_tb.v"],
    ),
]


def normalize(token: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", token.lower())


def build_index():
    idx: Dict[str, Dict[str, object]] = {}
    for item in DATABASE:
        idx[str(item["id"])] = item
        for alias in item["specs"]:
            idx[normalize(alias)] = item
    return idx


def unique(seq: List[str]) -> List[str]:
    seen = set()
    out = []
    for entry in seq:
        if entry not in seen:
            seen.add(entry)
            out.append(entry)
    return out


def copy_bundle(item: Dict[str, object], dest: Path, requested: str, force: bool):
    bundle_dir = dest / item["module"]
    if bundle_dir.exists():
        if not force:
            raise FileExistsError(f"{bundle_dir} already exists; use --force to overwrite.")
        shutil.rmtree(bundle_dir)
    rtl_dir = bundle_dir / "rtl"
    tb_dir = bundle_dir / "tb"
    rtl_dir.mkdir(parents=True, exist_ok=True)
    tb_dir.mkdir(parents=True, exist_ok=True)

    copied_rtl = []
    for filename in unique(item["rtl"]):
        src = LIB_RTL / filename
        if not src.exists():
            raise FileNotFoundError(f"Missing RTL source: {src}")
        shutil.copy2(src, rtl_dir / filename)
        copied_rtl.append(f"rtl/{filename}")

    copied_tb = []
    for filename in unique(item["tb"]):
        src = LIB_TB / filename
        if not src.exists():
            raise FileNotFoundError(f"Missing TB source: {src}")
        shutil.copy2(src, tb_dir / filename)
        copied_tb.append(f"tb/{filename}")

    manifest = {
        "requested": requested,
        "module": item["module"],
        "description": item["description"],
        "rtl_files": copied_rtl,
        "tb_files": copied_tb,
    }
    with open(bundle_dir / "manifest.json", "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)

    return bundle_dir


def list_modules():
    print("Available mixed-precision MAC bundles:\n")
    for item in DATABASE:
        print(f"  {item['id']:>2}  {item['module']:<24} {item['description']}")


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Copy mixed-precision MAC RTL + TB bundles.")
    parser.add_argument("spec", nargs="*", help="Module ID or alias (use --list to see options).")
    parser.add_argument("--dest", type=Path, default=None,
                        help="Destination directory (default: ./exports).")
    parser.add_argument("--force", action="store_true", help="Overwrite existing bundle folders.")
    parser.add_argument("--list", action="store_true", help="List supported bundles and exit.")
    args = parser.parse_args(argv)

    index = build_index()
    if args.list:
        list_modules()
        return 0

    if not args.spec:
        parser.error("Please provide an ID/name or use --list.")

    dest = args.dest or DEFAULT_DEST
    dest.mkdir(parents=True, exist_ok=True)

    for token in args.spec:
        key = token if token.isdigit() else normalize(token)
        item = index.get(key)
        if not item:
            raise SystemExit(f"Unknown spec '{token}'. Use --list for valid options.")
        bundle_dir = copy_bundle(item, dest, token, args.force)
        print(f"[ok] {token} -> {item['module']} at {bundle_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
