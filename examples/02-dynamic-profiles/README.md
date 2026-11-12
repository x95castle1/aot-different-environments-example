# 02 · Active profiles decided per environment at startup

**Question:** *The app has dynamic active profiles that vary by environment/index and can't be fixed at build time.*
Spring AOT runs at build time; does that freeze the profiles?

**Answer:** Spring AOT freezes **which beans exist**, not **values**. The image decides its profiles at startup from
`APP_ENV` + `APP_ENV_INDEX` (`dev` + `2` → `dev,dev2`), and profile-specific files load normally.
- **Works:** anything that is a *value* (properties from `application-{profile}.yml` / Config Server), and choosing an
  implementation *inside* a `@Bean` method.
- **Silently frozen:** `@Profile` and `@ConditionalOnProperty` beans. They were evaluated during the build, when no
  profile was active. This demo shows that side by side with Spring AOT switched off.
- **Startup doesn't suffer:** every environment uses the same JDK AOT cache (trained with no profile active) and
  starts as fast as prod1. Spring AOT itself makes startup ~30% faster than the same image with it off (each with
  a JDK AOT cache trained for its own start).

No external services needed.

## What's in this folder

Everything this example builds and runs; nothing outside it is needed (only `make demo`'s report uses the repo's
shared demo harness in [`scripts/`](../../scripts)).

| Path | What it is |
|---|---|
| [`app/`](app) | profiles-app (Maven module): `application-<profile>.yml` files, the profile post-processor, the pitfall beans |
| [`Dockerfile`](Dockerfile) | the image: offline Maven build with Spring AOT, then offline JDK AOT-cache training |
| [`pom.xml`](pom.xml), `mvnw` | this example's Maven build (`make test`, local JDK 25) |
| [`demo.sh`](demo.sh), [`expectations.json`](expectations.json) | the demo and what it expects |

## Run it

```bash
make demo                               # = ./demo.sh: build the image, six instances, the comparison table, 5 timed starts each
make demo RUNS=10                       # more timed starts per instance
make run APP_ENV=qa APP_ENV_INDEX=1     # one instance on :8201, prints GET /info/profiles
```

## What you'll see (Apple Silicon, Docker Desktop, JDK 25)

First the behaviour of each instance:

```
instance                   Spring AOT profiles          app.db-name   notifier       @Profile  @ConditionalOnProperty
dev1                       on         dev,dev1          orders_dev1   LogNotifier    false     false
dev2                       on         dev,dev2          orders_dev2   LogNotifier    false     false
qa1                        on         qa,qa1            orders_qa1    EmailNotifier  false     false
prod1                      on         prod,prod1        orders_prod1  PagerNotifier  false     false   <- frozen at build time
prod1 + debug profile      on         prod,prod1,debug  orders_prod1  PagerNotifier  false     false
prod1 without Spring AOT   off        prod,prod1        orders_prod1  PagerNotifier  true      true    <- what prod expects
```

- Values (`app.db-name`, `app.message`) and the notifier follow every environment, with AOT on.
- `ProdOnlyAuditor` (`@Profile("prod")`) and `FancyFeature` (`@ConditionalOnProperty`, switched on in
  `application-prod.yml`) **don't exist in prod1 with AOT on**. They only appear when the same image runs without AOT.
- An operator-added profile (`SPRING_PROFILES_ACTIVE=debug`) is kept and goes **last**, so its values win.

Then each instance is started again on its own, `RUNS` times, and the run ends with this table and the verdict:

```
  Two different AOTs in the table below: the "JDK AOT cache" pre-loads classes and is on for every row;
  Spring AOT (build-time bean code) is on for every row except "prod1 without Spring AOT", so the
  "vs no Spring AOT" column is what Spring AOT alone is worth for each environment.

== Startup times (median of each scenario's runs; each column compares every row with one scenario; * = the comparison its outcome is judged on)
  scenario                  JDK AOT cache   runs (s)                       median  vs no Spring AOT  vs prod1  outcome
  dev1                      USED 7558/7717  0.243 0.236 0.249 0.24 0.245   0.243s  1.8× faster       +1% *     unchanged
  dev2                      USED 7558/7719  0.237 0.313 0.252 0.244 0.244  0.244s  1.8× faster       +2% *     unchanged
  qa1                       USED 7558/7718  0.242 0.238 0.243 0.244 0.246  0.243s  1.8× faster       +1% *     unchanged
  prod1                     USED 7558/7720  0.242 0.237 0.24 0.245 0.237   0.24s   1.8× faster *     -         improved
  prod1 + debug profile     USED 7558/7723  0.241 0.24 0.242 0.277 0.244   0.242s  1.8× faster       +1% *     unchanged
  prod1 without Spring AOT  USED 7558/8397  0.429 0.426 0.479 0.426 0.436  0.429s  -                 -         baseline
```

