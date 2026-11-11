# 06 · Training the AOT cache with a real workload

**Question:** *A more complex application needs warming up with different pieces of code exercised. What does the
Dockerfile look like when training, given that the real Config Server, Vault and Mongo can't be reached at build
time?*

**Answer:** Training on startup alone (`-Dspring.context.exit=onRefresh`, examples 01–05) only caches what runs
during startup. To also cache the request path (validation, JSON, Mongo queries, error handling) and record method
profiles for the JIT, the training run must serve real requests. Those requests need a database, so train **in the
pipeline, not in `docker build`**:
1. build the image **without** a cache;
2. run it against **throwaway** Config Server / Vault / Mongo with fake data;
3. drive a **representative workload** at it;
4. **stop it cleanly**, so the JVM writes the cache on exit;
5. build the final image **from that exact image plus only `app.aot`**.

Real environment systems are never contacted, and the training services are deleted afterwards.

## The three images compared

| Image | AOT cache | Recorded how | Holds |
|---|---|---|---|
| `untrained` | none | — | nothing; every class is loaded from the jars |
| `context-trained` | yes | in `docker build`, by only **starting** the app: the Spring context comes up, then the JVM exits (`-Dspring.context.exit=onRefresh`) before any request | startup code only |
| `workload-trained` | yes | in the pipeline (`training-pipeline.sh`), while the app **served real requests** against throwaway services | startup **and** request-path code (validation, JSON, Mongo queries, error handling) + method profiles |

`context-trained` is what examples 01–05 use. `workload-trained` is what this example adds.

## The environments: dev1 and prod1

The images are timed in **dev1**. The image you'd ship, **workload-trained**, is then deployed unchanged to both
**dev1** and **prod1**. Both are services in [`compose.yml`](compose.yml), next to this example's own Config Server, Vault and Mongo, and an
environment is nothing but env vars plus what it fetches at startup:

| | dev1 | prod1 |
|---|---|---|
| Env vars → profiles | `APP_ENV=dev APP_ENV_INDEX=1` → `dev,dev1` | `APP_ENV=prod APP_ENV_INDEX=1` → `prod,prod1` |
| Config Server: shared | [`workload-app.yml`](config-repo/workload-app.yml) (Mongo host) | same |
| Config Server: tier | [`workload-app-dev.yml`](config-repo/workload-app-dev.yml) (`max-page-size: 50`) | [`workload-app-prod.yml`](config-repo/workload-app-prod.yml) (`max-page-size: 100`) |
| Config Server: environment | [`workload-app-dev1.yml`](config-repo/workload-app-dev1.yml) (database/user `workload_dev1`) | [`workload-app-prod1.yml`](config-repo/workload-app-prod1.yml) (database/user `workload_prod1`) |
| Vault (Mongo password) | `secret/workload-app/dev1` (its own token) | `secret/workload-app/prod1` (its own token) |
| Container memory | 768 MB | 1 GB |
| JVM flags | `-XX:+UseG1GC -Xmx384m -XX:+ExitOnOutOfMemoryError` | image default = the flags the caches were trained with (`MaxRAMPercentage=75` → 768 MB heap) |

There are no `application-dev1.yml` / `application-prod1.yml` files in the jar: the jar has only the shared
`application.yml`. The per-environment files live in the Config Server's repo, so the image stays the same
everywhere (example 04). The training stack has its own throwaway equivalent
([`training/config-repo`](training/config-repo)), whose `training` profile is never a real environment.

## Run it

```bash
make demo              # everything: train, time all three images in dev1, run the trained image as dev1 + prod1, report
make train             # only the training pipeline: workload-app:untrained, :context-trained, :workload-trained
make envs              # run dev1 (:8602) and prod1 (:8603) from compose.yml; IMAGE=workload-app:<tag> picks the build
make workload URL=http://localhost:8602 N=300   # drive the request mix at a running instance
make stop              # stop the environments and remove the training stack
make test              # unit + architecture tests (local JDK 25)
```

What runs is described in two compose files; the scripts only do the steps in order, measure, and write the report:

