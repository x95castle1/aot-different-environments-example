# Experiment: JIT compiler threads vs startup and warm-up

Why example 01's "512 MB container, 50% RAM" scenario started ~25-30% faster than prod, and whether that makes
lowering `-XX:CICompilerCount` a good tuning tip. Short answer: **it doesn't.**

## Findings

- **Cause:** a container memory limit makes the JVM start fewer C2 compiler threads. It adds one only while ~200 MB
  of memory is free, so a 512 MB container gets 2 C2 threads where the whole host gets 8.
- **Startup:** with the AOT cache on, fewer C2 threads start faster (0.43s with 12 compiler threads → 0.31s with 2).
  With the cache off, it barely matters (0.91s → 0.90s).
- **Peak throughput:** the same (~17k req/s) at every count except 2.
- **Time to peak:** fewer threads take **3-6 seconds longer** to get there. The default reached it in ~5s, 4 threads
  took ~9s, 3 threads took ~11-13s, and 2 threads hadn't reached it after 160k requests.
- **Recommendation:** leave the default for services that take traffic after startup. Consider 3-4 only where
  startup is the whole job (CLIs, batch, scale-to-zero). Never use 2.
- **A CPU limit already sets it:** the JVM's default is 2 at 1-2 CPUs, 3 at 4 CPUs, 4 at 8 CPUs, and 12 at 16. The
  big default only applies when a container sees every host CPU.

## Host

- **CPU:** AMD Ryzen 9 7940HS, 8 cores / 16 threads
- **Memory:** 29 GB
- **Software:** Docker 29.9.3, JDK 25.0.5+8
- **Other load:** a few unrelated containers were running throughout (same for every config)
- **Load generator:** curl, on the same host (it competes for the same 16 hardware threads)

## How the cause was found (example 01, `jvm-args-app:1.0.0`)

Medians of 5 starts, Spring's "Started ... in X seconds".

| Probe | Result | Ruled out / showed |
|---|---|---|
| `mem512` re-run | 0.29-0.32s, tight | Not noise |
| Prod flags + `--memory 512m` | 0.30s | The flag `MaxRAMPercentage=50` isn't it; the limit is |
| `-Xms8m` on prod / `-Xms256m` on mem512 | No change either way | Not initial heap size (the main `PrintFlagsFinal` difference) |
| Prod flags + `-XX:MaxRAM=512m`, no limit | 0.44s | Not heap ergonomics; something reads the container's real free memory |
| `--memory 2g` / `--memory 8g` | 0.41-0.43s | Only kicks in below ~2 GB |
| `-Xlog:jit+thread=debug` | 4 C1 + 8 C2 (no limit) vs 4 C1 + 2 C2 (512 MB, "free memory: 463MB") | The difference |
| Prod + `-XX:CICompilerCount=3`, no limit | 0.33s | Capping compiler threads reproduces most of it |
| `mem512-off` (512 MB, cache off) vs cache off | 0.897s vs 0.914s | With the cache off, the thread count barely matters |

## The sweeps

| Script | Measures | Needs | Raw results |
|---|---|---|---|
| [startup-sweep.sh](startup-sweep.sh) | Startup only, example 01, no limits, 10 rounds | `make examples EX=01` | [results/startup-sweep.txt](results/startup-sweep.txt) |
| [warmup-sweep.sh](warmup-sweep.sh) | Startup, 300-request warm-up, throughput under example 06's request mix, 3 rounds | `make -C examples/06-training-workload train envs` | [results/warmup-sweep.txt](results/warmup-sweep.txt), [results/warmup-sweep-long.txt](results/warmup-sweep-long.txt) (`LONG=6`, 2 rounds) |
| [peak-sweep.sh](peak-sweep.sh) | Time to peak: 8 phases × 20k read-only requests on fixed data, 2 rounds | same as above | [results/peak-sweep.txt](results/peak-sweep.txt) |

- **Config names:** `1g-*` is example 06's prod1 as `compose.yml` defines it (1 GB limit); `nolimit-*` removes the
  limit ([nolimit.yml](nolimit.yml)); the number is `-XX:CICompilerCount`.
- **Ordering:** configs run round-robin, so background drift hits every config equally.
- **Afterwards:** `make -C examples/06-training-workload stop`.

### Startup (example 01, medians of 10)

| `CICompilerCount` | default (12) | 8 | 6 | 4 | 3 | 2 |
|---|---|---|---|---|---|---|
| Startup | 0.431s | 0.381s | 0.344s | 0.350s | 0.324s | 0.307s |

### Time to peak (example 06, prod1, read-only load)

| Config | C2 threads (max) | Startup | Time to 15k req/s | 160k requests took | Last phase |
|---|---|---|---|---|---|
| nolimit-default | 8 | 0.70s | **5.3s** | **12.4s** | ~17k |
| nolimit-4 | 3 | 0.55s | 8.6s | 13.3s | ~17k |
| nolimit-3 | 2 | 0.51s | 11.0s | 14.5s | ~17k |
| 1g-default | 4 (memory-capped) | 0.56s | 7.3-8.6s | 13.4s | ~17k |
| 1g-3 | 2 | 0.53s | 12.9s | 15.3s | ~16-17k |
| 1g-2 | 1 | 0.50s | never | 19.2s | 12.3k |

- **The first ~20k requests:** fewer threads are faster (~6,000 vs ~5,100 req/s). The default overtakes in phase 2.
- **Time to 15k req/s:** the cumulative time of the phases up to the first phase at ≥ 15k req/s.

## Caveats

- **The early-load numbers in `warmup-sweep.txt` look like a win for fewer threads.** Example 06's mix is 40%
  creates, so the data keeps growing and Mongo writes become the bottleneck, which hides the JIT. That's why the
  long phases decline identically for every config, and why `peak-sweep.sh` uses read-only requests on fixed data.
- **Contention:** load generator, app, Mongo and compiler threads all share one host, which likely exaggerates the
  cost of compiler threads.
- **Scope:** one workload, 2-3 rounds per config.
- **Heap:** the `1g-*` and `nolimit-*` configs also differ in heap size; compare within a group.
- **Thread counts:** `c1`/`c2` in `warmup-sweep*.txt` count compiler threads *started*. The JVM retires idle ones
  and starts them again, so the number can exceed the maximum.
