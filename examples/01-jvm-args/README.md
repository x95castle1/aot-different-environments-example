# 01 · JVM arguments vary per environment

**Question:** *JVM arguments vary from environment to environment (we can choose prod as a workaround).*
Does that break the JVM AOT cache, and does startup suffer?

**Answer:** The AOT cache is trained once, in the image build, with the **prod** flags. Environments can change heap
size, container memory, CPU count, system properties, logging and even the GC (Parallel), and the cache is still
used: startup stays the same. Only flags that make the cache unusable fall back to a start without it. ZGC on
JDK 25 is the example here. If you'd rather fail than fall back, `-XX:AOTMode=on` turns the fallback into a
startup error.

No external services needed.

## What's in this folder

Everything this example builds and runs; nothing outside it is needed (only `make demo`'s report uses the repo's
shared demo harness in [`scripts/`](../../scripts)).

| Path | What it is |
|---|---|
| [`app/`](app) | jvm-args-app, the Spring Boot app (Maven module); `GET /info/jvm` shows the flags and the cache in use |
| [`Dockerfile`](Dockerfile) | the image: offline Maven build with Spring AOT, then the JDK AOT cache trained with the prod flags |
| [`pom.xml`](pom.xml), `mvnw` | this example's Maven build (`make test`, local JDK 25) |
| [`demo.sh`](demo.sh), [`expectations.json`](expectations.json) | the demo and what it expects |

## Run it

```bash
make demo          # = ./demo.sh: build the image, run every scenario 5x, print the table
make demo RUNS=10  # more runs per scenario
make run FLAGS="-XX:+UseG1GC -Xmx128m"   # one instance on :8101 with your own flags, then GET /info/jvm
```

## What you'll see (Apple Silicon, Docker Desktop, JDK 25)

The run ends with this table in the terminal, then the verdict. The same table is in the report.

```
== Startup times (median of each scenario's runs; each column compares every row with one scenario; * = the comparison its outcome is judged on)
  scenario                           JDK AOT cache    runs (s)                       median  vs cache off                         vs prod (trained flags)  outcome
  prod flags (trained with these)    USED 7505/7662   0.233 0.239 0.236 0.238 0.247  0.238s  2.4× faster *                        -                        improved
  smaller heap (-Xmx256m)            USED 7505/7662   0.254 0.238 0.238 0.232 0.232  0.238s  2.4× faster                          ±0% *                    unchanged
  bigger fixed heap (-Xms2g -Xmx2g)  USED 7505/7662   0.237 0.235 0.23 0.231 0.227   0.231s  2.5× faster                          -3% *                    unchanged
  512 MB container, 50% RAM          USED 7505/7704   0.244 0.244 0.241 0.239 0.254  0.244s  2.4× faster                          +3% *                    unchanged
  1 CPU                              USED 7505/7665   0.778 0.779 0.717 0.768 0.799  0.778s  1.9× faster (vs 1 CPU, cache off) *  -                        improved
  1 CPU, cache off (baseline)        not used 0/7419  1.687 1.499 1.507 1.502 1.498  1.502s  -                                    -                        baseline
  extra -D props + GC logging        USED 7505/7662   0.232 0.232 0.231 0.23 0.233   0.232s  2.5× faster                          -3% *                    unchanged
  Parallel GC                        USED 7505/7662   0.231 0.225 0.227 0.232 0.233  0.231s  2.5× faster                          -3% *                    unchanged
  ZGC                                not used 0/7420  0.64 0.635 0.611 0.644 0.611   0.635s  +9% *                                2.7× slower              no-benefit-expected
  cache off (baseline)               not used 0/7463  0.581 0.579 0.579 0.584 0.58   0.58s   -                                    -                        baseline
```

- **JDK AOT cache** column: whether the JVM used the cache, and how many of the loaded classes came from it. The
  ~1,400 in the two "cache off" rows come from the JDK's own default class archive (CDS), which a plain JVM uses.
  ZGC shows 0: a cache the JVM rejects switches that default archive off too.
- **vs cache off**: how much the cache is worth with these flags, compared with the same image started as a plain
  JVM (prod flags, no `-XX:AOTCache`). The 1 CPU row is compared with 1 CPU and no cache instead, because one CPU
  slows every start.
