#!/usr/bin/env bash
# Checks every environment: same image, its own profiles, config, secrets and database.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl
expect_init 05-all-together

ENVS=(dev1 dev2 qa1 prod1)
PORTS=(8081 8082 8083 8084)
PROFILES=("dev,dev1" "dev,dev2" "qa,qa1" "prod,prod1")
SINKS=(LogAuditSink LogAuditSink MongoAuditSink MongoAuditSink)

vault_get() {
  docker compose -f "$ROOT/infra/compose.yml" exec -T -e VAULT_TOKEN=root -e VAULT_ADDR=http://127.0.0.1:8200 vault \
    vault kv get -field="$1" "$2"
}

image_ids=()
fingerprints=()

for i in "${!ENVS[@]}"; do
  env=${ENVS[$i]}; base="http://localhost:${PORTS[$i]}"
  step "${env} (${base})"
  ok=yes; wait_for_http "${base}/actuator/health" 60 || ok=no
  docker compose logs --no-log-prefix "app-${env}" 2>&1 | save_evidence "${env}.startup.log"
  expect started "$env" "$ok" "" "${env}.startup.log"
  [[ "$ok" == yes ]] || continue

  info=$(curl -fs "${base}/info/runtime")
  jq . <<<"$info" | save_evidence "${env}.info.json"
  expect profiles "$env" "$(jq -r '.activeProfiles | join(",")' <<<"$info")" "${PROFILES[$i]}" "${env}.info.json"
  expect mongo-db "$env" "$(jq -r '.mongo.database' <<<"$info")" "demo_${env}" "${env}.info.json"
  expect mongo-ping "$env" "$(jq -r '.mongo.ping' <<<"$info")" "" "${env}.info.json"
  expect audit-sink "$env" "$(jq -r '.auditSink' <<<"$info")" "${SINKS[$i]}" "${env}.info.json"
  expect aot "$env" "$(jq -r '.jvm.springAotGeneratedCode' <<<"$info")" "" "${env}.info.json"
  jq -r '.configSources[] | "    loaded " + .' <<<"$info"

  fingerprints+=("$(jq -r '.secretFingerprints | to_entries | map(.value) | join(",")' <<<"$info")")

  api_key=$(vault_get app.api-key "secret/demo-app/${env}")
  expect post-401 "$env" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"message":"x"}' "${base}/api/greetings")"
  created=$(curl -fs -X POST -H 'Content-Type: application/json' -H "X-Api-Key: ${api_key}" \
    -d "{\"message\":\"hello from ${env}\"}" "${base}/api/greetings")
  expect greeting-env "$env" "$(jq -r '.env' <<<"$created")" "$env"
  expect isolation "$env" "$(curl -fs "${base}/api/greetings" | jq -r --arg env "$env" '[.[] | select(.env != $env)] | length')"

  image_ids+=("$(docker inspect --format '{{.Image}}' "$(docker compose ps -q "app-${env}")")")
done

step "across environments"
expect across.images "" "$(printf '%s\n' "${image_ids[@]}" | sort -u | wc -l | tr -d ' ')"
note "  image: $(printf '%s\n' "${image_ids[@]}" | sort -u | head -1)"
expect across.secrets "" "$(printf '%s\n' "${fingerprints[@]}" | sort -u | wc -l | tr -d ' ')"
finish
