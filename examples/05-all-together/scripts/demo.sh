#!/usr/bin/env bash
# Example 05 demo: one report for the whole run, reports/05-all-together/<run>/report.md.
#
#   1. Start everything: image, infra, credentials, four environments (make start)
#   2. verify.sh            every environment: same image, its own profiles, config, secrets and database
#   3. aot-check.sh         did each environment's JVM use the AOT cache?
#   4. startup-compare.sh   prod1's startup time with and without Spring AOT / the JDK AOT cache
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

RUNS=${RUNS:-3}
export RUNS

# ---------------------------------------------------------------------------------------------------- steps

start_everything() {
  step "Start: image, infra, credentials, four environments"
  make -s start 2>&1 | grep -vE "^\s*(#|=>)" | grep -E "bootstrapped|http://|ERROR|error" || true
  report_image demo-app:1.0.0
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
start_everything
run_checks
finish
