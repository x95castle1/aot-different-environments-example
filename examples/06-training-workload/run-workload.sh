#!/usr/bin/env bash
# run-workload.sh <base-url> <requests> [parallel=1] [seed=42]
#
# A fixed, repeatable request mix against workload-app, used both to TRAIN the AOT cache and to MEASURE
# warm-up. Prints one line per request: "<http status> <seconds>". Exits non-zero on 5xx or failed requests.
#
#   first 20 requests  create orders (their ids feed the get/update requests below)
#   then, seeded mix   40% create · 25% list by customer · 10% get by id · 10% stats aggregation
#                      10% status update · 5% invalid create (400)
#
# Requests run through ONE curl process per worker (a generated -K config), so connections are reused
# and curl's own start-up doesn't distort the latencies.
set -euo pipefail
base=${1:?usage: run-workload.sh <base-url> <requests> [parallel] [seed]}
count=${2:?usage: run-workload.sh <base-url> <requests> [parallel] [seed]}
parallel=${3:-1}
seed=${4:-42}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

create_body() { printf '{\\"customer\\":\\"c%02d\\",\\"items\\":[{\\"sku\\":\\"SKU-%d\\",\\"quantity\\":%d},{\\"sku\\":\\"SKU-%d\\",\\"quantity\\":1}],\\"amount\\":%d.%02d}' "$1" "$2" "$3" "$4" "$5" "$6"; }

# 1. Seed orders (sequential, part of the count) and keep their ids
seed_n=$(( count < 20 ? count : 20 ))
: > "$work/seed.cfg"
for i in $(seq 1 "$seed_n"); do
  cat >> "$work/seed.cfg" <<EOF
url = "${base}/orders"
request = "POST"
header = "Content-Type: application/json"
data = "$(create_body $((i % 20)) $((i * 7 % 50)) $((i % 5 + 1)) $((i * 3 % 50)) $((10 + i)) $((i % 100)))"
write-out = "\n@@ %{http_code} %{time_total}\n"
next
EOF
done
curl -s -K "$work/seed.cfg" > "$work/seed.out" 2>/dev/null || true
grep '^@@ ' "$work/seed.out" | sed 's/^@@ //'
ids=$(grep -o '"id":"[^"]*"' "$work/seed.out" | cut -d'"' -f4 | tr '\n' ' ')
[[ -n "$ids" ]] || { echo "no orders created: is the app up and connected to Mongo?" >&2; exit 1; }

# 2. The seeded mix, split across workers
remaining=$(( count - seed_n ))
if (( remaining > 0 )); then
  awk -v n="$remaining" -v seed="$seed" -v base="$base" -v ids="$ids" -v workers="$parallel" -v dir="$work" '
    BEGIN {
      srand(seed); split(ids, id, " "); nid = length(id)
      for (i = 0; i < n; i++) {
        f = sprintf("%s/mix-%d.cfg", dir, i % workers)
        r = rand(); c = int(rand() * 20); o = id[int(rand() * nid) + 1]
        if (r < 0.40) {
          printf "url = \"%s/orders\"\nrequest = \"POST\"\nheader = \"Content-Type: application/json\"\n", base > f
          printf "data = \"{\\\"customer\\\":\\\"c%02d\\\",\\\"items\\\":[{\\\"sku\\\":\\\"SKU-%d\\\",\\\"quantity\\\":%d}],\\\"amount\\\":%d.%02d}\"\n", c, int(rand()*50), int(rand()*5)+1, int(rand()*500)+1, int(rand()*100) > f
        } else if (r < 0.65) {
          printf "url = \"%s/orders?customer=c%02d&limit=20\"\n", base, c > f
        } else if (r < 0.75) {
          printf "url = \"%s/orders/%s\"\n", base, o > f
        } else if (r < 0.85) {
          printf "url = \"%s/orders/stats\"\n", base > f
        } else if (r < 0.95) {
          s = (rand() < 0.5) ? "PAID" : "SHIPPED"
          printf "url = \"%s/orders/%s/status\"\nrequest = \"PUT\"\nheader = \"Content-Type: application/json\"\ndata = \"{\\\"status\\\":\\\"%s\\\"}\"\n", base, o, s > f
        } else {
          printf "url = \"%s/orders\"\nrequest = \"POST\"\nheader = \"Content-Type: application/json\"\ndata = \"{\\\"customer\\\":\\\"\\\",\\\"items\\\":[],\\\"amount\\\":-1}\"\n", base > f
        }
        printf "output = \"/dev/null\"\nwrite-out = \"%%{http_code} %%{time_total}\\n\"\nnext\n" > f
      }
    }'
  ls "$work"/mix-*.cfg | xargs -P "$parallel" -I{} sh -c 'curl -s -K "$1" 2>/dev/null || true' _ {}
fi | tee "$work/mix.out"

if grep -qE '^(5[0-9][0-9]|000) ' "$work/mix.out" || grep '^@@ ' "$work/seed.out" | grep -qE '^@@ (5[0-9][0-9]|000) '; then
  echo "server errors or failed requests in the workload" >&2
  exit 1
fi
