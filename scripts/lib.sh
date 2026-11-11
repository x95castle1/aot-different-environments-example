#!/usr/bin/env bash
# Shared helpers for the example demo scripts. Source it:  . "$ROOT/scripts/lib.sh"  (ROOT = repo root)
#
# Reporting (see docs/reading-reports.md):
#   report_init <example>        start a run report in reports/<example>/<run id>/
#   report_image <image>         record an image the run used (digest, JDK, training flags)
#   expect <id> <subject> <measured> [expected] [evidence]
#                                a check; label/expected/why/hints come from examples/<example>/expectations.json
#   record_timing <id> <secs...> startup times for a scenario; judged at render time against its baseline
#   save_evidence <name>         stdin -> raw/<name> in the report
#   aot_usage <name> <cmd...>    run AOT_USAGE_SCRIPT via <cmd...>; sets CACHED, TOTAL, AOT_VERDICT; saves evidence
#   finish                       in the process that called report_init: render report.md/results.json, print summary
#
# A library: sourcing it only defines functions and settings, nothing runs. Sections: output, one demo at a time,
# reporting, timing and the AOT cache.

# ---------------------------------------------------------------------------------------------------- output

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

FAILURES=0

# step / note / pass / fail <text>: a heading, a dim note, a passed check, a failed check (counted in FAILURES)
step()  { printf '\n%s== %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
note()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
pass()  { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
fail()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$1"; FAILURES=$((FAILURES + 1)); }

# require <command...>: stop unless every command is installed
require() { for c in "$@"; do command -v "$c" >/dev/null || { echo "$c is required"; exit 1; }; done; }

# ---------------------------------------------------------------------------------------------------- one demo at a time

# acquire_demo_lock <what>: demos share host ports and the machine's CPU, and parallel runs skew
# each other's startup timings, so only one runs at a time. A lock whose process has gone is taken over.
# `make examples EX=all` holds it for the whole sequence; the demos it runs inherit it (DEMO_LOCK_PID).
DEMO_LOCK_FILE="${ROOT:-.}/reports/.demo.lock"
acquire_demo_lock() {
  if [[ -n "${DEMO_LOCK_PID:-}" && "$DEMO_LOCK_PID" != "$$" ]] && kill -0 "$DEMO_LOCK_PID" 2>/dev/null; then return 0; fi
  mkdir -p "$(dirname "$DEMO_LOCK_FILE")"
  if [[ -f "$DEMO_LOCK_FILE" ]]; then
    local pid what
    read -r pid what < "$DEMO_LOCK_FILE" || true
    if [[ -n "${pid:-}" && "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null; then
      printf '%sAnother demo is already running: %s (pid %s).%s\n' "$C_RED" "${what:-?}" "$pid" "$C_RESET" >&2
      echo "Demos share containers, ports and infrastructure, and two at once would skew the startup timings." >&2
      echo "Wait for it to finish, or stop it with: kill ${pid}" >&2
      exit 4
    fi
  fi
  echo "$$ $1" > "$DEMO_LOCK_FILE"
  export DEMO_LOCK_PID=$$
}

# release_demo_lock: only removes the lock if this process holds it
release_demo_lock() {
  local pid
  [[ -f "$DEMO_LOCK_FILE" ]] && read -r pid _ < "$DEMO_LOCK_FILE" && [[ "$pid" == "$$" ]] && rm -f "$DEMO_LOCK_FILE"
  return 0
}

# ---------------------------------------------------------------------------------------------------- reporting

# expect_init <example>: where check definitions come from (also done by report_init)
expect_init() { EXAMPLE=$1; EXPECT_FILE="$ROOT/examples/$1/expectations.json"; export EXAMPLE EXPECT_FILE; }

# report_init <example>: take the demo lock and start a run report in reports/<example>/<run id>/ (run.json)
report_init() {
  require jq
  acquire_demo_lock "$1"
  expect_init "$1"
  local id=${REPORT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
  REPORT_DIR="$ROOT/reports/$1/$id"
  RAW="$REPORT_DIR/raw"
  REPORT_OWNER=$$
  export REPORT_DIR RAW REPORT_OWNER
  mkdir -p "$RAW"
  : > "$REPORT_DIR/results.jsonl"
  : > "$REPORT_DIR/timings.jsonl"
  local docker_json
  docker_json=$(docker info --format '{{json .}}' 2>/dev/null \
    | jq -c '{version: .ServerVersion, os: .OperatingSystem, arch: .Architecture, cpus: .NCPU, memGb: ((.MemTotal / 1073741824 * 10 | round) / 10)}' 2>/dev/null)
  jq -n --arg started "$(date -u +%FT%TZ)" \
        --arg revision "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
        --arg dirty "$(git -C "$ROOT" status --porcelain 2>/dev/null | head -1)" \
        --arg host "$(uname -s) $(uname -m)" \
        --arg runs "${RUNS:-}" \
        --argjson docker "${docker_json:-null}" \
        '{started: $started, revision: $revision, uncommittedChanges: ($dirty != ""), host: $host,
          docker: $docker, timedRunsPerScenario: (if $runs == "" then null else ($runs | tonumber) end), images: []}' \
    > "$REPORT_DIR/run.json"
}

# _report_update_run <jq args...>: rewrite run.json through jq
_report_update_run() { local tmp; tmp=$(mktemp); jq "$@" "$REPORT_DIR/run.json" > "$tmp" && mv "$tmp" "$REPORT_DIR/run.json"; }

# report_image <image ref>: records what the run used (id, digest, JDK, flags the AOT cache was trained with)
report_image() {
  [[ -n "${REPORT_DIR:-}" ]] || return 0
  local info
  info=$(docker image inspect "$1" 2>/dev/null | jq -c --arg ref "$1" '.[0] | {
      ref: $ref, id: .Id, digest: (.RepoDigests[0] // null),
      created: (.Config.Labels["org.opencontainers.image.created"] // .Created),
      revision: (.Config.Labels["org.opencontainers.image.revision"] // null),
      jdk: ([.Config.Env[] | select(startswith("JAVA_VERSION=")) | sub("JAVA_VERSION="; "")][0] // null),
      trainingFlags: ([.Config.Env[] | select(startswith("JDK_JAVA_OPTIONS=")) | sub("JDK_JAVA_OPTIONS="; "")][0] // null)}')
  [[ -n "$info" ]] || return 0
  _report_update_run --argjson i "$info" '.images = ([.images[] | select(.ref != $i.ref)] + [$i])'
}

# expect <id> <subject> <measured> [expected] [evidence]
#   <id> must exist in expectations.json .checks. <subject> (may be "") prefixes the label, e.g. an environment.
#   [expected] overrides the check's expected value. Checks without "expected" are information only.
expect() {
  local id=$1 subject=$2 measured=$3 expected_override=${4:-} evidence=${5:-}
  local def
  def=$(jq -c --arg id "$id" '.checks[$id] // empty' "$EXPECT_FILE")
  [[ -n "$def" ]] || { echo "BUG: no check '$id' in $EXPECT_FILE" >&2; exit 3; }
  local label expected outcome has_expected
  label=$(jq -r '.label' <<<"$def"); [[ -n "$subject" ]] && label="$subject: $label"
  has_expected=$(jq -r 'has("expected")' <<<"$def")
  expected=${expected_override:-$(jq -r '.expected // ""' <<<"$def")}
  if [[ "$has_expected" == "false" && -z "$expected_override" ]]; then
    outcome=info; note "  · ${label}: ${measured}"
  elif [[ "$measured" == "$expected" ]]; then
    outcome=$(jq -r '.outcome // "works"' <<<"$def"); pass "${label}: ${measured}"
  else
    outcome=unexpected; fail "${label}: got '${measured}', expected '${expected}'"
  fi
  [[ -n "${REPORT_DIR:-}" ]] || return 0
  local excerpt=""
  if [[ -n "$evidence" && -f "$RAW/$evidence" ]]; then
    # Logs: the end is where errors are. Other evidence: the start is the summary.
    if [[ "$evidence" == *.log ]]; then excerpt=$(grep -v '^\s*$' "$RAW/$evidence" | tail -6 | cut -c1-220)
    else excerpt=$(head -6 "$RAW/$evidence" | cut -c1-220); fi
  fi
  jq -c -n --arg id "$id" --arg subject "$subject" --arg label "$label" --arg expected "$expected" \
        --arg measured "$measured" --arg outcome "$outcome" --arg evidence "$evidence" --arg excerpt "$excerpt" \
        --argjson d "$def" \
    '{kind: "check", id: $id, subject: (if $subject == "" then null else $subject end), group: ($d.group // "Checks"),
      check: $d.label, label: $label,
      short: (if $subject == "" then ($d.short // $d.label) else "\($subject): \($d.short // $d.label)" end),
      expected: (if $expected == "" then null else $expected end), measured: $measured, outcome: $outcome,
      why: ($d.why // ""), ifUnexpected: ($d.ifUnexpected // []),
      evidence: (if $evidence == "" then null else "raw/\($evidence)" end),
      evidenceExcerpt: (if $excerpt == "" then null else $excerpt end)}' >> "$REPORT_DIR/results.jsonl"
}

# record_timing <id> <secs...>  ("FAIL" or anything non-numeric counts as a failed start)
record_timing() {
  local id=$1; shift
  [[ -n "${REPORT_DIR:-}" ]] || return 0
  printf '%s\n' "$@" | jq -R . | jq -s -c --arg id "$id" '{id: $id, runs: map(tonumber? // null)}' >> "$REPORT_DIR/timings.jsonl"
}

# save_evidence <name>: stdin -> raw/<name> (discarded when not reporting)
save_evidence() { if [[ -n "${REPORT_DIR:-}" ]]; then cat > "$RAW/$1"; else cat > /dev/null; fi; }

# finish: print the result and exit non-zero if any check failed. The process that called report_init
# also renders the report and prints the summary.
finish() {
  if [[ -n "${REPORT_DIR:-}" && "${REPORT_OWNER:-}" == "$$" ]]; then report_finish; fi
  echo
  if (( FAILURES > 0 )); then printf '%s%d check(s) failed%s\n' "$C_RED" "$FAILURES" "$C_RESET"; exit 1; fi
  printf '%sAll checks passed.%s\n' "$C_GREEN" "$C_RESET"
}

# report_finish: render results.json + report.md, point latest at this run, print the timings and the verdict
report_finish() {
  _report_update_run --arg t "$(date -u +%FT%TZ)" '.finished = $t'
  "$ROOT/scripts/render-report.sh" "$REPORT_DIR" "$EXPECT_FILE"
  ln -sfn "$(basename "$REPORT_DIR")" "$(dirname "$REPORT_DIR")/latest"
  local results="$REPORT_DIR/results.json" verdict color
  print_timing_table "$results"
  verdict=$(jq -r '.verdict' "$results")
  case $verdict in PASS) color=$C_GREEN ;; FAIL) color=$C_RED ;; *) color=$C_YELLOW ;; esac
  printf '\n%s== VERDICT: %s%s%s\n' "$C_BOLD" "$color" "$verdict" "$C_RESET"
  jq -r '
    def names(o): reduce (.results[] | select(.outcome == o) | .short) as $n ([]; if index([$n]) then . else . + [$n] end)
                  | if length == 0 then "none" else join("; ") end;
    "  Answer:          \(.answer)",
    (if .kind != "functional" then
       "  Improved:        \(names("improved"))",
       "  Unchanged:       \(names("unchanged"))",
       "  Didn'"'"'t improve:  \(names("no-benefit-expected"))"
     else empty end),
    (if .kind != "performance" then
       "  Works:           \([.results[] | select(.outcome == "works")] | length) checks"
     else empty end),
    "  Limitations:     \(names("limitation-shown"))",
    "  Unexpected:      \(names("unexpected"))",
    (if (.counts.inconclusive // 0) > 0 then "  Inconclusive:    \(names("inconclusive")) (rerun with more RUNS)" else empty end)
  ' "$results" | wrap_labeled
  printf '  Report:          %s\n' "${REPORT_DIR#"$ROOT/"}/report.md"
  release_demo_lock
  [[ "$verdict" != "FAIL" ]] || FAILURES=$((FAILURES > 0 ? FAILURES : 1))
}

# wrap_labeled: stdin = "  Label:   text" lines; wraps each line to the terminal width (at most 120 columns), with the
# continuation lines indented to where the text starts, so they line up under it. A value may span several lines (e.g.
# an answer with "- " items): those lines get the same indent, items a hanging indent, and blank lines are dropped.
wrap_labeled() {
  local width=120
  if [[ -t 1 ]]; then width=$(tput cols 2>/dev/null || echo 120); (( width > 120 )) && width=120; fi
  awk -v width="$width" '
    # emit(prefix, text, pad): prefix + text wrapped at width, every following line starting with pad
    function emit(prefix, text, pad,    n, w, i, line, len, first) {
      line = prefix; len = length(prefix); first = 1
      n = split(text, w, " ")
      for (i = 1; i <= n; i++) {
        if (!first && len + 1 + length(w[i]) > width) { print line; line = pad w[i]; len = length(pad) + length(w[i]); continue }
        line = line (first ? "" : " ") w[i]; len += (first ? 0 : 1) + length(w[i]); first = 0
      }
      print line
    }
    match($0, /^  [^:]+: +/) { indent = sprintf("%" RLENGTH "s", ""); emit(substr($0, 1, RLENGTH), substr($0, RLENGTH + 1), indent); next }
    indent == "" { print; next }                       # not part of a labeled value
    /^[ \t]*$/ { next }                                 # blank line inside a value
    /^- / { emit(indent "- ", substr($0, 3), indent "  "); next }
    { emit(indent, $0, indent) }'
}

# print_timing_table <results.json>: the report's "Startup times" table, for the terminal
print_timing_table() {
  jq -e 'any(.results[]; .kind == "timing")' "$1" >/dev/null || return 0
  local heading="Startup times"
  jq -e 'any(.results[]; .kind == "timing" and .metric != null)' "$1" >/dev/null && heading="Timings"
  local explain='each row is compared with the scenario named under "compared with"'
  # With fixed comparison columns (timings.columns in expectations.json) every row has the same baselines
  jq -e 'any(.results[]; .comparisons != null)' "$1" >/dev/null && explain='every row vs the same baselines; * = the comparison its outcome is judged on'
  printf '\n%s== %s%s %s(median of each scenario'"'"'s runs; %s)%s\n' "$C_BOLD" "$heading" "$C_RESET" "$C_DIM" "$explain" "$C_RESET"
  jq -r '
    def secs: if . == null then "-" else "\(.)s" end;
    [.results[] | select(.kind == "timing")] as $t
    | ($t | any(.aotCache != null)) as $cache
    | ($t | any(.unit == "ms")) as $mixed
    | ($t | map(.comparisons // []) | max_by(length) | map(.label)) as $cols
    | (["scenario"] + (if $cache then ["JDK AOT cache"] else [] end) + [if $mixed then "runs" else "runs (s)" end, "median"]
        + (if ($cols | length) > 0 then $cols else ["compared with", "change"] end) + ["outcome"] | join("\t")),
      ($t[] | [.short]
        + (if $cache then [if .aotCache then "\(.aotCache.verdict) \(.aotCache.classes // "")" else "-" end] else [] end)
        # .shown is missing in results.json files rendered before it existed
        + [((.shown.runs // (.runs | map(if . == null then "fail" else tostring end))) | join(" ")) + (if $mixed then " \(.unit)" else "" end),
           (.shown.median // (.median | secs))]
        + (if ($cols | length) > 0 then
             [.comparisons // [] | .[] | if .ref == null then "-" else
                "\(.change)\(if .otherRef then " (vs \(.refLabel))" else "" end)\(if .judged then " *" else "" end)" end]
           else
             [(.compareToLabel // "-"), (if .referenceMedian then "\(.change) vs \(.referenceMedian)s" else "-" end)]
           end)
        + [(if .baseline or (.outcome == "info" and .compareTo == null) then "baseline" else .outcome end)]
        | join("\t"))' "$1" \
  | column -t -s $'\t' \
  | sed -e "1s/.*/${C_BOLD}&${C_RESET}/" \
        -e "s/ improved\$/ ${C_GREEN}improved${C_RESET}/" -e "s/ unchanged\$/ ${C_GREEN}unchanged${C_RESET}/" \
        -e "s/ no-benefit-expected\$/ ${C_YELLOW}no-benefit-expected${C_RESET}/" -e "s/ inconclusive\$/ ${C_YELLOW}inconclusive${C_RESET}/" \
        -e "s/ unexpected\$/ ${C_RED}unexpected${C_RESET}/" -e "s/ info\$/ ${C_DIM}info${C_RESET}/" \
        -e "s/ baseline\$/ ${C_DIM}baseline${C_RESET}/" \
        -e 's/^/  /'
  local attribution
  attribution=$(jq -r '.attribution.summary // empty' "$1")
  if [[ -n "$attribution" ]]; then echo; fold -s -w 116 <<<"$attribution" | sed -e 's/ *$//' -e 's/^/  /'; fi
}

# ---------------------------------------------------------------------------------------------------- timing and the AOT cache

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
# JDK_JAVA_OPTIONS apply), stops after the context is ready. Prints "<cached> <total>" on the first
# line, then the JVM's own AOT warnings (why a cache was rejected).
# shellcheck disable=SC2016
AOT_USAGE_SCRIPT='
JAVA_TOOL_OPTIONS="-Xlog:disable -Xlog:class+load=info:file=/tmp/cl.log -Xlog:aot=warning:file=/tmp/aot.log -Dspring.context.exit=onRefresh" \
  java -XX:AOTCache=/app/app.aot -Dspring.aot.enabled=true -jar /app/app.jar >/dev/null 2>&1
total=$(grep -c "source:" /tmp/cl.log 2>/dev/null || true)
cached=$(grep -c "source: shared objects file" /tmp/cl.log 2>/dev/null || true)
echo "${cached:-0} ${total:-0}"
cat /tmp/aot.log 2>/dev/null || true'

# aot_usage <evidence name> <command...>: runs <command...> "$AOT_USAGE_SCRIPT" (e.g. docker run ... --entrypoint sh IMAGE -c)
# Sets CACHED, TOTAL and AOT_VERDICT; saves the counts and the JVM's AOT messages as evidence.
aot_usage() {
  local name=$1; shift
  local out
  out=$("$@" "$AOT_USAGE_SCRIPT")
  read -r CACHED TOTAL <<<"$(head -1 <<<"$out")"
  AOT_VERDICT=$(aot_verdict "${CACHED:-0}" "${TOTAL:-0}")
  { echo "classes loaded from the JDK AOT cache: ${CACHED} / ${TOTAL}"
    tail -n +2 <<<"$out" | sed -E 's/^\[[0-9.]+s\]//'; } | save_evidence "$name"
}

# image_jvm_flags <image>: the JDK_JAVA_OPTIONS baked into an image (the flags the AOT cache was trained with)
image_jvm_flags() { docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | sed -n 's/^JDK_JAVA_OPTIONS=//p'; }

# aot_verdict <cached> <total>: "USED" when most classes came from the cache
aot_verdict() { if (( $2 > 0 && $1 * 2 > $2 )); then echo "USED"; else echo "not used"; fi; }
