#!/usr/bin/env bash
# startup-sweep.sh: -XX:CICompilerCount vs Spring's "Started ... in X seconds", on example 01's image, with the AOT
# cache on and off.
# Prod flags, no CPU or memory limit (the container sees every host CPU).
# Needs jvm-args-app:1.0.0 (make examples EX=01 builds it).
#
#   ./startup-sweep.sh                 # 10 rounds
#   ROUNDS=5 ./startup-sweep.sh
#
# Prints one line per start: "<config> <seconds>". <config> is the compiler-thread count ("default" = the JVM's own
# choice) with the AOT cache on, or "off-<count>" for the same image started as a plain JVM (no -XX:AOTCache, the
# way example 01 measures "cache off"). The configs run round-robin, so background drift hits every config
# equally. Summarize with: awk '{v[$1]=v[$1]" "$2} END {for (k in v) print k, v[k]}'
set -euo pipefail
IMG=jvm-args-app:1.0.0
PROD="-XX:+UseG1GC -XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"   # the image's JDK_JAVA_OPTIONS
ROUNDS=${ROUNDS:-10}
# name | extra JVM flags
CFGS=("default|" "2|-XX:CICompilerCount=2" "3|-XX:CICompilerCount=3" "4|-XX:CICompilerCount=4"
      "6|-XX:CICompilerCount=6" "8|-XX:CICompilerCount=8"
      "off-default|" "off-2|-XX:CICompilerCount=2" "off-3|-XX:CICompilerCount=3" "off-4|-XX:CICompilerCount=4"
      "off-6|-XX:CICompilerCount=6" "off-8|-XX:CICompilerCount=8")

# once <name> <extra flags>: start the app once, print Spring's startup seconds (FAIL if it didn't start in 10s)
once() {
  local n="aot-jit-sweep-$$" l="" i
  docker rm -f "$n" >/dev/null 2>&1 || true
  if [[ $1 == off-* ]]; then
    docker run -d --name "$n" -e "JDK_JAVA_OPTIONS=$PROD $2" --entrypoint java "$IMG" -Dspring.aot.enabled=true -jar /app/app.jar >/dev/null
  else
    docker run -d --name "$n" -e "JDK_JAVA_OPTIONS=$PROD $2" "$IMG" >/dev/null
  fi
  for ((i = 0; i < 100; i++)); do
    l=$(docker logs "$n" 2>&1 | grep -o 'Started [A-Za-z]* in [0-9.]*' | awk '{print $4}') || l=""
    [[ -n "$l" ]] && break
    sleep 0.1
  done
  docker rm -f "$n" >/dev/null
  echo "${l:-FAIL}"
}

for ((r = 1; r <= ROUNDS; r++)); do
  for c in "${CFGS[@]}"; do echo "${c%%|*} $(once "${c%%|*}" "${c#*|}")"; done
done
