#!/usr/bin/env bash
# Example 06: train the AOT cache with a real workload (training-pipeline.sh), then measure what it buys.
#
# Three images of the same app, all measured in the "real" dev1 environment (shared infra, its own
# credentials), never in the training stack:
#   untrained          no AOT cache at all
#   context-trained    cache trained in the build on startup only (-Dspring.context.exit=onRefresh)
#   workload-trained   cache trained by training-pipeline.sh with the request mix in run-workload.sh
# Per image, RUNS fresh starts (round-robin, data reset before each): startup time, first request,
# and the first WARMUP_REQUESTS requests (warm-up). Plus one run counting classes from the cache.
# Then the workload-trained image as dev1 and as prod1.
# Expected results: expectations.json. Writes reports/06-training-workload/<run>/report.md.
#
# Each part is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq curl

RUNS=${RUNS:-3}
WARMUP_REQUESTS=${WARMUP_REQUESTS:-300}
EARLY_REQUESTS=50                    # the "first 50 requests" timing
export RUNS
IMAGES=(untrained context-trained workload-trained)
METRICS=(startup first early warmup)
# The environments (dev1, prod1) are defined in compose.yml: env vars, Vault token, JVM flags, memory, ports.
ENVC=(docker compose -f compose.yml)
INFRA=(docker compose -f "$ROOT/infra/compose.yml")
# The demo's own instrumentation for counting classes (JAVA_TOOL_OPTIONS): log every class load and its source
CLASS_LOG="-Xlog:disable -Xlog:class+load=info:file=/tmp/cl.log"
# A row of the environments table
ROW_FORMAT='%-6s %-11s %-64s %-15s %-14s %-9s %s'

NAME="" PORT=""     # the running app's container id and host port (start_app)
TIMINGS=()          # "<timing id> <seconds>" per metric and timed start, e.g. "first.workload 0.031" (add_timings)
ROWS=()             # the environments table (check_environment)
ENV_IMAGES=()       # the image id each environment ran (check_environment)

cleanup() { "${ENVC[@]}" down --remove-orphans >/dev/null 2>&1 || true; }

# ---------------------------------------------------------------------------------------------------- helpers

# short <image>: its name in check ids, timing ids and evidence files: untrained, context, workload
short() { echo "${1%-trained}"; }

# reset_data <env>: empty that environment's orders collection, so every run starts from the same data
reset_data() {
  "${INFRA[@]}" exec -T mongo mongosh --quiet -u root -p example --authenticationDatabase admin \
    --eval "db.getSiblingDB('workload_$1').orders.drop()" >/dev/null
}

# start_app <env> <image> [JAVA_TOOL_OPTIONS]: docker compose up app-<env> with IMAGE=workload-app:<image>, waits
# until healthy. Sets NAME (container id) and PORT. The environment is entirely what compose.yml says; the optional
# JAVA_TOOL_OPTIONS is the demo's own instrumentation (class-load logging), never set otherwise.
start_app() {
  local env=$1 img=$2 tool=${3:-}
  cleanup
  if [[ -n "$tool" ]]; then
    JAVA_TOOL_OPTIONS="$tool" IMAGE="workload-app:$img" "${ENVC[@]}" up -d --force-recreate "app-$env" >/dev/null 2>&1
  else
    env -u JAVA_TOOL_OPTIONS IMAGE="workload-app:$img" "${ENVC[@]}" up -d --force-recreate "app-$env" >/dev/null 2>&1
  fi
  NAME=$("${ENVC[@]}" ps -q "app-$env")
  PORT=$("${ENVC[@]}" port "app-$env" 8080 | sed 's/.*://')
  [[ -n "$NAME" && -n "$PORT" ]] && wait_for_http "http://localhost:${PORT}/actuator/health" 90
}

# save_logs <evidence>: the app's log -> raw/<evidence>
save_logs() { docker logs "$NAME" 2>&1 | save_evidence "$1" || true; }

