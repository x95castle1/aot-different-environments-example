#!/usr/bin/env bash
# Shows whether each environment's JVM actually used the AOT cache baked into the image.
# Runs a one-off copy of the environment (same image, env vars and JVM flags) and counts how many
# classes came from the cache. Expected: prod1, dev1 and qa1 use it; dev2 (ZGC) falls back.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(cd ../.. && pwd)
. "$ROOT/scripts/lib.sh"
require jq
expect_init 05-all-together

for env in ${*:-prod1 dev1 qa1 dev2}; do
  step "${env}"
  flags=$(docker compose config --format json | jq -r --arg s "app-${env}" '.services[$s].environment.JDK_JAVA_OPTIONS // empty')
  [[ -n "$flags" ]] || flags="$(image_jvm_flags demo-app:1.0.0)  (image default = training flags)"
  aot_usage "${env}.aot-cache.txt" docker compose run --rm --no-deps -T --entrypoint sh "app-${env}" -c
  note "  JVM flags: ${flags}"
  note "  classes from AOT cache: ${CACHED} / ${TOTAL}"
  if [[ "$env" == dev2 ]]; then expect cache.zgc "$env" "$AOT_VERDICT" "" "${env}.aot-cache.txt"
  else expect cache "$env" "$AOT_VERDICT" "" "${env}.aot-cache.txt"; fi
done
finish
