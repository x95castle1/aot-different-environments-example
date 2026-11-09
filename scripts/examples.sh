#!/usr/bin/env bash
# Run an example's demo. Without an argument, pick one (or "all") with fzf; the preview shows its README.
# With an argument, run it directly: 01 | 01-jvm-args | jvm-args | all.
# "all" stops everything first, runs every demo in order, and exits non-zero if any failed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXAMPLES=()
for d in examples/[0-9][0-9]-*/; do EXAMPLES+=("$(basename "$d")"); done

title() { sed -n '1s/^# *[0-9]* · //p' "examples/$1/README.md" 2>/dev/null; }

run_one() {
  printf '\n\033[1m######## %s: %s\033[0m\n' "$1" "$(title "$1")"
  make -C "examples/$1" demo
}

run_all() {
  make -s stop
  local failed=()
  for e in "${EXAMPLES[@]}"; do run_one "$e" || failed+=("$e"); done
  echo
  if (( ${#failed[@]} > 0 )); then printf '\033[31mFailed: %s\033[0m\n' "${failed[*]}"; exit 1; fi
  printf '\033[32mAll %d examples passed.\033[0m\n' "${#EXAMPLES[@]}"
}

choice=${1:-}
if [[ -z "$choice" ]]; then
  command -v fzf >/dev/null || { echo "fzf is required for the picker (brew install fzf), or run: make examples EX=01|...|all"; exit 1; }
  menu=$( { for e in "${EXAMPLES[@]}"; do printf '%s\t%s\n' "$e" "$(title "$e")"; done
            printf 'all\tRun every example in order (stops everything first)\n'; } )
  choice=$(fzf --delimiter='\t' --with-nth=1,2 --prompt='example> ' \
      --header='Select an example to run (Enter = run, Esc = cancel)' \
      --preview='if [ {1} = all ]; then echo "Runs, in order:"; ls -d examples/[0-9][0-9]-* | sed "s#examples/#  #"; else sed -n "1,45p" examples/{1}/README.md; fi' \
      --preview-window='right,60%,wrap' <<<"$menu" | cut -f1) || exit 0
  [[ -n "$choice" ]] || exit 0
fi

if [[ "$choice" == "all" ]]; then run_all; exit; fi

for e in "${EXAMPLES[@]}"; do
  # Accept "01", "01-jvm-args" or "jvm-args"
  if [[ "$e" == "$choice" || "${e%%-*}" == "$choice" || "${e#*-}" == "$choice" ]]; then run_one "$e"; exit; fi
done
echo "Unknown example '$choice'. Choose one of: ${EXAMPLES[*]} all"
exit 2