There are two different AOTs here, and only one of them changes:
- **JDK AOT cache**: classes loaded and linked ahead of time, trained in the image build. It's on for every
  row; the column shows whether the JVM used it and how many of the loaded classes came from it. The last row
  uses a second cache, which the demo trains for the start without Spring AOT.
- **Spring AOT**: bean definitions generated as code at build time. Only the last row runs without it.

Every row is compared with the same two scenarios:
- **vs no Spring AOT**: how much faster this environment starts than prod1 without Spring AOT. Each side has a
  JDK AOT cache trained for its own start, so this is what Spring AOT alone is worth, and every environment gets
  it, not only prod1.
- **vs prod1**: did this environment's profiles cost startup time compared with prod1?
- **\***: the comparison the outcome is judged on: prod1 on vs no Spring AOT (Spring AOT must help), every other
  environment on vs prod1 (profiles must cost nothing).

Reading it:
- The cache was trained with no profile active, yet every environment loads the same ~7,550 classes from it. Profiles
  only change which config files Spring reads, not the JDK, classpath or JVM flags the cache depends on.
- Without Spring AOT, Spring loads ~300 more classes to process the configuration at startup and evaluates every
  condition again. That's the ~30% Spring AOT buys, in exchange for the frozen bean graph above.
- A cache only helps the start it was trained on. Started without Spring AOT on the image's own cache (trained
  with Spring AOT on), ~650 classes miss the cache and the gap grows to ~1.6×. That measures the mismatch as well
  as Spring AOT, which is why the last row gets its own cache.

## Reading the report

`make demo` writes `reports/02-dynamic-profiles/<run>/report.md` (for people) and `results.json` (for scripts and agents), plus the
evidence in `raw/`. The terminal ends with the verdict, the answer, and what improved, what didn't and what was
unexpected. PASS means profiles, values and the `@Bean` choice followed every environment (`works`), the pitfall beans were missing in prod with Spring AOT (`limitation-shown`, by design) but present without it, every instance used the JDK AOT cache, every environment's startup was `unchanged` vs prod1, and prod1 was `improved` vs prod1 without Spring AOT. A noisy machine gives `inconclusive` timings: rerun with `RUNS=10`. Each instance's `/info/profiles` JSON, startup log and AOT-cache class counts are in `raw/`. What each outcome means and how timings are judged: [docs/reading-reports.md](../../docs/reading-reports.md).
The labels, expected values and explanations come from [`expectations.json`](expectations.json).

## How it works

- [`EnvironmentProfilesPostProcessor`](app/src/main/java/com/example/profiles/env/EnvironmentProfilesPostProcessor.java)
  (registered in [`META-INF/spring.factories`](app/src/main/resources/META-INF/spring.factories)) runs at startup, before Spring reads config files, and adds the profiles. Environment
  post-processors run on every start, including with Spring AOT.
- **Right way:** [`NotifierConfig`](app/src/main/java/com/example/profiles/notify/NotifierConfig.java). One bean
  definition (fixed at build time); its method body reads `app.notifier` at startup and returns `Log`/`Email`/`PagerNotifier`.
- **Pitfall:** [`pitfall/`](app/src/main/java/com/example/profiles/pitfall). Kept on purpose for the demo.
- Guardrail: [`AotSafetyArchitectureTest`](app/src/test/java/com/example/profiles/AotSafetyArchitectureTest.java)
  fails the build if `@Profile` / `@ConditionalOnProperty` / `@ConditionalOnExpression` appear outside `pitfall/`.
- "prod1 without Spring AOT" is the same image started without `-Dspring.aot.enabled=true` (the entrypoint is
  overridden). Its JDK AOT cache is trained by [`demo.sh`](demo.sh) (`train_comparison_cache`) the way the
  Dockerfile trains the image's, minus that flag, into a volume mounted at `/cache`. So the two starts differ in
  Spring AOT only.
- [`demo.sh`](demo.sh) times the instances one at a time (the six functional instances start together and would
  compete for CPU), counts classes from the cache with `-Xlog:class+load` (`AOT_USAGE_SCRIPT` in
  [`scripts/lib.sh`](../../scripts/lib.sh)), and takes Spring's `Started … in X seconds`.

## Pitfalls

- Framework conditions count too: e.g. `management.endpoints.web.exposure.include` changed at runtime doesn't add
  actuator endpoints under AOT, because their beans were decided at build time.
- In this example the per-environment values are bundled `application-{profile}.yml` files so it runs standalone. In
  examples 03 and 05 the same values come from Config Server, and in 04 from outside the image.
