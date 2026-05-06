#!/usr/bin/env bash
# Run verification for ALL 51 configs in parallel.
#
# Produces:
#   verification/results.csv
#   verification/summary.txt
#   verification/logs/<lane>_<config>.log
set -u

ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
cd "$ROOT"

RESULTS="$ROOT/verification/results.csv"
SUMMARY="$ROOT/verification/summary.txt"
JOBS=16

# Build config list
CFG_LIST="$ROOT/verification/config_list.txt"
> "$CFG_LIST"
for lane in 1lane 2lane 4lane; do
  if [[ -d "$ROOT/mac_configs/$lane" ]]; then
    for cfg in $(ls "$ROOT/mac_configs/$lane"); do
      if [[ -d "$ROOT/mac_configs/$lane/$cfg/rtl" ]]; then
        echo "$lane $cfg" >> "$CFG_LIST"
      fi
    done
  fi
done
NCFG=$(wc -l < "$CFG_LIST")
echo "Running $NCFG configs with $JOBS parallel jobs..."

# Run each in parallel
PARTIAL="$ROOT/verification/results.partial"
> "$PARTIAL"

while read lane cfg; do
  bash "$ROOT/verification/run_one.sh" "$lane" "$cfg" &
  # Throttle
  while [[ $(jobs -r | wc -l) -ge $JOBS ]]; do wait -n; done
done < "$CFG_LIST" | tee "$PARTIAL"

wait

# The run_one.sh writes one CSV line per invocation to its stdout. We captured
# them all to $PARTIAL. Now build the final CSV with header.
{
  echo "config,lane,exp_4c,exp_5c,exp_6c,meas_4c,meas_5c,meas_6c,compared,err_5_vs_4,err_6_vs_4,status"
  sort "$PARTIAL"
} > "$RESULTS"

# Build summary
{
  echo "==== Verification Summary ===="
  TOTAL=$(tail -n +2 "$RESULTS" | wc -l)
  PASS=$(tail -n +2 "$RESULTS" | grep -c ',PASS$' || printf 0)
  FAIL=$(tail -n +2 "$RESULTS" | grep -c ',FAIL$' || printf 0)
  echo "Total: $TOTAL    PASS: $PASS    FAIL: $FAIL"
  echo ""
  for lane in 1lane 2lane 4lane; do
    TOT=$(tail -n +2 "$RESULTS" | awk -F, -v l=$lane '$2==l' | wc -l)
    P=$(tail -n +2 "$RESULTS"   | awk -F, -v l=$lane '$2==l && $NF=="PASS"' | wc -l)
    F=$(tail -n +2 "$RESULTS"   | awk -F, -v l=$lane '$2==l && $NF=="FAIL"' | wc -l)
    printf "  %-6s total=%-3d pass=%-3d fail=%-3d\n" "$lane" "$TOT" "$P" "$F"
  done
  echo ""
  echo "=== FAIL details ==="
  printf "  %-28s %-6s %-12s %-12s %s\n" "CONFIG" "LANE" "EXPECTED" "MEASURED" "NOTE"
  while IFS=, read -r cfg lane e4 e5 e6 m4 m5 m6 cmp err5 err6 status; do
    if [[ "$status" == "FAIL" ]]; then
      note=""
      if [[ "$m4" != "$e4" || "$m5" != "$e5" || "$m6" != "$e6" ]]; then
        note="LATENCY_MISMATCH"
      fi
      if [[ "$err5" != "0" || "$err6" != "0" ]]; then
        [[ -n "$note" ]] && note="$note,"
        note="${note}BITEXACT_FAIL(e5=$err5,e6=$err6)"
      fi
      printf "  %-28s %-6s %-12s %-12s %s\n" "$cfg" "$lane" "${e4}/${e5}/${e6}" "${m4}/${m5}/${m6}" "$note"
    fi
  done < <(tail -n +2 "$RESULTS")
  echo ""
  echo "=== PASS list ==="
  while IFS=, read -r cfg lane e4 e5 e6 m4 m5 m6 cmp err5 err6 status; do
    if [[ "$status" == "PASS" ]]; then
      printf "  %-28s %-6s meas=%s\n" "$cfg" "$lane" "${m4}/${m5}/${m6}"
    fi
  done < <(tail -n +2 "$RESULTS")
} > "$SUMMARY"

cat "$SUMMARY"
echo ""
echo "Full CSV at: $RESULTS"
echo "Summary at:  $SUMMARY"
