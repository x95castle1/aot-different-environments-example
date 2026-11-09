#!/usr/bin/env bash
# Starts the prod1 environment from the same image three ways and reports Spring's startup time:
#   1. Spring AOT + JDK AOT cache (how the image runs by default)
#   2. Spring AOT only
#   3. neither (plain JVM)
# Each run is a fresh one-off container connected to the real Config Server, Vault and Mongo.
set -euo pipefail
cd "$(dirname "$0")/.."

RUNS=${RUNS:-3}
ENV=${ENV:-prod1}

measure() {
  local label=$1; shift
  local times=()
  for _ in $(seq 1 "$RUNS"); do
    local name="startup-compare-$$"
    docker compose run -d --rm --no-deps --name "$name" --entrypoint java "app-${ENV}" "$@" >/dev/null
    local line=""
    for _ in $(seq 1 120); do
      line=$(docker logs "$name" 2>&1 | grep -m1 "Started DemoApplication" || true)
      [[ -n "$line" ]] && break
      sleep 0.5
    done
    docker rm -f "$name" >/dev/null 2>&1 || true
    [[ -z "$line" ]] && { echo "  ${label}: did not start"; return; }
    times+=("$(sed -E 's/.*in ([0-9.]+) seconds \(process running for ([0-9.]+)\).*/\1s (JVM total \2s)/' <<<"$line")")
  done
  local joined; joined=$(printf ' | %s' "${times[@]}")
  printf '  %-30s%s\n' "$label" "${joined}"
}

echo "Startup time for ${ENV}, ${RUNS} runs each:"
measure "Spring AOT + JDK AOT cache"  -XX:AOTCache=/app/app.aot -Dspring.aot.enabled=true -jar /app/demo-app.jar
measure "Spring AOT only"             -Dspring.aot.enabled=true -jar /app/demo-app.jar
measure "Neither"                     -jar /app/demo-app.jar
