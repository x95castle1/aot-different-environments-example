#!/usr/bin/env bash
# Example 05 demo: one report for the whole run, reports/05-all-together/<run>/report.md.
#
#   1. Build the one image          docker compose build app-dev1 (the Dockerfile in this folder)
#   2. Start the infrastructure     docker compose up config-server vault mongo
#   3. Credentials per environment  ./bootstrap.sh dev1 dev2 qa1 prod1
#   4. Start four environments      docker compose up app-dev1 app-dev2 app-qa1 app-prod1 (all the same image)
#   5. verify.sh                    every environment: same image, its own profiles, config, secrets and database
#   6. aot-check.sh                 did each environment's JVM use the AOT cache?
#   7. startup-compare.sh           prod1's startup time with and without Spring AOT / the JDK AOT cache
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

RUNS=${RUNS:-3}
export RUNS
export REVISION=${REVISION:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}   # compose.yml passes it to the build
ENVS=(dev1 dev2 qa1 prod1)
APPS=(app-dev1 app-dev2 app-qa1 app-prod1)   # their services in compose.yml

# ---------------------------------------------------------------------------------------------------- steps

# build_image: app-dev1 is the only service in compose.yml with a build section; the other environments reuse its image
build_image() {
  step "1. Build the one image demo-app:1.0.0"
  note "  docker compose build app-dev1   (Dockerfile: offline Maven build with Spring AOT, then the JDK AOT cache"
  note "                                   trained with the prod JVM flags)"
  docker compose build -q app-dev1 >/dev/null
  report_image demo-app:1.0.0
}

start_infra() {
  step "2. Config Server, Vault and MongoDB"
  note "  docker compose up -d --wait --build config-server vault mongo"
  docker compose up -d --wait --build config-server vault mongo >/dev/null 2>&1
}

bootstrap_envs() {
  step "3. Credentials per environment"
  note "  ./bootstrap.sh ${ENVS[*]}"
  ./bootstrap.sh "${ENVS[@]}" | sed 's/^/  /'
}

# start_envs: --no-deps leaves the running infra (and Vault's in-memory secrets) alone
start_envs() {
  step "4. Four environments from the same image"
  note "  docker compose up -d --no-deps --force-recreate ${APPS[*]}"
  docker compose up -d --no-deps --force-recreate "${APPS[@]}" >/dev/null 2>&1
  note "  dev1 :8081   dev2 :8082   qa1 :8083   prod1 :8084"
}

# run_checks: the sub-scripts write into this run's report (REPORT_DIR is exported); their exit codes are
# folded into the verdict through the recorded results.
run_checks() {
  ./scripts/verify.sh || true
  ./scripts/aot-check.sh || true
  ./scripts/startup-compare.sh || true
}

# ---------------------------------------------------------------------------------------------------- main

report_init 05-all-together
build_image
start_infra
bootstrap_envs
start_envs
run_checks
finish
