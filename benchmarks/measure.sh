#!/bin/bash
# benchmarks/measure.sh — samples one process and prints an §8 benchmark row.
# usage: measure.sh <label> <duration_s> <pid> [tier]
set -euo pipefail

label="${1:?label}"
dur="${2:?duration seconds}"
pid="${3:?pid}"
tier="${4:-unknown}"
interval=5
samples=$(( dur / interval ))
[ "$samples" -lt 2 ] && samples=2

rss_before=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")
tmp=$(mktemp /tmp/drift-bench.XXXXXX)
trap 'rm -f "$tmp"' EXIT

# First top sample reflects since-boot averages — dropped during parsing.
top -l $((samples + 1)) -s "$interval" -pid "$pid" -stats pid,cpu,mem,csw > "$tmp" 2>&1

rss_after=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")

awk -v pid="$pid" -v label="$label" -v tier="$tier" -v dur="$dur" \
    -v interval="$interval" -v rssb="$rss_before" -v rssa="$rss_after" '
  $1 == pid && $2 ~ /^[0-9.]+%?$/ {
    cpu = $2; sub(/%$/, "", cpu); cpu += 0
    n++
    if (n > 1) {
      sum += cpu
      if (cpu > max) max = cpu
      if (mem == "") mem = $3
      csw = $4; gsub(/\+/, "", csw); csw += 0
      if (prev != "") {
        d = csw - prev
        if (d < 0) d = 0
        cswsum += d
      }
      prev = csw
    } else {
      mem = $3
      csw = $4; gsub(/\+/, "", csw); prev = csw + 0
    }
  }
  END {
    if (n < 2) { print "NO SAMPLES for pid " pid > "/dev/stderr"; exit 1 }
    counted = n - 1
    cswmin = (counted > 0) ? (cswsum * 60.0 / (counted * interval)) : 0
    delta = "?"
    if (rssb != "?" && rssa != "?") delta = rssa - rssb
    printf "| — | 14 | %s [%s] | %.2f%% avg / %.2f%% peak | %s (Δ%+d KB) | %.0f/min (csw proxy) | unmeasured (root) | unmeasured (root) | %d samples × %ds over %ds |\n",
      label, tier, sum / counted, max, mem, delta, cswmin, counted, interval, dur
  }
' "$tmp" | tee -a "${BENCH_RESULTS:-/tmp/drift-bench-results.md}"
