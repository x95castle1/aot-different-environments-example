# Renders report.md from results.json (jq -r -f scripts/report-md.jq results.json).

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
        "Where the gain comes from (median startup): neither \($R.attribution.neither)s → Spring AOT only \($R.attribution.springAotOnly)s → Spring AOT + JDK AOT cache \($R.attribution.full)s. Spring AOT saved \($R.attribution.springAotSaved)s (\($R.attribution.springAotShare // "?")% of the gain), the JDK AOT cache \($R.attribution.aotCacheSaved)s (\($R.attribution.aotCacheShare // "?")%).",
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
     "## Measurements and references (information only)", "",
     ($info[] | "- \(.label): \(.measured)" + (if .why != "" then " (\(.why))" else "" end)), ""
   else empty end),
  (if ($timings | length) > 0 then
     (if any($timings[]; .metric != null) then "## Timings" else "## Startup times" end), "",
     "| Scenario | JDK AOT cache | Runs (s) | Median | Compared with | Change | Outcome |",
     "|---|---|---|---|---|---|---|",
     ($timings[] | "| \(.short | cell) | \(if .aotCache then "\(.aotCache.verdict) \(.aotCache.classes // "")" else "-" end) | \(.runs | map(if . == null then "fail" else tostring end) | join(", ")) | \(.median // "-")s | \((.compareToLabel // "-") | cell) | \(if .referenceMedian then "\(.change) (\(.median)s vs \(.referenceMedian)s)" else "-" end) | \(.outcome) |"),
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
