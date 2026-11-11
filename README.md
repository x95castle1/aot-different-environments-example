# aot-different-environments-example

Spring Boot with **Spring AOT on the JVM** and the **JDK 25 AOT cache**, built once and deployed unchanged to every
environment. Each requirement has its own small, runnable example, plus one that combines them.

Stack: Spring Boot 4.0.9, Spring Cloud 2025.1.4, Java 25, Maven, Docker Compose.

| # | Question | Example | Run | What you'll see |
|---|---|---|---|---|
| 1 | JVM arguments vary per environment (prod as the workaround) | [01-jvm-args](examples/01-jvm-args) | `make examples EX=01` | One image, 10 flag scenarios: compatible flags keep ~0.3 s startup from the cache; ZGC falls back (~0.8 s); `AOTMode=on` makes that an error |
| 2 | Active profiles vary per environment/index, not fixed at build time | [02-dynamic-profiles](examples/02-dynamic-profiles) | `make examples EX=02` | `APP_ENV`+`APP_ENV_INDEX` → profiles at startup; values follow each env, while `@Profile` beans are frozen by AOT (shown without Spring AOT for contrast); every env starts as fast as prod1 from the same cache, and Spring AOT makes it ~1.6× faster |
| 3 | Connect to Config Server, Vault, Mongo at startup; nothing reachable at build time | [03-startup-connections](examples/03-startup-connections) | `make examples EX=03` | Build under `--network=none`; startup pulls config + secrets and connects; secret rotation without rebuild; fail-fast when anything is missing |
| 4 | Same build deployed to all environments | [04-one-image](examples/04-one-image) | `make examples EX=04` | Build once, push, deploy the digest to dev1 → qa1 → prod1; image scan finds no env config; all use the AOT cache |
| 6 | A complex app needs warming up: how do you train the AOT cache with a real workload? | [06-training-workload](examples/06-training-workload) | `make examples EX=06` | Pipeline training against throwaway services: same startup, first request 2.3× faster, first 300 requests 10–20% faster, 314 vs 2,158 classes loaded from the jars; the trained image then runs as dev1 and prod1 |
| ★ | All of the above at once | [05-all-together](examples/05-all-together) | `make examples EX=05` | Four environments, one image, real Config Server/Vault/Mongo, per-env JVM flags |

```bash
make examples   # pick an example (or "all") with fzf and run its demo; EX=01..05|all skips the picker
make help       # all targets
make test       # unit + architecture tests of every example (local JDK 25)
make status     # which demo is running (and how far along), every container, the last report
make logs       # fzf picker over those containers, follow logs
make stop       # stop everything (every example, including its infrastructure)
make clean      # stop everything, delete images, volumes, secrets and build output
```

Needs Docker, `jq`, `fzf` (for the pickers) and, only for `make test`/`make build`, a local JDK 25.

**Every run writes a report** to `reports/<example>/<run>/`: `report.md` (verdict, answer, what was tested, what
improved, what didn't and why, unexpected results with what to check), `results.json` (the same, structured) and the
raw evidence. `make examples EX=all` adds `reports/all/<run>/summary.md`. How to read them:
[docs/reading-reports.md](docs/reading-reports.md). Running these with an AI agent: [AGENTS.md](AGENTS.md).

## The one idea behind all of it

Spring AOT runs the app's configuration at build time and generates the bean definitions as code. At runtime the app
skips that work (faster startup), **but which beans exist is now fixed**. Property *values*, profile-specific files
and `spring.config.import` sources (Config Server, Vault) are still resolved at every startup. The JDK AOT cache
adds class loading/linking and method profiles, trained in the image build.

| Concern | Fixed at build | Resolved at startup | Example |
|---|---|---|---|
| Bean definitions (Spring AOT) | ✅ | | 02 |
| Classes + method profiles (JDK AOT cache), trained with prod flags, offline | ✅ | | 01, 03 |
| Active profiles | | ✅ `APP_ENV` + `APP_ENV_INDEX` | 02 |
| Config values (Config Server, profile files, mounted config) | | ✅ | 02, 03, 04 |
| Secrets (Vault) and connections (Mongo) | | ✅ | 03 |
| JVM flags | prod = image default | ✅ `JDK_JAVA_OPTIONS` per env | 01 |

Rules that keep one image working everywhere:
1. **No `@Profile`, `@ConditionalOnProperty` or `@ConditionalOnExpression` in app code.** AOT evaluates them at build
   time. Each app has an architecture test that enforces this.
2. **Choose per-environment behaviour inside a `@Bean` method.** The method still runs at startup.
3. **Never expect a runtime property to add or remove a bean.** That includes framework conditions such as actuator
   endpoint exposure.
4. **Keep integrations enabled at build time.** Imports are `optional:` and fail-fast is off only during the build
   (`build-time.yml`). At runtime `fail-fast: true` makes them mandatory again.
5. **Train the AOT cache with the prod flags** and deploy by digest. Other environments override `JDK_JAVA_OPTIONS`;
   incompatible flags fall back safely.

## Layout

Every example is **self-contained**: its folder holds everything to build, run and test it, so you can read or copy
one without the rest of the repo. Only the demo/report harness in `scripts/` is shared.

```
examples/NN-*/                    one example, standalone:
  app/                              the Spring Boot app (Maven module), incl. its own copies of the small helpers
                                    (EnvironmentProfilesPostProcessor: APP_ENV -> profiles, JvmInfo, Fingerprints)
  pom.xml, mvnw, .mvn/              its own Maven build (Spring Boot parent; app + config-server where there is one)
  Dockerfile                        its image: offline Maven + Spring AOT, offline JDK AOT-cache training
                                    (06: untrained stage + startup-only training; Dockerfile.trained adds the workload cache)
  compose.yml                       what it runs: its environments and (03, 05, 06) its own Config Server, Vault, MongoDB
  config-server/, config-repo/      (03, 05, 06) the local Config Server and the files it serves
  bootstrap.sh                      (03, 05, 06) per-environment credentials: Mongo user, Vault secret/policy/token
  Makefile                          help/test/demo/start/stop/clean/…
  demo.sh, expectations.json        the demo, and its expected results, explanations, hints, timing rules
  README.md
scripts/                          the shared demo/report harness:
  lib.sh                            demo helpers: expect/record_timing (reporting), startup timing, AOT-cache usage counting
  report*.jq, render-report.sh      turn a run's records + expectations.json into results.json and report.md
  examples.sh, status.sh, logs.sh   `make examples` (fzf picker), `make status`, `make logs`
docs/reading-reports.md           how to read the reports (outcomes, verdicts, timing rules, schema)
```

## Demo shortcuts (not for production)
Vault runs in dev mode (in-memory, root token `root`), so after `make stop` an example bootstraps again
(automatically in `make demo`, or with `make start` / `make envs`). Mongo uses a fixed root password. Each example's
`bootstrap.sh` stands in for the platform that issues per-environment credentials; it writes only Vault tokens to the
example's `.secrets/` (git-ignored). The infrastructure publishes no host ports, so examples never clash.

## Adding CyberArk later
Add another `optional:` config-data import (a small `ConfigDataLocationResolver` + `ConfigDataLoader` calling the
CyberArk/Conjur REST API) registered in `spring.factories`. Like Config Server and Vault, it then runs at every
startup even with AOT, and slots into example 03. CyberArk's `conjur-sdk-springboot` (built on Spring Boot 2.7,
hooks in through auto-configuration and bean registrars) isn't a fit, because AOT would freeze its registration at
build time.
