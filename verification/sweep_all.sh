#!/usr/bin/env bash
# Generate job list and run in parallel
set -u
ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
CSV=$ROOT/verification/synth_all.csv
LOG=$ROOT/verification/synth_all.log
JOBLIST=$ROOT/verification/jobs.txt

> "$CSV"
> "$LOG"
> "$JOBLIST"

for d in $ROOT/mac_configs/1lane/*/ $ROOT/mac_configs/2lane/*/ $ROOT/mac_configs/4lane/*/; do
  cfg=$(basename "$d")
  lane=$(basename "$(dirname "$d")")
  for v in 4c 5c 6c; do
    echo "$lane $cfg $v" >> "$JOBLIST"
  done
done

echo "Total jobs: $(wc -l < $JOBLIST)"

# Run in parallel via xargs
cat "$JOBLIST" | xargs -P 16 -n 3 -I {} bash -c '
  args="{}"
  read -ra a <<<"$args"
  "$ROOT/verification/run_one_synth.sh" "${a[0]}" "${a[1]}" "${a[2]}"
' >> "$LOG" 2>&1

echo "[SWEEP DONE]"
wc -l "$CSV"
