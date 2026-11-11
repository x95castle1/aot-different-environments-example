#!/usr/bin/env bash
# Shows whether each environment's JVM actually used the AOT cache baked into the image.
# Runs a one-off copy of the environment (same image, env vars and JVM flags) and counts how many
# classes came from the cache. Expected: prod1, dev1 and qa1 use it; dev2 (ZGC) falls back.
#
# Usage: scripts/aot-check.sh [env...]     (default: prod1 dev1 qa1 dev2)
#
# Each step is a function below; main, at the bottom, runs them in order.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq
expect_init 05-all-together

# ---------------------------------------------------------------------------------------------------- helpers

# env_flags <env>: the environment's JDK_JAVA_OPTIONS from compose.yml, or the image default
env_flags() {
  local flags
  flags=$(docker compose config --format json | jq -r --arg s "app-$1" '.services[$s].environment.JDK_JAVA_OPTIONS // empty')
  echo "${flags:-$(image_jvm_flags demo-app:1.0.0)  (image default = training flags)}"
}

# ---------------------------------------------------------------------------------------------------- steps

# check_env <env>: classes loaded from the AOT cache by a one-off copy of <env>
check_env() {
  local env=$1
  step "${env}"
  aot_usage "${env}.aot-cache.txt" docker compose run --rm --no-deps -T --entrypoint sh "app-${env}" -c
  note "  JVM flags: $(env_flags "$env")"
  note "  classes from JDK AOT cache: ${CACHED} / ${TOTAL}"
  if [[ "$env" == dev2 ]]; then expect cache.zgc "$env" "$AOT_VERDICT" "" "${env}.aot-cache.txt"
  else expect cache "$env" "$AOT_VERDICT" "" "${env}.aot-cache.txt"; fi
}

# ---------------------------------------------------------------------------------------------------- main

for env in ${*:-prod1 dev1 qa1 dev2}; do check_env "$env"; done
finish