# time_workload: send the app run-workload.sh's first WARMUP_REQUESTS requests (sequential, same mix every time).
# Sets FIRST (the first request), EARLY (the first EARLY_REQUESTS) and WARMUP (all of them), in seconds.
time_workload() {
  local out
  out=$(./run-workload.sh "http://localhost:${PORT}" "$WARMUP_REQUESTS" 1 42 || true)
  FIRST=$(awk 'NR == 1 {print $2}' <<<"$out")
  FIRST=${FIRST:-FAIL}
  EARLY=$(seconds_of_first "$EARLY_REQUESTS" <<<"$out")
  WARMUP=$(seconds_of_first "$WARMUP_REQUESTS" <<<"$out")
}

# seconds_of_first <n>: stdin = run-workload.sh's output; the total time of its first <n> requests
seconds_of_first() { awk -v n="$1" 'NR <= n && $2 ~ /^[0-9.]+$/ {t += $2} END {printf "%.3f", t}'; }

# count_classes <evidence>: the classes the app (started with CLASS_LOG) has loaded so far, and how many came from
# the AOT cache. Sets TOTAL, CACHED and FROM_JARS; saves the counts as raw/<evidence>.
count_classes() {
  read -r CACHED TOTAL < <(docker exec "$NAME" sh -c 'echo "$(grep -c "shared objects file" /tmp/cl.log) $(grep -c "source:" /tmp/cl.log)"')
  FROM_JARS=$((TOTAL - CACHED))
  printf 'classes loaded (startup + %s requests): %s, from the AOT cache: %s, from the jars: %s\n' \
    "$WARMUP_REQUESTS" "$TOTAL" "$CACHED" "$FROM_JARS" | save_evidence "$1"
}

# add_timings <image> <startup> <first> <early> <warmup>: one timed start's results (FAIL: it didn't start)
add_timings() {
  local s m
  s=$(short "$1"); shift
  for m in "${METRICS[@]}"; do TIMINGS+=("${m}.${s} $1"); shift; done
}

# record_timings: one record_timing per image and metric (e.g. first.workload), with its result from every round
record_timings() {
  local img m id
  for img in "${IMAGES[@]}"; do
    for m in "${METRICS[@]}"; do
      id="${m}.$(short "$img")"
      # shellcheck disable=SC2046  # one argument per round
      record_timing "$id" $(printf '%s\n' "${TIMINGS[@]}" | awk -v id="$id" '$1 == id {print $2}')
    done
  done
}

# ---------------------------------------------------------------------------------------------------- training

# train: training-pipeline.sh builds workload-app:untrained and :context-trained and trains :workload-trained.
# If it stops early there's nothing to measure: report what it recorded and stop.
train() {
  local status=0
  ./training-pipeline.sh || status=$?
  expect training.pipeline "" "$([[ $status -eq 0 ]] && echo yes || echo "no (exit ${status})")"
  (( status == 0 )) || finish
  local img
  for img in "${IMAGES[@]}"; do report_image "workload-app:$img"; done
}

# ---------------------------------------------------------------------------------------------------- setup

show_images() {
  step "The three images"
  note "  untrained         no AOT cache at all"
  note "  context-trained   cache recorded in docker build by only starting the app (Spring context up, JVM exits"
  note "                    before any request): startup code only"
  note "  workload-trained  cache recorded by training-pipeline.sh while the app served real requests: startup + request-path code"
}

# start_environments: the shared infrastructure, with dev1's and prod1's settings and credentials
start_environments() {
  step "Environments: dev1 and prod1 on the shared infrastructure"
  note "  Both defined in compose.yml (services app-dev1, app-prod1):"
  "${ENVC[@]}" config --format json | jq -r '.services | to_entries[] | .key as $service | .value
    | "    \($service)  profiles from APP_ENV=\(.environment.APP_ENV) APP_ENV_INDEX=\(.environment.APP_ENV_INDEX)"
      + "  memory \((.mem_limit | tonumber) / 1048576 | floor) MB"
      + "  JVM flags: \(.environment.JDK_JAVA_OPTIONS // "image default (the flags the caches were trained with)")"'
  note "  Each gets its tier + environment settings from Config Server and its own Mongo password from Vault."
  make -s -C "$ROOT/infra" up >/dev/null 2>&1
  "$ROOT/infra/bootstrap.sh" workload-app dev1 prod1 | sed 's/^/  /'
}

