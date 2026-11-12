# Reading the run reports

Every example's demo (`make examples`, or `make -C examples/NN-* demo`) writes a report:

```
reports/<example>/<run id>/
  report.md      for people: verdict, answer, what was tested, what improved / works, what didn't and why,
                 unexpected results with what to check, all checks, evidence, how to reproduce
  results.json   the same, structured (schema below), for scripts and agents
  raw/           evidence: startup logs, the JVM's AOT-cache messages, class-load counts, /info JSON, build logs
  run.json, results.jsonl, timings.jsonl   the raw records results.json was built from
reports/<example>/latest -> the newest run
reports/all/<run id>/summary.md|json      after `make examples EX=all`: one line per example
```

`reports/` is git-ignored. Rerunning never overwrites an older run.

## Verdict

| Verdict | Meaning | What to do |
|---|---|---|
| `PASS` | Every result matched what the example is known to show. | Read the **Answer** and the improved / didn't-improve sections. |
| `FAIL` | At least one result is `unexpected`. | Read **Unexpected results**: each lists expected vs measured, why it was expected and what to check. |
| `INCONCLUSIVE` | Nothing unexpected, but some timings varied too much to judge. | Close other workloads and rerun with more runs (`RUNS=10`). Not a failure. |
| `ERROR` (summary only) | The demo stopped before writing its report. | Rerun that example alone and read the terminal output. |

## Outcomes (every result has exactly one)

| Outcome | Meaning | Counts against the verdict? |
|---|---|---|
| `improved` | Measurably better than its baseline, beyond the noise band (e.g. AOT cache on vs off). | no |
| `unchanged` | A varied input didn't change the result (within the noise band). Usually the point, e.g. "heap size doesn't affect the cache". | no |
| `no-benefit-expected` | No gain, for a known and documented reason, e.g. ZGC can't use the JDK 25 AOT cache. The JVM's own message is in the evidence. | no |
| `works` | A functional check passed. | no |
| `limitation-shown` | A known limitation behaved as documented, e.g. `@Profile` beans frozen by Spring AOT. Shown on purpose. | no |
| `info` | A measurement without a pass/fail. In timing tables, the rows the others are compared with are shown as `baseline` (e.g. the cache-off run); in results.json they are `info` with `"baseline": true`. | no |
| `inconclusive` | Timing can't be judged: fewer than 3 runs, or too noisy (slowest/fastest > 1.5 after dropping one outlier). | makes the verdict INCONCLUSIVE |
| `unexpected` | Measured ≠ expected. | makes the verdict FAIL |

## How timings are judged (examples 01, 02, 05 and 06)

