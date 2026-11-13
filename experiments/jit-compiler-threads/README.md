# Experiment: JIT compiler threads vs startup and warm-up

Why example 01's "512 MB container, 50% RAM" scenario starts ~25-30% faster than prod wherever the container sees
16 or more CPUs, and whether that makes lowering `-XX:CICompilerCount` a good tuning tip. Short answer: **it
doesn't.**

## Findings

- **Cause:** a container memory limit makes the JVM start fewer C2 compiler threads. It allows one per ~200 MB of
  free memory, so a 512 MB container gets 2 C2 threads where the whole host gets 8.
- **Only where the default is large:** the JVM's default is 2 compiler threads at 1-3 CPUs, 3 at 4-7, 4 at 8-15 and
  12 at 16-31. A container that sees fewer than 16 CPUs already has a small default, so the memory cap changes
  little and example 01's 512 MB scenario matches prod there. Probe on the second host, medians of 8 starts of
  `docker run [--memory 512m] -e JDK_JAVA_OPTIONS="<prod flags> [-XX:ActiveProcessorCount=8]" jvm-args-app:1.0.0`:
  0.309s vs 0.227s with all 18 CPUs, 0.217s vs 0.216s when the JVM is told it has 8.
- **Startup:** fewer compiler threads start faster: 0.43s with 12 compiler threads → 0.31s with 2 (AOT cache on).
- **It isn't specific to the AOT cache.** On the second host the saving is about 0.1s either way: 0.30s → 0.19s
  with the cache on, 0.59s → 0.49s with it off. The cache only makes it a larger share of a shorter start. (On the
  first host a single probe with the cache off showed almost none: 0.91s → 0.90s under a 512 MB limit.)
- **Peak throughput:** every count ends on the same plateau, except 2 on the first host, which hadn't got there
  after 160k requests. The plateau is the load path's ceiling rather than the app's peak (see Caveats), so this
  shows that none of them ends up slower than the load generator, not that their compiled code is equally fast.
- **Time to peak:** fewer threads take longer to get there. First host: the default reached it in ~5s, 4 threads
  took ~9s, 3 threads ~11-13s. Second host, where the plateau is lower and reached sooner: 3 and 4 threads were
  within ~0.5s of the default (one 3-thread run took 2.5s longer), 2 threads took 8s longer.