# ---------------------------------------------------------------------------------------------------- measure

time_images() {
  step "Timing the three images in dev1"
  note "  ${RUNS} fresh starts per image, round-robin; first request = first POST /orders after ready;"
  note "  warm-up = total time of the first ${EARLY_REQUESTS} and the first ${WARMUP_REQUESTS} requests of run-workload.sh (sequential, same mix every time)"
  local run img
  for run in $(seq 1 "$RUNS"); do
    step "Round ${run}/${RUNS}"
    for img in "${IMAGES[@]}"; do time_image "$img" "$run"; done
  done
  cleanup
  record_timings
}

# time_image <image> <round>: one fresh start in dev1: its startup time, then the workload's
time_image() {
  local img=$1 run=$2 s st
  s=$(short "$img")
  reset_data dev1
  if ! start_app dev1 "$img"; then
    save_logs "${s}.failed-start.log"
    add_timings "$img" FAIL FAIL FAIL FAIL
    fail "${img}: did not start"
    return 0
  fi
  st=$(started_in "$NAME")
  time_workload
  if [[ "$run" == 1 ]]; then save_logs "${s}.startup.log"; fi
  add_timings "$img" "$st" "$FIRST" "$EARLY" "$WARMUP"
  printf '  %-17s startup %6ss   first request %7ss   first %s %6ss   first %s %6ss\n' \
    "$img" "$st" "$FIRST" "$EARLY_REQUESTS" "$EARLY" "$WARMUP_REQUESTS" "$WARMUP"
}

# ---------------------------------------------------------------------------------------------------- classes

# count_cached_classes: per image, one start in dev1 with class-load logging, then the workload: how many classes
# came from the AOT cache, and how many still had to be loaded from the jars
count_cached_classes() {
  step "Classes loaded in dev1 during startup + ${WARMUP_REQUESTS} requests: from the AOT cache vs from the jars"
  local img s context_jars="" workload_jars=""
  for img in "${IMAGES[@]}"; do
    s=$(short "$img")
    reset_data dev1
    start_app dev1 "$img" "$CLASS_LOG" || { fail "${img}: did not start"; continue; }
    ./run-workload.sh "http://localhost:${PORT}" "$WARMUP_REQUESTS" 1 42 >/dev/null || true
    count_classes "${s}.classes.txt"
    printf '  %-17s %6s classes loaded, %6s from the AOT cache, %5s from the jars\n' "$img" "$TOTAL" "$CACHED" "$FROM_JARS"
    expect "cache.${s}" "" "$(aot_verdict "$CACHED" "$TOTAL")" "" "${s}.classes.txt"
    expect "outside.${s}" "" "${FROM_JARS} classes"
    case $s in
      context)  context_jars=$FROM_JARS ;;
      workload) workload_jars=$FROM_JARS ;;
    esac
  done
  cleanup
  if [[ -n "$context_jars" && -n "$workload_jars" ]]; then
    expect fewer-outside "" "$([[ $workload_jars -lt $context_jars ]] && echo yes || echo no)" "" workload.classes.txt
  fi
}

# ---------------------------------------------------------------------------------------------------- environments

