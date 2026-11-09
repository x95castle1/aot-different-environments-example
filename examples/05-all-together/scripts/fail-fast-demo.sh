#!/usr/bin/env bash
# Shows that Config Server and Vault are contacted at startup (not baked in at build time) and that
# each environment fails fast when they're wrong. Uses one-off copies of dev1 pointed at a broken
# setting; nothing that's running is stopped or changed.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
expect_init 05-all-together

try() {
  local id=$1 name=$2; shift 2
  step "$(jq -r --arg id "$id" '.checks[$id].label' "$EXPECT_FILE")"
  set +e
  output=$(docker compose run --rm --no-deps -T "$@" app-dev1 2>&1)
  code=$?
  set -e
  local cause
  cause=$(grep -E "ConfigClientFailFast|VaultException|permission denied|Status 403|Application run failed|Caused by" <<<"$output" \
    | grep -vE "^\s*(at |\* )" | sed -E 's/^.* (ERROR|WARN) .* -- //' | cut -c1-200 | head -6 || true)
  save_evidence "failfast-${name}.log" <<<"$cause"
  sed 's/^/    /' <<<"$cause"
  expect "$id" "" "$([[ $code -ne 0 ]] && echo "refused to start" || echo "started")" "" "failfast-${name}.log"
}

try failfast.configserver configserver -e CONFIG_SERVER_URL=http://config-server-down.invalid:8888
try failfast.vault vault -e VAULT_ADDR=http://vault-down.invalid:8200
try failfast.token token -e VAULT_TOKEN="$(sed -n 's/^VAULT_TOKEN=//p' "$ROOT/.secrets/demo-app/qa1.env")"
finish
