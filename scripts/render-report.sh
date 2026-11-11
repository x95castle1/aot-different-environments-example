#!/usr/bin/env bash
# render-report.sh <report dir> <expectations.json>
# Turns a run's raw records (run.json, results.jsonl, timings.jsonl, raw/) into results.json and report.md.
#
#   1. results.json   the records judged against expectations.json (report.jq)
#   2. report.md      results.json for people (report-md.jq)
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
DIR=$1
EXPECTATIONS=$2
HERE="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------------------------------- steps

render_results() {
  jq -n --slurpfile exp "$EXPECTATIONS" --slurpfile run "$DIR/run.json" \
        --slurpfile checks "$DIR/results.jsonl" --slurpfile timings "$DIR/timings.jsonl" \
        --arg evidence "$(cd "$DIR/raw" && ls -1 2>/dev/null || true)" \
        -f "$HERE/report.jq" > "$DIR/results.json"
}

render_markdown() { jq -r -f "$HERE/report-md.jq" "$DIR/results.json" > "$DIR/report.md"; }

# ---------------------------------------------------------------------------------------------------- main

render_results
render_markdown
