# aot-different-environments-example

A Spring Boot app that uses **Spring AOT on the JVM** plus the **JDK 25 AOT cache**, where:

- active profiles are decided per environment **at startup** (`dev1`, `dev2`, `qa1`, `prod1`, …), not at build time;
- the app connects at startup to **Config Server, Vault and MongoDB**, whose servers and credentials differ per environment and **can't be reached at build time**;
- **JVM flags differ** per environment (the AOT cache is trained with the **prod** flags);
- **one image** (same digest) is deployed to every environment.

Stack: Spring Boot 4.0.9, Spring Cloud 2025.1.4, Java 25, Maven, Docker Compose.

## Quick start

Needs Docker, `jq`, `fzf` (for `make logs`), and (only for `make test` / `make build`) a local JDK 25.

```bash
make start            # build the image, start Config Server + Vault + Mongo, bootstrap, start dev1/dev2/qa1/prod1
make verify           # check every env: profiles, config, secrets, Mongo, data isolation, same image
make aot-check        # which envs' JVMs used the AOT cache
make startup-compare  # startup time with/without Spring AOT and the AOT cache
make fail-fast-demo   # startup refuses to run when Config Server/Vault are unreachable or the token is wrong
make report ENV=prod1 # an env's startup report
make logs             # pick a container with fzf and follow its logs (or ENV=dev1)
make status           # containers, the image each runs, health
make stop             # stop everything
make help             # everything else (test, build, logs, clean, …)
```

