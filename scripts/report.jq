# Builds results.json from a run's raw records + the example's expectations.json.
# Inputs (jq --slurpfile): $exp, $run, $checks (results.jsonl), $timings (timings.jsonl); --arg evidence (file list)
# See docs/reading-reports.md for the outcome vocabulary.

def median: sort | if length == 0 then null elif length % 2 == 1 then .[(length - 1) / 2] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
# How much the runs vary: slowest / fastest, after dropping the single slowest run (one outlier is normal).
def spread: sort | (if length >= 3 then .[0:-1] else . end) | if length == 0 or .[0] <= 0 then null else .[-1] / .[0] end;
def r3: if . == null then null else (. * 1000 | round) / 1000 end;
def r2: if . == null then null else (. * 100 | round) / 100 end;
def r1: if . == null then null else (. * 10 | round) / 10 end;
# t($unit): a duration in seconds as shown in the report ("0.439s", or "28 ms" for unit "ms")
def t($unit): if . == null then "-" elif $unit == "ms" then "\(. * 1000 | round) ms" else "\(. | r3)s" end;
def change($ratio):
  if $ratio == null then ""
  elif $ratio <= 0.67 then "\((1 / $ratio) | r1)× faster"
  elif $ratio >= 1.5 then "\($ratio | r1)× slower"
  else (((($ratio - 1) * 100) | round) as $p | if $p == 0 then "±0%" elif $p > 0 then "+\($p)%" else "\($p)%" end) end;

