#!/usr/bin/env bash
# Example 03: Config Server, Vault and MongoDB are contacted at startup, never at build time.
#
#   1. Build with no network: Spring AOT processing and AOT-cache training skip the remote imports.
#   2. Start this example's Config Server, Vault and MongoDB (compose.yml) and give dev1 its credentials.
#   3. Start dev1: config from Config Server, Mongo password from Vault, Mongo connection.
#   4. Rotate the password in Vault, restart: the same image picks up the new secret.
#   5. Break each dependency: startup refuses to run.
# Expected results: expectations.json. Writes reports/03-startup-connections/<run>/report.md.
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

IMAGE=connections-app:1.0.0
BASE=http://localhost:8301             # app-dev1's port in compose.yml
OUT=$(mktemp -d)                       # the build log, the broken starts' output
FINGERPRINT=""                         # dev1's Mongo password fingerprint before rotation; empty if it didn't start
cleanup() { rm -rf "$OUT"; }

# ---------------------------------------------------------------------------------------------------- helpers

# build_summary: stdin = the docker build log; a readable summary of what happened in the two offline steps
build_summary() {
  grep -E "RUN --network=none|Fetching config from server at : http://config-server.invalid|Vault location \[secret/connections-app\] not resolvable|BUILD SUCCESS|BUILD FAILURE|AOTCache creation is complete|ERROR" \
    | sed -E 's/^#[0-9]+ [0-9.]* ?//; s/^.*(INFO|WARN) +[0-9]+ --- \[[^]]*\] \[ *[^]]*\] [^ ]+ *: //; s/  +/ /g' \
    | cut -c1-160 | awk '!seen[$0]++'
}

# start_dev1: (re)create app-dev1 from compose.yml (--no-deps: leave the running infra, and Vault's secrets, alone)
start_dev1() { docker compose up -d --no-deps --force-recreate app-dev1 >/dev/null 2>&1; }

# start_broken <check id> <name> <docker compose run options...>: a one-off dev1 with one dependency broken;
# expected to refuse to start. Keeps the root cause (the exception lines), not the stack frames.
start_broken() {
  local id=$1 name=$2; shift 2
  local code=0
  docker compose run --rm --no-deps -T "$@" app-dev1 > "$OUT/failfast.log" 2>&1 || code=$?
  grep -E "Application run failed|Exception|Caused by|Status 403|permission denied" "$OUT/failfast.log" | grep -vE "^\s*(at |\* )" \
    | sed -E 's/^.* (ERROR|WARN) .* -- //' | cut -c1-200 | head -8 | save_evidence "failfast-${name}.log"
  expect "$id" "" "$([[ $code -ne 0 ]] && echo "refused to start" || echo "started")" "" "failfast-${name}.log"
}

# ---------------------------------------------------------------------------------------------------- steps

# build_offline: stops the run (finish) if the build fails
build_offline() {
  step "1. Build with no network (fresh build so the steps actually run)"
  local code=0
  docker build --no-cache --progress=plain --build-arg REVISION="${REVISION:-unknown}" -t "$IMAGE" . \
    > "$OUT/build.log" 2>&1 || code=$?
  save_evidence build.log < "$OUT/build.log"
  build_summary < "$OUT/build.log" | save_evidence build-summary.txt
  sed 's/^/    /' "$RAW/build-summary.txt"
  report_image "$IMAGE"

  local summary="$RAW/build-summary.txt" maven_ok skipped training_ok
  maven_ok=$(grep -q "mvnw -B -o" "$summary" && grep -q "BUILD SUCCESS" "$summary" && echo "succeeded with --network=none" || echo "failed")
  skipped=$(grep -q "config-server.invalid" "$summary" && grep -q "not resolvable" "$summary" && echo "skipped (unreachable)" || echo "not seen")
  training_ok=$([[ $code -eq 0 ]] && grep -q "AOTCache creation is complete" "$summary" && echo "succeeded with --network=none" || echo "failed")
  expect build.maven-offline "" "$maven_ok" "" build-summary.txt
  expect build.imports-skipped "" "$skipped" "" build-summary.txt
  expect build.training-offline "" "$training_ok" "" build-summary.txt
  [[ $code -eq 0 ]] || finish
}