- **vs prod (trained flags)**: did these flags lose any of the cache's benefit compared with the prod flags it was
  trained with? Prod isn't a baseline: it's judged itself (vs cache off), and it's the target every compatible flag
  set should match.
- **\***: the comparison the outcome is judged on:
  - prod is judged on vs cache off (the cache must help);
  - the other compatible flags on vs prod (they must keep the full benefit, so a partial cache hit still fails);
  - 1 CPU on vs 1 CPU, cache off;
  - ZGC on vs cache off (no benefit expected).
- After the table: ZGC + `-XX:AOTMode=on` **refuses to start** (the guardrail check).

Reading it:
- With compatible flags, startup stays at the prod baseline, because the same ~7,500 classes come from the cache.
- One CPU is slower for every app (less CPU). The cache is still used and still helps; compare with the "cache off"
  baseline row.
- ZGC starts about as fast as "cache off" (a little slower): the JVM printed `Unable to use AOT cache` and started
  without it, and without the JDK's default class archive.

## Reading the report

`make demo` writes `reports/01-jvm-args/<run>/report.md` (for people) and `results.json` (for scripts and agents), plus the
evidence in `raw/`. The terminal ends with the verdict, the answer, and what improved, what didn't and what was
unexpected. PASS means every flag scenario behaved as known: the cache helps prod (`improved` vs cache-off), compatible flags are `unchanged` vs prod, ZGC is `no-benefit-expected` (the JVM's reason is quoted from `-Xlog:aot`), and the guardrail refuses to start. A noisy machine gives `inconclusive` timings: rerun with `RUNS=10`. What each outcome means and how timings are judged: [docs/reading-reports.md](../../docs/reading-reports.md).
The labels, expected values and explanations come from [`expectations.json`](expectations.json).

## How it works

- [`Dockerfile`](Dockerfile) sets the prod flags once
  (`ENV JDK_JAVA_OPTIONS=-XX:+UseG1GC -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError`) and trains the cache
  with them (`-XX:AOTCacheOutput`, `-Dspring.context.exit=onRefresh`, `--network=none`), plus an explicit `-Xmx1g`
  so the build machine's RAM doesn't decide the heap (see Pitfalls). A second `RUN` then starts the app once with
  `-XX:AOTMode=on -Xmx256m`: a cache that a small environment couldn't use fails the build.
- Prod doesn't set `JDK_JAVA_OPTIONS`, so it runs with exactly the trained flags. Every other environment overrides it.
- The JVM checks compatibility at startup (`-XX:AOTMode=auto`, the default): use the cache if possible, otherwise warn
  and continue.
- The two "cache off" baselines start the same image without `-XX:AOTCache` (the entrypoint is overridden), i.e. as
  a plain JVM. They don't use `-XX:AOTMode=off`: that also switches off the JDK's default class archive, which
  every plain JVM has, and would make the baseline slower than a real one.
- [`demo.sh`](demo.sh) counts classes loaded from `shared objects file` with `-Xlog:class+load` (see
  `AOT_USAGE_SCRIPT` in [`scripts/lib.sh`](../../scripts/lib.sh)) and takes Spring's `Started … in X seconds`.

## Pitfalls

- The cache is tied to the **JDK build, CPU architecture and classpath**. Build the image for the platform you deploy
  to (`docker buildx build --platform linux/amd64`); multi-arch images train once per platform.
- **ZGC needs JDK 26+** to use the AOT cache (JEP 516). On JDK 25 it silently falls back unless `AOTMode=on`.
- **The fallback is slightly worse than no cache.** A cache the JVM rejects also disables the JDK's default class
  archive, so that start is a few percent slower than the same JVM without `-XX:AOTCache`. An environment that has
  to keep incompatible flags is better off started without the flag (override the entrypoint).
- **Compressed oops must match the training run.** A heap above ~32 GB turns them off, and the JVM then rejects a
  cache recorded with them (and the other way round). That includes the training run itself: `docker build` has no
  memory limit, so with `MaxRAMPercentage=75` a build machine with more than ~43 GB of RAM would record a cache
  that every smaller environment rejects. Hence the explicit `-Xmx` and the `-XX:AOTMode=on` check in the
  [`Dockerfile`](Dockerfile).
- APM agents (`-javaagent`) can change class loading; measure them the same way.
