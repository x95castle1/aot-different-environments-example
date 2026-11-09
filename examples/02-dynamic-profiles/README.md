# 02 · Active profiles decided per environment at startup

**Question:** *The app has dynamic active profiles that vary by environment/index and can't be fixed at build time.*
Spring AOT runs at build time; does that freeze the profiles?

**Answer:** Spring AOT freezes **which beans exist**, not **values**. The image decides its profiles at startup from
`APP_ENV` + `APP_ENV_INDEX` (`dev` + `2` → `dev,dev2`), and profile-specific files load normally.
- **Works:** anything that is a *value* (properties from `application-{profile}.yml` / Config Server), and choosing an
  implementation *inside* a `@Bean` method.
- **Silently frozen:** `@Profile` and `@ConditionalOnProperty` beans. They were evaluated during the build, when no
  profile was active. This demo shows that side by side with Spring AOT switched off.

No external services needed.

## Run it

```bash
make demo                               # six instances of one image, then the comparison table
make run APP_ENV=qa APP_ENV_INDEX=1     # one instance on :8201, prints GET /info/profiles
```

## What you'll see

```
instance               AOT  profiles          app.db-name   notifier       @Profile  @ConditionalOnProperty
dev1                   on   dev,dev1          orders_dev1   LogNotifier    false     false
dev2                   on   dev,dev2          orders_dev2   LogNotifier    false     false
qa1                    on   qa,qa1            orders_qa1    EmailNotifier  false     false
prod1                  on   prod,prod1        orders_prod1  PagerNotifier  false     false   <- frozen at build time
prod1 + debug profile  on   prod,prod1,debug  orders_prod1  PagerNotifier  false     false
prod1, Spring AOT OFF  off  prod,prod1        orders_prod1  PagerNotifier  true      true    <- what prod expects
```

- Values (`app.db-name`, `app.message`) and the notifier follow every environment, with AOT on.
- `ProdOnlyAuditor` (`@Profile("prod")`) and `FancyFeature` (`@ConditionalOnProperty`, switched on in
  `application-prod.yml`) **don't exist in prod1 with AOT on**. They only appear when the same image runs without AOT.
- An operator-added profile (`SPRING_PROFILES_ACTIVE=debug`) is kept and goes **last**, so its values win.

## Reading the report

`make demo` writes `reports/02-dynamic-profiles/<run>/report.md` (for people) and `results.json` (for scripts and agents), plus the
evidence in `raw/`. The terminal ends with the verdict, the answer, and what improved, what didn't and what was
unexpected. PASS means profiles, values and the `@Bean` choice followed every environment (`works`), and the pitfall beans were missing in prod with AOT on (`limitation-shown`, by design) but present with AOT off. Each instance's `/info/profiles` JSON and startup log are in `raw/`. What each outcome means and how timings are judged: [docs/reading-reports.md](../../docs/reading-reports.md).
The labels, expected values and explanations come from [`expectations.json`](expectations.json).

## How it works

- [`EnvironmentProfilesPostProcessor`](../../common/src/main/java/com/example/common/env/EnvironmentProfilesPostProcessor.java)
  (shared in `common/`) runs at startup, before Spring reads config files, and adds the profiles. Environment
  post-processors run on every start, including with Spring AOT.
- **Right way:** [`NotifierConfig`](app/src/main/java/com/example/profiles/notify/NotifierConfig.java). One bean
  definition (fixed at build time); its method body reads `app.notifier` at startup and returns `Log`/`Email`/`PagerNotifier`.
- **Pitfall:** [`pitfall/`](app/src/main/java/com/example/profiles/pitfall). Kept on purpose for the demo.
- Guardrail: [`AotSafetyArchitectureTest`](app/src/test/java/com/example/profiles/AotSafetyArchitectureTest.java)
  fails the build if `@Profile` / `@ConditionalOnProperty` / `@ConditionalOnExpression` appear outside `pitfall/`.

## Pitfalls

- Framework conditions count too: e.g. `management.endpoints.web.exposure.include` changed at runtime doesn't add
  actuator endpoints under AOT, because their beans were decided at build time.
- In this example the per-environment values are bundled `application-{profile}.yml` files so it runs standalone. In
  examples 03 and 05 the same values come from Config Server, and in 04 from outside the image.