Endpoints per env (dev1 `:8081`, dev2 `:8082`, qa1 `:8083`, prod1 `:8084`):
`GET /info/runtime`, `GET|POST /api/greetings` (POST needs `X-Api-Key`, the env's key from Vault), `/actuator/health`.

## The idea: the build fixes *which beans exist*; environments only change *values*

Spring AOT runs the app's configuration at build time and generates the bean definitions as code. At runtime the
app skips that work, which is where the startup gain comes from, **but the bean graph is now fixed**. Property
*values* are still resolved on every startup, and so are profile-specific files and `spring.config.import`
sources such as Config Server and Vault.

| Concern | Fixed at build | Resolved at startup |
|---|---|---|
| Bean definitions (Spring AOT, `process-aot`) | ✅ | |
| Class loading/linking + method profiles (JDK AOT cache) | ✅ trained with prod flags, offline | |
| Active profiles | | ✅ from `APP_ENV` + `APP_ENV_INDEX` |
| Config Server values (Mongo host/db/user, audit sink) | | ✅ `demo-app-{profile}.yml` |
| Vault secrets (Mongo password, API key) | | ✅ `secret/demo-app/{profile}` |
| JVM flags | prod = image default | ✅ other envs override `JDK_JAVA_OPTIONS` |

### Rules that keep one image working everywhere

1. **No `@Profile`, `@ConditionalOnProperty` or `@ConditionalOnExpression` in app code.** AOT evaluates them once,
   at build time. `AotSafetyArchitectureTest` fails the build if one appears.
2. **Choose per-environment behaviour inside a `@Bean` method.** The definition is fixed; the method body still runs
   at startup. See [`AuditConfig`](demo-app/src/main/java/com/example/demo/audit/AuditConfig.java): dev logs audit
   events, qa/prod write them to Mongo, chosen by `app.audit.sink` from Config Server.
3. **Never change a property a condition reads at runtime and expect a different bean.** Framework conditions count
   too. Example: `management.endpoints.web.exposure.include=env` set at runtime does **not** add `/actuator/env`
   (it returns 404), because the endpoint bean's condition was evaluated at build time.
4. **Keep every integration enabled at build time.** Imports are `optional:` so the offline build can skip them,
   and `fail-fast: true` makes them mandatory again at runtime (fail-fast overrides `optional:`).

## How each requirement is met

### Dynamic profiles: `APP_ENV` + `APP_ENV_INDEX`
[`EnvironmentProfilesPostProcessor`](demo-app/src/main/java/com/example/demo/env/EnvironmentProfilesPostProcessor.java)
runs at startup, just before Spring's config-data processing. `APP_ENV=dev APP_ENV_INDEX=2` activates `dev,dev2`
(tier first, so `dev2` settings win) and publishes `app.env.id=dev2`. Profiles in `SPRING_PROFILES_ACTIVE` are kept.
Config Server then serves `demo-app.yml` → `demo-app-dev.yml` → `demo-app-dev2.yml`, and Vault reads
`secret/demo-app`, `…/dev`, `…/dev2`.

### Config Server, Vault, Mongo: contacted at startup, never at build time
- `application.yml` (identical everywhere) imports `optional:configserver:` and `optional:vault://` with
  `fail-fast: true`. Server locations and the Vault token come from env vars per environment.
- **Build time** (Spring AOT processing and the AOT-cache training run) adds
  [`build-time.yml`](demo-app/src/main/resources/build-time.yml) via `spring.config.additional-location`. It points
  both clients at `.invalid` hosts and switches fail-fast off. It contains values only, never `*.enabled`.
  - It is deliberately **not** `application-build.yml`: Config Server and Vault are called in the *initial*
    config-data phase, before profile-specific files are read, so a profile file is too late.
- Mongo needs nothing special. The driver connects lazily, so creating the client at build time makes no connection.
- Spring Cloud Vault registers `VaultTemplate` & co. as singletons from its config-data loader (not as normal bean
  definitions), at build time and again at runtime, so the generated bean graph stays consistent.
- `spring.cloud.refresh.enabled=false`, because refresh scope can't work with a fixed bean graph.

### JVM flags differ per environment
The Dockerfile sets the prod flags once (`ENV JDK_JAVA_OPTIONS=…`) and trains the AOT cache with them. Prod doesn't
override `JDK_JAVA_OPTIONS`, so it runs with exactly the trained flags. Other envs override it. The JVM checks
compatibility at startup: if the flags are compatible it uses the cache, otherwise it logs a warning and starts
normally (`-XX:AOTMode=auto`, the default).

| Change vs. training flags | Cache used? |
|---|---|
| Different `-Xmx` / `MaxRAMPercentage` (same compressed-oops mode) | ✅ (dev1, qa1) |
| `-D` system properties, logging flags | ✅ |
| Different GC: **ZGC on JDK 25** | ❌ falls back (dev2 shows this; JDK 26 adds ZGC support) |
| Heap > ~32 GB (compressed oops off) | ⚠️ partially/not, check with `-Xlog:aot` |
| Different JDK build, CPU architecture, or classpath | ❌ |
| `-javaagent` (APM agents) | ⚠️ test it with `make aot-check`-style logging |

The cache is tied to the JDK build and **CPU architecture**: build the image on (or for) the platform you deploy to,
e.g. `docker buildx build --platform linux/amd64`. A multi-arch image trains once per platform.

### One image for every environment
Nothing environment-specific is in the image. `make verify` checks that all four containers run the same image ID
and still end up with different profiles, databases and secrets. The training step runs with
`RUN --network=none`, which shows the build needs no environment at all.

## Measured locally (Apple Silicon, Docker Desktop)

`make startup-compare` (prod1, connected to the real Config Server/Vault/Mongo; Spring's "Started … in"):

| Mode | Typical startup |
|---|---|
| Spring AOT + JDK AOT cache (default) | ~0.5 s |
| Spring AOT only | ~1.2 s |
| Neither | ~1.5 s |

`make aot-check`: prod1 and dev1 load ~11,000 of ~11,600 classes from the cache; dev2 (ZGC) loads 0 and still starts.

## Layout

```
demo-app/            the app (Spring AOT enabled via process-aot in its pom)
  …/env/             EnvironmentProfilesPostProcessor: APP_ENV/APP_ENV_INDEX -> profiles
  …/audit/           AOT-safe per-env choice inside a @Bean method
  …/greeting/        Mongo-backed endpoint (proves per-env db + Vault password)
  …/runtime/         /info/runtime + startup report
  resources/application.yml, build-time.yml
config-server/       local stand-in Config Server (native backend)
config-repo/         demo-app{,-dev,-dev1,…}.yml served by the Config Server
Dockerfile           build -> extract -> AOT-cache training (offline, prod flags) -> runtime
docker-compose.yml   infra + four envs from one image
scripts/             bootstrap, verify, aot-check, startup-compare, fail-fast-demo
Makefile             demo entry point
```

## Demo shortcuts (not for production)
Vault runs in dev mode (in-memory, root token `root`): after `make stop`, run `make bootstrap` again.
Mongo uses a fixed root password. `scripts/bootstrap.sh` stands in for the platform that would issue per-env
credentials. It rotates the Mongo passwords, API keys and Vault tokens on every run, and writes only the Vault token
to `.secrets/<env>.env` (git-ignored).

## Adding CyberArk later
Use another `optional:` config-data import (a small `ConfigDataLocationResolver` + `ConfigDataLoader` calling the
CyberArk/Conjur REST API), registered in `spring.factories`. Like Config Server and Vault, it then runs at startup
even with AOT. CyberArk's `conjur-sdk-springboot` (built on Spring Boot 2.7, hooks in through auto-configuration and
bean registrars) isn't a fit, because AOT would freeze its registration at build time.
