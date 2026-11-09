# aot-different-environments-example

Spring Boot with **Spring AOT on the JVM** and the **JDK 25 AOT cache**, built once and deployed unchanged to every
environment. Each requirement has its own small, runnable example, plus one that combines them.

Stack: Spring Boot 4.0.9, Spring Cloud 2025.1.4, Java 25, Maven, Docker Compose.

| # | Question | Example | Run | What you'll see |
|---|---|---|---|---|
| 1 | JVM arguments vary per environment (prod as the workaround) | [01-jvm-args](examples/01-jvm-args) | `make examples EX=01` | One image, 10 flag scenarios: compatible flags keep ~0.3 s startup from the cache; ZGC falls back (~0.8 s); `AOTMode=on` makes that an error |
| 2 | Active profiles vary per environment/index, not fixed at build time | [02-dynamic-profiles](examples/02-dynamic-profiles) | `make examples EX=02` | `APP_ENV`+`APP_ENV_INDEX` → profiles at startup; values follow each env, while `@Profile` beans are frozen by AOT (shown with AOT off for contrast) |
| 3 | Connect to Config Server, Vault, Mongo at startup; nothing reachable at build time | [03-startup-connections](examples/03-startup-connections) | `make examples EX=03` | Build under `--network=none`; startup pulls config + secrets and connects; secret rotation without rebuild; fail-fast when anything is missing |
| 4 | Same build deployed to all environments | [04-one-image](examples/04-one-image) | `make examples EX=04` | Build once, push, deploy the digest to dev1 → qa1 → prod1; image scan finds no env config; all use the AOT cache |
| ★ | All of the above at once | [05-all-together](examples/05-all-together) | `make examples EX=05` | Four environments, one image, real Config Server/Vault/Mongo, per-env JVM flags |

```bash
make examples   # pick an example (or "all") with fzf and run its demo; EX=01..05|all skips the picker
make help       # all targets
make test       # unit + architecture tests for every module (local JDK 25)
make status     # every running container from every example
make logs       # fzf picker over those containers, follow logs
make stop       # stop everything (all examples + shared infra)
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

```
common/                 shared: EnvironmentProfilesPostProcessor (APP_ENV -> profiles), JvmInfo, Fingerprints
docker/app.Dockerfile   one Dockerfile for every example: offline Maven + Spring AOT, offline AOT-cache training
infra/                  Config Server, Vault, MongoDB (shared by 03 and 05), config-repo, bootstrap.sh
examples/NN-*/          app/ (Maven module), Makefile (help/demo/stop/clean/…), demo.sh, README.md
scripts/lib.sh          demo helpers: expect/record_timing (reporting), startup timing, AOT-cache usage counting
scripts/report*.jq      turn a run's records + expectations.json into results.json and report.md
examples/NN-*/expectations.json   per example: expected results, explanations, hints, timing rules
docs/reading-reports.md how to read the reports (outcomes, verdicts, timing rules, schema)
scripts/examples.sh     fzf example picker behind `make examples`
scripts/logs.sh         fzf log picker
make/common.mk          shared Makefile bits (help, JDK 25 detection, git revision)
```

## Demo shortcuts (not for production)
Vault runs in dev mode (in-memory, root token `root`), so after `make stop` the examples bootstrap again
automatically (03) or with `make start` (05). Mongo uses a fixed root password. `infra/bootstrap.sh` stands in for
the platform that issues per-environment credentials; it writes only Vault tokens to `.secrets/` (git-ignored).

## Adding CyberArk later
Add another `optional:` config-data import (a small `ConfigDataLocationResolver` + `ConfigDataLoader` calling the
CyberArk/Conjur REST API) registered in `spring.factories`. Like Config Server and Vault, it then runs at every
startup even with AOT, and slots into example 03. CyberArk's `conjur-sdk-springboot` (built on Spring Boot 2.7,
hooks in through auto-configuration and bean registrars) isn't a fit, because AOT would freeze its registration at
build time.
