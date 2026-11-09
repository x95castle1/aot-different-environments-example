#!/usr/bin/env bash
# Starts the prod1 environment from the same image three ways and reports Spring's startup time
# (median of RUNS). Each run is a fresh one-off container using the real Config Server, Vault and Mongo.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"

RUNS=${RUNS:-3}
ENV=${ENV:-prod1}

measure() {
  local label=$1; shift
  local times=()
  for _ in $(seq 1 "$RUNS"); do
    local name="aot05-startup-$$"
    docker compose run -d --rm --no-deps --name "$name" --entrypoint java "app-${ENV}" "$@" >/dev/null
    times+=("$(started_in "$name")")
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  printf '  %-30s median %ss   (runs: %s)\n' "$label" "$(median "${times[@]}")" "${times[*]}"
}

step "Startup time for ${ENV}, ${RUNS} runs each"
measure "Spring AOT + JDK AOT cache"  -XX:AOTCache=/app/app.aot -Dspring.aot.enabled=true -jar /app/app.jar
measure "Spring AOT only"             -Dspring.aot.enabled=true -jar /app/app.jar
measure "Neither"                     -jar /app/app.jar
