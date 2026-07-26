#!/usr/bin/env bash
# End-to-end Casper bench:
#   1. Wipe ./casper/ except the binary itself.
#   2. Start ./casper/casper (HTTP 7222, gRPC 7223 — defaults).
#   3. Create collection, import HDF5 via ./import/import.
#   4. For each quantization { f32, i8 }:
#        - DELETE existing index (if any), POST /index with the quantization,
#          wait until the index is searchable.
#        - For each k in $SEARCH_LIMITS run ./goose/goose-load-test and save
#          its output to results/casper/<quant>/k=<k>.log.
#   5. Stop Casper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

HDF5="${HDF5:-$PERF_DIR/deep-image-96-angular.hdf5}"
RESULTS_DIR="${RESULTS_DIR:-$PERF_DIR/results}"
USERS="${USERS:-32}"
RUN_TIME_SECONDS="${RUN_TIME_SECONDS:-90}"
SEARCH_LIMITS="${SEARCH_LIMITS:-10 100 1000}"
EF_SEARCH="${EF_SEARCH:-10 100 1000}"
# Pause after index build so CPU temperature settles before load test
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-60}"
# NUMA pinning: pin Casper + import to one socket and goose to the other so
# the load generator never steals CPU/cache from the server under test.
# Empty = no pinning (single-socket machines, laptops).
SERVER_NUMA_NODE="${SERVER_NUMA_NODE:-}"
LOAD_NUMA_NODE="${LOAD_NUMA_NODE:-}"

COLLECTION="test_collection"
DIM=96
MAX_SIZE=10000000
BASE_URL="http://localhost:7222"

CASPER_DIR="$PERF_DIR/casper"
CASPER_BIN="$CASPER_DIR/casper"
IMPORT_BIN="$PERF_DIR/import/import"
GOOSE_BIN="$PERF_DIR/goose/goose-load-test"

CASPER_PID=""
LOGS_DIR="$RESULTS_DIR/casper/logs"

cleanup() {
  stop_pid "${CASPER_PID:-}"
}
trap cleanup EXIT INT TERM

# --- preflight --------------------------------------------------------------
[[ -x "$CASPER_BIN" ]] || { echo "ERROR: missing executable $CASPER_BIN" >&2; exit 1; }
[[ -x "$IMPORT_BIN" ]] || { echo "ERROR: missing executable $IMPORT_BIN" >&2; exit 1; }
[[ -x "$GOOSE_BIN"  ]] || { echo "ERROR: missing executable $GOOSE_BIN"  >&2; exit 1; }
[[ -f "$HDF5"       ]] || { echo "ERROR: HDF5 dataset not found at $HDF5" >&2; exit 1; }
: "${API_TOKEN:?ERROR: API_TOKEN env var is required}"

# Resolve NUMA prefixes once. Arrays so the empty case = no prefix.
read -ra NUMA_SERVER < <(numa_prefix "$SERVER_NUMA_NODE")
read -ra NUMA_LOAD   < <(numa_prefix "$LOAD_NUMA_NODE")
[[ ${#NUMA_SERVER[@]} -gt 0 ]] && log "Casper pinned to NUMA node $SERVER_NUMA_NODE"
[[ ${#NUMA_LOAD[@]}   -gt 0 ]] && log "Goose/import pinned to NUMA node $LOAD_NUMA_NODE"

# --- 1. clean ---------------------------------------------------------------
log "Cleaning $CASPER_DIR (keeping only 'casper' binary)"
clean_dir "$CASPER_DIR" "casper"

mkdir -p "$LOGS_DIR"

# --- 2. start Casper --------------------------------------------------------
log "Starting Casper from $CASPER_DIR"
(
  cd "$CASPER_DIR"
  API_TOKEN="$API_TOKEN" RUST_LOG="${RUST_LOG:-info}" \
    "${NUMA_SERVER[@]}" ./casper \
      >"$LOGS_DIR/casper.stdout" 2>"$LOGS_DIR/casper.stderr" &
  echo $! >"$LOGS_DIR/casper.pid"
)
CASPER_PID="$(cat "$LOGS_DIR/casper.pid")"
log "Casper pid=$CASPER_PID"

wait_for_http "$BASE_URL/health" "Casper HTTP" 60

# --- 3. create collection + load data --------------------------------------
log "Creating collection '$COLLECTION' (dim=$DIM, max_size=$MAX_SIZE)"
curl -fsS -X POST -H 'Content-Type: application/json' \
  "$BASE_URL/collection/$COLLECTION?dim=$DIM&max_size=$MAX_SIZE" >/dev/null

log "Importing HDF5 dataset into Casper (this may take a while)"
"${NUMA_LOAD[@]}" "$IMPORT_BIN" "$HDF5" \
  --format hdf5 \
  --dataset train \
  --base-url "$BASE_URL" \
  --collection "$COLLECTION" \
  --quiet \
  | tee "$LOGS_DIR/import.log"

# --- 4. per-quantization runs ----------------------------------------------
create_index() {
  local quant="$1"
  local body
  body=$(cat <<EOF
{
  "hnsw": {
    "metric": "inner-product",
    "quantization": "$quant",
    "m": 16,
    "m0": 32,
    "ef_construction": 200
  },
  "normalization": true
}
EOF
)
  log "Creating $quant index"
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -d "$body" "$BASE_URL/collection/$COLLECTION/index" >/dev/null
  wait_for_casper_index "$BASE_URL" "$COLLECTION"
  log "Cooldown ${COOLDOWN_SECONDS}s — letting CPU settle after index build"
  sleep "$COOLDOWN_SECONDS"
}

delete_index() {
  log "Deleting existing index (if any)"
  curl -fsS -X DELETE "$BASE_URL/collection/$COLLECTION/index" >/dev/null || true
}

run_goose() {
  local quant="$1"
  local out_dir="$RESULTS_DIR/casper/$quant"
  local limits=()
  local ef_values=()
  mkdir -p "$out_dir"
  read -ra limits <<< "$SEARCH_LIMITS"
  read -ra ef_values <<< "$EF_SEARCH"
  if [[ ${#limits[@]} -ne ${#ef_values[@]} ]]; then
    echo "ERROR: SEARCH_LIMITS and EF_SEARCH must have the same number of values" >&2
    echo "  SEARCH_LIMITS='$SEARCH_LIMITS'" >&2
    echo "  EF_SEARCH='$EF_SEARCH'" >&2
    exit 1
  fi
  for i in "${!limits[@]}"; do
    local k="${limits[$i]}"
    local ef="${ef_values[$i]}"
    local out_file="$out_dir/k=${k}.log"
    log "Goose run: quant=$quant k=$k ef_search=$ef users=$USERS run_time=${RUN_TIME_SECONDS}s"
    POOL_SOURCE=hdf5 \
    POOL_PATH="$HDF5" \
    POOL_SIZE=100000 \
    POOL_DATASET=train \
    SEARCH_LIMIT="$k" \
    HNSW_EF="$ef" \
    CASPER_COLLECTION="$COLLECTION" \
    OUTPUT_FORMAT=bin \
    USERS="$USERS" \
    RUN_TIME_SECONDS="$RUN_TIME_SECONDS" \
      "${NUMA_LOAD[@]}" "$GOOSE_BIN" --host "$BASE_URL" --hatch-rate "$USERS" \
      2>&1 | tee "$out_file" || true
  done
}

for quant in f32 i8; do
  delete_index
  create_index "$quant"
  run_goose "$quant"
done

log "Casper bench complete. Results: $RESULTS_DIR/casper/"
