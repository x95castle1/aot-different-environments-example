# 01 · JVM arguments vary per environment

**Question:** *JVM arguments vary from environment to environment (we can choose prod as a workaround).*
Does that break the JVM AOT cache, and does startup suffer?

**Answer:** The AOT cache is trained once, in the image build, with the **prod** flags. Environments can change heap
size, container memory, CPU count, system properties, logging and even the GC (Parallel), and the cache is still
used: startup stays the same. Only flags that make the cache unusable fall back to a normal JVM start. ZGC on
JDK 25 is the example here. If you'd rather fail than fall back, `-XX:AOTMode=on` turns the fallback into a
startup error.

No external services needed.

## Run it

```bash
make demo          # build the image, run every scenario 5x, print the table
make demo RUNS=10  # more runs per scenario
make run FLAGS="-XX:+UseG1GC -Xmx128m"   # one instance on :8101 with your own flags, then GET /info/jvm
```

## What you'll see (Apple Silicon, Docker Desktop, JDK 25)

| Scenario | AOT cache | Classes from cache | Startup |
|---|---|---|---|
| prod flags (trained with these) | USED | 7547 / 7704 | ~0.30 s |
| `-Xmx256m` | USED | 7547 / 7702 | ~0.28 s |
| `-Xms2g -Xmx2g` | USED | 7547 / 7702 | ~0.35 s |
| 512 MB container, `MaxRAMPercentage=50` | USED | 7547 / 7702 | ~0.29 s |
| `--cpus 1` | USED | 7547 / 7704 | ~0.89 s |
| `--cpus 1`, cache off (reference) | not used | 0 / 7466 | slower still |
| extra `-D` props + `-Xlog:gc` | USED | 7547 / 7702 | ~0.35–0.45 s (GC logging to stdout) |
| Parallel GC | USED | 7547 / 7702 | ~0.30 s |
| ZGC | **not used** | 0 / 7466 | ~0.79 s |
| `-XX:AOTMode=off` (reference) | not used | 0 / 7466 | ~0.74 s |
| ZGC + `-XX:AOTMode=on` | — | — | **refuses to start** |

Reading it:
- With compatible flags, startup stays at the prod baseline, because the same ~7,500 classes come from the cache.
- One CPU is slower for every app (less CPU). The cache is still used and still helps; compare with the "cache off"
  reference row.
- ZGC startup equals "cache off": the JVM printed `Unable to use AOT cache` and started normally.

## How it works

- [`docker/app.Dockerfile`](../../docker/app.Dockerfile) sets the prod flags once
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
