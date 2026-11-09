#!/usr/bin/env bash
# Checks every environment: same image, its own profiles, config, secrets and database.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

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

  if ! wait_for_http "${base}/actuator/health" 60; then
    fail "not healthy after 60s (make logs ENV=${env})"
    continue
  fi

  info=$(curl -fs "${base}/info/runtime")
  check "profiles" "$(jq -r '.activeProfiles | join(",")' <<<"$info")" "${PROFILES[$i]}"
  check "mongo database (from Config Server)" "$(jq -r '.mongo.database' <<<"$info")" "demo_${env}"
  check "mongo ping (password from Vault)" "$(jq -r '.mongo.ping' <<<"$info")" "ok"
  check "audit sink (chosen at startup)" "$(jq -r '.auditSink' <<<"$info")" "${SINKS[$i]}"
  check "Spring AOT generated code in use" "$(jq -r '.jvm.springAotGeneratedCode' <<<"$info")" "true"
  jq -r '.configSources[] | "    loaded " + .' <<<"$info"

  fingerprints+=("$(jq -r '.secretFingerprints | to_entries | map(.value) | join(",")' <<<"$info")")

  api_key=$(vault_get app.api-key "secret/demo-app/${env}")
  check "POST without API key" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"message":"x"}' "${base}/api/greetings")" "401"
  created=$(curl -fs -X POST -H 'Content-Type: application/json' -H "X-Api-Key: ${api_key}" \
    -d "{\"message\":\"hello from ${env}\"}" "${base}/api/greetings")
  check "greeting stored in this env's database" "$(jq -r '.env' <<<"$created")" "${env}"
  others=$(curl -fs "${base}/api/greetings" | jq -r --arg env "$env" '[.[] | select(.env != $env)] | length')
  check "no other environment's data visible" "$others" "0"

  image_ids+=("$(docker inspect --format '{{.Image}}' "$(docker compose ps -q "app-${env}")")")
done

step "across environments"
check "distinct images across all environments" "$(printf '%s\n' "${image_ids[@]}" | sort -u | wc -l | tr -d ' ')" "1"
pass "image: $(printf '%s\n' "${image_ids[@]}" | sort -u | head -1)"
check "distinct secret sets (one per environment)" "$(printf '%s\n' "${fingerprints[@]}" | sort -u | wc -l | tr -d ' ')" "${#ENVS[@]}"
finish
