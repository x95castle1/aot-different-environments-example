#!/usr/bin/env bash
# Checks every environment: same image, its own profiles, config, secrets and database.
#
#   1. Each environment (dev1, dev2, qa1, prod1): started, profiles, database, audit sink, Spring AOT, its own
#      API key, and only its own data
#   2. Across environments: one image, different secrets
#
# Each step is a function below; main, at the bottom, runs them in order.
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
IMAGE_IDS=()        # the image id each environment runs (check_env)
FINGERPRINTS=()     # each environment's secret fingerprints (check_env)

# ---------------------------------------------------------------------------------------------------- helpers

# vault_get <field> <path>: read a secret from this example's Vault as root
vault_get() {
  docker compose exec -T -e VAULT_TOKEN=root -e VAULT_ADDR=http://127.0.0.1:8200 vault \
    vault kv get -field="$1" "$2"
}

# count_distinct <values...>: how many different values
count_distinct() { printf '%s\n' "$@" | sort -u | wc -l | tr -d ' '; }

# ---------------------------------------------------------------------------------------------------- steps

# check_env <index>: ENVS[index] against what's expected for it. Adds to IMAGE_IDS and FINGERPRINTS.
check_env() {
  local i=$1
  local env=${ENVS[$i]} base="http://localhost:${PORTS[$i]}"
  step "${env} (${base})"
  local ok=yes
  wait_for_http "${base}/actuator/health" 60 || ok=no
  docker compose logs --no-log-prefix "app-${env}" 2>&1 | save_evidence "${env}.startup.log"
  expect started "$env" "$ok" "" "${env}.startup.log"
  [[ "$ok" == yes ]] || return 0

  local info
  info=$(curl -fs "${base}/info/runtime")
  jq . <<<"$info" | save_evidence "${env}.info.json"
  expect profiles "$env" "$(jq -r '.activeProfiles | join(",")' <<<"$info")" "${PROFILES[$i]}" "${env}.info.json"
  expect mongo-db "$env" "$(jq -r '.mongo.database' <<<"$info")" "demo_${env}" "${env}.info.json"
  expect mongo-ping "$env" "$(jq -r '.mongo.ping' <<<"$info")" "" "${env}.info.json"
  expect audit-sink "$env" "$(jq -r '.auditSink' <<<"$info")" "${SINKS[$i]}" "${env}.info.json"
  expect aot "$env" "$(jq -r '.jvm.springAotGeneratedCode' <<<"$info")" "" "${env}.info.json"
  jq -r '.configSources[] | "    loaded " + .' <<<"$info"

  FINGERPRINTS+=("$(jq -r '.secretFingerprints | to_entries | map(.value) | join(",")' <<<"$info")")

  local api_key created
  api_key=$(vault_get app.api-key "secret/demo-app/${env}")
  expect post-401 "$env" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"message":"x"}' "${base}/api/greetings")"
  created=$(curl -fs -X POST -H 'Content-Type: application/json' -H "X-Api-Key: ${api_key}" \
    -d "{\"message\":\"hello from ${env}\"}" "${base}/api/greetings")
  expect greeting-env "$env" "$(jq -r '.env' <<<"$created")" "$env"
  expect isolation "$env" "$(curl -fs "${base}/api/greetings" | jq -r --arg env "$env" '[.[] | select(.env != $env)] | length')"

  IMAGE_IDS+=("$(docker inspect --format '{{.Image}}' "$(docker compose ps -q "app-${env}")")")
}

# check_across: skipped when no environment started (their "started" checks already failed)
check_across() {
  step "across environments"
  (( ${#IMAGE_IDS[@]} > 0 )) || { note "  no environment started: nothing to compare"; return 0; }
  expect across.images "" "$(count_distinct "${IMAGE_IDS[@]}")"
  note "  image: $(printf '%s\n' "${IMAGE_IDS[@]}" | sort -u | head -1)"
  expect across.secrets "" "$(count_distinct "${FINGERPRINTS[@]}")"
}

# ---------------------------------------------------------------------------------------------------- main

for i in "${!ENVS[@]}"; do check_env "$i"; done
check_across
finish