check_environments() {
  step "The image you'd ship (workload-trained) in each environment"
  note "  The same image, started as dev1 (profiles dev,dev1) and as prod1 (profiles prod,prod1)."
  check_environment dev1 dev 50
  check_environment prod1 prod 100
  cleanup
  (( ${#ENV_IMAGES[@]} > 0 )) || return 0
  expect env.same-image "" "$(printf '%s\n' "${ENV_IMAGES[@]}" | sort -u | wc -l | tr -d ' ')"
  # shellcheck disable=SC2059  # ROW_FORMAT is a format
  printf "\n  %s${ROW_FORMAT}%s\n" "$C_BOLD" "env" "profiles" "Config Server files (most specific first)" "database" "tier setting" "heap" "AOT cache" "$C_RESET"
  printf '  %s\n' "${ROWS[@]}"
}

# check_environment <env> <tier> <max page size>: start the workload-trained image as <env> and check it got that
# environment's profiles, Config Server files, tier setting, database and Vault secret, and used the AOT cache.
# Adds a row to ROWS and the image id to ENV_IMAGES.
check_environment() {
  local env=$1 tier=$2 max_page=$3
  reset_data "$env"
  if ! start_app "$env" workload-trained "$CLASS_LOG"; then
    save_logs "${env}.failed-start.log"
    expect env.started "$env" no "" "${env}.failed-start.log"
    return 0
  fi
  expect env.started "$env" yes

  local st info
  st=$(started_in "$NAME")
  info=$(curl -fs "http://localhost:${PORT}/info/runtime")
  jq . <<<"$info" | save_evidence "${env}.info.json"
  time_workload
  count_classes "${env}.classes.txt"
  ENV_IMAGES+=("$(docker inspect -f '{{.Image}}' "$NAME")")

  # What the app says about itself (GET /info/runtime)
  local profiles files vault db page heap flags
  profiles=$(jq -r '.activeProfiles | join(",")' <<<"$info")
  files=$(jq -r '[.configSources[] | select(startswith("configserver:")) | sub("^configserver:file:/config-repo/"; "") | sub(" \\(.*$"; "")] | join(", ")' <<<"$info")
  vault=$(jq -r --arg p "vault:secret/workload-app/${env} " '[.configSources[] | select(startswith($p))][0] // "not loaded" | sub(" \\(.*$"; "")' <<<"$info")
  db=$(jq -r '.mongo.database' <<<"$info")
  page=$(jq -r '.maxPageSize' <<<"$info")
  heap=$(jq -r '.jvm.maxHeapMb' <<<"$info")
  # The environment's own flags: leave out the AOT-cache flag (same everywhere) and the demo's -Xlog instrumentation
  flags=$(jq -r '.jvm.inputArguments | map(select(startswith("-X"))) | map(select((startswith("-XX:AOTCache") or startswith("-Xlog")) | not)) | join(" ")' <<<"$info")

  local evidence="${env}.info.json"
  expect env.profiles     "$env" "$profiles" "${tier},${env}" "$evidence"
  expect env.config-files "$env" "$files" "workload-app-${env}.yml, workload-app-${tier}.yml, workload-app.yml" "$evidence"
  expect env.tier-setting "$env" "$page" "$max_page" "$evidence"
  expect env.mongo-db     "$env" "$db" "workload_${env}" "$evidence"
  expect env.vault        "$env" "$vault" "vault:secret/workload-app/${env}" "$evidence"
  expect env.mongo-ping   "$env" "$(jq -r '.mongo.ping' <<<"$info")" "" "$evidence"
  expect env.cache        "$env" "$(aot_verdict "$CACHED" "$TOTAL")" "" "${env}.classes.txt"
  expect env.jvm          "$env" "${flags} (max heap ${heap} MB)"
  expect env.timing       "$env" "startup ${st}s, first request ${FIRST}s, ${FROM_JARS} classes loaded from the jars"
  # shellcheck disable=SC2059  # ROW_FORMAT is a format
  ROWS+=("$(printf "$ROW_FORMAT" "$env" "$profiles" "$files" "$db" "max-page $page" "${heap} MB" "${CACHED}/${TOTAL}")")
}

# ---------------------------------------------------------------------------------------------------- main

trap cleanup EXIT
report_init 06-training-workload
train
show_images
start_environments
time_images
count_cached_classes
check_environments
finish
