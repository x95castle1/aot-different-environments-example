#!/usr/bin/env bash
# Example 02: one image (Spring AOT on), profiles decided at startup from APP_ENV + APP_ENV_INDEX.
#
#   1. Start six instances of the same image (instances in expectations.json)
#   2. Check each one: profile-specific VALUES and a @Bean-method choice follow the environment, while
#      @Profile / @ConditionalOnProperty beans are frozen at build time. One instance runs without Spring AOT.
#   3. Time each instance on its own (RUNS starts) and count its classes from the AOT cache
# Writes reports/02-dynamic-profiles/<run>/report.md.
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

IMAGE=profiles-app:1.0.0
RUNS=${RUNS:-5}
export RUNS
OPTS=()            # the current instance's docker run options (set_opts)
ROWS=()            # the summary table (check_instance)
cleanup() { docker rm -f $(docker ps -aq --filter 'name=^aot-02-') >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------------------------------------------- helpers

# instances: one line per instance in expectations.json, fields separated by \x1f
instances() { jq -r '.instances[] | [.id, .name, .env, .index, .spa, .aot, (.port|tostring), .profiles, .db, .notifier, .pitfall] | join("\u001f")' expectations.json; }

# set_opts <env> <index> <SPRING_PROFILES_ACTIVE>: fills OPTS with the instance's environment variables
set_opts() {
  OPTS=(-e "APP_ENV=$1" -e "APP_ENV_INDEX=$2")
  [[ -n "$3" ]] && OPTS+=(-e "SPRING_PROFILES_ACTIVE=$3")
  return 0
}

# run_app <on|off> <docker run options...>: start the image with Spring AOT on (its ENTRYPOINT) or off
run_app() {
  local aot=$1; shift
  if [[ "$aot" == "off" ]]; then
    # Same image and AOT cache, but without the AOT-generated bean definitions: Spring evaluates @Profile etc. at runtime.
    docker run "$@" --entrypoint java "$IMAGE" -XX:AOTCache=/app/app.aot -jar /app/app.jar >/dev/null
  else
    docker run "$@" "$IMAGE" >/dev/null
  fi
}

# start_once <on|off>: start the app once with OPTS, print Spring's startup seconds
start_once() {
  local name="aot-02-profiles-run-$$"
  docker rm -f "$name" >/dev/null 2>&1 || true
  run_app "$1" -d --name "$name" "${OPTS[@]}"
  started_in "$name"
  docker rm -f "$name" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------------- steps

start_instances() {
  step "Starting six instances of ${IMAGE}"
  report_image "$IMAGE"
  local name env idx spa aot port
  while IFS=$'\x1f' read -r _ name env idx spa aot port _; do
    set_opts "$env" "$idx" "$spa"
    run_app "$aot" -d --name "aot-02-profiles-${port}" -p "${port}:8080" "${OPTS[@]}"
    note "  ${name}: APP_ENV=${env} APP_ENV_INDEX=${idx}${spa:+ SPRING_PROFILES_ACTIVE=${spa}} (Spring AOT ${aot}) -> :${port}"
  done < <(instances)
}

check_instances() {
  local id name env idx spa aot port exp_profiles exp_db exp_notifier pitfall
  while IFS=$'\x1f' read -r id name env idx spa aot port exp_profiles exp_db exp_notifier pitfall; do
    check_instance "$id" "$name" "$aot" "$port" "$exp_profiles" "$exp_db" "$exp_notifier" "$pitfall"
  done < <(instances)

  step "Summary"
  printf '  %s%-26s %-10s %-17s %-13s %-14s %-9s %s%s\n' "$C_BOLD" "instance" "Spring AOT" "profiles" "app.db-name" "notifier" "@Profile" "@ConditionalOnProperty" "$C_RESET"
  printf '  %s\n' "${ROWS[@]}"
}

# check_instance <id> <name> <aot> <port> <profiles> <db> <notifier> <pitfall>: what the running instance reports
# (GET /info/profiles) vs what's expected. Adds a row to ROWS.
check_instance() {
  local id=$1 name=$2 aot=$3 port=$4 exp_profiles=$5 exp_db=$6 exp_notifier=$7 pitfall=$8
  step "${name}"
  local ok=yes
  wait_for_http "http://localhost:${port}/info/profiles" 60 || ok=no
  docker logs "aot-02-profiles-${port}" 2>&1 | save_evidence "${id}.startup.log"
  expect started "$name" "$ok" "" "${id}.startup.log"
  [[ "$ok" == yes ]] || return 0

  local info profiles db notifier p1 p2
  info=$(curl -fs "http://localhost:${port}/info/profiles")
  jq . <<<"$info" | save_evidence "${id}.info.json"
  profiles=$(jq -r '.activeProfiles | join(",")' <<<"$info")
  db=$(jq -r '.values["app.db-name"]' <<<"$info")
  notifier=$(jq -r '.notifier' <<<"$info")
  p1=$(jq -r '.pitfall.profileProdBeanExists' <<<"$info")
  p2=$(jq -r '.pitfall.conditionalOnPropertyBeanExists' <<<"$info")
  note "  app.message: $(jq -r '.values["app.message"]' <<<"$info")"
  expect aot "$name" "$(jq -r '.springAotGeneratedCode' <<<"$info")" "$([[ $aot == on ]] && echo true || echo false)" "${id}.info.json"
  expect profiles "$name" "$profiles" "$exp_profiles" "${id}.info.json"
  expect db-name "$name" "$db" "$exp_db" "${id}.info.json"
  expect notifier "$name" "$notifier" "$exp_notifier" "${id}.info.json"
  expect "pitfall.profile.${pitfall}" "$name" "$p1" "" "${id}.info.json"
  expect "pitfall.conditional.${pitfall}" "$name" "$p2" "" "${id}.info.json"
  ROWS+=("$(printf '%-26s %-10s %-17s %-13s %-14s %-9s %s' "$name" "$aot" "$profiles" "$db" "$notifier" "$p1" "$p2")")
}

# time_instances: the six instances above started at the same time and competed for CPU, so time each one
# again on its own
time_instances() {
  cleanup
  step "Startup time per instance"
  note "  JDK AOT cache trained in the build with no profile active, with: $(image_jvm_flags "$IMAGE")"
  note "  ${RUNS} timed runs per instance, one at a time; Spring's \"Started ... in X seconds\""
  set_opts prod 1 ""
  start_once on >/dev/null   # warm-up

  local id name env idx spa aot
  while IFS=$'\x1f' read -r id name env idx spa aot _; do
    time_instance "$id" "$name" "$env" "$idx" "$spa" "$aot"
  done < <(instances)

  echo
  note "  Two different AOTs in the table below: \"JDK AOT cache\" pre-loads classes and is on for every row;"
  note "  \"without Spring AOT\" means no build-time bean code, so prod1 vs that row is what Spring AOT alone is worth."
}

# time_instance <id> <name> <env> <index> <SPRING_PROFILES_ACTIVE> <aot>: classes from the AOT cache, then RUNS starts
time_instance() {
  local id=$1 name=$2 env=$3 idx=$4 spa=$5 aot=$6
  step "$name"
  set_opts "$env" "$idx" "$spa"

  local usage_script=$AOT_USAGE_SCRIPT
  # Without Spring AOT: count the cache's classes for the same start command as run_app, without -Dspring.aot.enabled=true
  if [[ "$aot" == "off" ]]; then usage_script=${AOT_USAGE_SCRIPT/ -Dspring.aot.enabled=true/}; fi
  AOT_USAGE_SCRIPT=$usage_script aot_usage "${id}.aot-cache.txt" docker run --rm "${OPTS[@]}" --entrypoint sh "$IMAGE" -c
  expect "cache.${id}" "$name" "$AOT_VERDICT" "" "${id}.aot-cache.txt"
  note "  classes from JDK AOT cache: ${CACHED} / ${TOTAL}"

  local times=()
  for _ in $(seq 1 "$RUNS"); do times+=("$(start_once "$aot")"); done
  record_timing "$id" "${times[@]}"
  note "  startup (s): ${times[*]}   median $(median "${times[@]}")"
}

# ---------------------------------------------------------------------------------------------------- main

trap cleanup EXIT
cleanup
report_init 02-dynamic-profiles
start_instances
check_instances
time_instances
finish