$exp[0] as $e
| $run[0] as $r
| ($e.noiseBand // 0.25) as $band0
| ($e.inconclusiveSpread // 1.5) as $maxSpread
| ($e.minRuns // 3) as $minRuns
| (($e.scenarios // []) | map({key: .id, value: .label}) | from_entries) as $scenarioLabels
| def tlabel($id): ($e.timings.scenarios[$id].label // $scenarioLabels[$id] // $id);

# ---- AOT-cache check per scenario (check id "cache.<scenario id>"), shown next to its timing
  ($checks | map(select(.id | startswith("cache."))) | map({key: (.id | ltrimstr("cache.")), value: {
      verdict: .measured,
      classes: ((.evidenceExcerpt // "") | capture("AOT cache: (?<c>[0-9]+) / (?<t>[0-9]+)") // null | if . then "\(.c)/\(.t)" else null end)}})
   | from_entries) as $cacheBy

# ---- timing statistics per scenario
| [ $timings[] | (.runs | map(select(. != null))) as $ok
    | {id, runs: .runs, ok: $ok, min: ($ok | min), median: ($ok | median), max: ($ok | max), spread: ($ok | spread)} ] as $stats
| ($stats | map({key: .id, value: .}) | from_entries) as $S

# ---- judge each timing against its baseline (compareTo)
| [ $stats[] | . as $s
    | ($e.timings.scenarios[$s.id] // {}) as $rule
    # "reference" is the old name of "baseline"; both mean: shown for comparison, not judged
    | ($rule.expect // "info" | if . == "reference" then "baseline" else . end) as $want
    | ($rule.unit // "s") as $unit
    | (if $rule.compareTo then $S[$rule.compareTo] else null end) as $ref
    | ($rule.band // $band0) as $band
    | (if $ref != null and $ref.median != null and $s.median != null then $s.median / $ref.median else null end) as $ratio
    | (if ($s.ok | length) == 0 then "unexpected"
       elif $want == "info" or $want == "baseline" then "info"
       elif $ratio == null then "unexpected"
       # Too few runs to tell noise from a real difference
       elif ($s.ok | length) < $minRuns or ($ref.ok | length) < $minRuns then "inconclusive"
       elif (($s.spread // 1) > $maxSpread) or (($ref.spread // 1) > $maxSpread) then "inconclusive"
       elif $want == "improved" then (if $ratio <= 1 - $band then "improved" else "unexpected" end)
       # Faster than its baseline is still "unchanged": this scenario isn't meant to beat it, so it's noise.
       elif $want == "unchanged" then (if $ratio > 1 + $band then "unexpected" else "unchanged" end)
       elif $want == "no-benefit-expected" then (if $ratio >= 1 - $band then "no-benefit-expected" else "unexpected" end)
       else "unexpected" end) as $outcome
    # Optional fixed comparison columns (timings.columns): each compares every row with one scenario, for the table only.
    # The outcome above is still judged on compareTo; "judged" marks the column that matches it.
    # A column's default "*.<x>" means the row's own group: for row "first.workload", "*.untrained" is "first.untrained".
    # Baseline rows get no comparisons: they are what the others are compared with.
    | [ ($e.timings.columns // [])[] as $c
        | ($c.default // null | if . != null and startswith("*.") then ($s.id | sub("\\.[^.]*$"; "")) + ltrimstr("*") else . end) as $cdefault
        | (if ($c.scenarios // {}) | has($s.id) then $c.scenarios[$s.id] else $cdefault end) as $cref
        | ($S[$cref // ""].median // null) as $cmed
        | if $want == "baseline" or $cref == null or $cref == $s.id or $cmed == null or $s.median == null then {label: $c.label, ref: null}
          else ($s.median / $cmed) as $cr
            | {label: $c.label, ref: $cref, refLabel: (tlabel($cref) | sub(" \\((reference|baseline)\\)$"; "")), refMedian: ($cmed | r3), ratio: ($cr | r3),
               change: change($cr), detail: "(\($s.median | t($unit)) vs \($cmed | t($unit)))",
               otherRef: ($cref != $cdefault), judged: ($cref == $rule.compareTo and ($want | IN("info", "baseline") | not))} end ] as $comparisons
    | ($rule.metric // null) as $metric
    | {kind: "timing", id: $s.id, subject: null, group: ($metric // "Startup time"), metric: $metric,
       # Metric first, so rows grouped by metric read as "first request · untrained", "first request · workload-trained"
       label: (if $metric then "\($metric) · \(tlabel($s.id))" else "\(tlabel($s.id)): startup time" end),
       short: (if $metric then "\($metric) · \(tlabel($s.id))" else tlabel($s.id) end),
       baseline: ($want == "baseline"), unit: $unit,
       shown: {median: ($s.median | t($unit)),
               runs: ($s.runs | map(if . == null then "fail" elif $unit == "ms" then "\(. * 10000 | round / 10)" else tostring end))},
       runs: $s.runs, min: ($s.min | r3), median: ($s.median | r3), max: ($s.max | r3), spread: ($s.spread | r2),
       compareTo: ($rule.compareTo // null),
       compareToLabel: (if $rule.compareTo then tlabel($rule.compareTo) else null end),
       referenceMedian: ($ref.median | r3), ratio: ($ratio | r3), change: change($ratio), band: $band,
       comparisons: (if ($comparisons | length) > 0 then $comparisons else null end),
       expected: (if $want == "info" or $want == "baseline" then null
                  elif $rule.compareTo then "\($want) vs \(tlabel($rule.compareTo)) (±\(($band * 100) | round)% band)"
                  else $want end),
       measured: (if $s.median == null then "did not start"
                  elif $ratio == null then "median \($s.median | t($unit))"
                  else "median \($s.median | t($unit)) vs \(tlabel($rule.compareTo)) \($ref.median | t($unit)) (\(change($ratio)))" end
                  + (if $outcome != "inconclusive" then ""
                     elif ($s.ok | length) < $minRuns or ($ref.ok | length) < $minRuns then ", only \([($s.ok | length), ($ref.ok | length)] | min) run(s); at least \($minRuns) needed to judge"
                     else ", runs vary \(($s.spread // 0) | r1)×" end)),
       outcome: $outcome,
       why: ($rule.why // ""),
       ifUnexpected: ($rule.ifUnexpected // ["Was something else running? Check `make status`, then rerun.",
                                             "Rerun with more runs, e.g. RUNS=10."]),
       aotCache: ($cacheBy[$s.id] // null),
       evidence: null, evidenceExcerpt: null} ]
  # Rows in the order expectations.json lists them (e.g. grouped by metric), not the order they were recorded in
  | (($e.timings.scenarios // {}) | keys_unsorted) as $order
  | sort_by(.id as $id | ($order | index($id)) // 1e9) as $timingResults

# ---- attribution: what Spring AOT and the JDK AOT cache each save on their own, and together. All four
# combinations are measured, so nothing depends on which one is "added first".
| (($e.attribution // null) as $a
   | if $a == null then null else
       ($S[$a.full].median) as $f | ($S[$a.springAotOnly].median) as $o | ($S[$a.cacheOnly].median) as $c | ($S[$a.neither].median) as $n
       | if $f == null or $o == null or $c == null or $n == null then null else
           {neither: ($n | r3), springAotOnly: ($o | r3), cacheOnly: ($c | r3), full: ($f | r3),
            springAotSaved: (($n - $o) | r3), aotCacheSaved: (($n - $c) | r3), totalSaved: (($n - $f) | r3),
            sumOfEachAlone: ((($n - $o) + ($n - $c)) | r3)}
           | . + {summary: "Where the gain comes from (median startup, compared with the Plain JVM - No Cache at \(.neither)s): Spring AOT alone saves \(.springAotSaved)s, the JDK AOT cache alone saves \(.aotCacheSaved)s, and both together save \(.totalSaved)s (each alone adds up to \(.sumOfEachAlone)s)."} end end) as $attribution

| ($checks + $timingResults) as $all
| ($all | map(.outcome)) as $outcomes
| (if any($outcomes[]; . == "unexpected") then "FAIL"
   elif any($outcomes[]; . == "inconclusive") then "INCONCLUSIVE"
   else "PASS" end) as $verdict
| {
    example: $e.example,
    title: $e.title,
    kind: ($e.kind // "functional"),
    question: $e.question,
    verdict: $verdict,
    answer: ($e.answer[$verdict | ascii_downcase] // ""),
    run: $r,
    tested: ($e.tested // []),
    counts: (reduce $outcomes[] as $o ({}; .[$o] += 1)),
    attribution: $attribution,
    results: $all,
    evidence: ($evidence | split("\n") | map(select(. != "")) | map("raw/" + .)),
    reproduce: ($e.reproduce // []),
    howToRead: "docs/reading-reports.md"
  }
