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
| `improved` | Measurably better than its reference, beyond the noise band (e.g. AOT cache on vs off). | no |
| `unchanged` | A varied input didn't change the result (within the noise band). Usually the point, e.g. "heap size doesn't affect the cache". | no |
| `no-benefit-expected` | No gain, for a known and documented reason, e.g. ZGC can't use the JDK 25 AOT cache. The JVM's own message is in the evidence. | no |
| `works` | A functional check passed. | no |
| `limitation-shown` | A known limitation behaved as documented, e.g. `@Profile` beans frozen by Spring AOT. Shown on purpose. | no |
| `info` | A measurement or reference run without a pass/fail (e.g. the cache-off reference). | no |
| `inconclusive` | Timing can't be judged: fewer than 3 runs, or too noisy (slowest/fastest > 1.5 after dropping one outlier). | makes the verdict INCONCLUSIVE |
| `unexpected` | Measured ≠ expected. | makes the verdict FAIL |

## How timings are judged (examples 01, 02 and 05)

- Each scenario runs `RUNS` times; the report keeps every run plus the median.
- Each scenario is compared with a **reference** scenario named in `expectations.json`:
  - "prod flags" vs "cache off";
  - "1 CPU" vs "1 CPU, cache off" (a slow machine doesn't look like a cache problem);
  - "smaller heap" vs "prod flags";
  - in 02: each environment vs "prod1", and "prod1" vs "prod1 without Spring AOT" (JDK AOT cache still on).
- The comparison uses a **noise band** (default ±25%, set per scenario):
  - expected `improved`: the median must be at least one band faster than the reference;
  - expected `unchanged`: the median must not be more than one band slower (faster counts as noise, still `unchanged`);
  - expected `no-benefit-expected`: about as slow as the reference.
- Example 05 also reports **attribution**: how much of the startup gain comes from Spring AOT and how much from the
  JDK AOT cache (neither → Spring AOT only → both).

## Where the interpretation comes from

Each example has an `expectations.json` next to its `demo.sh`. For every check it holds:
- the label;
- the expected value;
- the outcome when it matches (`works`, `no-benefit-expected`, `limitation-shown`, ...);
- `why`: the explanation shown in the report;
- `ifUnexpected`: the hints shown when the result doesn't match.

It also holds the timing rules (reference, expectation, band), the question, and the answer for each verdict. To
change what a report says, edit that file; the demo scripts only measure.

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
  "attribution": null | { "neither", "springAotOnly", "full", "springAotSaved", "aotCacheSaved", "springAotShare", "aotCacheShare" },
  "results": [
    // checks
    { "kind": "check", "id", "subject", "group", "check", "label", "short", "expected", "measured", "outcome",
      "why", "ifUnexpected": [], "evidence": "raw/...", "evidenceExcerpt": "..." },
    // timings
    { "kind": "timing", "id", "label", "short", "runs": [s], "min", "median", "max", "spread",
      "compareTo", "compareToLabel", "referenceMedian", "ratio", "change", "band",
      "expected", "measured", "outcome", "why", "ifUnexpected": [] }
  ],
  "evidence": [ "raw/..." ], "reproduce": [ "..." ], "howToRead": "docs/reading-reports.md"
}
```

## What good looks like, per example

| Example | PASS looks like | Common unexpected results and causes |
|---|---|---|
| 01 JVM args | Prod ~2–3× faster than cache-off. Heap, memory, CPU, `-D`, GC logging and Parallel GC are `unchanged`. ZGC is `no-benefit-expected`. The guardrail refuses to start. | **Cache "not used" everywhere:** image built for another CPU architecture or JDK; rebuild on/for this platform. **ZGC "USED":** the JDK is 26+, so update the expectation. **Timings `inconclusive`:** busy machine; rerun with `RUNS=10`. |
| 02 Profiles | Profiles, values and notifier follow each env. The `@Profile`/`@ConditionalOnProperty` beans are `limitation-shown` in prod with Spring AOT and `works` (present) without Spring AOT. Every instance uses the JDK AOT cache; every env is `unchanged` vs prod1, and prod1 is `improved` (~1.6×) vs prod1 without Spring AOT. | **Pitfall bean present with AOT on:** Spring AOT isn't active (check the "Spring AOT generated code" check) or the build ran with the prod profile. **Cache "not used" everywhere:** image built for another CPU architecture or JDK. **Timings `inconclusive`:** rerun with `RUNS=10`. |
| 03 Connections | Both build steps succeed under `--network=none` with the imports skipped. dev1 loads its Config Server file and Vault path and pings Mongo. Rotation changes the fingerprint. All three broken setups refuse to start. | **Build fails offline:** `go-offline` missed a dependency. **Vault path not loaded:** Vault was restarted (in-memory), so rerun the bootstrap. **A broken setup started:** fail-fast is off at runtime. |
| 04 One image | Zero environment markers in the image. All three envs run the promoted digest with their own settings, use the AOT cache, and report one build. | **Marker found:** environment config was bundled in the jar or the image ENV. **Digest mismatch:** a deployment used a tag, not the digest. |
| 05 All together | Every env verified. dev1/qa1/prod1 use the cache; dev2 (ZGC) is `no-benefit-expected`. Spring AOT + cache is several times faster than neither, with both contributing. | **Env not healthy:** Vault restarted, so run `make -C examples/05-all-together bootstrap apps`. **Timings `inconclusive`:** rerun `startup-compare RUNS=5`. |
| 06 Training workload | Training writes `app.aot` on a clean stop, and the final image is the untrained image + 1 layer. Both caches are used. Startup is `unchanged` between them. First request and first 300 requests are `improved` with the workload cache (first 50 is info only). Fewer classes are loaded from the jars. The workload-trained image runs as dev1 and prod1 with their own profiles, Config Server files, database and Vault path, and uses the cache in both. | **Cache missing after stop:** the container was killed before assembly finished; raise the `docker stop` timeout. **Workload cache not used:** the final image wasn't built FROM the trained untrained image. **First 300 `unexpected`:** a noisy machine; rerun with `RUNS=5`. |
