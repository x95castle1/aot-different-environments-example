#!/usr/bin/env bash
# Starts the prod1 environment (ENV=...) from the same image four ways, one per combination of Spring AOT and the
# JDK AOT cache, and reports Spring's startup time (RUNS starts each). Each start is a fresh one-off container
# using the real Config Server, Vault and Mongo.
#
#   1. Spring AOT + JDK AOT cache   (what the image's ENTRYPOINT does)
#   2. JDK AOT cache only           (a cache trained for the start without Spring AOT: see below)
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
IMAGE=demo-app:1.0.0
CACHE=-XX:AOTCache=/app/app.aot
SPRING_AOT=-Dspring.aot.enabled=true
# "JDK AOT cache only" starts without Spring AOT, and the image's cache wasn't trained on that start (Spring then
# parses the configuration classes at startup). It gets its own cache, in this volume (train_cache_without_spring_aot),
# so the row shows what a cache is worth without Spring AOT, not what a mismatched one is.
COMPARE_VOLUME=aot-05-no-spring-aot-cache
CACHE_WITHOUT_SPRING_AOT=-XX:AOTCache=/cache/app.aot
cleanup() { docker volume rm -f "$COMPARE_VOLUME" >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------------------------------------------- helpers

# cache_usage <timing id> <java options...>: classes loaded from the JDK AOT cache by one start of app-<ENV>
# with <java options...>
cache_usage() {
  local id=$1; shift
  aot_usage_with "$*" "${id}.aot-cache.txt" \
    docker compose run --rm --no-deps -T -v "$COMPARE_VOLUME:/cache:ro" --entrypoint sh "app-${ENV}" -c
  expect "cache.${id}" "" "$AOT_VERDICT" "" "${id}.aot-cache.txt"
}

# measure <timing id> <label> <java options...>: the class count, then RUNS one-off starts of app-<ENV>
measure() {
  local id=$1 label=$2; shift 2
  cache_usage "$id" "$@"
  local times=() name="aot-05-startup-$$"
  for _ in $(seq 1 "$RUNS"); do
    docker compose run -d --rm --no-deps -v "$COMPARE_VOLUME:/cache:ro" --name "$name" --entrypoint java "app-${ENV}" "$@" -jar /app/app.jar >/dev/null
    times+=("$(started_in "$name")")
    docker rm -f "$name" >/dev/null 2>&1 || true
  done
  record_timing "$id" "${times[@]}"
  printf '  %-28s classes from the JDK AOT cache %5s / %-5s  median %ss   (runs: %s)\n' \
    "$label" "$CACHED" "$TOTAL" "$(median "${times[@]}")" "${times[*]}"
}

# ---------------------------------------------------------------------------------------------------- steps

# train_cache_without_spring_aot: recorded the way the Dockerfile records the image's cache (offline, build-time.yml,
# the prod flags, an explicit heap, exit when the context is ready), just without -Dspring.aot.enabled=true
train_cache_without_spring_aot() {
  step "Train a JDK AOT cache for the start without Spring AOT (the \"JDK AOT cache only\" row)"
  docker volume create "$COMPARE_VOLUME" >/dev/null
  local out
  out=$(docker run --rm --network none --user root -v "$COMPARE_VOLUME:/cache" --entrypoint java "$IMAGE" \
    -XX:AOTCacheOutput=/cache/app.aot -Xmx1g \
    -Dspring.config.additional-location=optional:classpath:/build-time.yml \
    -Dspring.context.exit=onRefresh -jar /app/app.jar 2>&1) || true
  save_evidence cache-only.training.log <<<"$out"
  note "  $(grep -o 'AOTCache creation is complete.*' <<<"$out" || echo "no cache written: see raw/cache-only.training.log")"
}

compare_startup() {
  step "Startup time for ${ENV}, ${RUNS} runs each"
  measure full       "Spring AOT + JDK AOT cache"  "$CACHE" "$SPRING_AOT"
  measure cache-only "JDK AOT cache only"          "$CACHE_WITHOUT_SPRING_AOT"
  measure aot-only   "Spring AOT only"             "$SPRING_AOT"
  measure neither    "Plain JVM - No Cache"
}

# ---------------------------------------------------------------------------------------------------- main

trap cleanup EXIT
train_cache_without_spring_aot
compare_startup
