#!/usr/bin/env bash
# Consume $ROOT/verification/synth_all.csv and emit:
#   per-config results.md
#   mac_configs/SUMMARY.md
set -u
ROOT="$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
CSV=$ROOT/verification/synth_all.csv
SUMMARY=$ROOT/mac_configs/SUMMARY.md

python3 - <<'PY'
import csv, os, collections

ROOT = "$(cd "$(dirname "$(realpath "$0")")/.." && pwd)"
CSV = f"{ROOT}/verification/synth_all.csv"

rows = []
with open(CSV) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        if line.startswith("#"): continue
        p = line.split("|")
        if p[0] == "OK":
            # OK|lane|cfg|var|top|LUT|FF|DSP|WNS|FMAX
            rows.append({
                "status":"OK", "lane":p[1], "cfg":p[2], "var":p[3],
                "top":p[4], "lut":int(p[5]), "ff":int(p[6]), "dsp":int(p[7]),
                "wns":float(p[8]), "fmax":float(p[9]),
            })
        else:
            rows.append({
                "status":"FAIL", "lane":p[1], "cfg":p[2], "var":p[3],
                "reason":"|".join(p[4:]),
            })

by_cfg = collections.defaultdict(list)
for r in rows:
    by_cfg[(r["lane"], r["cfg"])].append(r)

lat_map = {"4c":4, "5c":5, "6c":6}

ok_count = sum(1 for r in rows if r["status"]=="OK")
fail_count = sum(1 for r in rows if r["status"]!="OK")

for (lane, cfg), lst in by_cfg.items():
    dir = f"{ROOT}/mac_configs/{lane}/{cfg}"
    os.makedirs(dir, exist_ok=True)
    path = f"{dir}/results.md"
    lines = []
    lines.append(f"# {cfg} Synthesis Results (U55C, 450 MHz target)\n")
    lines.append("Target clock: 2.222 ns (450 MHz)  ")
    lines.append("Part: xcu55c-fsvh2892-2L-e  ")
    lines.append(f"Lane group: {lane}\n")
    lines.append("| Variant | Latency | LUT | FF | DSP | Route WNS (ns) | Fmax (MHz) |")
    lines.append("|---------|---------|-----|-----|-----|----------------|------------|")
    order = {"4c":0,"5c":1,"6c":2}
    lst_sorted = sorted(lst, key=lambda r: order.get(r["var"], 9))
    for r in lst_sorted:
        if r["status"] == "OK":
            wns = r["wns"]
            wns_s = ("+%.3f" % wns) if wns >= 0 else ("%.3f" % wns)
            lines.append(f"| {r['var']} | {lat_map[r['var']]} | {r['lut']} | {r['ff']} | {r['dsp']} | {wns_s} | {r['fmax']:.1f} |")
        else:
            reason = r["reason"].replace("\n"," ").replace("|"," ")
            lines.append(f"| {r['var']} | {lat_map[r['var']]} | FAIL | FAIL | FAIL | FAIL | FAIL: {reason[:80]} |")
    lines.append("")
    # Notes
    if cfg == "int8_int8_int32":
        lines.append("## Notes")
        lines.append("- The int32 accumulator core has a built-in `+1` output register that is not controllable via the `ADD_LAT` parameter, so the reported latency reflects the wrapper configuration plus this extra stage.")
        lines.append("")

    dsps = [r["dsp"] for r in lst if r["status"]=="OK"]
    if dsps and max(dsps) > 1:
        lines.append("## Warning")
        lines.append(f"- DSP count is {max(dsps)} (expected 1 for a single-MAC wrapper). Review synthesis log.")
        lines.append("")

    with open(path, "w") as f:
        f.write("\n".join(lines))

# Build summary
all_ok = [r for r in rows if r["status"]=="OK"]
summary_path = f"{ROOT}/mac_configs/SUMMARY.md"
out = []
out.append("# MAC Configurations Synthesis Summary\n")
out.append("Target: Xilinx Alveo U55C (xcu55c-fsvh2892-2L-e)  ")
out.append("Clock constraint: 2.222 ns (450 MHz)  ")
out.append(f"Total runs: {len(rows)}  ")
out.append(f"Successful: {ok_count}  ")
out.append(f"Failed: {fail_count}  \n")

out.append("## All configurations (sorted by lane, then config)\n")
out.append("| Lane | Config | Variant | LUT | FF | DSP | WNS (ns) | Fmax (MHz) |")
out.append("|------|--------|---------|-----|-----|-----|----------|------------|")
def sk(r):
    lane_order={"1lane":0,"2lane":1,"4lane":2}
    return (lane_order.get(r["lane"],9), r["cfg"], {"4c":0,"5c":1,"6c":2}.get(r["var"],9))
