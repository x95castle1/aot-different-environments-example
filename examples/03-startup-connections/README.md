# 03 · Config Server, Vault and MongoDB at startup, nothing at build time

**Question:** *The app connects to Config Server, Vault and MongoDB at startup. Systems and credentials vary by
environment, and none of them is reachable at build time.*

**Answer:** Both build-time steps run with **no network at all** (`RUN --network=none`): Spring AOT processing
(inside `mvn package`) and the JDK AOT-cache training run. Config Server and Vault are config imports, which Spring
resolves at every startup, AOT or not. Mongo connects lazily. So the image is built blind and connects for real when
each environment starts it. Rotating a secret needs a restart, not a rebuild. A missing or broken dependency stops
startup (fail fast).

## What's in this folder

Everything this example builds and runs against; nothing outside it is needed (only `make demo`'s report uses the
repo's shared demo harness in [`scripts/`](../../scripts)).

| Path | What it is |
|---|---|
| [`app/`](app) | connections-app, the Spring Boot app (Maven module) |
| [`Dockerfile`](Dockerfile) | the image: offline Maven build with Spring AOT, then offline JDK AOT-cache training |
| [`pom.xml`](pom.xml), `mvnw` | this example's Maven build (`app` + `config-server`) |
| [`compose.yml`](compose.yml) | its own Config Server, Vault and MongoDB, plus the dev1 environment |
| [`config-server/`](config-server) | the local stand-in for each environment's Config Server |
| [`config-repo/`](config-repo) | what the Config Server serves: `connections-app.yml`, `connections-app-dev1.yml` |
| [`bootstrap.sh`](bootstrap.sh) | the "platform": dev1's Mongo user, Vault secret, policy and token (`.secrets/dev1.env`) |
| [`demo.sh`](demo.sh), [`expectations.json`](expectations.json) | the demo and what it expects |

## Run it

```bash
make demo     # offline build, start dev1, rotate its secret, break each dependency
make start    # just infra + dev1 on :8301 (GET /info/connections)
make stop     # stop dev1 and its infra
make test     # unit tests (local JDK 25)
```

## What you'll see

```
== 1. Build with no network
    [build 5/6] RUN --network=none ... ./mvnw -B -o ... package          <- Spring AOT, offline
    Fetching config from server at : http://config-server.invalid:8888   <- skipped at build time
    Vault location [secret/connections-app] not resolvable: ...
    [stage-1 5/5] RUN --network=none java -XX:AOTCacheOutput=...         <- JDK AOT cache training, offline
== 3. Start dev1
    Located environment: name=connections-app, profiles=[dev,dev1]
    Started ConnectionsApplication in 0.52 seconds
    Connected at startup: sources=[configserver:...connections-app-dev1.yml (3 keys), vault:secret/connections-app/dev1 (2 keys) ...] mongo={... ping=ok}
== 4. Rotate the Mongo password in Vault, restart the same image
  password fingerprint: sha256:5cd5949a776b -> sha256:67e28ae71bf0   ✓ Mongo ping with the new password: ok
== 5. Each dependency is required at startup
  Config Server unreachable: ConfigClientFailFastException ...   ✓ refused to start
  Vault unreachable:         VaultException ... UnknownHost ...  ✓ refused to start
  Vault token invalid:       VaultException: Status 403 ...      ✓ refused to start
```

## Reading the report

`make demo` writes `reports/03-startup-connections/<run>/report.md` (for people) and `results.json` (for scripts and agents), plus the
evidence in `raw/`. The terminal ends with the verdict, the answer, and what improved, what didn't and what was
unexpected. PASS means both build steps ran offline with the imports skipped (the build log and a summary are in `raw/`), dev1 loaded its Config Server file and Vault path and reached Mongo, the rotated password was picked up after a restart, and all three broken setups refused to start (the root cause of each is in `raw/failfast-*.log`). What each outcome means and how timings are judged: [docs/reading-reports.md](../../docs/reading-reports.md).
The labels, expected values and explanations come from [`expectations.json`](expectations.json).

## How it works

- [`application.yml`](app/src/main/resources/application.yml) (the same everywhere) imports
  `optional:configserver:` and `optional:vault://` with `fail-fast: true`. Server URLs and the Vault token come from
  env vars per environment (see [`compose.yml`](compose.yml)).
- [`build-time.yml`](app/src/main/resources/build-time.yml) is added only at build time
  (`spring.config.additional-location`, in the [pom](app/pom.xml) and the
  [Dockerfile](Dockerfile)). It points both clients at `.invalid` hosts and switches fail-fast off,
  so the imports are skipped. It contains values only, never `*.enabled`, so the bean graph matches runtime.
- It's deliberately **not** `application-build.yml`. Config Server and Vault are called in the *initial*
  config-data phase, before profile files are read, so a profile file would be too late.
- The Dockerfile downloads dependencies in one step (with network), then builds with `-o` under
  `--network=none`. This was tested from an empty dependency cache.
- [`bootstrap.sh`](bootstrap.sh) acts as the platform: a Mongo user per environment, its password
  in Vault (`secret/connections-app/dev1`), a Vault policy and token that can read only that path.
- `spring.cloud.refresh.enabled=false`: refresh scope can't work with a bean graph fixed at build time. Values change
  on restart, as step 4 shows.

## Pitfalls

- With AOT, Spring Cloud Vault adds `VaultTemplate` & co. from its config-data loader (not as normal bean
  definitions), both at build time and at runtime, so the generated bean graph stays consistent. Keep Vault
  **enabled** at build time; only fail-fast is switched off.
- `optional:` alone would let a misconfigured environment start without its config. `fail-fast: true` at runtime is
  what makes the import mandatory again.
