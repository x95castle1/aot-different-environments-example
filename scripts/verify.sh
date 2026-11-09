#!/usr/bin/env bash
# Checks every environment: same image, its own profiles, config, secrets and database.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v jq >/dev/null || { echo "jq is required (brew install jq)"; exit 1; }

ENVS=(dev1 dev2 qa1 prod1)
PORTS=(8081 8082 8083 8084)
PROFILES=("dev,dev1" "dev,dev2" "qa,qa1" "prod,prod1")
SINKS=(LogAuditSink LogAuditSink MongoAuditSink MongoAuditSink)

failures=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; failures=$((failures + 1)); }
check() { if [[ "$2" == "$3" ]]; then pass "$1: $2"; else fail "$1: got '$2', expected '$3'"; fi; }

wait_for() {
  local url=$1
  for _ in $(seq 1 60); do
    curl -fs "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

image_ids=()
fingerprints=()

for i in "${!ENVS[@]}"; do
  env=${ENVS[$i]}; port=${PORTS[$i]}; base="http://localhost:${port}"
  echo "== ${env} (${base})"

  if ! wait_for "${base}/actuator/health"; then
    fail "not healthy after 60s (docker compose logs app-${env})"
    continue
  fi

  info=$(curl -fs "${base}/info/runtime")
  check "profiles" "$(jq -r '.activeProfiles | join(",")' <<<"$info")" "${PROFILES[$i]}"
  check "mongo database (from Config Server)" "$(jq -r '.mongo.database' <<<"$info")" "demo_${env}"
  check "mongo ping (password from Vault)" "$(jq -r '.mongo.ping' <<<"$info")" "ok"
  check "audit sink (chosen at startup)" "$(jq -r '.auditSink' <<<"$info")" "${SINKS[$i]}"
  check "Spring AOT generated code in use" "$(jq -r '.aot.springAotGeneratedCode' <<<"$info")" "true"
  jq -r '.configSources[] | "    loaded " + .' <<<"$info"

  fingerprints+=("$(jq -r '.secretFingerprints | to_entries | map(.value) | join(",")' <<<"$info")")

  api_key=$(docker compose exec -T -e VAULT_TOKEN=root -e VAULT_ADDR=http://127.0.0.1:8200 vault \
    vault kv get -field=app.api-key "secret/demo-app/${env}")
  check "POST without API key" \
    "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"message":"x"}' "${base}/api/greetings")" "401"
  created=$(curl -fs -X POST -H 'Content-Type: application/json' -H "X-Api-Key: ${api_key}" \
    -d "{\"message\":\"hello from ${env}\"}" "${base}/api/greetings")
  check "greeting stored in this env's database" "$(jq -r '.env' <<<"$created")" "${env}"
  others=$(curl -fs "${base}/api/greetings" | jq -r --arg env "$env" '[.[] | select(.env != $env)] | length')
  check "no other environment's data visible" "$others" "0"

  image_ids+=("$(docker inspect --format '{{.Image}}' "$(docker compose ps -q "app-${env}")")")
done

echo "== across environments"
check "distinct images across all environments" "$(printf '%s\n' "${image_ids[@]}" | sort -u | wc -l | tr -d ' ')" "1"
pass "image: $(printf '%s\n' "${image_ids[@]}" | sort -u | head -1)"
check "distinct secret sets (one per environment)" "$(printf '%s\n' "${fingerprints[@]}" | sort -u | wc -l | tr -d ' ')" "${#ENVS[@]}"

echo
if (( failures > 0 )); then echo "${failures} check(s) failed"; exit 1; fi
echo "All checks passed."
