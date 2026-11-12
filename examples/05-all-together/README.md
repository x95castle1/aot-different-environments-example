# 05 · All together

All four questions at once: **four environments** (`dev1`, `dev2`, `qa1`, `prod1`) run **one image** with Spring AOT
and the JDK AOT cache. Each one:
- decides its profiles at startup (example 02);
- pulls its config from Config Server and its secrets from Vault, then connects to its own Mongo database (example 03);
- runs with its own JVM flags (example 01);
- runs the same image ID as the others (example 04).

Self-contained: this folder holds the app ([`app/`](app)), its [`Dockerfile`](Dockerfile) and Maven build
([`pom.xml`](pom.xml), `mvnw`), and everything it runs against: [`compose.yml`](compose.yml) starts its own
Config Server ([`config-server/`](config-server), serving [`config-repo/`](config-repo)), Vault and MongoDB, and
[`bootstrap.sh`](bootstrap.sh) gives each environment its credentials. Only the demo's report uses the repo's shared
demo harness in [`scripts/`](../../scripts) (the root one, not this folder's `scripts/`).

## Run it

```bash
make demo              # = scripts/demo.sh: build, start infra + four envs, verify, aot-check, startup-compare
make start             # build the image, start infra, bootstrap credentials, start the four environments
make verify            # per env: profiles, config source, secrets, Mongo, data isolation; same image everywhere
make aot-check         # which envs' JVMs used the AOT cache (dev2 runs ZGC on purpose: falls back)
make startup-compare   # prod1 startup four ways: Spring AOT and the JDK AOT cache, each on or off
make fail-fast-demo    # startup refuses to run when Config Server/Vault are unreachable or the token is wrong
make report ENV=prod1  # an env's startup report
make logs              # fzf picker over every running container (or ENV=dev1)
make status            # this example's containers
make stop              # stop the four environments and the infra
make test              # unit + architecture tests (local JDK 25)
```

Endpoints: dev1 `:8081`, dev2 `:8082`, qa1 `:8083`, prod1 `:8084`.
- `GET /info/runtime`
- `GET|POST /api/greetings` (POST needs `X-Api-Key`, the env's key from Vault)
- `/actuator/health`

## What differs per environment ([`compose.yml`](compose.yml))

| Env | Profiles | JVM flags | Audit sink | Mongo db | Vault path |
|---|---|---|---|---|---|
| dev1 | `dev,dev1` | `-Xmx256m` | log | `demo_dev1` | `secret/demo-app/dev1` |
| dev2 | `dev,dev2` | **`-XX:+UseZGC`** (cache falls back) | log | `demo_dev2` | `secret/demo-app/dev2` |
| qa1 | `qa,qa1` | `-Xmx384m` | mongo | `demo_qa1` | `secret/demo-app/qa1` |
| prod1 | `prod,prod1` | image default (= training flags) | mongo | `demo_prod1` | `secret/demo-app/prod1` |

Where the values come from:
- **Config Server** ([`config-repo/demo-app*.yml`](config-repo)): Mongo host/db/user and the audit sink.
- **Vault**: the Mongo password and the API key.
- **Env vars** in [`compose.yml`](compose.yml): `APP_ENV`, `APP_ENV_INDEX`, the server URLs and JVM flags.
- **Vault token**: per environment, written by [`bootstrap.sh`](bootstrap.sh). Its policy can read
  only that environment's paths.

## Measured locally (Apple Silicon, Docker Desktop)

`make startup-compare` (prod1, real Config Server/Vault/Mongo; Spring's "Started … in"):

```
scenario                                     JDK AOT cache        runs (s)           median  vs Plain JVM - No Cache  outcome
prod1: Spring AOT + JDK AOT cache (default)  USED 10995/11611     0.408 0.411 0.427  0.411s  2.9× faster *            improved
prod1: JDK AOT cache only                    USED 11260/12005     0.59 0.576 0.686   0.59s   2× faster                info
prod1: Spring AOT only                       not used 1461/11302  0.977 1.022 0.996  0.996s  -17%                     info
prod1: Plain JVM - No Cache                  not used 1461/11576  1.177 1.199 1.286  1.199s  -                        baseline

Where the gain comes from (median startup, compared with the Plain JVM - No Cache at 1.199s): Spring AOT alone
saves 0.203s, the JDK AOT cache alone saves 0.609s, and both together save 0.788s (each alone adds up to 0.812s).
```

- All four combinations of Spring AOT and the JDK AOT cache (on or off each) are timed, so what each one saves on
  its own is measured, not inferred from the order they're added in.
- Each row has the cache it would really have. "JDK AOT cache only" starts without Spring AOT, which the image's
  cache wasn't trained on, so `startup-compare.sh` first trains a cache for that start (the Dockerfile's training
  run minus `-Dspring.aot.enabled=true`, into a volume). With the image's own cache that row would be ~0.1 s
  slower and understate what the cache alone is worth.
- **JDK AOT cache**: classes loaded from a cache, counted in one extra start per row. The ~1,460 in the two "off"
  rows come from the JDK's own default class archive (CDS), which a plain JVM uses, not from the app's cache.
- **vs Plain JVM - No Cache**: every row against the same image with neither Spring AOT nor the JDK AOT cache.
  Only the default row is judged (`*`); the two "only" rows are information (Spring AOT alone is ~15-25% faster,
  at or inside the ±25% noise band).
- Without Spring AOT, Spring loads ~350 more classes to process the configuration at startup; the cache trained
  for that start holds them.

`make aot-check`: prod1, dev1 and qa1 load ~11,000 of ~11,650 classes from the cache; dev2 (ZGC) loads 0 and still starts.

## Reading the report

`make demo` writes `reports/05-all-together/<run>/report.md` (for people) and `results.json` (for scripts and agents), plus the
evidence in `raw/`. The terminal ends with the verdict, the answer, and what improved, what didn't and what was
unexpected. PASS means every environment verified (`works`), the JDK AOT cache was used everywhere except dev2/ZGC (`no-benefit-expected`), and Spring AOT + the cache started prod1 faster than the Plain JVM - No Cache (`improved`). The report also shows what Spring AOT and the JDK AOT cache each save on their own, and together. What each outcome means and how timings are judged: [docs/reading-reports.md](../../docs/reading-reports.md).
The labels, expected values and explanations come from [`expectations.json`](expectations.json).

## Code

- [`AuditConfig`](app/src/main/java/com/example/demo/audit/AuditConfig.java): choosing per environment the
  AOT-safe way (inside a `@Bean` method).
- [`RuntimeInfo`](app/src/main/java/com/example/demo/runtime/RuntimeInfo.java): what `/info/runtime` and the startup
  report show.
- [`GreetingController`](app/src/main/java/com/example/demo/greeting/GreetingController.java): Mongo reads and
  writes; the Vault API key guards POST.
- [`AotSafetyArchitectureTest`](app/src/test/java/com/example/demo/AotSafetyArchitectureTest.java): no `@Profile` or
  `@ConditionalOnProperty` in app code.