- **Recommendation:** leave the default for services that take traffic after startup. Consider 3-4 only where
  startup is the whole job (CLIs, batch, scale-to-zero). Don't force 2 on a container with more than a few CPUs:
  it was by far the slowest to warm up on both hosts. (2 is the JVM's own default at 1-3 CPUs.)
- **A CPU limit already sets it:** see the defaults above. The big default only applies when a container sees 16
  or more CPUs, typically every CPU of a large host.

## Hosts

| | First host (everything not marked otherwise) | Second host ([results/second-host/](results/second-host)) |
|---|---|---|
| **CPU** | AMD Ryzen 9 7940HS, 8 cores / 16 threads | Apple M5 Pro; the Docker Desktop VM sees 18 CPUs |
| **Memory** | 29 GB | 23.4 GB (the VM) |
| **Software** | Docker 29.9.3, JDK 25.0.5+8 | Docker Desktop (engine 29.9.3), JDK 25.0.5+8 |
| **Other load** | a few unrelated containers throughout (same for every config) | no other containers |
| **Load generator** | curl, on the same host (it competes for the same 16 hardware threads) | curl on macOS, through Docker Desktop's port forwarding |

The second host reruns the sweeps to see what carries over. It adds the cache-off startup sweep and the 16-worker
peak run, which the first host doesn't have.

## How the cause was found (example 01, `jvm-args-app:1.0.0`)

Medians of 5 starts, Spring's "Started ... in X seconds". These were interactive probes on the first host; they
aren't scripted, so there are no raw results for them.

| Probe | Result | Ruled out / showed |
|---|---|---|
| `mem512` re-run | 0.29-0.32s, tight | Not noise |
| Prod flags + `--memory 512m` | 0.30s | The flag `MaxRAMPercentage=50` isn't it; the limit is |
| `-Xms8m` on prod / `-Xms256m` on mem512 | No change either way | Not initial heap size (the main `PrintFlagsFinal` difference) |
| Prod flags + `-XX:MaxRAM=512m`, no limit | 0.44s | Not heap ergonomics; something reads the container's real free memory |
| `--memory 2g` / `--memory 8g` | 0.41-0.43s | Only kicks in below ~2 GB |
| `-Xlog:jit+thread=debug` | 4 C1 + 8 C2 (no limit) vs 4 C1 + 2 C2 (512 MB, "free memory: 463MB") | The difference |
| Prod + `-XX:CICompilerCount=3`, no limit | 0.33s | Capping compiler threads reproduces most of it |
| `mem512-off` (512 MB, `-XX:AOTMode=off`) vs `-XX:AOTMode=off` | 0.897s vs 0.914s | On this host, almost no difference with the cache off. The second host's sweep does show one (below) |

## The sweeps

| Script | Measures | Needs | Raw results |
|---|---|---|---|
| [startup-sweep.sh](startup-sweep.sh) | Startup only, example 01, no limits, AOT cache on and off, 10 rounds | `make examples EX=01` | [results/startup-sweep.txt](results/startup-sweep.txt) (cache on only: it predates the cache-off configs), [results/second-host/startup-sweep.txt](results/second-host/startup-sweep.txt) |
| [warmup-sweep.sh](warmup-sweep.sh) | Startup, 300-request warm-up, throughput under example 06's request mix, 3 rounds | `make -C examples/06-training-workload train envs` | [results/warmup-sweep.txt](results/warmup-sweep.txt), [results/warmup-sweep-long.txt](results/warmup-sweep-long.txt) (`LONG=6`, 2 rounds) |
| [peak-sweep.sh](peak-sweep.sh) | Time to peak: 8 phases × 20k read-only requests on fixed data, 2 rounds | same as above | [results/peak-sweep.txt](results/peak-sweep.txt), [results/second-host/peak-sweep.txt](results/second-host/peak-sweep.txt), [results/second-host/peak-sweep-16-workers.txt](results/second-host/peak-sweep-16-workers.txt) (`WORKERS=16 ONLY=nolimit-default`) |

- **Config names:** `1g-*` is example 06's prod1 as `compose.yml` defines it (1 GB limit); `nolimit-*` removes the
  limit ([nolimit.yml](nolimit.yml)); the number is `-XX:CICompilerCount`. In the startup sweep, `off-*` is the same
  image started as a plain JVM (no `-XX:AOTCache`), the way example 01 measures "cache off".
- **Ordering:** configs run round-robin, so background drift hits every config equally.
- **Afterwards:** `make -C examples/06-training-workload stop`.

### Startup (example 01, medians of 10)

| `CICompilerCount` | default (12) | 8 | 6 | 4 | 3 | 2 |
|---|---|---|---|---|---|---|
| First host, AOT cache on | 0.431s | 0.381s | 0.344s | 0.350s | 0.324s | 0.307s |
| Second host, AOT cache on | 0.303s | 0.260s | 0.229s | 0.209s | 0.199s | 0.193s |
| Second host, AOT cache off | 0.587s | 0.548s | 0.524s | 0.507s | 0.497s | 0.488s |

On the second host, going from the default to 2 saves 0.110s with the cache on and 0.099s with it off.

### Time to peak (example 06, prod1, read-only load)

First host:

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

Second host, where every config levels off at ~10k req/s:

| Config | C2 threads (max) | Startup | Time to 9.5k req/s | 160k requests took | First phase |
|---|---|---|---|---|---|
| nolimit-default | 8 | 0.48-0.49s | **4.4-4.5s** | **16.0-16.1s** | ~7,800 req/s |
| nolimit-4 | 3 | 0.33-0.34s | 4.6-4.7s | 16.4-16.6s | ~7,350 |
| nolimit-3 | 2 | 0.31-0.32s | 4.9-5.0s | 16.8-16.9s | ~6,900 |
| 1g-default | 4 (memory-capped) | 0.41-0.42s | 4.6-4.8s | 16.3-16.4s | ~7,200 |
| 1g-3 | 2 | 0.32-0.34s | 5.1-7.0s | 16.7-16.9s | ~6,750 |
| 1g-2 | 1 | 0.31-0.33s | 12.6s | 18.5-18.6s | ~6,450 |

- **The same order, closer together.** A lower plateau is reached sooner, so only 2 stands out. Here the default is
  also the fastest over the first 20k requests, unlike on the first host.
- **With 16 curl workers** instead of 8, `nolimit-default` levels off at ~12.5k req/s instead of ~10.3k: the
  plateau is set by the load path, not the app.

## Caveats

- **The early-load numbers in `warmup-sweep.txt` look like a win for fewer threads.** Example 06's mix is 40%
  creates, so the data keeps growing and Mongo writes become the bottleneck, which hides the JIT. That's why the
  long phases decline identically for every config, and why `peak-sweep.sh` uses read-only requests on fixed data.
- **The plateau is the load path, not the app's peak.** Eight single-threaded curl workers, on the same machine
  and through Docker's port forwarding, set the ceiling: on the second host, 16 workers raise it by ~20%. So
  "the same peak" means no config stays below what the load path can deliver. Comparing the peaks themselves
  needs a stronger load generator on another machine. The time-to-plateau comparison doesn't depend on this.
- **Contention:** load generator, app, Mongo and compiler threads all share one host, which likely exaggerates the
  cost of compiler threads.
- **Scope:** one workload, 2-3 rounds per config, two hosts.
- **Heap:** the `1g-*` and `nolimit-*` configs also differ in heap size; compare within a group.
- **Thread counts:** `c1`/`c2` in the committed `warmup-sweep*.txt` overstate the threads started: the script
  matched the JVM's log lines for threads it added and for threads it removed. It now counts only the added ones.
  That number can still exceed the maximum, because the JVM retires idle threads and starts them again.
