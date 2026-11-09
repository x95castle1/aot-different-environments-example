#!/usr/bin/env bash
# Shared helpers for the example demo scripts. Source it:  . "$ROOT/scripts/lib.sh"

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

FAILURES=0

step()  { printf '\n%s== %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
note()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
pass()  { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
fail()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1"; FAILURES=$((FAILURES + 1)); }

# check <label> <actual> <expected>
check() { if [[ "$2" == "$3" ]]; then pass "$1: $2"; else fail "$1: got '$2', expected '$3'"; fi; }

# check_true <label> <command...>: passes when the command succeeds
check_true() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

# finish: print the result and exit non-zero if any check failed
finish() {
  echo
  if (( FAILURES > 0 )); then printf '%s%d check(s) failed%s\n' "$C_RED" "$FAILURES" "$C_RESET"; exit 1; fi
  printf '%sAll checks passed.%s\n' "$C_GREEN" "$C_RESET"
}

require() { for c in "$@"; do command -v "$c" >/dev/null || { echo "$c is required"; exit 1; }; done; }

# wait_for_http <url> [seconds]
wait_for_http() {
  local url=$1 secs=${2:-60}
  for _ in $(seq 1 "$secs"); do curl -fs "$url" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

# started_in <container> [seconds]: Spring's "Started ... in X seconds" for a running container, or "FAIL"
started_in() {
  local name=$1 secs=${2:-60} line=""
  for _ in $(seq 1 $((secs * 4))); do
    line=$(docker logs "$name" 2>&1 | grep -m1 "Started .* in [0-9.]* seconds" || true)
    [[ -n "$line" ]] && break
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != "true" ]]; then break; fi
    sleep 0.25
  done
  if [[ -z "$line" ]]; then echo "FAIL"; else sed -E 's/.* in ([0-9.]+) seconds.*/\1/' <<<"$line"; fi
}

# median <numbers...>
median() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {if (NR==0) print "n/a"; else if (NR%2) print a[(NR+1)/2]; else printf "%.3f\n", (a[NR/2]+a[NR/2+1])/2}'; }

# AOT_USAGE_SCRIPT: run inside an app container (entrypoint sh -c) to see how many classes the JVM
# loaded from the AOT cache. Starts the app exactly like the image's ENTRYPOINT (the env's
# JDK_JAVA_OPTIONS apply), stops after the context is ready, prints "<cached> <total>".
# shellcheck disable=SC2016
AOT_USAGE_SCRIPT='
JAVA_TOOL_OPTIONS="-Xlog:disable -Xlog:class+load=info:file=/tmp/cl.log -Dspring.context.exit=onRefresh" \
  java -XX:AOTCache=/app/app.aot -Dspring.aot.enabled=true -jar /app/app.jar >/dev/null 2>&1
total=$(grep -c "source:" /tmp/cl.log 2>/dev/null || true)
cached=$(grep -c "source: shared objects file" /tmp/cl.log 2>/dev/null || true)
echo "${cached:-0} ${total:-0}"'

# image_jvm_flags <image>: the JDK_JAVA_OPTIONS baked into an image (the flags the AOT cache was trained with)
image_jvm_flags() { docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n 's/^JDK_JAVA_OPTIONS=//p'; }

# aot_verdict <cached> <total>: "USED" when most classes came from the cache
aot_verdict() { if (( $2 > 0 && $1 * 2 > $2 )); then echo "USED"; else echo "not used"; fi; }
