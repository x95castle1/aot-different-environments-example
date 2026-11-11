# 01 · JVM arguments vary per environment

**Question:** *JVM arguments vary from environment to environment (we can choose prod as a workaround).*
Does that break the JVM AOT cache, and does startup suffer?

**Answer:** The AOT cache is trained once, in the image build, with the **prod** flags. Environments can change heap
size, container memory, CPU count, system properties, logging and even the GC (Parallel), and the cache is still
used: startup stays the same. Only flags that make the cache unusable fall back to a normal JVM start. ZGC on
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
== Startup times (median of each scenario's runs; each row is compared with the scenario named under "compared with")
  scenario                           JDK AOT cache    runs (s)                       median  compared with                    change                 outcome
  prod flags (trained with these)    USED 7547/7702   0.354 0.254 0.248 0.268 0.335  0.268s  cache off (reference)            2.5× faster vs 0.673s  improved
  smaller heap (-Xmx256m)            USED 7547/7702   0.263 0.334 0.242 0.243 0.241  0.243s  prod flags (trained with these)  -9% vs 0.268s          unchanged
  bigger fixed heap (-Xms2g -Xmx2g)  USED 7547/7702   0.241 0.232 0.232 0.231 0.293  0.232s  prod flags (trained with these)  -13% vs 0.268s         unchanged
  512 MB container, 50% RAM          USED 7547/7702   0.249 0.251 0.248 0.239 0.235  0.248s  prod flags (trained with these)  -7% vs 0.268s          unchanged
  1 CPU                              USED 7547/7704   0.777 0.714 0.769 0.714 0.794  0.769s  1 CPU, cache off (reference)     2× faster vs 1.57s     improved
  1 CPU, cache off (reference)       not used 0/7409  1.518 1.776 1.502 1.57 1.675   1.57s   -                                -                      reference
  extra -D props + GC logging        USED 7547/7702   0.236 0.238 0.246 0.241 0.243  0.241s  prod flags (trained with these)  -10% vs 0.268s         unchanged
  Parallel GC                        USED 7547/7702   0.293 0.251 0.223 0.23 0.233   0.233s  prod flags (trained with these)  -13% vs 0.268s         unchanged
  ZGC                                not used 0/7466  0.684 0.684 0.725 0.664 0.669  0.684s  cache off (reference)            +2% vs 0.673s          no-benefit-expected
  cache off (reference)              not used 0/7466  0.629 0.691 0.673 1.892 0.643  0.673s  -                                -                      reference
```

- **JDK AOT cache** column: whether the JVM used the cache, and how many of the loaded classes came from it.
- **compared with / change**: each row is judged against its reference:
  - prod against prod-with-cache-off (what the cache is worth);
  - other flags against prod (did the flag change anything?);
  - 1 CPU against 1 CPU with the cache off.
- After the table: ZGC + `-XX:AOTMode=on` **refuses to start** (the guardrail check).

Reading it:
- With compatible flags, startup stays at the prod baseline, because the same ~7,500 classes come from the cache.
- One CPU is slower for every app (less CPU). The cache is still used and still helps; compare with the "cache off"
  reference row.
- ZGC startup equals "cache off": the JVM printed `Unable to use AOT cache` and started normally.

## Reading the report

`make demo` writes `reports/01-jvm-args/<run>/report.md` (for people) and `results.json` (for scripts and agents), plus the
evidence in `raw/`. The terminal ends with the verdict, the answer, and what improved, what didn't and what was
unexpected. PASS means every flag scenario behaved as known: the cache helps prod (`improved` vs cache-off), compatible flags are `unchanged` vs prod, ZGC is `no-benefit-expected` (the JVM's reason is quoted from `-Xlog:aot`), and the guardrail refuses to start. A noisy machine gives `inconclusive` timings: rerun with `RUNS=10`. What each outcome means and how timings are judged: [docs/reading-reports.md](../../docs/reading-reports.md).
The labels, expected values and explanations come from [`expectations.json`](expectations.json).

## How it works

- [`Dockerfile`](Dockerfile) sets the prod flags once
  (`ENV JDK_JAVA_OPTIONS=-XX:+UseG1GC -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError`) and trains the cache
  with them (`-XX:AOTCacheOutput`, `-Dspring.context.exit=onRefresh`, `--network=none`).
- Prod doesn't set `JDK_JAVA_OPTIONS`, so it runs with exactly the trained flags. Every other environment overrides it.
- The JVM checks compatibility at startup (`-XX:AOTMode=auto`, the default): use the cache if possible, otherwise warn
  and continue.
- [`demo.sh`](demo.sh) counts classes loaded from `shared objects file` with `-Xlog:class+load` (see
  `AOT_USAGE_SCRIPT` in [`scripts/lib.sh`](../../scripts/lib.sh)) and takes Spring's `Started … in X seconds`.

## Pitfalls

- The cache is tied to the **JDK build, CPU architecture and classpath**. Build the image for the platform you deploy
  to (`docker buildx build --platform linux/amd64`); multi-arch images train once per platform.
- **ZGC needs JDK 26+** to use the AOT cache (JEP 516). On JDK 25 it silently falls back unless `AOTMode=on`.
- A heap above ~32 GB turns compressed oops off; check with this demo's method (`-Xlog:class+load`) before relying on it.
- APM agents (`-javaagent`) can change class loading; measure them the same way.
