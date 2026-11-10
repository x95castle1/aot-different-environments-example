# Notes for agents running these examples

This repo answers four questions about Spring AOT + the JDK AOT cache with one example each, a combined one, and one on
training the cache with a real workload (see
README.md). Each example measures, then writes a report that already interprets the results.

## Run

```bash
make examples EX=01      # 01..06, or EX=all (no fzf picker when EX is given)
make test                # unit + architecture tests (needs a local JDK 25)
make status              # which demo is running (how far along), all containers, the last report
make stop                # stop everything
```

Needs Docker (running), `jq`, `curl` and `unzip`. Examples 03 and 05 start Config Server, Vault and MongoDB
themselves. Exit code 0 means PASS or INCONCLUSIVE, 1 means FAIL.

## Read the results

- Single example: `reports/<example>/latest/results.json`. After `EX=all`: `reports/all/latest/summary.json`.
- Read `verdict`, then `answer` (the conclusion in plain words), then `results[]`:
  - `outcome` is one of `improved`, `unchanged`, `no-benefit-expected`, `works`, `limitation-shown`, `info`,
    `inconclusive`, `unexpected`;
  - `why` explains the result;
  - `ifUnexpected` lists what to check when `outcome` is `unexpected`;
  - `evidence` points to a raw file, and `evidenceExcerpt` has its key lines.
- `no-benefit-expected` and `limitation-shown` are **expected** results that the examples demonstrate on purpose
  (e.g. ZGC can't use the JDK 25 AOT cache; `@Profile` beans are frozen by Spring AOT). Don't report them as problems.
- `inconclusive` means noisy timings: rerun with `RUNS=10` before drawing conclusions. It is not a failure.
- Timings depend on the machine: compare ratios (`ratio`, `change`, `attribution`), not absolute seconds.

Full guide: [docs/reading-reports.md](docs/reading-reports.md).

## Change the interpretation, not the measurement

What a report says (labels, expected values, explanations, hints, timing references and noise bands) lives in
`examples/<example>/expectations.json`. The `demo.sh` scripts only measure and call `expect` / `record_timing`
(see `scripts/lib.sh`). Rendering: `scripts/report.jq` (judging) and `scripts/report-md.jq` (Markdown).
