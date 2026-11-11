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

# preview <example|all>: the picker's preview pane, from the "preview" block of the example's expectations.json:
# the question, the demo's steps, the expected answer, and how its last run went. "all": one line per example.
preview() {
  local b=$'\033[1m' d=$'\033[2m' r=$'\033[0m'
  if [[ "$1" == "all" ]]; then
    printf '%sRuns every example in order%s, stopping everything first; one report each + a summary.\n\n' "$b" "$r"
    local e
    for e in "${EXAMPLES[@]}"; do
      printf '%s%s%s\n  %s\n  %slast run: %s%s\n\n' "$b" "$(title "$e")" "$r" \
        "$(jq -r '.preview.answer' "examples/$e/expectations.json")" "$d" "$(last_run "$e")" "$r"
    done
    return
  fi
  local exp="examples/$1/expectations.json"
  printf '%s%s%s\n%s\n\n' "$b" "$(title "$1")" "$r" "$(jq -r '.question' "$exp")"
  printf '%sSteps%s\n' "$b" "$r"
  jq -r '.preview.steps | to_entries[] | "  \(.key + 1). \(.value)"' "$exp"
  printf '\n%sExpected%s  %s\n' "$b" "$r" "$(jq -r '.preview.answer' "$exp")"
  printf '%sLast run%s  %s\n\n' "$b" "$r" "$(last_run "$1")"
  printf '%sDetails: examples/%s/README.md%s\n' "$d" "$1" "$r"
}

# name_width: stdin = "name<TAB>text" lines; the longest name's length + 2
name_width() { cut -f1 | awk '{ if (length > m) m = length } END { print m + 2 }'; }

# last_run <example>: "PASS · 2m 23s · 2026-11-11 14:35 UTC" from reports/<example>/latest, or "not run yet"
last_run() {
  local dir="reports/$1/latest"
  [[ -f "$dir/results.json" && -f "$dir/run.json" ]] || { echo "not run yet"; return; }
  jq -rn --slurpfile res "$dir/results.json" --slurpfile run "$dir/run.json" '
    ($run[0].started | fromdateiso8601) as $s | (($run[0].finished // $run[0].started) | fromdateiso8601) as $f
    | (($f - $s) | floor) as $secs
    | "\($res[0].verdict) · \(if $secs >= 60 then "\($secs / 60 | floor)m \($secs % 60)s" else "\($secs)s" end) · \($run[0].started | sub("T"; " ") | sub(":[0-9]{2}Z$"; " UTC"))"'
}

# ---------------------------------------------------------------------------------------------------- steps

# pick_example: prints the chosen example (or "all"); nothing when cancelled
pick_example() {
  command -v fzf >/dev/null || { echo "fzf is required for the picker (brew install fzf), or run: make examples EX=01|...|all" >&2; exit 1; }
  local menu e
  menu=$( { for e in "${EXAMPLES[@]}"; do printf '%s\t%s\n' "$e" "$(title "$e")"; done
            printf 'all\tRun every example in order (stops everything first)\n'; } )
  # --tabstop: one column wider than the longest name, so every title starts in the same column
  fzf --delimiter='\t' --with-nth=1,2 --tabstop="$(name_width <<<"$menu")" --prompt='example> ' \
      --header='Select an example to run (Enter = run, Esc = cancel)' \
      --preview="'$ROOT/scripts/examples.sh' --preview {1}" \
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

if [[ "${1:-}" == "--preview" ]]; then preview "${2:-}"; exit; fi   # called by fzf for the preview pane
choice=${1:-}
if [[ -z "$choice" ]]; then choice=$(pick_example); fi
[[ -n "$choice" ]] || exit 0
run_choice "$choice"
