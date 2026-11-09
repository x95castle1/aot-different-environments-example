#!/usr/bin/env bash
# Example 05 demo: start everything, verify every environment, check AOT-cache use, compare startup
# times. One report for the whole run: reports/05-all-together/<run>/report.md.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

RUNS=${RUNS:-3}
export RUNS
report_init 05-all-together

step "Start: image, infra, credentials, four environments"
make -s start 2>&1 | grep -vE "^\s*(#|=>)" | grep -E "bootstrapped|http://|ERROR|error" || true
report_image demo-app:1.0.0

# The sub-scripts write into this run's report (REPORT_DIR is exported); their exit codes are
# folded into the verdict through the recorded results.
./scripts/verify.sh || true
./scripts/aot-check.sh || true
./scripts/startup-compare.sh || true
finish
