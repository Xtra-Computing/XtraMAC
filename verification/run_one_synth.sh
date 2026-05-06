#!/usr/bin/env bash
# Usage: run_one_synth.sh <lane> <config_name> <variant>
# e.g. run_one_synth.sh 2lane bf16_bf16_bf16 4c
set -u
LANE="$1"; CFG="$2"; VAR="$3"

ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
CFG_DIR=$ROOT/mac_configs/$LANE/$CFG
RTL=$CFG_DIR/rtl/mac_${VAR}.v
PERIOD_NS="${PERIOD_NS:-2.222}"
TAG="${TAG:-}"
RUN_DIR=$ROOT/verification/runs/${LANE}_${CFG}_${VAR}${TAG}
LOG=$RUN_DIR/synth.log
CSV="${CSV_OUT:-$ROOT/verification/synth_all.csv}"

mkdir -p "$RUN_DIR"

# Extract top module name
TOP=$(grep -oP '^module \K\w+' "$RTL" | head -1)

# Gather all .v files to read
ALL_V=$(find $ROOT/common $ROOT/mac_cores -name '*.v')

# TCL content
TCL=$RUN_DIR/run.tcl
cat > "$TCL" <<EOF
set_param general.maxThreads 8
set RTL_TOP "$RTL"
set TOP_MODULE "$TOP"
# Read wrapper
read_verilog -sv "\$RTL_TOP"
# Read cores
EOF

for f in $ALL_V; do
  echo "read_verilog -sv \"$f\"" >> "$TCL"
done

cat >> "$TCL" <<EOF
# Include dirs for .vh
set inc_dirs [list $ROOT/mac_cores/mixed_precision]
EOF

cat >> "$TCL" <<'EOF'
if {[catch {
  synth_design -top $TOP_MODULE -part xcu55c-fsvh2892-2L-e -include_dirs $inc_dirs
} err]} {
  puts "RESULT|FAIL_SYNTH|$err"
  exit 1
}

create_clock -period PERIOD_PLACEHOLDER -name clk [get_ports clk]

# Post-synth utilization
set u [report_utilization -return_string]
set l 0; set f 0; set d 0
regexp {CLB LUTs\*?\s+\|\s+(\d+)} $u -> l
regexp {CLB Registers\s+\|\s+(\d+)} $u -> f
regexp {DSPs\s+\|\s+(\d+)} $u -> d

if {[catch {opt_design} err]} { puts "RESULT|FAIL_OPT|$err"; exit 1 }
if {[catch {place_design} err]} { puts "RESULT|FAIL_PLACE|$err"; exit 1 }
if {[catch {phys_opt_design} err]} { puts "RESULT|FAIL_PHYS|$err"; exit 1 }
if {[catch {route_design} err]} { puts "RESULT|FAIL_ROUTE|$err"; exit 1 }

set wr 0.0
set paths [get_timing_paths -max_paths 1 -nworst 1]
if {[llength $paths] > 0} {
  set wr [get_property SLACK [lindex $paths 0]]
}
set period PERIOD_PLACEHOLDER
set fmax [expr {1000.0/($period - $wr)}]
puts [format "RESULT|OK|%s|%s|%s|%d|%d|%d|%.3f|%.2f" $TOP_MODULE "VAR_PLACEHOLDER" "CFG_PLACEHOLDER" $l $f $d $wr $fmax]
exit
EOF

# Replace placeholders
sed -i "s/VAR_PLACEHOLDER/$VAR/; s/CFG_PLACEHOLDER/$CFG/; s/PERIOD_PLACEHOLDER/$PERIOD_NS/g" "$TCL"

cd "$RUN_DIR"
# Caller is expected to have sourced their Vivado settings64.sh first.
if ! command -v vivado >/dev/null 2>&1; then
  echo "ERROR: 'vivado' not on PATH. Source your Vivado settings64.sh first." >&2
  exit 1
fi
vivado -mode batch -nojournal -nolog -source "$TCL" > "$LOG" 2>&1
RC=$?

# Extract result line (log can contain binary bytes from Vivado progress bars)
RESULT_LINE=$(grep -a -E '^RESULT\|(OK|FAIL)' "$LOG" | tail -1 || true)
if [[ -z "$RESULT_LINE" ]]; then
  RESULT_LINE=$(grep -a -E 'RESULT\|(OK|FAIL)' "$LOG" | tail -1 || true)
fi

if [[ -z "$RESULT_LINE" ]]; then
  echo "FAIL|$LANE|$CFG|$VAR|vivado_crash|exit=$RC" >> "$CSV"
else
  if [[ "$RESULT_LINE" == *"|OK|"* ]]; then
    # RESULT|OK|top|var|cfg|lut|ff|dsp|wns|fmax
    IFS='|' read -r _ _ TOP_OUT VAR_OUT CFG_OUT LUT FF DSP WNS FMAX <<< "$RESULT_LINE"
    echo "OK|$LANE|$CFG|$VAR|$TOP_OUT|$LUT|$FF|$DSP|$WNS|$FMAX" >> "$CSV"
  else
    REASON=$(echo "$RESULT_LINE" | cut -d'|' -f2-)
    echo "FAIL|$LANE|$CFG|$VAR|$REASON" >> "$CSV"
  fi
fi

echo "[DONE] $LANE/$CFG/$VAR rc=$RC"