| File | What it runs |
|---|---|
| [`training/compose.yml`](training/compose.yml) | the **training stack**: throwaway Config Server, Vault and Mongo, plus `trainer` (the untrained image started with `-XX:AOTCacheOutput`, `stop_grace_period: 300s`) |
| [`compose.yml`](compose.yml) | the **environments** `app-dev1` and `app-prod1`, plus the Config Server ([`config-server/`](config-server) serving [`config-repo/`](config-repo)), Vault and Mongo they connect to: profiles, Vault token, JVM flags, memory, ports. `IMAGE` selects which of the three images runs |

Everything else this example needs is in this folder too: the app ([`app/`](app)) and its Maven build
([`pom.xml`](pom.xml), `mvnw`), and [`bootstrap.sh`](bootstrap.sh), which gives an environment (or the training
stack) its credentials. Only `make demo`'s report uses the repo's shared demo harness in [`scripts/`](../../scripts).

## How each image is built

All three images share one build of the app. Two come straight from stages of this example's own
[`Dockerfile`](Dockerfile); the third is built on top of the first by [`Dockerfile.trained`](Dockerfile.trained)
after the training run. The example is self-contained: copy this folder's two Dockerfiles, `training-pipeline.sh`
and `run-workload.sh` as a starting point for your own app. (`Dockerfile`'s build stage is the same as in the other
examples' Dockerfiles.)

```
eclipse-temurin:25-jre                      ← JRE_IMAGE in Dockerfile
└─ workload-app:untrained                   ← stage "untrained": /app (app.jar + lib/), prod JDK_JAVA_OPTIONS,
   │                                           user "app", ENTRYPOINT java -XX:AOTCache=/app/app.aot ...
   ├─ workload-app:context-trained          ← stage "context-trained" (default target): + app.aot recorded in docker build
   └─ workload-app:workload-trained         ← Dockerfile.trained: + app.aot recorded by training-pipeline.sh (the only new layer)
```

### `untrained`: no cache

`docker build --target untrained` stops at the stage that has the app, the prod JVM flags and the entrypoint, but
no `app.aot`. The entrypoint still passes `-XX:AOTCache=/app/app.aot`; with the file missing, the JVM prints a
warning and runs without a cache. This image is the baseline, and it is what `training-pipeline.sh` trains.

### `context-trained`: cache recorded in `docker build` by only starting the app

This is the default target of [`Dockerfile`](Dockerfile), and the same startup-only training examples 01–05 do in
their Dockerfiles. `training-pipeline.sh` builds it in step 1 for
comparison:

```dockerfile
FROM untrained AS context-trained
USER root
RUN --network=none java \
      -XX:AOTCacheOutput=/app/app.aot \
      -Dspring.aot.enabled=true \
      -Dspring.config.additional-location=optional:classpath:/build-time.yml \
      -Dspring.context.exit=onRefresh \
      -jar /app/app.jar
USER app
```

What happens in that `RUN`:

1. **The JVM starts with the prod flags.** They come from the `JDK_JAVA_OPTIONS` the `untrained` stage set, so the
   cache is recorded under prod settings. `-XX:AOTCacheOutput` tells it to record which classes it loads and
   links, plus method profiles.
2. **Spring starts with its build-time code** (`-Dspring.aot.enabled=true`), the same as in every environment.
3. **The Config Server and Vault imports are skipped.** `build-time.yml` points them at unreachable `.invalid`
   hosts with fail-fast off, and `--network=none` means nothing could connect anyway.
4. **Every bean is created,** including the Mongo client, which doesn't connect until first use.
5. **Spring stops right after startup** (`-Dspring.context.exit=onRefresh`): it exits as soon as the application
   context is ready, before the web server takes any requests.
6. **The JVM exits normally,** and JDK 25 assembles what it recorded into `/app/app.aot` (~76 MB), which stays in
   the image.

So the cache holds only what ran during startup: Spring, your beans, the Mongo and Vault clients, Tomcat setup. No
request was ever served, so the request path is missing (validation, JSON, Mongo queries, error handling). Those
are the ~2,150 classes still loaded from the jars on the first requests. The upside: it needs no network and no
services, just `docker build`.

### `workload-trained`: cache recorded by `training-pipeline.sh` while the app served real requests

[`training-pipeline.sh`](training-pipeline.sh) (next section) runs `workload-app:untrained` against throwaway services with
`-XX:AOTCacheOutput=/tmp/app.aot`, sends it the workload, stops it cleanly, and copies the cache out. Then
[`Dockerfile.trained`](Dockerfile.trained) adds the cache on top of the **exact** image that was trained:

```dockerfile
ARG BASE                       # workload-app:untrained, passed by training-pipeline.sh (--build-arg BASE=...)
FROM ${BASE}
COPY app.aot /app/app.aot      # the only new layer: no training data, secrets or tools
```

The base is the untrained image itself, not a fresh build, because the cache only works with the same JDK build
and the same `/app` files (down to their sizes and timestamps) that it was trained with. Building on top of the
trained image guarantees that, and `training-pipeline.sh` checks it: the final image must be the untrained image's layers plus
exactly one. In a real pipeline pass the untrained image **by digest**
(`BASE=registry/workload-app@sha256:…`), so the final image can't be built on a different build from the one that
was trained, even if a tag moves in between.

## The pipeline ([`training-pipeline.sh`](training-pipeline.sh)), step by step

These are the commands the script runs, in order; you can run them by hand from `examples/06-training-workload/`
(the environments' infrastructure isn't needed for training):

```bash
# 1. the image without a cache (and the startup-only one, for comparison)
docker build --target untrained -t workload-app:untrained .
docker build                    -t workload-app:context-trained .

# 2. throwaway services with fake data (no host ports; deleted at the end)
docker compose -f training/compose.yml up -d --wait --build config-server vault mongo
COMPOSE_FILE=training/compose.yml ./bootstrap.sh training

# 3. the trainer: the untrained image, recording a cache (Spring AOT on, prod flags from the image), on :8601
docker compose -f training/compose.yml up -d trainer

# 4. the workload: the same request mix the app sees in prod
./run-workload.sh http://localhost:8601 3000 8

# 5. clean stop: SIGTERM -> graceful shutdown -> the JVM assembles the cache on exit (a few seconds), then copy it out
docker compose -f training/compose.yml stop trainer
mkdir -p out && docker compose -f training/compose.yml cp trainer:/tmp/app.aot out/app.aot
docker compose -f training/compose.yml down -v

# 6. final image = untrained image + app.aot
docker build -f Dockerfile.trained --build-arg BASE=workload-app:untrained -t workload-app:workload-trained out/
rm -rf out      # *.aot is git-ignored anyway

# then run it as the environments, with their own Config Server, Vault and Mongo
docker compose up -d --wait --build config-server vault mongo && ./bootstrap.sh dev1 prod1
docker compose up -d app-dev1 app-prod1    # dev1 on :8602, prod1 on :8603
curl -s localhost:8603/info/runtime | jq   # prod1's profiles, Config Server files, database, JVM flags
```

In CI these are the steps of one job: build, start the training stack (or use CI service containers), run the
trainer, drive the workload, stop, copy the cache, build, push. Promote the final image by digest (example 04).

## What you'll see (Apple Silicon, Docker Desktop, JDK 25, 5 runs)

```
== Classes loaded in dev1 during startup + 300 requests: from the AOT cache vs from the jars
  untrained          13581 classes loaded,      0 from the AOT cache, 13581 from the jars
  context-trained    13845 classes loaded,  11685 from the AOT cache,  2160 from the jars
  workload-trained   13957 classes loaded,  13641 from the AOT cache,   316 from the jars

== Timings (median of each scenario's runs; each column compares every row with one scenario; * = the comparison its outcome is judged on)
  scenario                               runs                             median  vs untrained   vs context-trained  outcome
  startup time · untrained               1.171 1.112 1.197 1.094 1.114 s  1.114s  -              -                   baseline
  startup time · context-trained         0.452 0.521 0.467 0.47 0.443 s   0.467s  2.4× faster *  -                   improved
  startup time · workload-trained        0.424 0.44 0.389 0.411 0.416 s   0.416s  2.7× faster    -11% *              unchanged
  first request · untrained              63.9 62.2 62 60.8 59.3 ms        62 ms   -              -                   baseline
  first request · context-trained        50.1 57 53.2 53.9 97.1 ms        54 ms   -13%           -                   info
  first request · workload-trained       27.7 26.9 27.2 28.3 26.4 ms      27 ms   2.3× faster    2× faster *         improved
  first 50 requests · untrained          0.233 0.254 0.247 0.262 0.217 s  0.247s  -              -                   baseline
  first 50 requests · context-trained    0.211 0.224 0.257 0.211 0.278 s  0.224s  -9%            -                   info
  first 50 requests · workload-trained   0.173 0.171 0.185 0.159 0.160 s  0.171s  -31%           -24%                info
  first 300 requests · untrained         0.746 0.725 0.742 0.694 0.691 s  0.725s  -              -                   baseline
  first 300 requests · context-trained   0.748 0.735 0.881 0.681 0.768 s  0.748s  +3%            -                   info
  first 300 requests · workload-trained  0.559 0.588 0.592 0.505 0.522 s  0.559s  -23%           -25% *              improved
```

- Rows are grouped by what's measured; within each group, every row is compared with the same two scenarios:
  - **vs untrained**: what each cache is worth compared with no cache at all;
  - **vs context-trained**: what workload training adds on top of the startup-only cache;
  - **\***: the comparison the outcome is judged on. The other rows are information only.
- **Startup** is the same with either cache (both ~2.5× faster than untrained). The workload cache holds more, but
  startup isn't slower.
- **The first request** is over 2× faster. The startup-only cache leaves ~2,150 request-path classes to be loaded
  from the jars on the first requests; the workload cache leaves ~300. The context-trained cache barely helps here
  (vs untrained), because it never saw a request.
- **Warm-up**, across five runs on this machine:
  - **first request**: 2.1–2.8× faster every time (~30 ms saved). This is the reliable gain;
  - **first 300 requests**: 13–21% faster, or more (judged with a ±10% band);
  - **first 50 requests**: anywhere from 10% to 1.7× faster. The ~30 ms gain is within the noise of a ~0.2 s total,
    so this row is information only, not pass/fail.
- The cache grows from ~76 MB (startup only) to ~92 MB (with the request path and method profiles).

And the image you'd ship, in each environment:

```
  env    profiles    Config Server files (most specific first)                        database        tier setting   heap      AOT cache
  dev1   dev,dev1    workload-app-dev1.yml, workload-app-dev.yml, workload-app.yml    workload_dev1   max-page 50    384 MB    13639/13963
  prod1  prod,prod1  workload-app-prod1.yml, workload-app-prod.yml, workload-app.yml  workload_prod1  max-page 100   768 MB    13639/13965
```

One image (the demo checks both run the same image ID), two environments: each loaded its own Config Server files,
tier setting, database and Vault secret, ran with its own JVM flags, and used the same AOT cache.

## Reading the report

`make demo` writes `reports/06-training-workload/<run>/report.md` (for people) and `results.json` (for scripts and
agents), plus the evidence in `raw/` (training log, class counts, final image history). PASS means:
- the training pipeline ran to the end (if it stops early, the report shows how far it got and nothing else is
  measured) and produced a cache on a clean exit;
- the final image is the untrained image plus one layer;
- both caches are used;
- startup is unchanged between the two caches;
- the first request and the first 300 requests are faster with the workload cache (first 50 is shown, not judged);
- fewer classes are loaded from the jars;
- the workload-trained image runs as dev1 and prod1 with each environment's own profiles, Config Server files, tier
  setting, database and Vault path, uses the AOT cache in both, and both run the same image.

What each outcome means: [docs/reading-reports.md](../../docs/reading-reports.md). The expectations and
explanations come from [`expectations.json`](expectations.json).

## Rules for your own app

- **Train with what prod runs:** Spring AOT on (`-Dspring.aot.enabled=true`), the prod JVM flags (the image's
  `JDK_JAVA_OPTIONS`), and the same image layers (final image `FROM` the trained one).
- **Make the workload look like prod traffic:** the main endpoints, serialization, DB queries, error paths,
  scheduled jobs. Paths the workload never touches stay uncached (the ~300 classes above).
- **Stop cleanly with time to spare:** SIGTERM, not SIGKILL. JDK 25 assembles the cache after the app exits, so give
  the container a long stop timeout (`stop_grace_period: 300s` in [`training/compose.yml`](training/compose.yml)).
- **Keep training out of the final image:** fake data, fake credentials, throwaway services. Only `app.aot` is
  copied.
- **Training inside `docker build`** (with `RUN --network=none`) is fine when the hot paths don't need a database:
  start the app in the `RUN`, fake HTTP dependencies on localhost (e.g. WireMock), drive requests, stop it. Database
  paths can't be trained there; `mongod` doesn't even run on the JDK 25 base image (Ubuntu 26.04 vs Mongo's 24.04
  libraries).
