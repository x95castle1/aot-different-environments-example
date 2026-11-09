#!/usr/bin/env bash
# Example 03: Config Server, Vault and MongoDB are contacted at startup, never at build time.
#   1. Build with no network: Spring AOT processing and AOT-cache training skip the remote imports.
#   2. Start the shared infra and give dev1 its credentials.
#   3. Start dev1: config from Config Server, Mongo password from Vault, Mongo connection.
#   4. Rotate the password in Vault, restart: the same image picks up the new secret.
#   5. Break each dependency: startup refuses to run.
# Expected results: expectations.json. Writes reports/03-startup-connections/<run>/report.md.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

IMAGE=connections-app:1.0.0
BASE=http://localhost:8301
report_init 03-startup-connections

step "1. Build with no network (fresh build so the steps actually run)"
set +e
docker build --no-cache --progress=plain -f "$ROOT/docker/app.Dockerfile" \
  --build-arg MODULE=examples/03-startup-connections/app --build-arg APP=connections-app \
  --build-arg REVISION="${REVISION:-unknown}" -t "$IMAGE" "$ROOT" > /tmp/aot-03-build.$$ 2>&1
build_code=$?
set -e
save_evidence build.log < /tmp/aot-03-build.$$
# A readable summary of what happened in the two offline steps
grep -E "RUN --network=none|Fetching config from server at : http://config-server.invalid|Vault location \[secret/connections-app\] not resolvable|BUILD SUCCESS|BUILD FAILURE|AOTCache creation is complete|ERROR" /tmp/aot-03-build.$$ \
  | sed -E 's/^#[0-9]+ [0-9.]* ?//; s/^.*(INFO|WARN) +[0-9]+ --- \[[^]]*\] \[ *[^]]*\] [^ ]+ *: //; s/  +/ /g' \
  | cut -c1-160 | awk '!seen[$0]++' | save_evidence build-summary.txt
sed 's/^/    /' "$RAW/build-summary.txt"
rm -f /tmp/aot-03-build.$$
report_image "$IMAGE"
summary="$RAW/build-summary.txt"
maven_ok=$(grep -q "mvnw -B -o" "$summary" && grep -q "BUILD SUCCESS" "$summary" && echo "succeeded with --network=none" || echo "failed")
skipped=$(grep -q "config-server.invalid" "$summary" && grep -q "not resolvable" "$summary" && echo "skipped (unreachable)" || echo "not seen")
training_ok=$([[ $build_code -eq 0 ]] && grep -q "AOTCache creation is complete" "$summary" && echo "succeeded with --network=none" || echo "failed")
expect build.maven-offline "" "$maven_ok" "" build-summary.txt
expect build.imports-skipped "" "$skipped" "" build-summary.txt
expect build.training-offline "" "$training_ok" "" build-summary.txt
[[ $build_code -eq 0 ]] || finish

step "2. Shared infrastructure + dev1 credentials"
make -s -C "$ROOT/infra" up >/dev/null 2>&1
"$ROOT/infra/bootstrap.sh" connections-app dev1 | sed 's/^/  /'

step "3. Start dev1"
docker compose up -d --force-recreate app-dev1 >/dev/null 2>&1
ok=yes; wait_for_http "$BASE/info/connections" 60 || ok=no
docker compose logs --no-log-prefix app-dev1 2>&1 | save_evidence dev1.startup.log
expect started "dev1" "$ok" "" dev1.startup.log
if [[ "$ok" == yes ]]; then
  grep -E "Fetching config|Located environment: name=connections-app, profiles=\[dev|Vault location|Connected at startup|Started" "$RAW/dev1.startup.log" \
    | sed -E 's/^.*(INFO|WARN) +[0-9]+ --- \[[^]]*\] \[ *[^]]*\] [^ ]+ *: /    /' | cut -c1-170
  info=$(curl -fs "$BASE/info/connections")
  jq . <<<"$info" | save_evidence dev1.info.json
  expect start.aot "" "$(jq -r '.springAotGeneratedCode' <<<"$info")" "" dev1.info.json
  expect start.configserver "" "$(jq -r 'if any(.configSources[]; startswith("configserver:") and contains("connections-app-dev1.yml")) then "loaded connections-app-dev1.yml" else "not loaded" end' <<<"$info")" "" dev1.info.json
  expect start.vault "" "$(jq -r '[.configSources[] | select(startswith("vault:secret/connections-app/dev1 "))][0] // "not loaded"' <<<"$info")" "" dev1.info.json
  expect start.mongo-db "" "$(jq -r '.mongo.database' <<<"$info")" "" dev1.info.json
  expect start.mongo-ping "" "$(jq -r '.mongo.ping' <<<"$info")" "" dev1.info.json
  expect start.time "" "$(sed -nE 's/.*Started .* in ([0-9.]+) seconds.*/\1s/p' "$RAW/dev1.startup.log" | head -1)"
  before=$(jq -r '.mongoPasswordFingerprint' <<<"$info")

  step "4. Rotate the Mongo password in Vault, restart the same image"
  "$ROOT/infra/bootstrap.sh" connections-app dev1 | sed 's/^/  /'
  docker compose up -d --force-recreate app-dev1 >/dev/null 2>&1
  wait_for_http "$BASE/info/connections" 60 || true
  info=$(curl -fs "$BASE/info/connections" || echo '{}')
  jq . <<<"$info" | save_evidence dev1.after-rotation.info.json
  after=$(jq -r '.mongoPasswordFingerprint // "none"' <<<"$info")
  note "  password fingerprint: ${before} -> ${after}"
  expect rotation.changed "" "$([[ "$before" != "$after" && "$after" != none ]] && echo yes || echo no)" "" dev1.after-rotation.info.json
  expect rotation.ping "" "$(jq -r '.mongo.ping // "no answer"' <<<"$info")" "" dev1.after-rotation.info.json
fi

step "5. Each dependency is required at startup"
try() {
  local id=$1 name=$2; shift 2
  set +e
  docker compose run --rm --no-deps -T "$@" app-dev1 > /tmp/aot-03-ff.$$ 2>&1
  local code=$?
  set -e
  # Keep the root cause (the exception lines), not the stack frames
  grep -E "Application run failed|Exception|Caused by|Status 403|permission denied" /tmp/aot-03-ff.$$ | grep -vE "^\s*(at |\* )" \
    | sed -E 's/^.* (ERROR|WARN) .* -- //' | cut -c1-200 | head -8 | save_evidence "failfast-${name}.log"
  rm -f /tmp/aot-03-ff.$$
  expect "$id" "" "$([[ $code -ne 0 ]] && echo "refused to start" || echo "started")" "" "failfast-${name}.log"
}
try failfast.configserver configserver -e CONFIG_SERVER_URL=http://config-server-down.invalid:8888
try failfast.vault vault -e VAULT_ADDR=http://vault-down.invalid:8200
try failfast.token token -e VAULT_TOKEN=not-a-real-token

finish
