#!/usr/bin/env bash
# render-report.sh <report dir> <expectations.json>
# Turns a run's raw records (run.json, results.jsonl, timings.jsonl, raw/) into results.json and report.md.
set -euo pipefail
dir=$1 exp=$2
here="$(cd "$(dirname "$0")" && pwd)"
jq -n --slurpfile exp "$exp" --slurpfile run "$dir/run.json" \
      --slurpfile checks "$dir/results.jsonl" --slurpfile timings "$dir/timings.jsonl" \
      --arg evidence "$(cd "$dir/raw" && ls -1 2>/dev/null || true)" \
      -f "$here/report.jq" > "$dir/results.json"
jq -r -f "$here/report-md.jq" "$dir/results.json" > "$dir/report.md"
