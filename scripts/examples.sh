#!/usr/bin/env bash
# Run an example's demo. Without an argument, pick one (or "all") with fzf; the preview shows its README.
# With an argument, run it directly: 01 | 01-jvm-args | jvm-args | all.
# "all" stops everything first, runs every demo in order, and exits non-zero if any failed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

. "$ROOT/scripts/lib.sh"

EXAMPLES=()
for d in examples/[0-9][0-9]-*/; do EXAMPLES+=("$(basename "$d")"); done

title() { sed -n '1s/^# *[0-9]* · //p' "examples/$1/README.md" 2>/dev/null; }

run_one() {
  printf '\n\033[1m######## %s: %s\033[0m\n' "$1" "$(title "$1")"
  make -C "examples/$1" demo
}

run_all() {
  # One run id for every example, so their reports and the summary line up.
  export REPORT_RUN_ID
  REPORT_RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)
  local started; started=$(date -u +%FT%TZ)
  acquire_demo_lock "make examples EX=all"   # before `make stop`, so a running demo isn't torn down
  make -s stop
  for e in "${EXAMPLES[@]}"; do run_one "$e" || true; done
  write_summary "$started"
}

# write_summary: reports/all/<run id>/summary.{json,md}, one line per example, from each results.json
write_summary() {
  local dir="reports/all/$REPORT_RUN_ID" entries=()
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

choice=${1:-}
if [[ -z "$choice" ]]; then
  command -v fzf >/dev/null || { echo "fzf is required for the picker (brew install fzf), or run: make examples EX=01|...|all"; exit 1; }
  menu=$( { for e in "${EXAMPLES[@]}"; do printf '%s\t%s\n' "$e" "$(title "$e")"; done
            printf 'all\tRun every example in order (stops everything first)\n'; } )
  choice=$(fzf --delimiter='\t' --with-nth=1,2 --prompt='example> ' \
      --header='Select an example to run (Enter = run, Esc = cancel)' \
      --preview='if [ {1} = all ]; then echo "Runs, in order:"; ls -d examples/[0-9][0-9]-* | sed "s#examples/#  #"; else sed -n "1,45p" examples/{1}/README.md; fi' \
      --preview-window='right,60%,wrap' <<<"$menu" | cut -f1) || exit 0
  [[ -n "$choice" ]] || exit 0
fi

if [[ "$choice" == "all" ]]; then run_all; exit; fi

for e in "${EXAMPLES[@]}"; do
  # Accept "01", "01-jvm-args" or "jvm-args"
  if [[ "$e" == "$choice" || "${e%%-*}" == "$choice" || "${e#*-}" == "$choice" ]]; then run_one "$e"; exit; fi
done
echo "Unknown example '$choice'. Choose one of: ${EXAMPLES[*]} all"
exit 2
