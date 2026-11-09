#!/usr/bin/env bash
# Example 03: Config Server, Vault and MongoDB are contacted at startup, never at build time.
#   1. Build with no network: Spring AOT processing and AOT-cache training skip the remote imports.
#   2. Start the shared infra and give dev1 its credentials.
#   3. Start dev1: config from Config Server, Mongo password from Vault, Mongo connection.
#   4. Rotate the password in Vault, restart: the same image picks up the new secret.
#   5. Break each dependency: startup refuses to run.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

IMAGE=connections-app:1.0.0
BASE=http://localhost:8301

step "1. Build with no network (fresh build so the steps actually run)"
docker build --no-cache --progress=plain -f "$ROOT/docker/app.Dockerfile" \
  --build-arg MODULE=examples/03-startup-connections/app --build-arg APP=connections-app \
  --build-arg REVISION="${REVISION:-unknown}" -t "$IMAGE" "$ROOT" 2>&1 \
  | grep -E "RUN --network=none|Fetching config from server at : http://config-server.invalid|Vault location \[secret/connections-app\] not resolvable|BUILD SUCCESS|AOTCache creation is complete|ERROR" \
  | sed -E 's/^#[0-9]+ [0-9.]* ?//; s/^.*(INFO|WARN) +[0-9]+ --- \[[^]]*\] \[ *[^]]*\] [^ ]+ *: //; s/  +/ /g; s/^/    /' \
  | cut -c1-150 | awk '!seen[$0]++'
check_true "image built" docker image inspect "$IMAGE" >/dev/null

step "2. Shared infrastructure + dev1 credentials"
make -s -C "$ROOT/infra" up >/dev/null 2>&1
"$ROOT/infra/bootstrap.sh" connections-app dev1 | sed 's/^/  /'

step "3. Start dev1"
docker compose up -d --force-recreate app-dev1 >/dev/null 2>&1
wait_for_http "$BASE/info/connections" 60 || { fail "dev1 did not start"; docker compose logs app-dev1 | tail -20; finish; }
docker compose logs app-dev1 2>&1 | grep -E "Fetching config|Located environment: name=connections-app, profiles=\[dev|Vault location|Connected at startup|Started" \
  | sed -E 's/^.*(INFO|WARN) [0-9]+ --- \[[^]]*\] \[ *[^]]*\] [^ ]+ *: /    /' | cut -c1-170
info=$(curl -fs "$BASE/info/connections")
check "Spring AOT generated code" "$(jq -r '.springAotGeneratedCode' <<<"$info")" "true"
check "Config Server file for dev1 loaded" "$(jq -r '[.configSources[] | select(startswith("configserver:") and contains("connections-app-dev1.yml"))] | length' <<<"$info")" "1"
check "Vault secret/connections-app/dev1 loaded" "$(jq -r '[.configSources[] | select(startswith("vault:secret/connections-app/dev1 "))][0] // "missing"' <<<"$info")" "vault:secret/connections-app/dev1 (2 keys)"
check "Mongo database (from Config Server)" "$(jq -r '.mongo.database' <<<"$info")" "connections_dev1"
check "Mongo ping (password from Vault)" "$(jq -r '.mongo.ping' <<<"$info")" "ok"
before=$(jq -r '.mongoPasswordFingerprint' <<<"$info")

step "4. Rotate the Mongo password in Vault, restart the same image"
"$ROOT/infra/bootstrap.sh" connections-app dev1 | sed 's/^/  /'
docker compose up -d --force-recreate app-dev1 >/dev/null 2>&1
wait_for_http "$BASE/info/connections" 60 || fail "dev1 did not restart"
info=$(curl -fs "$BASE/info/connections")
after=$(jq -r '.mongoPasswordFingerprint' <<<"$info")
note "  password fingerprint: ${before} -> ${after}"
check "new password picked up at startup" "$([[ "$before" != "$after" ]] && echo yes || echo no)" "yes"
check "Mongo ping with the new password" "$(jq -r '.mongo.ping' <<<"$info")" "ok"

step "5. Each dependency is required at startup"
try() {
  local label=$1; shift
  set +e
  output=$(docker compose run --rm --no-deps -T "$@" app-dev1 2>&1)
  code=$?
  set -e
  note "  ${label}:"
  grep -E "ConfigClientFailFast|VaultException|MongoSecurityException|Caused by: java.net.UnknownHost" <<<"$output" \
    | grep -vE "^\s*(at |\* )" | sed -E 's/^.* (ERROR|WARN) .* -- //; s/^/      /' | cut -c1-150 | head -2
  check "${label}: refused to start" "$([[ $code -ne 0 ]] && echo yes || echo no)" "yes"
}
try "Config Server unreachable" -e CONFIG_SERVER_URL=http://config-server-down.invalid:8888
try "Vault unreachable" -e VAULT_ADDR=http://vault-down.invalid:8200
try "Vault token invalid" -e VAULT_TOKEN=not-a-real-token

finish
