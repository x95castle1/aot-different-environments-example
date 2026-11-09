#!/usr/bin/env bash
# Starts the prod1 environment from the same image three ways and reports Spring's startup time
# (RUNS starts each). Each run is a fresh one-off container using the real Config Server, Vault and Mongo.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
expect_init 05-all-together

RUNS=${RUNS:-3}
ENV=${ENV:-prod1}

measure() {
  local id=$1 label=$2; shift 2
  local times=()
  for _ in $(seq 1 "$RUNS"); do
    local name="aot-05-startup-$$"
    docker compose run -d --rm --no-deps --name "$name" --entrypoint java "app-${ENV}" "$@" >/dev/null
    times+=("$(started_in "$name")")
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  record_timing "$id" "${times[@]}"
  printf '  %-30s median %ss   (runs: %s)\n' "$label" "$(median "${times[@]}")" "${times[*]}"
}

step "Startup time for ${ENV}, ${RUNS} runs each"
measure full     "Spring AOT + JDK AOT cache"  -XX:AOTCache=/app/app.aot -Dspring.aot.enabled=true -jar /app/app.jar
measure aot-only "Spring AOT only"             -Dspring.aot.enabled=true -jar /app/app.jar
measure neither  "Neither"                     -jar /app/app.jar
