#!/usr/bin/env bash
# End-to-end Qdrant bench:
#   1. Wipe ./qdrant/ except the binary itself.
#   2. Start ./qdrant/qdrant (HTTP 6333, gRPC 6334 — defaults).
#   3. For each variant { no-quant, i8 }:
#        - PUT /collections/<name> with the right config, load HDF5 via
#          ./import/import (HTTP backend), wait until status=green.
#        - For each k in $SEARCH_LIMITS run ./goose/goose-load-test (Qdrant
#          backend, gRPC) and save its output to
#          results/qdrant/<variant>/k=<k>.log.
#        - DELETE the collection between variants so the next round starts
#          clean (otherwise we'd be re-indexing on top of leftover data).
#   4. Stop Qdrant.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERF_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/common.sh"

HDF5="${HDF5:-$PERF_DIR/deep-image-96-angular.hdf5}"
RESULTS_DIR="${RESULTS_DIR:-$PERF_DIR/results}"
USERS="${USERS:-32}"
RUN_TIME_SECONDS="${RUN_TIME_SECONDS:-90}"
SEARCH_LIMITS="${SEARCH_LIMITS:-10 100 1000}"
# Pause after index build so CPU temperature settles before load test
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-60}"
# NUMA pinning: pin Qdrant + import to one socket and goose to the other so
# the load generator never steals CPU/cache from the server under test.
# Empty = no pinning (single-socket machines, laptops).
SERVER_NUMA_NODE="${SERVER_NUMA_NODE:-}"
LOAD_NUMA_NODE="${LOAD_NUMA_NODE:-}"

COLLECTION="deep-image-96-noindex"
BASE_URL="http://localhost:6333"
GRPC_URL="http://localhost:6334"
IMPORT_BATCH_SIZE="${IMPORT_BATCH_SIZE:-512}"

QDRANT_DIR="$PERF_DIR/qdrant"
QDRANT_BIN="$QDRANT_DIR/qdrant"
IMPORT_BIN="$PERF_DIR/import/import"
GOOSE_BIN="$PERF_DIR/goose/goose-load-test"

QDRANT_PID=""
LOGS_DIR="$RESULTS_DIR/qdrant/logs"

cleanup() {
  stop_pid "${QDRANT_PID:-}"
}
trap cleanup EXIT INT TERM

# --- preflight --------------------------------------------------------------
[[ -x "$QDRANT_BIN" ]] || { echo "ERROR: missing executable $QDRANT_BIN" >&2; exit 1; }
[[ -x "$IMPORT_BIN" ]] || { echo "ERROR: missing executable $IMPORT_BIN" >&2; exit 1; }
[[ -x "$GOOSE_BIN"  ]] || { echo "ERROR: missing executable $GOOSE_BIN"  >&2; exit 1; }
[[ -f "$HDF5"       ]] || { echo "ERROR: HDF5 dataset not found at $HDF5" >&2; exit 1; }

