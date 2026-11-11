# 04 · One build, promoted unchanged through every environment

**Question:** *The same build gets deployed to all environments.* Can a Spring AOT + JDK AOT-cache image really be
built once and promoted dev → qa → prod?

**Answer:** Yes. The image is built once and pushed, and from then on **only its digest** is deployed. Each
environment supplies its own env vars (`envs/<env>/app.env`: profiles and JVM flags) and its own config directory
(`envs/<env>/config`, mounted at `/config`). A scan shows the image contains no environment names, hosts or settings.
All three environments report the same build and all three use the AOT cache.

Needs only a local registry (`localhost:5001`, started by the demo); no Config Server, Vault or Mongo.

## What's in this folder

Everything this example builds and runs; nothing outside it is needed (only `make demo`'s report uses the repo's
shared demo harness in [`scripts/`](../../scripts)).

| Path | What it is |
|---|---|
| [`app/`](app) | one-image-app (Maven module); `GET /info` shows the build, profiles and settings |
| [`Dockerfile`](Dockerfile) | the image, built once: offline Maven build with Spring AOT, then offline JDK AOT-cache training |
| [`pom.xml`](pom.xml), `mvnw` | this example's Maven build (`make test`, local JDK 25) |
| [`compose.yml`](compose.yml) | the local registry and the three environments, each running the image by digest |
| [`envs/`](envs) | each environment's settings: `app.env` (env vars) and `config/` (mounted at `/config`) |
| [`demo.sh`](demo.sh), [`expectations.json`](expectations.json) | the demo and what it expects |

## Run it

```bash
make demo     # build once, push, scan, promote by digest to dev1 -> qa1 -> prod1, compare
make status   # which digest each environment is running
make stop     # stop the registry and environments
```

## What you'll see

```
== 1. Build once, push to the registry
  promoted artifact: localhost:5001/one-image-app@sha256:63fd0eeb...
    label org.opencontainers.image.revision=022d981
== 2. Scan the image for environment-specific settings
  ✓ image contains 'dev1': 0   ✓ 'prod-db.internal': 0   ✓ 'oncall@example.com': 0   ...
== 3. Promote: dev1 -> qa1 -> prod1
  ✓ dev1 runs the promoted digest   ✓ dev1 profiles: dev,dev1   ✓ dev1 JDK AOT cache: USED   ...
== 4. Across environments
  ✓ distinct images running: 1
  ✓ distinct build times reported by the apps: 1

  env    digest         app.db-url                                       heap flags                 JDK AOT cache
  dev1   63fd0eebcfd1   mongodb://dev-db.internal:27017/orders_dev1      -Xmx256m                   7520/7680
  qa1    63fd0eebcfd1   mongodb://qa-db.internal:27017/orders_qa1        -Xmx384m                   7520/7680
  prod1  63fd0eebcfd1   mongodb://prod-db.internal:27017/orders_prod1    -XX:MaxRAMPercentage=75    7520/7680
```

## Reading the report

`make demo` writes `reports/04-one-image/<run>/report.md` (for people) and `results.json` (for scripts and agents), plus the
evidence in `raw/`. The terminal ends with the verdict, the answer, and what improved, what didn't and what was
unexpected. PASS means the image scan found no environment markers (`raw/image-scan.txt` lists what is bundled), every environment ran the promoted digest with its own settings, used the AOT cache, and reported the same build. What each outcome means and how timings are judged: [docs/reading-reports.md](../../docs/reading-reports.md).
The labels, expected values and explanations come from [`expectations.json`](expectations.json).

## How it works

- [`compose.yml`](compose.yml): every environment uses `image: ${IMAGE_REF}`, which the demo sets to
  `localhost:5001/one-image-app@sha256:…`. The local tag is deleted after the push, so environments really pull the
  digest from the registry.
- [`envs/`](envs): everything that differs, kept outside the image. `app.env` holds `APP_ENV`, `APP_ENV_INDEX` and
  `JDK_JAVA_OPTIONS` (prod has none, so it runs with the training flags). `config/application.yml` holds the settings.
- [`application.yml`](app/src/main/resources/application.yml) bundles only neutral defaults plus
  `spring.config.import: optional:file:/config/`, so the mounted file overrides them at startup.
- The app reports `build-info` (version and build time, stamped into the jar by Maven). Matching build times prove
  the environments run the same build. The image also carries OCI labels (`revision`, `created`) for traceability.
- The scan extracts `/app/app.jar`, reads every bundled `.yml`/`.properties`, and checks the image's env vars for
  environment markers.

## Pitfalls

- Promote **digests**, not tags. A tag can be moved between deployments; a digest can't.
- The AOT cache inside the image is tied to the image's JDK build and CPU architecture. Promotion across clusters
  with different CPU architectures needs a multi-arch image (one training run per platform).
- Anything bundled as `application-<env>.yml` *is* environment config inside the image. In this example it lives
  only in `envs/`.