start_infra() {
  step "2. Config Server, Vault, MongoDB (compose.yml) + dev1 credentials"
  docker compose up -d --wait --build config-server vault mongo >/dev/null 2>&1
  note "  docker compose up -d --wait --build config-server vault mongo"
  ./bootstrap.sh dev1 | sed 's/^/  /'
}

# check_dev1: sets FINGERPRINT when dev1 started
check_dev1() {
  step "3. Start dev1"
  start_dev1
  local ok=yes
  wait_for_http "$BASE/info/connections" 60 || ok=no
  docker compose logs --no-log-prefix app-dev1 2>&1 | save_evidence dev1.startup.log
  expect started "dev1" "$ok" "" dev1.startup.log
  [[ "$ok" == yes ]] || return 0

  grep -E "Fetching config|Located environment: name=connections-app, profiles=\[dev|Vault location|Connected at startup|Started" "$RAW/dev1.startup.log" \
    | sed -E 's/^.*(INFO|WARN) +[0-9]+ --- \[[^]]*\] \[ *[^]]*\] [^ ]+ *: /    /' | cut -c1-170
  local info
  info=$(curl -fs "$BASE/info/connections")
  jq . <<<"$info" | save_evidence dev1.info.json
  expect start.aot "" "$(jq -r '.springAotGeneratedCode' <<<"$info")" "" dev1.info.json
  expect start.configserver "" "$(jq -r 'if any(.configSources[]; startswith("configserver:") and contains("connections-app-dev1.yml")) then "loaded connections-app-dev1.yml" else "not loaded" end' <<<"$info")" "" dev1.info.json
  expect start.vault "" "$(jq -r '[.configSources[] | select(startswith("vault:secret/connections-app/dev1 "))][0] // "not loaded"' <<<"$info")" "" dev1.info.json
  expect start.mongo-db "" "$(jq -r '.mongo.database' <<<"$info")" "" dev1.info.json
  expect start.mongo-ping "" "$(jq -r '.mongo.ping' <<<"$info")" "" dev1.info.json
  expect start.time "" "$(sed -nE 's/.*Started .* in ([0-9.]+) seconds.*/\1s/p' "$RAW/dev1.startup.log" | head -1)"
  FINGERPRINT=$(jq -r '.mongoPasswordFingerprint' <<<"$info")
}

# rotate_password: skipped when dev1 didn't start
rotate_password() {
  [[ -n "$FINGERPRINT" ]] || return 0
  step "4. Rotate the Mongo password in Vault, restart the same image"
  ./bootstrap.sh dev1 | sed 's/^/  /'
  start_dev1
  wait_for_http "$BASE/info/connections" 60 || true
  local info after
  info=$(curl -fs "$BASE/info/connections" || echo '{}')
  jq . <<<"$info" | save_evidence dev1.after-rotation.info.json
  after=$(jq -r '.mongoPasswordFingerprint // "none"' <<<"$info")
  note "  password fingerprint: ${FINGERPRINT} -> ${after}"
  expect rotation.changed "" "$([[ "$FINGERPRINT" != "$after" && "$after" != none ]] && echo yes || echo no)" "" dev1.after-rotation.info.json
  expect rotation.ping "" "$(jq -r '.mongo.ping // "no answer"' <<<"$info")" "" dev1.after-rotation.info.json
}

check_fail_fast() {
  step "5. Each dependency is required at startup"
  start_broken failfast.configserver configserver -e CONFIG_SERVER_URL=http://config-server-down.invalid:8888
  start_broken failfast.vault vault -e VAULT_ADDR=http://vault-down.invalid:8200
  start_broken failfast.token token -e VAULT_TOKEN=not-a-real-token
}

# ---------------------------------------------------------------------------------------------------- main

trap cleanup EXIT
report_init 03-startup-connections
build_offline
start_infra
check_dev1
rotate_password
check_fail_fast
finish
