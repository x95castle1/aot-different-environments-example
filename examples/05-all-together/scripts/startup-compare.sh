#!/usr/bin/env bash
# Starts the prod1 environment (ENV=...) from the same image four ways, one per combination of Spring AOT and the
# JDK AOT cache, and reports Spring's startup time (RUNS starts each). Each start is a fresh one-off container
# using the real Config Server, Vault and Mongo.
#
#   1. Spring AOT + JDK AOT cache   (what the image's ENTRYPOINT does)
#   2. JDK AOT cache only
#   3. Spring AOT only
#   4. Plain JVM - No Cache (neither Spring AOT nor the JDK AOT cache)
#
# For each: first one start that counts how many classes came from the JDK AOT cache, then RUNS timed starts.
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
expect_init 05-all-together

RUNS=${RUNS:-3}
ENV=${ENV:-prod1}
CACHE=-XX:AOTCache=/app/app.aot
SPRING_AOT=-Dspring.aot.enabled=true

# ---------------------------------------------------------------------------------------------------- helpers

# cache_usage <timing id> <java options...>: classes loaded from the JDK AOT cache by one start of app-<ENV>
# with <java options...> (AOT_USAGE_SCRIPT, with its java options replaced by these)
cache_usage() {
  local id=$1; shift
  local from="java ${CACHE} ${SPRING_AOT} -jar"
  [[ "$AOT_USAGE_SCRIPT" == *"$from"* ]] || { echo "BUG: AOT_USAGE_SCRIPT no longer starts with '$from'" >&2; exit 3; }
  AOT_USAGE_SCRIPT=${AOT_USAGE_SCRIPT/"$from"/java ${*:+$* }-jar} \
    aot_usage "${id}.aot-cache.txt" docker compose run --rm --no-deps -T --entrypoint sh "app-${ENV}" -c
  expect "cache.${id}" "" "$AOT_VERDICT" "" "${id}.aot-cache.txt"
}

# measure <timing id> <label> <java options...>: the class count, then RUNS one-off starts of app-<ENV>
measure() {
  local id=$1 label=$2; shift 2
  cache_usage "$id" "$@"
  local times=() name="aot-05-startup-$$"
  for _ in $(seq 1 "$RUNS"); do
    docker compose run -d --rm --no-deps --name "$name" --entrypoint java "app-${ENV}" "$@" -jar /app/app.jar >/dev/null
    times+=("$(started_in "$name")")
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  record_timing "$id" "${times[@]}"
  printf '  %-28s classes from the JDK AOT cache %5s / %-5s  median %ss   (runs: %s)\n' \
    "$label" "$CACHED" "$TOTAL" "$(median "${times[@]}")" "${times[*]}"
}

# ---------------------------------------------------------------------------------------------------- steps

compare_startup() {
  step "Startup time for ${ENV}, ${RUNS} runs each"
  measure full       "Spring AOT + JDK AOT cache"  "$CACHE" "$SPRING_AOT"
  measure cache-only "JDK AOT cache only"          "$CACHE"
  measure aot-only   "Spring AOT only"             "$SPRING_AOT"
  measure neither    "Plain JVM - No Cache"
}

# ---------------------------------------------------------------------------------------------------- main

compare_startup
