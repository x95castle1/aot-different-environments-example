#!/usr/bin/env bash
# Shows that Config Server and Vault are contacted at startup (not baked in at build time) and that
# each environment fails fast when they're wrong. Uses one-off copies of dev1 pointed at a broken
# setting; nothing that's running is stopped or changed.
set -euo pipefail
cd "$(dirname "$0")/.."

try() {
  local label=$1; shift
  echo "== ${label}"
  set +e
  output=$(docker compose run --rm --no-deps -T "$@" app-dev1 2>&1)
  code=$?
  set -e
  grep -E "ConfigClientFailFast|Could not locate|VaultException|permission denied|Status 403|Application run failed|Caused by" <<<"$output" \
    | grep -vE "^\s*(at |\* )" | sed -E 's/^.* (ERROR|WARN) .* -- /\1 /; s/^/  /' | cut -c1-200 | head -4
  echo "  -> exit code ${code} (non-zero = refused to start)"
  echo
}

try "Config Server unreachable" -e CONFIG_SERVER_URL=http://config-server-down.invalid:8888
try "Vault unreachable"         -e VAULT_ADDR=http://vault-down.invalid:8200
try "dev1 using qa1's Vault token (can't read dev1 secrets)" \
    -e VAULT_TOKEN="$(sed -n 's/^VAULT_TOKEN=//p' .secrets/qa1.env)"
