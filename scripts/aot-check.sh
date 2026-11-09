#!/usr/bin/env bash
# Shows whether each environment's JVM actually used the AOT cache baked into the image.
# Runs a one-off copy of the environment (same image, same env vars and JVM flags), logs where
# every class was loaded from, and stops right after the Spring context is ready.
set -euo pipefail
cd "$(dirname "$0")/.."

ENVS=(${*:-prod1 dev1 dev2})

for env in "${ENVS[@]}"; do
  echo "== ${env}"
  docker compose run --rm --no-deps -T \
    -e JAVA_TOOL_OPTIONS="-Xlog:class+load=info:file=/tmp/classload.log -Xlog:aot=warning:file=/tmp/aot.log -Dspring.context.exit=onRefresh" \
    --entrypoint sh "app-${env}" -c '
      java -XX:AOTCache=/app/app.aot -Dspring.aot.enabled=true -jar /app/demo-app.jar >/dev/null 2>&1
      total=$(grep -c "source:" /tmp/classload.log)
      cached=$(grep -c "source: shared objects file" /tmp/classload.log || true)
      app_total=$(grep -c "com.example.demo" /tmp/classload.log)
      app_cached=$(grep "com.example.demo" /tmp/classload.log | grep -c "shared objects file" || true)
      echo "  JVM flags        : ${JDK_JAVA_OPTIONS}"
      echo "  classes from AOT cache: ${cached} / ${total} (app classes: ${app_cached} / ${app_total})"
      if [ "${cached}" -gt 1000 ]; then echo "  result           : AOT cache USED"; else echo "  result           : AOT cache NOT used (JVM fell back, app still started)"; grep -m3 -E "aot" /tmp/aot.log | sed "s/^/  jvm says         : /"; fi
    '
done
