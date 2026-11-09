# 05 · All together

All four questions at once: **four environments** (`dev1`, `dev2`, `qa1`, `prod1`) run **one image** with Spring AOT
and the JDK AOT cache. Each one:
- decides its profiles at startup (example 02);
- pulls its config from Config Server and its secrets from Vault, then connects to its own Mongo database (example 03);
- runs with its own JVM flags (example 01);
- runs the same image ID as the others (example 04).

Uses the shared infrastructure in [`infra/`](../../infra).

## Run it

```bash
make demo              # start + verify + aot-check
make start             # build the image, start infra, bootstrap credentials, start the four environments
make verify            # per env: profiles, config source, secrets, Mongo, data isolation; same image everywhere
make aot-check         # which envs' JVMs used the AOT cache (dev2 runs ZGC on purpose: falls back)
make startup-compare   # Spring AOT + AOT cache vs Spring AOT only vs neither
make fail-fast-demo    # startup refuses to run when Config Server/Vault are unreachable or the token is wrong
make report ENV=prod1  # an env's startup report
make logs              # fzf picker over every running container (or ENV=dev1)
make status            # this example's containers
make stop              # stop the four environments (infra keeps running)
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
- **Config Server** ([`infra/config-repo/demo-app*.yml`](../../infra/config-repo)): Mongo host/db/user and the audit sink.
- **Vault**: the Mongo password and the API key.
- **Env vars** in [`compose.yml`](compose.yml): `APP_ENV`, `APP_ENV_INDEX`, the server URLs and JVM flags.
- **Vault token**: per environment, written by [`infra/bootstrap.sh`](../../infra/bootstrap.sh). Its policy can read
  only that environment's paths.

## Measured locally (Apple Silicon, Docker Desktop)

`make startup-compare` (prod1, real Config Server/Vault/Mongo; Spring's "Started … in"):

| Mode | Typical startup |
|---|---|
| Spring AOT + JDK AOT cache (default) | ~0.5 s |
| Spring AOT only | ~1.2 s |
| Neither | ~1.5 s |

`make aot-check`: prod1, dev1 and qa1 load ~11,000 of ~11,650 classes from the cache; dev2 (ZGC) loads 0 and still starts.

## Reading the report

`make demo` writes `reports/05-all-together/<run>/report.md` (for people) and `results.json` (for scripts and agents), plus the
evidence in `raw/`. The terminal ends with the verdict, the answer, and what improved, what didn't and what was
unexpected. PASS means every environment verified (`works`), the AOT cache was used everywhere except dev2/ZGC (`no-benefit-expected`), and Spring AOT + the cache started prod1 faster than neither (`improved`). The report also splits the gain between Spring AOT and the AOT cache. What each outcome means and how timings are judged: [docs/reading-reports.md](../../docs/reading-reports.md).
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
