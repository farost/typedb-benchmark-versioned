#!/bin/bash
# One-shot: start server_a (master), run http-bench, stop, then server_b
# (cluster), run, stop, compare. Assumes binaries are already in
# bin/mode3/server_{a,b}.
#
# Usage:
#   ./http-bench/compare-master-cluster.sh [CLIENTS] [DURATION]
#
# Defaults: 4 clients × 60 seconds.

set -Eeuo pipefail

CLIENTS="${1:-4}"
DURATION="${2:-60}"
RESULTS_DIR="${RESULTS_DIR:-/tmp/http-bench-$(date +%Y%m%d_%H%M%S)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$RESULTS_DIR"

# Source the harness helpers so we get cleanup_servers, mode3_start_server, etc.
cd "$BENCH_DIR"
# shellcheck disable=SC1091
source modes/common.sh
# shellcheck disable=SC1091
source modes/mode3.sh

trap 'cleanup_servers || true' EXIT INT TERM

run_one() {
    local label="$1" binary="$2"
    [[ -x "$binary" ]] || { error "binary missing or not executable: $binary"; return 1; }

    header "▶ $label  ($binary)"
    cleanup_servers
    if ! mode3_start_server "$binary" "${label}"; then
        error "server failed to start for $label"
        return 1
    fi
    sleep 2
    # liveness check
    if ! curl -fsS "http://127.0.0.1:${HTTP_PORT}/v1/health" >/dev/null; then
        error "HTTP not responding at :$HTTP_PORT for $label"
        cleanup_servers
        return 1
    fi

    local out="$RESULTS_DIR/${label}.json"
    log "running http-bench → $out"
    "$SCRIPT_DIR/bench.py" \
        --addr "http://127.0.0.1:${HTTP_PORT}" \
        --reset \
        --clients "$CLIENTS" \
        --duration "$DURATION" \
        --label "$label" \
        --out "$out"
    log "$label done"

    cleanup_servers
    sleep 1
}

run_one master  "$BENCH_DIR/bin/mode3/server_a"
run_one cluster "$BENCH_DIR/bin/mode3/server_b"

echo
echo "=================== COMPARISON ==================="
"$SCRIPT_DIR/compare.py" "$RESULTS_DIR/master.json" "$RESULTS_DIR/cluster.json"
echo
echo "Results saved under: $RESULTS_DIR"
