#!/usr/bin/env python3
"""
Spec-driven MAC bundle generator.

Given a textual description such as "FP8e4m3*FP8e4m3+FP8e4m3", copy the
corresponding RTL module (including its helper submodules) and the matching
testbench into User_spec/exports/<module>.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Dict, List

REPO_ROOT = Path(__file__).resolve().parents[1]
LIB_ROOT = Path(__file__).resolve().parent / "library"
SRC_DIR = LIB_ROOT / "rtl"
SIM_DIR = LIB_ROOT / "tb"
DEFAULT_DEST = Path(__file__).resolve().parent / "exports"


def _spec_entry(
    entry_id: int,
    module: str,
    description: str,
    specs: List[str],
    rtl_files: List[str],
    tb_files: List[str],
) -> Dict[str, object]:
    return {
        "id": entry_id,
        "module": module,
        "description": description,
        "specs": specs,
        "rtl": rtl_files,
        "tb": tb_files,
    }


MODULE_DATABASE = [
    _spec_entry(
        entry_id=1,
        module="bf16_mac",
        description="Dual-lane BF16 * BF16 + BF16",
        specs=["bf16*bf16+bf16", "bf16_mac", "bf16"],
        rtl_files=["bf16_mac.v", "bf16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_bf16_mac.v"],
    ),
    _spec_entry(
        entry_id=2,
        module="bf16_32_mac",
        description="Dual-lane BF16 * BF16 + FP32",
        specs=["bf16*bf16+fp32", "bf16_32_mac"],
        rtl_files=["bf16_32_mac.v", "fp16_32_mac.v", "dsp48e2_mac.v"],
        tb_files=["tb_bf16_32_mac.v"],
    ),
    _spec_entry(
        entry_id=3,
        module="fp16_mac",
        description="FP16 * FP16 + FP16 (4-cycle pipeline)",
        specs=["fp16*fp16+fp16", "fp16_mac"],
        rtl_files=["fp16_mac.v", "fp16_mul.v", "fp16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp16_mac.v"],
    ),
    _spec_entry(
        entry_id=4,
        module="fp16_32_mac",
        description="FP16 * FP16 + FP32 (widened accumulator)",
        specs=["fp16*fp16+fp32", "fp16_32_mac"],
        rtl_files=["fp16_32_mac.v"],
        tb_files=["tb_fp16_32_mac.v"],
    ),
    _spec_entry(
        entry_id=5,
        module="fp12_mac",
        description="Dual-lane FP12 * FP12 + FP12",
        specs=["fp12*fp12+fp12", "fp12_mac", "fp12"],
        rtl_files=["fp12_mac.v", "fp12_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp12_mac.v"],
    ),
    _spec_entry(
        entry_id=6,
        module="fp9_mac",
        description="Quad-lane FP9 (E4M4) * FP9 + FP9",
        specs=["fp9*fp9+fp9", "fp9_mac", "fp9"],
        rtl_files=["fp9_mac.v", "fp9_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp9_mac.v"],
    ),
    _spec_entry(
        entry_id=7,
        module="fp8e4m3_mac",
        description="Quad-lane FP8(E4M3) * FP8(E4M3) + FP8",
        specs=["fp8e4m3*fp8e4m3+fp8e4m3", "fp8e4m3_mac", "fp8e4m3"],
        rtl_files=["fp8e4m3_mac.v", "fp8e4m3_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e4m3_mac.v"],
    ),
    _spec_entry(
        entry_id=8,
        module="fp8e4m3_fp16_mac",
        description="FP8(E4M3) lanes * FP16 + FP16",
        specs=["fp8e4m3*fp16+fp16", "fp8e4m3_fp16_mac"],
        rtl_files=["fp8e4m3_fp16_mac.v", "fp16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e4m3_fp16_mac.v"],
    ),
    _spec_entry(
        entry_id=9,
        module="fp8e4m3_fp16_32_mac",
        description="FP8(E4M3) lanes * FP16 + FP32",
        specs=["fp8e4m3*fp16+fp32", "fp8e4m3_fp16_32_mac"],
        rtl_files=["fp8e4m3_fp16_32_mac.v", "fp16_32_mac.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e4m3_fp16_32_mac.v"],
    ),
    _spec_entry(
        entry_id=10,
        module="fp8e4m3_bf16_mac",
        description="FP8(E4M3) lanes * BF16 + BF16",
        specs=["fp8e4m3*bf16+bf16", "fp8e4m3_bf16_mac"],
        rtl_files=["fp8e4m3_bf16_mac.v", "bf16_mac.v", "bf16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e4m3_bf16_mac.v"],
    ),
    _spec_entry(
        entry_id=11,
        module="fp8e4m3_bf16_32_mac",
        description="FP8(E4M3) lanes * BF16 + FP32",
        specs=["fp8e4m3*bf16+fp32", "fp8e4m3_bf16_32_mac"],
        rtl_files=[
            "fp8e4m3_bf16_32_mac.v",
            "bf16_32_mac.v",
            "fp16_32_mac.v",
            "dsp48e2_mac.v",
        ],
        tb_files=["tb_fp8e4m3_bf16_32_mac.v"],
    ),
    _spec_entry(
        entry_id=12,
        module="fp8e5m2_mac",
        description="Quad-lane FP8(E5M2) * FP8(E5M2) + FP8",
        specs=["fp8e5m2*fp8e5m2+fp8e5m2", "fp8e5m2_mac", "fp8e5m2"],
        rtl_files=["fp8e5m2_mac.v", "fp8e5m2_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e5m2_mac.v"],
    ),
    _spec_entry(
        entry_id=13,
        module="fp8e5m2_fp16_mac",
        description="FP8(E5M2) lanes * FP16 + FP16",
        specs=["fp8e5m2*fp16+fp16", "fp8e5m2_fp16_mac"],
        rtl_files=["fp8e5m2_fp16_mac.v", "fp16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e5m2_fp16_mac.v"],
    ),
    _spec_entry(
        entry_id=14,
        module="fp8e5m2_fp16_32_mac",
        description="FP8(E5M2) lanes * FP16 + FP32",
        specs=["fp8e5m2*fp16+fp32", "fp8e5m2_fp16_32_mac"],
        rtl_files=["fp8e5m2_fp16_32_mac.v", "fp16_32_mac.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e5m2_fp16_32_mac.v"],
    ),
    _spec_entry(
        entry_id=15,
        module="fp8e5m2_bf16_mac",
        description="FP8(E5M2) lanes * BF16 + BF16",
        specs=["fp8e5m2*bf16+bf16", "fp8e5m2_bf16_mac"],
        rtl_files=["fp8e5m2_bf16_mac.v", "bf16_mac.v", "bf16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e5m2_bf16_mac.v"],
    ),
    _spec_entry(
        entry_id=16,
        module="fp8e5m2_bf16_32_mac",
        description="FP8(E5M2) lanes * BF16 + FP32",
        specs=["fp8e5m2*bf16+fp32", "fp8e5m2_bf16_32_mac"],
        rtl_files=[
            "fp8e5m2_bf16_32_mac.v",
            "bf16_32_mac.v",
            "fp16_32_mac.v",
            "dsp48e2_mac.v",
        ],
        tb_files=["tb_fp8e5m2_bf16_32_mac.v"],
    ),
    _spec_entry(
        entry_id=17,
        module="int8_fp16_mac",
        description="INT8 lanes * FP16 + FP16",
        specs=["int8*fp16+fp16", "int8_fp16_mac"],
        rtl_files=["int8_fp16_mac.v", "fp16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_int8_fp16_mac.v"],
    ),
    _spec_entry(
        entry_id=18,
        module="int8_fp16_32_mac",
        description="INT8 lanes * FP16 + FP32",
        specs=["int8*fp16+fp32", "int8_fp16_32_mac"],
        rtl_files=["int8_fp16_32_mac.v", "fp16_32_mac.v", "dsp48e2_mac.v"],
        tb_files=["tb_int8_fp16_32_mac.v"],
    ),
    _spec_entry(
        entry_id=19,
        module="int8_bf16_mac",
        description="INT8 lanes * BF16 + BF16",
        specs=["int8*bf16+bf16", "int8_bf16_mac"],
        rtl_files=["int8_bf16_mac.v", "bf16_mac.v", "bf16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_int8_bf16_mac.v"],
    ),
    _spec_entry(
        entry_id=20,
        module="int8_bf16_32_mac",
        description="INT8 lanes * BF16 + FP32",
        specs=["int8*bf16+fp32", "int8_bf16_32_mac"],
        rtl_files=[
            "int8_bf16_32_mac.v",
            "bf16_32_mac.v",
            "fp16_32_mac.v",
            "dsp48e2_mac.v",
        ],
        tb_files=["tb_int8_bf16_32_mac.v"],
    ),
    _spec_entry(
        entry_id=21,
        module="fp8e4m3_16_mac",
        description="FP8(E4M3) * FP8(E4M3) + FP16",
        specs=["fp8e4m3*fp8e4m3+fp16", "fp8e4m3_16_mac"],
        rtl_files=["fp8e4m3_16_mac.v", "fp16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e4m3_16_mac.v"],
    ),
    _spec_entry(
        entry_id=22,
        module="fp8e5m2_16_mac",
        description="FP8(E5M2) * FP8(E5M2) + FP16",
        specs=["fp8e5m2*fp8e5m2+fp16", "fp8e5m2_16_mac"],
        rtl_files=["fp8e5m2_16_mac.v", "fp16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp8e5m2_16_mac.v"],
    ),
    _spec_entry(
        entry_id=23,
        module="fp4e1m2_fp8e4m3_mac",
        description="FP4(E1M2) lanes * FP8(E4M3) + FP8(E4M3)",
        specs=["fp4e1m2*fp8e4m3+fp8e4m3", "fp4e1m2_fp8e4m3_mac"],
        rtl_files=[
            "fp4e1m2_fp8e4m3_mac.v",
            "fp4_fp8e4m3_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=["tb_fp4e1m2_fp8e4m3_mac.v"],
    ),
    _spec_entry(
        entry_id=24,
        module="fp4e2m1_fp8e4m3_mac",
        description="FP4(E2M1) lanes * FP8(E4M3) + FP8(E4M3)",
        specs=["fp4e2m1*fp8e4m3+fp8e4m3", "fp4e2m1_fp8e4m3_mac"],
        rtl_files=[
            "fp4e2m1_fp8e4m3_mac.v",
            "fp4_fp8e4m3_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=["tb_fp4e2m1_fp8e4m3_mac.v"],
    ),
    _spec_entry(
        entry_id=25,
        module="fp4e3m0_fp8e4m3_mac",
        description="FP4(E3M0) lanes * FP8(E4M3) + FP8(E4M3)",
        specs=["fp4e3m0*fp8e4m3+fp8e4m3", "fp4e3m0_fp8e4m3_mac"],
        rtl_files=[
            "fp4e3m0_fp8e4m3_mac.v",
            "fp4_fp8e4m3_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=["tb_fp4e3m0_fp8e4m3_mac.v"],
    ),
    _spec_entry(
        entry_id=26,
        module="fp4e1m2_fp8e4m3_16_mac",
        description="FP4(E1M2) lanes * FP8(E4M3) + FP16",
        specs=["fp4e1m2*fp8e4m3+fp16", "fp4e1m2_fp8e4m3_16_mac"],
        rtl_files=[
            "fp4e1m2_fp8e4m3_16_mac.v",
            "fp4_fp8e4m3_16_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=[
            "tb_fp4e1m2_fp8e4m3_16_mac.v",
            "tb_fp4_fp8e4m3_16_mac_base.v",
        ],
    ),
    _spec_entry(
        entry_id=27,
        module="fp4e2m1_fp8e4m3_16_mac",
        description="FP4(E2M1) lanes * FP8(E4M3) + FP16",
        specs=["fp4e2m1*fp8e4m3+fp16", "fp4e2m1_fp8e4m3_16_mac"],
        rtl_files=[
            "fp4e2m1_fp8e4m3_16_mac.v",
            "fp4_fp8e4m3_16_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=[
            "tb_fp4e2m1_fp8e4m3_16_mac.v",
            "tb_fp4_fp8e4m3_16_mac_base.v",
        ],
    ),
    _spec_entry(
        entry_id=28,
        module="fp4e3m0_fp8e4m3_16_mac",
        description="FP4(E3M0) lanes * FP8(E4M3) + FP16",
        specs=["fp4e3m0*fp8e4m3+fp16", "fp4e3m0_fp8e4m3_16_mac"],
        rtl_files=[
            "fp4e3m0_fp8e4m3_16_mac.v",
            "fp4_fp8e4m3_16_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=[
            "tb_fp4e3m0_fp8e4m3_16_mac.v",
            "tb_fp4_fp8e4m3_16_mac_base.v",
        ],
    ),
    _spec_entry(
        entry_id=29,
        module="fp4e1m2_fp8e5m2_mac",
        description="FP4(E1M2) lanes * FP8(E5M2) + FP8(E5M2)",
        specs=["fp4e1m2*fp8e5m2+fp8e5m2", "fp4e1m2_fp8e5m2_mac"],
        rtl_files=[
            "fp4e1m2_fp8e5m2_mac.v",
            "fp4_fp8e5m2_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=["tb_fp4e1m2_fp8e5m2_mac.v"],
    ),
    _spec_entry(
        entry_id=30,
        module="fp4e2m1_fp8e5m2_mac",
        description="FP4(E2M1) lanes * FP8(E5M2) + FP8(E5M2)",
        specs=["fp4e2m1*fp8e5m2+fp8e5m2", "fp4e2m1_fp8e5m2_mac"],
        rtl_files=[
            "fp4e2m1_fp8e5m2_mac.v",
            "fp4_fp8e5m2_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=["tb_fp4e2m1_fp8e5m2_mac.v"],
    ),
    _spec_entry(
        entry_id=31,
        module="fp4e3m0_fp8e5m2_mac",
        description="FP4(E3M0) lanes * FP8(E5M2) + FP8(E5M2)",
        specs=["fp4e3m0*fp8e5m2+fp8e5m2", "fp4e3m0_fp8e5m2_mac"],
        rtl_files=[
            "fp4e3m0_fp8e5m2_mac.v",
            "fp4_fp8e5m2_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=["tb_fp4e3m0_fp8e5m2_mac.v"],
    ),
    _spec_entry(
        entry_id=32,
        module="fp4e1m2_fp8e5m2_16_mac",
        description="FP4(E1M2) lanes * FP8(E5M2) + FP16",
        specs=["fp4e1m2*fp8e5m2+fp16", "fp4e1m2_fp8e5m2_16_mac"],
        rtl_files=[
            "fp4e1m2_fp8e5m2_16_mac.v",
            "fp4_fp8e5m2_16_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=[
            "tb_fp4e1m2_fp8e5m2_16_mac.v",
            "tb_fp4_fp8e5m2_16_mac_base.v",
        ],
    ),
    _spec_entry(
        entry_id=33,
        module="fp4e2m1_fp8e5m2_16_mac",
        description="FP4(E2M1) lanes * FP8(E5M2) + FP16",
        specs=["fp4e2m1*fp8e5m2+fp16", "fp4e2m1_fp8e5m2_16_mac"],
        rtl_files=[
            "fp4e2m1_fp8e5m2_16_mac.v",
            "fp4_fp8e5m2_16_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=[
            "tb_fp4e2m1_fp8e5m2_16_mac.v",
            "tb_fp4_fp8e5m2_16_mac_base.v",
        ],
    ),
    _spec_entry(
        entry_id=34,
        module="fp4e3m0_fp8e5m2_16_mac",
        description="FP4(E3M0) lanes * FP8(E5M2) + FP16",
        specs=["fp4e3m0*fp8e5m2+fp16", "fp4e3m0_fp8e5m2_16_mac"],
        rtl_files=[
            "fp4e3m0_fp8e5m2_16_mac.v",
            "fp4_fp8e5m2_16_core.v",
            "fp4_fp8_mac_common.vh",
        ],
        tb_files=[
            "tb_fp4e3m0_fp8e5m2_16_mac.v",
            "tb_fp4_fp8e5m2_16_mac_base.v",
        ],
    ),
    _spec_entry(
        entry_id=35,
        module="fp4e2m1_fp16_mac",
        description="FP4(E2M1) lanes * FP16 + FP16",
        specs=["fp4e2m1*fp16+fp16", "fp4e2m1_fp16_mac"],
        rtl_files=["fp4e2m1_fp16_mac.v", "fp16_add.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp4e2m1_fp16_mac.v"],
    ),
    _spec_entry(
        entry_id=36,
        module="fp4e2m1_bf16_mac",
        description="FP4(E2M1) lanes * BF16 + BF16",
        specs=["fp4e2m1*bf16+bf16", "fp4e2m1_bf16_mac"],
        rtl_files=["fp4e2m1_bf16_mac.v", "dsp48e2_mac.v"],
        tb_files=["tb_fp4e2m1_bf16_mac.v"],
    ),
    _spec_entry(
        entry_id=37,
        module="int4_fp8e4m3_mac",
        description="INT4 lanes * FP8(E4M3) + FP8(E4M3)",
        specs=["int4*fp8e4m3+fp8e4m3", "int4_fp8e4m3_mac"],
        rtl_files=[
            "int4_fp8e4m3_mac.v",
            "int4_fp8_common.vh",
            "dsp48e2_mac.v",
        ],
        tb_files=["tb_int4_fp8e4m3_mac.v"],
    ),
    _spec_entry(
        entry_id=38,
        module="int4_fp8e4m3_16_mac",
        description="INT4 lanes * FP8(E4M3) + FP16",
        specs=["int4*fp8e4m3+fp16", "int4_fp8e4m3_16_mac"],
        rtl_files=[
            "int4_fp8e4m3_16_mac.v",
            "int4_fp8_common.vh",
            "fp16_add.v",
            "dsp48e2_mac.v",
        ],
        tb_files=["tb_int4_fp8e4m3_16_mac.v"],
    ),
    _spec_entry(
        entry_id=39,
        module="int4_fp8e5m2_mac",
        description="INT4 lanes * FP8(E5M2) + FP8(E5M2)",
        specs=["int4*fp8e5m2+fp8e5m2", "int4_fp8e5m2_mac"],
        rtl_files=[
            "int4_fp8e5m2_mac.v",
            "int4_fp8_common.vh",
            "dsp48e2_mac.v",
        ],
        tb_files=["tb_int4_fp8e5m2_mac.v"],
    ),
    _spec_entry(
        entry_id=40,
        module="int4_fp8e5m2_16_mac",
        description="INT4 lanes * FP8(E5M2) + FP16",
        specs=["int4*fp8e5m2+fp16", "int4_fp8e5m2_16_mac"],
        rtl_files=[
            "int4_fp8e5m2_16_mac.v",
            "int4_fp8_common.vh",
            "fp16_add.v",
            "dsp48e2_mac.v",
        ],
        tb_files=["tb_int4_fp8e5m2_16_mac.v"],
    ),
    _spec_entry(
        entry_id=41,
        module="fp4e3m0_fp16_mac",
        description="FP4(E3M0) lanes * FP16 + FP16",
        specs=["fp4e3m0*fp16+fp16", "fp4e3m0_fp16_mac"],
        rtl_files=["fp4e3m0_fp16_mac.v", "fp4_fp8_mac_common.vh"],
        tb_files=["tb_fp4e3m0_fp16_mac.v"],
    ),
    _spec_entry(
        entry_id=42,
        module="fp4e1m2_fp16_mac",
        description="FP4(E1M2) lanes * FP16 + FP16",
        specs=["fp4e1m2*fp16+fp16", "fp4e1m2_fp16_mac"],
        rtl_files=["fp4e1m2_fp16_mac.v", "fp4_fp8_mac_common.vh"],
        tb_files=["tb_fp4e1m2_fp16_mac.v"],
    ),
    _spec_entry(
        entry_id=43,
        module="fp4e3m0_bf16_mac",
        description="FP4(E3M0) lanes * BF16 + BF16",
        specs=["fp4e3m0*bf16+bf16", "fp4e3m0_bf16_mac"],
        rtl_files=["fp4e3m0_bf16_mac.v", "fp4_fp8_mac_common.vh"],
        tb_files=["tb_fp4e3m0_bf16_mac.v"],
    ),
    _spec_entry(
        entry_id=44,
        module="fp4e1m2_bf16_mac",
        description="FP4(E1M2) lanes * BF16 + BF16",
        specs=["fp4e1m2*bf16+bf16", "fp4e1m2_bf16_mac"],
        rtl_files=["fp4e1m2_bf16_mac.v", "fp4_fp8_mac_common.vh"],
        tb_files=["tb_fp4e1m2_bf16_mac.v"],
    ),
]


def normalize_spec(value: str) -> str:
    return re.sub(r"[^a-z0-9*+>\-]", "", value.lower())


def build_spec_map():
    spec_map: Dict[str, Dict[str, object]] = {}
    for entry in MODULE_DATABASE:
        for key in entry["specs"]:
            norm = normalize_spec(key)
            if norm in spec_map:
                raise ValueError(f"Duplicate spec mapping for '{key}' -> {norm}")
            spec_map[norm] = entry
        entry_id_key = normalize_spec(str(entry["id"]))
        if entry_id_key in spec_map and spec_map[entry_id_key] is not entry:
            raise ValueError(f"Duplicate entry id mapping for {entry['id']}")
        spec_map[entry_id_key] = entry
    return spec_map


def unique(seq: List[str]) -> List[str]:
    seen = set()
    out: List[str] = []
    for item in seq:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def copy_bundle(entry: Dict[str, object], spec: str, dest_root: Path, force: bool) -> Path:
    bundle_dir = dest_root / entry["module"]
    if bundle_dir.exists():
        if not force:
            raise FileExistsError(
                f"{bundle_dir} already exists. Use --force to overwrite."
            )
        shutil.rmtree(bundle_dir)
    rtl_dir = bundle_dir / "rtl"
    tb_dir = bundle_dir / "tb"
    rtl_dir.mkdir(parents=True, exist_ok=True)
    tb_dir.mkdir(parents=True, exist_ok=True)

    copied_rtl = []
    for rel in unique(entry["rtl"]):
        src = SRC_DIR / rel
        if not src.exists():
            raise FileNotFoundError(f"Missing RTL file: {src}")
        shutil.copy2(src, rtl_dir / src.name)
        copied_rtl.append(f"rtl/{src.name}")

    copied_tb = []
    for rel in unique(entry["tb"]):
        src = SIM_DIR / rel
        if not src.exists():
            raise FileNotFoundError(f"Missing testbench file: {src}")
        shutil.copy2(src, tb_dir / src.name)
        copied_tb.append(f"tb/{src.name}")

    manifest = {
        "requested_spec": spec,
        "matched_module": entry["module"],
        "description": entry["description"],
        "rtl_files": copied_rtl,
        "testbench_files": copied_tb,
        "source_root": str(SRC_DIR),
        "testbench_root": str(SIM_DIR),
    }
    with open(bundle_dir / "manifest.json", "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)

    return bundle_dir


def list_specs():
    rows = []
    for entry in MODULE_DATABASE:
        canonical = entry["specs"][0]
        rows.append((entry["id"], canonical, entry["module"], entry["description"]))
    width_spec = max(len(r[1]) for r in rows) + 2
    print("Available MAC specifications (ID | spec -> module):\n")
    for entry_id, spec, module, desc in rows:
        print(f"  {entry_id:>2}  {spec.ljust(width_spec)}{module:<22} {desc}")


def main(argv: List[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Bundle RTL + TB files for a given MAC data-type specification."
    )
    parser.add_argument(
        "specs",
        nargs="*",
        help="Specification string (e.g. FP8e4m3*FP8e4m3+FP8e4m3) or module name.",
    )
    parser.add_argument(
        "--dest",
        type=Path,
        default=None,
        help=f"Destination directory (default: {DEFAULT_DEST})",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite the destination module folder if it already exists.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List supported specifications and exit.",
    )

    args = parser.parse_args(argv)
    spec_map = build_spec_map()

    if args.list:
        list_specs()
        return 0

    if not args.specs:
        parser.error("Please provide at least one spec string or use --list.")

    trailing_dest: Path | None = None
    if args.dest is None and len(args.specs) > 1:
        candidate = args.specs[-1]
        if normalize_spec(candidate) not in spec_map:
            trailing_dest = Path(candidate)
            args.specs = args.specs[:-1]

    if not args.specs:
        parser.error("Missing spec string before destination path.")
    if trailing_dest is not None and len(args.specs) != 1:
        parser.error("When using a positional destination, provide exactly one spec.")

    dest_root = args.dest or trailing_dest or DEFAULT_DEST
    dest_root.mkdir(parents=True, exist_ok=True)

    for raw_spec in args.specs:
        norm = normalize_spec(raw_spec)
        entry = spec_map.get(norm)
        if not entry:
            raise SystemExit(
                f"Unknown spec '{raw_spec}'. Use --list to see supported combinations."
            )
        bundle_dir = copy_bundle(entry, raw_spec, dest_root, args.force)
        print(f"[ok] {raw_spec} -> {entry['module']} at {bundle_dir}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
