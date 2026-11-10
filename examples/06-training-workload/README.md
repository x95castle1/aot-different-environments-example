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

## Run it

```bash
make demo              # train with the workload, then measure all three images in dev1, write the report
make train             # only the pipeline: workload-app:untrained, :context-trained, :workload-trained
make workload URL=http://localhost:8602 N=300   # drive the request mix at a running instance
```

## How each image is built

All three images share one build of the app. Two come straight from stages of this example's own
[`Dockerfile`](Dockerfile); the third is built on top of the first by [`Dockerfile.trained`](Dockerfile.trained)
after the training run. The example is self-contained: copy this folder's two Dockerfiles, `training-pipeline.sh`
and `run-workload.sh` as a starting point for your own app. (`Dockerfile`'s build stage mirrors the shared
`docker/app.Dockerfile` that examples 01–05 use.)

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
the shared Dockerfile. `training-pipeline.sh` builds it in step 1 for
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

```bash
# 1. image without a cache
docker build -f examples/06-training-workload/Dockerfile --target untrained -t workload-app:untrained .

# 2. throwaway services with fake data (no host ports; deleted at the end)
docker compose -f training/compose.yml up -d --wait
INFRA_COMPOSE=training/compose.yml infra/bootstrap.sh workload-app training

# 3. run the untrained image against them, recording a cache (Spring AOT on, prod flags from the image)
docker run -d --name train --network aot-06-training -e APP_ENV=training ... \
  --entrypoint java workload-app:untrained \
  -XX:AOTCacheOutput=/tmp/app.aot -Dspring.aot.enabled=true -jar /app/app.jar

# 4. the workload: the same request mix the app sees in prod
./run-workload.sh http://localhost:8601 3000 8

# 5. clean stop: SIGTERM -> graceful shutdown -> the JVM assembles the cache on exit (child JVM, a few seconds)
docker stop -t 300 train && docker cp train:/tmp/app.aot out/app.aot

# 6. final image = untrained image + app.aot
docker build -f Dockerfile.trained --build-arg BASE=workload-app:untrained -t workload-app:workload-trained out/
```

In CI these are the steps of one job: build, start the services (or use CI service containers), run, drive the
workload, stop, `docker cp`, build, push. Promote the final image by digest (example 04).

## What you'll see (Apple Silicon, Docker Desktop, JDK 25, 3 runs)

```
== Classes loaded during startup + 300 requests: from the AOT cache vs from the jars
  untrained          13575 classes loaded,      0 from the AOT cache, 13575 from the jars
  context-trained    13834 classes loaded,  11676 from the AOT cache,  2158 from the jars
  workload-trained   13948 classes loaded,  13634 from the AOT cache,   314 from the jars

== Timings
  scenario                               median  compared with    change                 outcome
  context-trained · startup time         0.414s  untrained        2.8× faster vs 1.164s  improved
  workload-trained · startup time        0.389s  context-trained  -6% vs 0.414s          unchanged
  workload-trained · first request       0.025s  context-trained  2.3× faster vs 0.059s  improved
  workload-trained · first 50 requests   0.17s   context-trained  1.6× faster vs 0.269s  info
  workload-trained · first 300 requests  0.653s  context-trained  -21% vs 0.822s         improved
```

- **Startup** is the same with either cache. The workload cache holds more, but startup isn't slower.
- **The first request** is over 2× faster. The startup-only cache leaves ~2,150 request-path classes to be loaded
  from the jars on the first requests; the workload cache leaves ~300.
- **Warm-up**, across five runs on this machine:
  - **first request**: 2.1–2.8× faster every time (~30 ms saved). This is the reliable gain;
  - **first 300 requests**: 13–21% faster, or more (judged with a ±10% band);
  - **first 50 requests**: anywhere from 10% to 1.7× faster. The ~30 ms gain is within the noise of a ~0.2 s total,
    so this row is information only, not pass/fail.
- The cache grows from ~76 MB (startup only) to ~92 MB (with the request path and method profiles).

## Reading the report

`make demo` writes `reports/06-training-workload/<run>/report.md` (for people) and `results.json` (for scripts and
agents), plus the evidence in `raw/` (training log, class counts, final image history). PASS means:
- the training produced a cache on a clean exit;
- the final image is the untrained image plus one layer;
- both caches are used;
- startup is unchanged between the two caches;
- the first request and the first 300 requests are faster with the workload cache (first 50 is shown, not judged);
- fewer classes are loaded from the jars.

What each outcome means: [docs/reading-reports.md](../../docs/reading-reports.md). The expectations and
explanations come from [`expectations.json`](expectations.json).

## Rules for your own app

- **Train with what prod runs:** Spring AOT on (`-Dspring.aot.enabled=true`), the prod JVM flags (the image's
  `JDK_JAVA_OPTIONS`), and the same image layers (final image `FROM` the trained one).
- **Make the workload look like prod traffic:** the main endpoints, serialization, DB queries, error paths,
  scheduled jobs. Paths the workload never touches stay uncached (the ~300 classes above).
- **Stop cleanly with time to spare:** SIGTERM, not SIGKILL. JDK 25 assembles the cache after the app exits, so give
  `docker stop` a long timeout.
- **Keep training out of the final image:** fake data, fake credentials, throwaway services. Only `app.aot` is
  copied.
- **Training inside `docker build`** (with `RUN --network=none`) is fine when the hot paths don't need a database:
  start the app in the `RUN`, fake HTTP dependencies on localhost (e.g. WireMock), drive requests, stop it. Database
  paths can't be trained there; `mongod` doesn't even run on the JDK 25 base image (Ubuntu 26.04 vs Mongo's 24.04
  libraries).