# Resolve NUMA prefixes once. Arrays so the empty case = no prefix.
read -ra NUMA_SERVER < <(numa_prefix "$SERVER_NUMA_NODE")
read -ra NUMA_LOAD   < <(numa_prefix "$LOAD_NUMA_NODE")
[[ ${#NUMA_SERVER[@]} -gt 0 ]] && log "Qdrant pinned to NUMA node $SERVER_NUMA_NODE"
[[ ${#NUMA_LOAD[@]}   -gt 0 ]] && log "Goose/import pinned to NUMA node $LOAD_NUMA_NODE"

# --- 1. clean ---------------------------------------------------------------
log "Cleaning $QDRANT_DIR (keeping only 'qdrant' binary)"
clean_dir "$QDRANT_DIR" "qdrant"

mkdir -p "$LOGS_DIR"

# --- 2. start Qdrant --------------------------------------------------------
log "Starting Qdrant from $QDRANT_DIR"
(
  cd "$QDRANT_DIR"
  "${NUMA_SERVER[@]}" ./qdrant \
    >"$LOGS_DIR/qdrant.stdout" 2>"$LOGS_DIR/qdrant.stderr" &
  echo $! >"$LOGS_DIR/qdrant.pid"
)
QDRANT_PID="$(cat "$LOGS_DIR/qdrant.pid")"
log "Qdrant pid=$QDRANT_PID"

# Qdrant's root returns version info on HTTP 200 once it's accepting connections.
wait_for_http "$BASE_URL/readyz" "Qdrant HTTP" 60 || \
  wait_for_http "$BASE_URL/"      "Qdrant HTTP" 60

# --- 3. per-variant runs ----------------------------------------------------
create_collection_no_quant() {
  log "Creating Qdrant collection '$COLLECTION' (no quantization)"
  local body
  body=$(cat <<'EOF'
{
  "vectors": { "size": 96, "distance": "Dot" },
  "hnsw_config": {
    "m": 16,
    "ef_construct": 200,
    "full_scan_threshold": 10000,
    "max_indexing_threads": 0,
    "on_disk": false
  }
}
EOF
)
  curl -fsS -X PUT -H 'Content-Type: application/json' \
    -d "$body" "$BASE_URL/collections/$COLLECTION" >/dev/null
}

create_collection_i8() {
  log "Creating Qdrant collection '$COLLECTION' (int8 scalar quantization)"
  local body
  body=$(cat <<'EOF'
{
  "vectors": { "size": 96, "distance": "Dot" },
  "hnsw_config": {
    "m": 16,
    "ef_construct": 200,
    "full_scan_threshold": 10000,
    "max_indexing_threads": 0,
    "on_disk": false
  },
  "quantization_config": {
    "scalar": {
      "type": "int8",
      "quantile": 0.99,
      "always_ram": true
    }
  }
}
EOF
)
  curl -fsS -X PUT -H 'Content-Type: application/json' \
    -d "$body" "$BASE_URL/collections/$COLLECTION" >/dev/null
}

delete_collection() {
  log "Deleting Qdrant collection '$COLLECTION'"
  curl -fsS -X DELETE -H 'Content-Type: application/json' \
    "$BASE_URL/collections/$COLLECTION" >/dev/null || true
}

import_data() {
  log "Importing HDF5 dataset into Qdrant (batch=$IMPORT_BATCH_SIZE)"
  "${NUMA_LOAD[@]}" "$IMPORT_BIN" "$HDF5" \
    --format hdf5 \
    --dataset train \
    --backend qdrant \
    --base-url "$BASE_URL" \
    --collection "$COLLECTION" \
    --batch-size "$IMPORT_BATCH_SIZE" \
    --quiet \
    | tee "$LOGS_DIR/import.log"
}

run_goose() {
  local variant="$1"
  local out_dir="$RESULTS_DIR/qdrant/$variant"
  mkdir -p "$out_dir"
  for k in $SEARCH_LIMITS; do
    local out_file="$out_dir/k=${k}.log"
    log "Goose run: variant=$variant k=$k users=$USERS run_time=${RUN_TIME_SECONDS}s"
    BACKEND=qdrant \
    POOL_SOURCE=hdf5 \
    POOL_PATH="$HDF5" \
    POOL_SIZE=100000 \
    POOL_DATASET=train \
    SEARCH_LIMIT="$k" \
    OUTPUT_FORMAT=bin \
    HNSW_EF="$k" \
    QDRANT_URL="$GRPC_URL" \
    QDRANT_COLLECTION="$COLLECTION" \
    USERS="$USERS" \
    RUN_TIME_SECONDS="$RUN_TIME_SECONDS" \
      "${NUMA_LOAD[@]}" "$GOOSE_BIN" --host "$GRPC_URL" --hatch-rate "$USERS" \
      2>&1 | tee "$out_file" || true
  done
}

# Variant 1: no quantization
create_collection_no_quant
import_data
wait_for_qdrant_green "$BASE_URL" "$COLLECTION"
log "Cooldown ${COOLDOWN_SECONDS}s — letting CPU settle after index build"
sleep "$COOLDOWN_SECONDS"
run_goose "no-quant"

# Variant 2: int8 scalar quantization — start from a clean collection.
delete_collection
create_collection_i8
import_data
wait_for_qdrant_green "$BASE_URL" "$COLLECTION"
log "Cooldown ${COOLDOWN_SECONDS}s — letting CPU settle after index build"
sleep "$COOLDOWN_SECONDS"
run_goose "i8"

log "Qdrant bench complete. Results: $RESULTS_DIR/qdrant/"
