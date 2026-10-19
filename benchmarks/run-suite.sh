#!/bin/bash
# benchmarks/run-suite.sh — Drift benchmark scenarios (spec §4.2, Phase 14).
# B1 active (bounded 10 min) → B3 summary (bounded 10 min) →
# B4 suspended (bounded 10 min) → B8-on power (3 min).
# Results append to $BENCH_RESULTS (default /tmp/drift-bench-results.md).
set -euo pipefail

cd "$(dirname "$0")/.."
LOG="${TMPDIR%/}/drift-probe.log"
APP=.build/Drift.app
export BENCH_RESULTS="${BENCH_RESULTS:-/tmp/drift-bench-results.md}"
DUR="${BENCH_DUR:-600}"
DUR_POWER="${BENCH_DUR_POWER:-180}"

if [ ! -x "$APP/Contents/MacOS/Drift" ]; then
    echo "error: $APP missing — package first" >&2
    exit 1
fi

wait_ready() {
    local mode="$1"
    local start_lines
    start_lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    for _ in $(seq 1 60); do
        if tail -n +"$((start_lines + 1))" "$LOG" 2>/dev/null \
            | grep -q "\[bench\] mode=$mode ready"; then
            return 0
        fi
        sleep 1
    done
    echo "error: bench mode=$mode never became ready" >&2
    return 1
}

run_scenario() {
    local mode="$1" label="$2" dur="$3"
    pkill -x Drift 2>/dev/null || true
    sleep 2
    open "$APP" --args --bench "$mode"
    wait_ready "$mode" || return 1
    local pid
    pid=$(pgrep -x Drift | head -1)
    echo "== $label (pid=$pid, ${dur}s) ==" | tee -a "$BENCH_RESULTS"
    benchmarks/measure.sh "$label" "$dur" "$pid" "$mode"
    if [ "$mode" = "power" ]; then
        pmset -g assertions 2>/dev/null | grep -i "drift" \
            | tee -a "$BENCH_RESULTS" || echo "| (no drift assertion found in pmset)" >>"$BENCH_RESULTS"
    fi
}

{
    echo "# Drift benchmark results ($(date '+%Y-%m-%d %H:%M'))"
    echo
} >>"$BENCH_RESULTS"

run_scenario active "B1 window visible, idle, no input" "$DUR"
run_scenario summary "B3 window hidden, item on (.summary)" "$DUR"
run_scenario suspended "B4 window hidden, item off (.suspended)" "$DUR"
run_scenario power "B8 sleep-prevention ON, hidden+item (.summary + assertion)" "$DUR_POWER"

pkill -x Drift 2>/dev/null || true
echo "suite done → $BENCH_RESULTS"
