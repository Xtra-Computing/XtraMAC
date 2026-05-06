#!/usr/bin/env bash
# Run verification for ONE config.
#
# Usage: run_one.sh <lane> <config>
#
# Prints a single CSV line on stdout:
#   config,lane,4c_vs_5c_errors,4c_vs_6c_errors,compared,status
# and writes full logs to verification/logs/<lane>_<config>.log

set -uo pipefail

LANE="$1"
CFG="$2"
ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
CORE_DIR="$ROOT/mac_cores"
CFG_DIR="$ROOT/mac_configs/$LANE/$CFG"
TB="$CFG_DIR/tb/tb_mac.v"
LOGD="$ROOT/verification/logs"
BUILDD="$ROOT/verification/build"
mkdir -p "$LOGD" "$BUILDD"
LOG="$LOGD/${LANE}_${CFG}.log"
VVP="$BUILDD/${LANE}_${CFG}.vvp"
DSP_STUB="$ROOT/verification/dsp_usage_sim.v"

WRAPPERS=(
  "$CFG_DIR/rtl/mac_4c.v"
  "$CFG_DIR/rtl/mac_5c.v"
  "$CFG_DIR/rtl/mac_6c.v"
)

# Gather all core .v files (the .vh are pulled in by `include` via -I)
mapfile -t CORES < <(ls "$CORE_DIR"/*/*.v)

# Build compile command: include paths cover each .vh location
INC_ARGS=(-I "$CORE_DIR/mixed_precision")

{
  echo "==== Verifying $LANE/$CFG ===="
  echo "TB: $TB"
  echo "Wrappers: ${WRAPPERS[*]}"

  iverilog -g2012 -o "$VVP" \
           "${INC_ARGS[@]}" \
           -s tb_mac \
           "$DSP_STUB" \
           "${CORES[@]}" \
           "${WRAPPERS[@]}" \
           "$TB" 2>&1
  RC=$?
  if [[ $RC -ne 0 ]]; then
    echo "RESULT=$CFG FAIL (compile error rc=$RC)"
    exit 1
  fi

  vvp "$VVP" 2>&1
} > "$LOG" 2>&1

# Extract result line
RESULT_LINE=$(grep -E "^RESULT=" "$LOG" | tail -1 || true)
STATS_LINE=$(grep -E "^CONFIG=" "$LOG" | tail -1 || true)

STATUS="FAIL"
if [[ "$RESULT_LINE" == *PASS* ]]; then
  STATUS="PASS"
fi

# Parse STATS_LINE of the form:
#   CONFIG=<name> LANE=<lane> EXP=<e4>,<e5>,<e6> MEAS=<m4>,<m5>,<m6> CMP=<N> ERR5=<N> ERR6=<N>
EXP=$(echo "$STATS_LINE"   | grep -oE "EXP=[0-9]+,[0-9]+,[0-9]+"   | cut -d= -f2 || true)
MEAS=$(echo "$STATS_LINE"  | grep -oE "MEAS=-?[0-9]+,-?[0-9]+,-?[0-9]+" | cut -d= -f2 || true)
CMP=$(echo "$STATS_LINE"   | grep -oE "CMP=[0-9]+"                 | cut -d= -f2 || true)
ERR5=$(echo "$STATS_LINE"  | grep -oE "ERR5=[0-9]+"                | cut -d= -f2 || true)
ERR6=$(echo "$STATS_LINE"  | grep -oE "ERR6=[0-9]+"                | cut -d= -f2 || true)
EXP="${EXP:-NA}"
MEAS="${MEAS:-NA}"
ERR5="${ERR5:-NA}"
ERR6="${ERR6:-NA}"
CMP="${CMP:-0}"

echo "$CFG,$LANE,$EXP,$MEAS,$CMP,$ERR5,$ERR6,$STATUS"