for r in sorted(rows, key=sk):
    if r["status"]=="OK":
        wns_s = ("+%.3f"%r["wns"]) if r["wns"]>=0 else ("%.3f"%r["wns"])
        out.append(f"| {r['lane']} | {r['cfg']} | {r['var']} | {r['lut']} | {r['ff']} | {r['dsp']} | {wns_s} | {r['fmax']:.1f} |")
    else:
        out.append(f"| {r['lane']} | {r['cfg']} | {r['var']} | FAIL | FAIL | FAIL | FAIL | FAIL |")

# Fmax per config per variant trend
out.append("\n## Fmax trend by variant (4c -> 5c -> 6c)\n")
out.append("| Lane | Config | 4c Fmax | 5c Fmax | 6c Fmax | Best variant |")
out.append("|------|--------|---------|---------|---------|--------------|")
cfg_fmax = {}
for r in all_ok:
    cfg_fmax.setdefault((r["lane"],r["cfg"]),{})[r["var"]] = r["fmax"]

def best(d):
    if not d: return ("-", 0)
    k = max(d, key=lambda k: d[k])
    return (k, d[k])

for (lane,cfg), fm in sorted(cfg_fmax.items(), key=lambda x: ({"1lane":0,"2lane":1,"4lane":2}[x[0][0]], x[0][1])):
    f4 = fm.get("4c", None); f5 = fm.get("5c", None); f6 = fm.get("6c", None)
    def fmt(x): return "-" if x is None else f"{x:.1f}"
    b, bv = best(fm)
    out.append(f"| {lane} | {cfg} | {fmt(f4)} | {fmt(f5)} | {fmt(f6)} | {b} ({bv:.1f} MHz) |")

# Highlights
out.append("\n## Highlights\n")
if all_ok:
    top_fmax = sorted(all_ok, key=lambda r: -r["fmax"])[:10]
    out.append("### Top 10 fastest runs\n")
    out.append("| Lane | Config | Variant | Fmax (MHz) | LUT | FF | DSP |")
    out.append("|------|--------|---------|------------|-----|-----|-----|")
    for r in top_fmax:
        out.append(f"| {r['lane']} | {r['cfg']} | {r['var']} | {r['fmax']:.1f} | {r['lut']} | {r['ff']} | {r['dsp']} |")

    bot = sorted(all_ok, key=lambda r: r["fmax"])[:10]
    out.append("\n### Slowest 10 runs (most timing-bottlenecked)\n")
    out.append("| Lane | Config | Variant | Fmax (MHz) | LUT | FF | DSP |")
    out.append("|------|--------|---------|------------|-----|-----|-----|")
    for r in bot:
        out.append(f"| {r['lane']} | {r['cfg']} | {r['var']} | {r['fmax']:.1f} | {r['lut']} | {r['ff']} | {r['dsp']} |")

# DSP anomalies
dsp_anom = [r for r in all_ok if r["dsp"] != 1]
out.append("\n### DSP count anomalies (expected 1 DSP per wrapper)\n")
if dsp_anom:
    out.append("| Lane | Config | Variant | DSP count |")
    out.append("|------|--------|---------|-----------|")
    for r in dsp_anom:
        out.append(f"| {r['lane']} | {r['cfg']} | {r['var']} | {r['dsp']} |")
else:
    out.append("_No anomalies: every successful run used exactly 1 DSP._")

# Fmax monotonicity check (4c < 5c < 6c as adding pipeline stages should help)
out.append("\n### Fmax monotonicity by variant\n")
out.append("Adding pipeline stages (4c -> 5c -> 6c) generally increases Fmax. Configs that break monotonicity:\n")
non_mono = []
for (lane,cfg), fm in cfg_fmax.items():
    if "4c" in fm and "5c" in fm and "6c" in fm:
        if not (fm["4c"] <= fm["5c"] <= fm["6c"] + 5):  # allow 5 MHz noise tolerance
            non_mono.append((lane,cfg,fm))
if non_mono:
    out.append("| Lane | Config | 4c | 5c | 6c |")
    out.append("|------|--------|-----|-----|-----|")
    for lane,cfg,fm in non_mono:
        out.append(f"| {lane} | {cfg} | {fm['4c']:.1f} | {fm['5c']:.1f} | {fm['6c']:.1f} |")
else:
    out.append("_All configs show non-decreasing Fmax as latency grows (within 5 MHz tolerance)._")

# Failures
fails = [r for r in rows if r["status"]!="OK"]
if fails:
    out.append("\n## Failures\n")
    out.append("| Lane | Config | Variant | Reason |")
    out.append("|------|--------|---------|--------|")
    for r in fails:
        out.append(f"| {r['lane']} | {r['cfg']} | {r['var']} | {r['reason'][:120]} |")

with open(summary_path, "w") as f:
    f.write("\n".join(out))

print(f"Wrote {len(by_cfg)} results.md files and SUMMARY.md")
print(f"  OK: {ok_count}  FAIL: {fail_count}")
PY
