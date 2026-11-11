#!/usr/bin/env bash
# What's running:
#
#   1. The demo holding the run lock: which one, for how long, which example it's on
#   2. Every running container from every example (all named aot-*)
#   3. The last finished report
#
# Each step is a function below; main, at the bottom, runs them in order.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[0m'
[[ -t 1 ]] || { B=""; D=""; G=""; Y=""; R=""; }
LOCK=reports/.demo.lock

# ---------------------------------------------------------------------------------------------------- helpers

# mtime <file>: its modification time, in seconds since the epoch (macOS or Linux stat)
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }

# ago <epoch seconds>: how long ago, e.g. "3m 12s"
ago() { local s=$(( $(date +%s) - $1 )); if (( s >= 60 )); then echo "$((s / 60))m $((s % 60))s"; else echo "${s}s"; fi; }

# current_report: the example in progress is the newest run directory without a finished results.json
current_report() {
  ls -dt reports/0*/2*/ 2>/dev/null | while read -r d; do [[ -f "$d/results.json" ]] || { echo "${d%/}"; break; }; done
}

# finished_in_run <run id>: "<example> <verdict>, ..." for the examples that already finished in that run
finished_in_run() {
  local f list=""
  for f in reports/0*/"$1"/results.json; do
    [[ -f "$f" ]] && list+="$(basename "$(dirname "$(dirname "$f")")") $(jq -r .verdict "$f" 2>/dev/null), "
  done
  echo "${list%, }"
}

# ---------------------------------------------------------------------------------------------------- steps

show_demo() {
  local pid="" what="" current recorded unexpected
  [[ -f "$LOCK" ]] && read -r pid what < "$LOCK"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    printf '%s== Demo running:%s %snone%s (make examples to start one)\n' "$B" "$R" "$G" "$R"
    return
  fi
  printf '%s== Demo running:%s %s%s%s (pid %s, started %s ago)\n' "$B" "$R" "$Y" "$what" "$R" "$pid" "$(ago "$(mtime "$LOCK")")"
  current=$(current_report)
  if [[ -n "$current" ]]; then
    printf '   now on: %s  %s(report in progress: %s)%s\n' "$(basename "$(dirname "$current")")" "$D" "$current" "$R"
    recorded=$(grep -c '"outcome":"' "$current/results.jsonl" 2>/dev/null || true)
    unexpected=$(grep -c '"outcome":"unexpected"' "$current/results.jsonl" 2>/dev/null || true)
    printf '   checks so far: %s recorded, %s unexpected\n' "${recorded:-0}" "${unexpected:-0}"
    # For "EX=all": which examples already finished in this run
    if [[ "$what" == *"EX=all"* ]]; then
      printf '   finished in this run: %s\n' "$(finished_in_run "$(basename "$current")")"
    fi
  fi
  printf '   %sstop it with: kill %s%s\n' "$D" "$pid" "$R"
}

show_containers() {
  printf '\n%s== Containers%s\n' "$B" "$R"
  if [[ -z "$(docker ps -q --filter 'name=^aot-')" ]]; then
    echo "   none"
  else
    docker ps --filter 'name=^aot-' --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' | sed 's/^/   /'
  fi
}

show_last_report() {
  local latest
  latest=$(ls -dt reports/0*/latest 2>/dev/null | head -1)
  if [[ -n "$latest" && -f "$latest/results.json" ]]; then
    printf '\n%s== Last finished report:%s %s: %s  %s(%s/report.md)%s\n' "$B" "$R" \
      "$(basename "$(dirname "$latest")")" "$(jq -r .verdict "$latest/results.json")" "$D" "$latest" "$R"
  fi
}

# ---------------------------------------------------------------------------------------------------- main

show_demo
show_containers
show_last_report
