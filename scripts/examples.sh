#!/usr/bin/env bash
# Run an example's demo. Without an argument, pick one (or "all") with fzf; the preview shows its README.
# With an argument, run it directly: 01 | 01-jvm-args | jvm-args | all.
# "all" stops everything first, runs every demo in order, writes a summary, and exits non-zero if any failed.
#
#   1. Pick an example (fzf), unless one was given
#   2. Run it, or all of them
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
. "$ROOT/scripts/lib.sh"

EXAMPLES=()        # 01-jvm-args, 02-dynamic-profiles, ...
for d in examples/[0-9][0-9]-*/; do EXAMPLES+=("$(basename "$d")"); done

# ---------------------------------------------------------------------------------------------------- helpers

# title <example>: the title line of its README
title() { sed -n '1s/^# *[0-9]* · //p' "examples/$1/README.md" 2>/dev/null; }

# run_one <example>: its demo
run_one() {
  printf '\n\033[1m######## %s: %s\033[0m\n' "$1" "$(title "$1")"
  make -C "examples/$1" demo
}

# write_summary <started>: reports/all/<run id>/summary.{json,md}, one line per example, from each results.json
write_summary() {
  local dir="reports/all/$REPORT_RUN_ID" entries=() e
  mkdir -p "$dir"
  for e in "${EXAMPLES[@]}"; do
    local results="reports/$e/$REPORT_RUN_ID/results.json"
    if [[ -f "$results" ]]; then
      entries+=("$(jq -c --arg report "../../$e/$REPORT_RUN_ID/report.md" '{example, title, kind, verdict, answer, counts, report: $report,
          improved: [.results[] | select(.outcome == "improved") | .short] | unique,
          notImproved: [.results[] | select(.outcome == "no-benefit-expected" or .outcome == "limitation-shown") | .short] | unique,
          unexpected: [.results[] | select(.outcome == "unexpected") | .short] | unique}' "$results")")
    else
      entries+=("$(jq -n -c --arg e "$e" '{example: $e, title: $e, verdict: "ERROR", answer: "No report: the demo stopped before finishing. Rerun it alone (make examples EX=\($e[0:2])) and read its output.", counts: {}, report: null, improved: [], notImproved: [], unexpected: []}')")
    fi
  done
  printf '%s\n' "${entries[@]}" | jq -s --arg run "$REPORT_RUN_ID" --arg started "$1" --arg finished "$(date -u +%FT%TZ)" \
      --arg revision "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    '{run: $run, started: $started, finished: $finished, revision: $revision,
      verdict: (if any(.[]; .verdict == "FAIL" or .verdict == "ERROR") then "FAIL" elif any(.[]; .verdict == "INCONCLUSIVE") then "INCONCLUSIVE" else "PASS" end),
      examples: .}' > "$dir/summary.json"
  jq -r 'def list: if length == 0 then "-" else join("; ") end;
    "# All examples: \(.verdict)", "",
    "Run \(.run) · revision \(.revision) · \(.started) → \(.finished) (UTC). How to read reports: [docs/reading-reports.md](../../../docs/reading-reports.md).", "",
    "| Example | Verdict | Improved | Didn'"'"'t improve / limitations | Unexpected | Report |",
    "|---|---|---|---|---|---|",
    (.examples[] | "| \(.title) | \(.verdict) | \(.improved | list) | \(.notImproved | list) | \(.unexpected | list) | \(if .report then "[report](\(.report))" else "-" end) |"),
    "",
    "## Answers", "",
    (.examples[] | "- **\(.title)** (\(.verdict)): \(.answer)")' "$dir/summary.json" > "$dir/summary.md"
  ln -sfn "$REPORT_RUN_ID" reports/all/latest

  echo
  jq -r '.examples[] | "  \(.verdict | if . == "PASS" then "✓" else "✗" end) \(.title): \(.verdict)"' "$dir/summary.json"
  printf '  Summary: %s\n' "$dir/summary.md"
  release_demo_lock
  [[ "$(jq -r .verdict "$dir/summary.json")" != "FAIL" ]] || exit 1
}

# ---------------------------------------------------------------------------------------------------- steps

# pick_example: prints the chosen example (or "all"); nothing when cancelled
pick_example() {
  command -v fzf >/dev/null || { echo "fzf is required for the picker (brew install fzf), or run: make examples EX=01|...|all" >&2; exit 1; }
  local menu e
  menu=$( { for e in "${EXAMPLES[@]}"; do printf '%s\t%s\n' "$e" "$(title "$e")"; done
            printf 'all\tRun every example in order (stops everything first)\n'; } )
  fzf --delimiter='\t' --with-nth=1,2 --prompt='example> ' \
      --header='Select an example to run (Enter = run, Esc = cancel)' \
      --preview='if [ {1} = all ]; then echo "Runs, in order:"; ls -d examples/[0-9][0-9]-* | sed "s#examples/#  #"; else sed -n "1,45p" examples/{1}/README.md; fi' \
      --preview-window='right,60%,wrap' <<<"$menu" | cut -f1 || true
}

# run_choice <choice>: "all", or one example by "01", "01-jvm-args" or "jvm-args"
run_choice() {
  if [[ "$1" == "all" ]]; then run_all; return; fi
  local e
  for e in "${EXAMPLES[@]}"; do
    if [[ "$e" == "$1" || "${e%%-*}" == "$1" || "${e#*-}" == "$1" ]]; then run_one "$e"; return; fi
  done
  echo "Unknown example '$1'. Choose one of: ${EXAMPLES[*]} all"
  exit 2
}

# run_all: every example in order with one run id, so their reports and the summary line up
run_all() {
  export REPORT_RUN_ID
  REPORT_RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
  local started e
  started=$(date -u +%FT%TZ)
  acquire_demo_lock "make examples EX=all"   # before `make stop`, so a running demo isn't torn down
  make -s stop
  for e in "${EXAMPLES[@]}"; do run_one "$e" || true; done
  write_summary "$started"
}

# ---------------------------------------------------------------------------------------------------- main

choice=${1:-}
if [[ -z "$choice" ]]; then choice=$(pick_example); fi
[[ -n "$choice" ]] || exit 0
run_choice "$choice"
