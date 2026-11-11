#!/usr/bin/env bash
# Shows that Config Server and Vault are contacted at startup (not baked in at build time) and that
# each environment fails fast when they're wrong. Uses one-off copies of dev1 pointed at a broken
# setting; nothing that's running is stopped or changed.
#
#   1. Config Server unreachable
#   2. Vault unreachable
#   3. A Vault token for another environment (qa1's)
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
expect_init 05-all-together

# ---------------------------------------------------------------------------------------------------- helpers

# root_cause: stdin = a failed start's output; the exception lines, not the stack frames
root_cause() {
  grep -E "ConfigClientFailFast|VaultException|permission denied|Status 403|Application run failed|Caused by" \
    | grep -vE "^\s*(at |\* )" | sed -E 's/^.* (ERROR|WARN) .* -- //' | cut -c1-200 | head -6 || true
}

# ---------------------------------------------------------------------------------------------------- steps

# start_broken <check id> <name> <docker compose run options...>: a one-off dev1 with one setting broken;
# expected to refuse to start
start_broken() {
  local id=$1 name=$2; shift 2
  step "$(jq -r --arg id "$id" '.checks[$id].label' "$EXPECT_FILE")"
  local output code=0 cause
  output=$(docker compose run --rm --no-deps -T "$@" app-dev1 2>&1) || code=$?
  cause=$(root_cause <<<"$output")
  save_evidence "failfast-${name}.log" <<<"$cause"
  sed 's/^/    /' <<<"$cause"
  expect "$id" "" "$([[ $code -ne 0 ]] && echo "refused to start" || echo "started")" "" "failfast-${name}.log"
}

# ---------------------------------------------------------------------------------------------------- main

start_broken failfast.configserver configserver -e CONFIG_SERVER_URL=http://config-server-down.invalid:8888
start_broken failfast.vault vault -e VAULT_ADDR=http://vault-down.invalid:8200
start_broken failfast.token token -e VAULT_TOKEN="$(sed -n 's/^VAULT_TOKEN=//p' .secrets/qa1.env)"
finish