- Each scenario runs `RUNS` times; the report keeps every run plus the median.
- Each scenario is judged against a **baseline** scenario named in `expectations.json` (`compareTo`):
  - "prod flags" vs "cache off";
  - "1 CPU" vs "1 CPU, cache off" (a slow machine doesn't look like a cache problem);
  - "smaller heap" vs "prod flags";
  - in 02: each environment vs "prod1", and "prod1" vs "prod1 without Spring AOT" (which has a JDK AOT cache
    trained for its own start, so only Spring AOT differs).
  - in 06: per metric, context-trained vs untrained and workload-trained vs context-trained.
- A scenario with `"expect": "baseline"` isn't judged itself; it's only there to compare with (e.g. cache off). A
  judged scenario can also be compared with, like 01's prod flags, but it isn't a baseline. (`"reference"`,
  the old name, still works.)
- Optionally, `timings.columns` in `expectations.json` adds fixed comparison columns to the table, so every row is
  compared with the same scenarios (01: "vs cache off" and "vs prod (trained flags)"). Each column has a `default` scenario and
  per-scenario overrides (`null` = no comparison). A default of `*.<x>` means the row's own group: in 06, for the
  row `first.workload`, `*.untrained` is `first.untrained` (the same metric). Baseline rows show no comparisons.
  These columns are for reading only; a `*` marks the one that matches the row's `compareTo`, which is what the
  outcome is judged on.
- Rows are listed in the order of `timings.scenarios` in `expectations.json` (06: grouped by metric). A scenario with
  `"unit": "ms"` is shown in milliseconds (06's first request); results.json keeps seconds.
- The comparison uses a **noise band** (default ±25%, set per scenario):
  - expected `improved`: the median must be at least one band faster than the baseline;
  - expected `unchanged`: the median must not be more than one band slower (faster counts as noise, still `unchanged`);
  - expected `no-benefit-expected`: about as slow as the baseline.
- Example 05 also reports **attribution**: prod1 is timed in all four combinations of Spring AOT and the JDK AOT cache
  (on or off each), so the report states what each one saves on its own and what both save together, with no
  assumption about which is added first. The start with the cache but without Spring AOT uses a cache trained for
  that start: a cache only helps the start it was trained on.

## Where the interpretation comes from

Each example has an `expectations.json` next to its `demo.sh`. For every check it holds:
- the label;
- the expected value;
- the outcome when it matches (`works`, `no-benefit-expected`, `limitation-shown`, ...);
- `why`: the explanation shown in the report;
- `ifUnexpected`: the hints shown when the result doesn't match.

It also holds the timing rules (baseline, expectation, band), the question, and the answer for each verdict. To
change what a report says, edit that file; the demo scripts only measure. Its `preview` block (a few one-line
`steps` and a one-sentence `answer`) is only for the `make examples` picker's preview pane, not the report.

## results.json schema

```jsonc
{
  "example": "01-jvm-args", "title": "...", "kind": "performance | functional | mixed",
  "question": "...", "verdict": "PASS | FAIL | INCONCLUSIVE", "answer": "...",
  "run": { "started", "finished", "revision", "uncommittedChanges", "host", "timedRunsPerScenario",
           "docker": { "version", "arch", "cpus", "memGb" },
           "images": [ { "ref", "id", "digest", "jdk", "trainingFlags", "created", "revision" } ] },
  "tested": [ "..." ],
  "counts": { "<outcome>": n },
  "attribution": null | { "neither", "springAotOnly", "cacheOnly", "full", "springAotSaved", "aotCacheSaved", "totalSaved", "sumOfEachAlone", "summary" },
  "results": [
    // checks
    { "kind": "check", "id", "subject", "group", "check", "label", "short", "expected", "measured", "outcome",
      "why", "ifUnexpected": [], "evidence": "raw/...", "evidenceExcerpt": "..." },
    // timings
    { "kind": "timing", "id", "label", "short", "runs": [s], "min", "median", "max", "spread",
      "compareTo", "compareToLabel", "referenceMedian", "ratio", "change", "band", "baseline": bool, "unit": "s | ms",
      "shown": { "median", "runs": [] },   // as displayed, in the row's unit
      "comparisons": null | [ { "label", "ref", "refLabel", "refMedian", "ratio", "change", "otherRef", "judged" } ],
      "expected", "measured", "outcome", "why", "ifUnexpected": [] }
  ],
  "evidence": [ "raw/..." ], "reproduce": [ "..." ], "howToRead": "docs/reading-reports.md"
}
```

## What good looks like, per example

| Example | PASS looks like | Common unexpected results and causes |
|---|---|---|
| 01 JVM args | Prod ~2–3× faster than cache-off. Heap, memory, CPU, `-D`, GC logging and Parallel GC are `unchanged`. ZGC is `no-benefit-expected`. The guardrail refuses to start. | **Cache "not used" everywhere:** image built for another CPU architecture or JDK; rebuild on/for this platform. **ZGC "USED":** the JDK is 26+, so update the expectation. **Timings `inconclusive`:** busy machine; rerun with `RUNS=10`. |
| 02 Profiles | Profiles, values and notifier follow each env. The `@Profile`/`@ConditionalOnProperty` beans are `limitation-shown` in prod with Spring AOT and `works` (present) without Spring AOT. Every instance uses the JDK AOT cache; every env is `unchanged` vs prod1, and prod1 is `improved` (~30% faster) vs prod1 without Spring AOT. | **Pitfall bean present with AOT on:** Spring AOT isn't active (check the "Spring AOT generated code" check) or the build ran with the prod profile. **Cache "not used" everywhere:** image built for another CPU architecture or JDK. **Timings `inconclusive`:** rerun with `RUNS=10`. |
| 03 Connections | Both build steps succeed under `--network=none` with the imports skipped. dev1 loads its Config Server file and Vault path and pings Mongo. Rotation changes the fingerprint. All three broken setups refuse to start. | **Build fails offline:** `go-offline` missed a dependency. **Vault path not loaded:** Vault was restarted (in-memory), so rerun the bootstrap. **A broken setup started:** fail-fast is off at runtime. |
| 04 One image | Zero environment markers in the image. All three envs run the promoted digest with their own settings, use the AOT cache, and report one build. | **Marker found:** environment config was bundled in the jar or the image ENV. **Digest mismatch:** a deployment used a tag, not the digest. |
| 05 All together | Every env verified. dev1/qa1/prod1 use the cache; dev2 (ZGC) is `no-benefit-expected`. Spring AOT + cache is several times faster than the Plain JVM - No Cache, with both contributing. | **Env not healthy:** Vault restarted, so run `make -C examples/05-all-together bootstrap apps`. **Timings `inconclusive`:** rerun `startup-compare RUNS=5`. |
| 06 Training workload | Training writes `app.aot` on a clean stop, and the final image is the untrained image + 1 layer. Both caches are used. Startup is `unchanged` between them. First request and first 300 requests are `improved` with the workload cache (first 50 is info only). Fewer classes are loaded from the jars. The workload-trained image runs as dev1 and prod1 with their own profiles, Config Server files, database and Vault path, and uses the cache in both. | **Cache missing after stop:** the container was killed before assembly finished; raise `stop_grace_period` in `training/compose.yml`. **Workload cache not used:** the final image wasn't built FROM the trained untrained image. **First 300 `unexpected`:** a noisy machine; rerun with `RUNS=10`. |
