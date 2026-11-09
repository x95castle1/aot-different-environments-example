#!/usr/bin/env bash
# Example 02: one image (Spring AOT on), profiles decided at startup from APP_ENV + APP_ENV_INDEX.
# Shows that profile-specific VALUES and a @Bean-method choice follow the environment, while
# @Profile / @ConditionalOnProperty beans are frozen at build time. Then the same prod run without Spring AOT.
# Then times each instance on its own (RUNS starts) and counts its classes from the AOT cache.
# Instances and expected results: expectations.json. Writes reports/02-dynamic-profiles/<run>/report.md.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

IMAGE=profiles-app:1.0.0
RUNS=${RUNS:-5}
export RUNS
cleanup() { docker rm -f $(docker ps -aq --filter 'name=^aot-02-') >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

report_init 02-dynamic-profiles
report_image "$IMAGE"

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

step "Starting six instances of ${IMAGE}"
while IFS=$'\x1f' read -r _ name env idx spa aot port _; do
  set_opts "$env" "$idx" "$spa"
  run_app "$aot" -d --name "aot-02-profiles-${port}" -p "${port}:8080" "${OPTS[@]}"
  note "  ${name}: APP_ENV=${env} APP_ENV_INDEX=${idx}${spa:+ SPRING_PROFILES_ACTIVE=${spa}} (Spring AOT ${aot}) -> :${port}"
done < <(instances)

rows=()
while IFS=$'\x1f' read -r id name env idx spa aot port exp_profiles exp_db exp_notifier pitfall; do
  step "${name}"
  ok=yes; wait_for_http "http://localhost:${port}/info/profiles" 60 || ok=no
  docker logs "aot-02-profiles-${port}" 2>&1 | save_evidence "${id}.startup.log"
  expect started "$name" "$ok" "" "${id}.startup.log"
  [[ "$ok" == yes ]] || continue
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
  rows+=("$(printf '%-26s %-10s %-17s %-13s %-14s %-9s %s' "$name" "$aot" "$profiles" "$db" "$notifier" "$p1" "$p2")")
done < <(instances)

step "Summary"
printf '  %s%-26s %-10s %-17s %-13s %-14s %-9s %s%s\n' "$C_BOLD" "instance" "Spring AOT" "profiles" "app.db-name" "notifier" "@Profile" "@ConditionalOnProperty" "$C_RESET"
printf '  %s\n' "${rows[@]}"

# The six instances above started at the same time and competed for CPU, so time each one again on its own.
cleanup
step "Startup time per instance"
note "  JDK AOT cache trained in the build with no profile active, with: $(image_jvm_flags "$IMAGE")"
note "  ${RUNS} timed runs per instance, one at a time; Spring's \"Started ... in X seconds\""
set_opts prod 1 ""
start_once on >/dev/null   # warm-up

while IFS=$'\x1f' read -r id name env idx spa aot _; do
  step "$name"
  set_opts "$env" "$idx" "$spa"

  usage_script=$AOT_USAGE_SCRIPT
  # Without Spring AOT: count the cache's classes for the same start command as run_app, without -Dspring.aot.enabled=true
  [[ "$aot" == "off" ]] && usage_script=${AOT_USAGE_SCRIPT/ -Dspring.aot.enabled=true/}
  AOT_USAGE_SCRIPT=$usage_script aot_usage "${id}.aot-cache.txt" docker run --rm "${OPTS[@]}" --entrypoint sh "$IMAGE" -c
  expect "cache.${id}" "$name" "$AOT_VERDICT" "" "${id}.aot-cache.txt"
  note "  classes from JDK AOT cache: ${CACHED} / ${TOTAL}"

  times=()
  for _ in $(seq 1 "$RUNS"); do times+=("$(start_once "$aot")"); done
  record_timing "$id" "${times[@]}"
  note "  startup (s): ${times[*]}   median $(median "${times[@]}")"
done < <(instances)

echo
note "  Two different AOTs in the table below: \"JDK AOT cache\" pre-loads classes and is on for every row;"
note "  \"without Spring AOT\" means no build-time bean code, so prod1 vs that row is what Spring AOT alone is worth."
finish
