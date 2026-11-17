#!/usr/bin/env bash
# Helpers shared by bench_casper.sh and bench_qdrant.sh.
# Source this file, do not execute it directly.

set -euo pipefail

# --- logging ----------------------------------------------------------------
log() { printf '\n>>> %s\n' "$*"; }

# --- directory hygiene ------------------------------------------------------
# Remove everything inside $dir except the file named $keep. Used to wipe
# server storage/logs from previous runs while preserving the executable.
clean_dir() {
  local dir="$1"
  local keep="$2"
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  find "$dir" -mindepth 1 -maxdepth 1 ! -name "$keep" -exec rm -rf {} +
}

# --- HTTP readiness ---------------------------------------------------------
# Poll $url until curl gets a successful response or $timeout seconds elapse.
wait_for_http() {
  local url="$1"
  local label="$2"
  local timeout="${3:-60}"
  local i
  for ((i = 0; i < timeout; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      log "$label is up"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: $label did not become reachable at $url within ${timeout}s" >&2
  return 1
}

# --- Casper index readiness -------------------------------------------------
# Poll GET /collections/{name} until index.state is "ready". Index build is
# async (202 Accepted from POST /index/start); "not_started" after a start
# means the build failed.
wait_for_casper_index() {
  local base_url="$1"
  local collection="$2"
  local timeout="${3:-1800}"  # up to 30 min for 9.9M points

  local url="${base_url}/collections/${collection}"
  local ready_re='"state"[[:space:]]*:[[:space:]]*"ready"'
  local failed_re='"state"[[:space:]]*:[[:space:]]*"not_started"'
  local i
  log "Waiting for Casper index to be ready (timeout ${timeout}s)…"
  for ((i = 0; i < timeout; i += 2)); do
    local body
    body="$(curl -fsS "$url" 2>/dev/null || true)"
    if [[ "$body" =~ $ready_re ]]; then
      log "Casper index ready after ~${i}s"
      return 0
    fi
    if [[ "$body" =~ $failed_re ]]; then
      echo "ERROR: Casper index build failed (index.state=not_started)" >&2
      return 1
    fi
    sleep 2
  done
  echo "ERROR: Casper index did not become ready within ${timeout}s" >&2
  return 1
}

# --- Qdrant collection readiness --------------------------------------------
# Poll Qdrant collection until status=green (HNSW + quantization built).
wait_for_qdrant_green() {
  local base_url="$1"
  local collection="$2"
  local timeout="${3:-1800}"
  local url="${base_url}/collections/${collection}"
  local i
  log "Waiting for Qdrant collection '$collection' to go green (timeout ${timeout}s)…"
  for ((i = 0; i < timeout; i += 2)); do
    local body
    body="$(curl -fsS "$url" 2>/dev/null || true)"
    if [[ "$body" == *'"status":"green"'* ]]; then
      log "Qdrant collection green after ~${i}s"
      return 0
    fi
    sleep 2
  done
  echo "ERROR: Qdrant collection '$collection' did not go green within ${timeout}s" >&2
  return 1
}

# --- NUMA pinning -----------------------------------------------------------
# Echo a `numactl --cpunodebind=N --membind=N` prefix when $1 (node id) is set
# and `numactl` is available, otherwise echo nothing. Callers consume it as an
# array, so the empty case naturally degrades to "no prefix".
#
# Usage:
#   read -ra NUMA_SERVER < <(numa_prefix "${SERVER_NUMA_NODE:-}")
#   "${NUMA_SERVER[@]}" ./casper ...
numa_prefix() {
  local node="$1"
  if [[ -z "$node" ]]; then
    echo
    return 0
  fi
  if ! command -v numactl >/dev/null 2>&1; then
    echo "WARNING: numactl not installed, ignoring NUMA pinning for node=$node" >&2
    echo
    return 0
  fi
  printf 'numactl --cpunodebind=%s --membind=%s\n' "$node" "$node"
}

# --- process control --------------------------------------------------------
# Send SIGTERM to a PID and wait until it actually exits (max 30s),
# then SIGKILL if still alive. Safe to call when pid is empty / dead.
stop_pid() {
  local pid="${1:-}"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  log "Stopping pid=$pid (SIGTERM)…"
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for ((i = 0; i < 30; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "pid=$pid exited"
      return 0
    fi
    sleep 1
  done
  log "pid=$pid still alive after 30s, sending SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
}
