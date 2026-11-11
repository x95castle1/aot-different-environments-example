# Renders report.md from results.json (jq -r -f scripts/report-md.jq results.json).

def t($unit): if . == null then "-" elif $unit == "ms" then "\(. * 1000 | round) ms" else "\(.)s" end;
def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
def bt: "`\(. | tostring | gsub("`"; "'"))`";
def evidence_block:
  if .evidenceExcerpt then
    "  - Evidence ([\(.evidence)](\(.evidence))):", "", "    ```", (.evidenceExcerpt | split("\n")[] | "    \(.)"), "    ```"
  elif .evidence then "  - Evidence: [\(.evidence)](\(.evidence))"
  else empty end;
# Evidence excerpts only where a reader needs the explanation (not for plain passes).
def item: "- **\(.label)**: \(.measured)", (if .why != "" then "  - Why: \(.why)" else empty end),
          (if (.outcome | IN("works", "unchanged", "improved", "info")) then empty else evidence_block end);
def section($title; $items; $none):
  "## \($title)", "", (if ($items | length) == 0 then $none else ($items[] | item) end), "";

. as $R
| ($R.kind == "performance") as $perf
| [$R.results[] | select(.outcome == "improved")] as $improved
| [$R.results[] | select(.outcome == "unchanged")] as $unchanged
| [$R.results[] | select(.outcome == "works")] as $works
| [$R.results[] | select(.outcome == "no-benefit-expected")] as $noBenefit
| [$R.results[] | select(.outcome == "limitation-shown")] as $limits
| [$R.results[] | select(.outcome == "unexpected")] as $unexpected
| [$R.results[] | select(.outcome == "inconclusive")] as $inconclusive
| [$R.results[] | select(.outcome == "info")] as $info
| [$R.results[] | select(.kind == "timing")] as $timings
| [$R.results[] | select(.kind == "check")] as $checks
| (
  "# \($R.title): \($R.verdict)",
  "",
  "**Question:** \($R.question)",
  "",
  "**Answer from this run:** \($R.answer)",
  "",
  "Outcomes: " + ($R.counts | to_entries | map("\(.value) \(.key)") | join(" · ")) + ". How to read this report: [\($R.howToRead)](../../../\($R.howToRead)).",
  "",
  "## Run",
  "",
  "| | |",
  "|---|---|",
  "| Started → finished (UTC) | \($R.run.started) → \($R.run.finished // "?") |",
  "| Revision | \($R.run.revision)\(if $R.run.uncommittedChanges then " (plus uncommitted changes)" else "" end) |",
  ($R.run.images[] | "| Image | \(.ref | bt) · id \(.id[7:19]) · JDK \(.jdk // "?") · JDK AOT cache trained with \((.trainingFlags // "?") | bt) |"),
  (if $R.run.timedRunsPerScenario then "| Timed runs per scenario | \($R.run.timedRunsPerScenario) |" else empty end),
  "| Docker | \($R.run.docker.version // "?") · \($R.run.docker.arch // "?") · \($R.run.docker.cpus // "?") CPUs · \($R.run.docker.memGb // "?") GB |",
  "| Host | \($R.run.host) |",
  "",
  "## What was tested",
  "",
  ($R.tested[] | "- \(.)"),
  "",
  (if ($timings | length) > 0 then
     section("What improved"; $improved; "Nothing measured as improved."),
     (if $R.attribution then
        $R.attribution.summary,
        ""
      else empty end),
     (if ($unchanged | length) > 0 or $perf then section("Stayed the same (as intended)"; $unchanged; "Nothing in this category.") else empty end)
   else empty end),
  (if $perf then
     "The pass/fail checks behind these numbers (cache used, app started, ...) are in [All checks](#all-checks).", ""
   else
     "## What works", "",
     (if ($works | length) == 0 then "Nothing passed."
      else ($works | group_by(.group)[]
            | "### \(.[0].group)", "",
              # One bullet per check and explanation, so per-scenario checks (cache.<id>) that say the same thing merge
              (group_by([.check, .why])[] | "- **\(.[0].check // .[0].label)**" + (if .[0].why != "" then ": \(.[0].why)" else "" end),
                                 (.[] | "  - \(.subject // "result"): \(.measured)")),
              "") end),
     ""
   end),
  section("What didn't improve, and why"; $noBenefit; "Nothing: every scenario that should benefit did."),
  (if ($limits | length) > 0 then section("Limitations demonstrated (by design)"; $limits; "") else empty end),
  "## Unexpected results",
  "",
  (if ($unexpected | length) == 0 then "None. Every result matched what this example is known to show."
   else ($unexpected[] |
     "### \(.label)", "",
     "- Expected: \(.expected // "-")",
     "- Measured: \(.measured)",
     (if .why != "" then "- Why that was expected: \(.why)" else empty end),
     "- What to check:", (.ifUnexpected[] | "  - \(.)"),
     evidence_block, "") end),
  "",
  (if ($inconclusive | length) > 0 then
     "## Inconclusive (rerun)", "",
     "These timings couldn't be judged: fewer than 3 runs, or runs that varied too much (slowest/fastest > 1.5 after dropping one outlier). Close other workloads and rerun with more runs, e.g. `RUNS=10`.", "",
     ($inconclusive[] | "- **\(.label)**: \(.measured)"), ""
   else empty end),
  (if ($info | length) > 0 then
     (if any($info[]; .baseline == true) then "## Measurements and baselines (information only)" else "## Measurements (information only)" end), "",
     ($info[] | "- \(.label): \(.measured)" + (if .why != "" then " (\(.why))" else "" end)), ""
   else empty end),
  (if ($timings | length) > 0 then
     (if any($timings[]; .metric != null) then "## Timings" else "## Startup times" end), "",
     ($timings | map(.comparisons // []) | max_by(length) | map(.label)) as $cols
     | ($timings | any(.aotCache != null)) as $hasCache
     # Mixed units (s and ms): the unit goes into every runs cell instead of the header
     | ($timings | any(.unit == "ms")) as $mixed
     | def cache: if $hasCache then [if .aotCache then "\(.aotCache.verdict) \(.aotCache.classes // "")" else "-" end] else [] end;
       def runs: (.shown.runs | join(", ")) + (if $mixed then " \(.unit)" else "" end);
       # Baseline rows are information in results.json; the table names them for what they are
       def outcome: if .baseline or (.outcome == "info" and .compareTo == null) then "baseline" else .outcome end;
       def row($cells): "| " + ($cells | map(cell) | join(" | ")) + " |";
       def head: ["Scenario"] + (if $hasCache then ["JDK AOT cache"] else [] end) + [if $mixed then "Runs" else "Runs (s)" end, "Median"];
     if ($cols | length) > 0 then
       # Fixed comparison columns: each compares every row with one scenario; * marks the one the outcome is judged on
       "Each comparison column compares every row with one scenario. \\* marks the comparison its outcome is judged on.", "",
       row(head + $cols + ["Outcome"]),
       row(head + $cols + ["Outcome"] | map("---")),
       ($timings[] | row([.short] + cache + [runs, .shown.median]
           + [.comparisons // [] | .[] | if .ref == null then "-" else
                "\(.change)\(if .otherRef then " vs \(.refLabel)" else "" end) \(.detail)\(if .judged then " \\*" else "" end)" end]
           + [outcome]))
     else
       row(head + ["Compared with", "Change", "Outcome"]),
       row(head + ["Compared with", "Change", "Outcome"] | map("---")),
       ($timings[] | row([.short] + cache + [runs, .shown.median, (.compareToLabel // "-"),
           (if .referenceMedian then "\(.change) (\(.shown.median) vs \(.unit as $u | .referenceMedian | t($u // "s")))" else "-" end), outcome]))
     end,
     ""
   else empty end),
  "## All checks",
  "",
  "| Group | Check | Expected | Measured | Outcome |",
  "|---|---|---|---|---|",
  ($checks[] | "| \(.group | cell) | \(.label | cell) | \((.expected // "-") | cell) | \(.measured | cell) | \(.outcome) |"),
  "",
  "## Evidence",
  "",
  (if ($R.evidence | length) == 0 then "None saved." else ($R.evidence[] | "- [\(.)](\(.))") end),
  "",
  "## Reproduce",
  "",
  "```bash",
  ($R.reproduce[]),
  "```"
)
