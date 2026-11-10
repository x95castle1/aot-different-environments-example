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
# and curl's own start-up doesn't distort the latencies. In a config, a request body is data = "...", with its
# quotes escaped as \".
set -euo pipefail
usage="usage: run-workload.sh <base-url> <requests> [parallel] [seed]"
base=${1:?$usage}
count=${2:?$usage}
parallel=${3:-1}
seed=${4:-42}
SEED_ORDERS=20
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# seed_order <i>: the i-th seed order's body, quotes escaped for data = "..."
seed_order() {
  local i=$1 json
  json=$(printf '{"customer":"c%02d","items":[{"sku":"SKU-%d","quantity":%d},{"sku":"SKU-%d","quantity":1}],"amount":%d.%02d}' \
    $((i % 20)) $((i * 7 % 50)) $((i % 5 + 1)) $((i * 3 % 50)) $((10 + i)) $((i % 100)))
  echo "${json//\"/\\\"}"
}

# seed_config <n>: curl config creating <n> orders. Keeps the response bodies (they hold the new ids) and marks
# each request's status line with "@@ ".
seed_config() {
  local i
  for i in $(seq 1 "$1"); do
    cat <<EOF
url = "${base}/orders"
request = "POST"
header = "Content-Type: application/json"
data = "$(seed_order "$i")"
write-out = "\n@@ %{http_code} %{time_total}\n"
next
EOF
  done
}

# mix_configs <n> <ids>: the seeded mix of <n> requests, dealt round-robin into one curl config per worker
# ($work/mix-<worker>.cfg). <ids> are the seed orders' ids, for the get-by-id and status-update requests.
mix_configs() {
  awk -v n="$1" -v ids="$2" -v seed="$seed" -v base="$base" -v workers="$parallel" -v dir="$work" '
    # send(method, path[, body]): one request, appended to the current worker config f
    function send(method, path, body) {
      printf "url = \"%s%s\"\n", base, path > f
      if (method != "GET") {
        gsub(/"/, "\\\"", body)
        printf "request = \"%s\"\nheader = \"Content-Type: application/json\"\ndata = \"%s\"\n", method, body > f
      }
      printf "output = \"/dev/null\"\nwrite-out = \"%%{http_code} %%{time_total}\\n\"\nnext\n" > f
    }
    function new_order(customer) {
      return sprintf("{\"customer\":\"%s\",\"items\":[{\"sku\":\"SKU-%d\",\"quantity\":%d}],\"amount\":%d.%02d}",
                     customer, int(rand() * 50), int(rand() * 5) + 1, int(rand() * 500) + 1, int(rand() * 100))
    }
    BEGIN {
      srand(seed); split(ids, id, " "); nid = length(id)
      for (i = 0; i < n; i++) {
        f = sprintf("%s/mix-%d.cfg", dir, i % workers)
        roll = rand(); customer = sprintf("c%02d", int(rand() * 20)); order = id[int(rand() * nid) + 1]
        if      (roll < 0.40) send("POST", "/orders", new_order(customer))
        else if (roll < 0.65) send("GET",  "/orders?customer=" customer "&limit=20")
        else if (roll < 0.75) send("GET",  "/orders/" order)
        else if (roll < 0.85) send("GET",  "/orders/stats")
        else if (roll < 0.95) send("PUT",  "/orders/" order "/status", "{\"status\":\"" (rand() < 0.5 ? "PAID" : "SHIPPED") "\"}")
        else                  send("POST", "/orders", "{\"customer\":\"\",\"items\":[],\"amount\":-1}")
      }
    }'
}

# send_mix: each worker config through its own curl process, <parallel> at a time
send_mix() {
  printf '%s\n' "$work"/mix-*.cfg | xargs -P "$parallel" -I{} sh -c 'curl -s -K "$1" 2>/dev/null || true' _ {}
}

# 1. Seed orders (sequential, part of the count) and keep their ids
seed_n=$(( count < SEED_ORDERS ? count : SEED_ORDERS ))
seed_config "$seed_n" > "$work/seed.cfg"
curl -s -K "$work/seed.cfg" > "$work/seed.out" 2>/dev/null || true
sed -n 's/^@@ //p' "$work/seed.out" | tee "$work/status.out"
ids=$(grep -o '"id":"[^"]*"' "$work/seed.out" | cut -d'"' -f4 | tr '\n' ' ' || true)
[[ -n "$ids" ]] || { echo "no orders created: is the app up and connected to Mongo?" >&2; exit 1; }

# 2. The seeded mix, split across workers
if (( count > seed_n )); then
  mix_configs $((count - seed_n)) "$ids"
  send_mix | tee -a "$work/status.out"
fi

# 3. Any 5xx, or a request that got no response at all (000), fails the run
if grep -qE '^(5[0-9][0-9]|000) ' "$work/status.out"; then
  echo "server errors or failed requests in the workload" >&2
  exit 1
fi
