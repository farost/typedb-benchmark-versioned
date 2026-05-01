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
GRPC_PORT=1729
HTTP_PORT=8000
MONITORING_PORT=4104

mkdir -p "$RESULTS_DIR"

# Source the harness helpers so we get cleanup_servers, wait_for_port, etc.
cd "$BENCH_DIR"
# shellcheck disable=SC1091
source modes/common.sh

trap 'cleanup_servers || true' EXIT INT TERM

# Start the server with HTTP explicitly enabled. The mode3 config template
# defaults http.enabled to false; we override on the CLI. We build the config
# inline so this works on master (which uses the simpler core.yml.template)
# and on cluster (which uses new_server.yml.template) — same file format
# minus a couple of optional fields, and we just use the cluster template
# (extra fields are ignored on master).
start_server_with_http() {
    local binary="$1" tag="$2"
    local data_dir="$BENCH_DIR/data/mode3"
    local wal_dir="$BENCH_DIR/logs/mode3_wal"
    local log_file="$BENCH_DIR/logs/mode3_${tag}.log"
    local config="$BENCH_DIR/configs/generated/mode3.yml"

    rm -rf "$data_dir"
    mkdir -p "$data_dir" "$wal_dir" "$BENCH_DIR/configs/generated"

    # Pick the template that exists; both have HTTP_PORT/GRPC_PORT placeholders
    local template
    if [[ -f "$BENCH_DIR/configs/new_server.yml.template" ]]; then
        template="$BENCH_DIR/configs/new_server.yml.template"
    else
        template="$BENCH_DIR/configs/core.yml.template"
    fi
    sed -e "s|DATA_DIR_PLACEHOLDER|$data_dir|g" \
        -e "s|LOG_DIR_PLACEHOLDER|$wal_dir|g" \
        -e "s|GRPC_PORT|$GRPC_PORT|g" \
        -e "s|HTTP_PORT|$HTTP_PORT|g" \
        -e "s|MONITORING_PORT|$MONITORING_PORT|g" \
        "$template" > "$config"

    log "starting server: $binary  (gRPC=$GRPC_PORT, HTTP=$HTTP_PORT)"
    "$binary" \
        --config "$config" \
        --development-mode.enabled true \
        --server.http.enabled true \
        > "$log_file" 2>&1 &

    if ! wait_for_port "$GRPC_PORT" 30; then
        error "gRPC did not come up on :$GRPC_PORT — log tail:"
        tail -30 "$log_file" >&2
        return 1
    fi
    if ! wait_for_port "$HTTP_PORT" 30; then
        error "HTTP did not come up on :$HTTP_PORT — log tail:"
        tail -30 "$log_file" >&2
        return 1
    fi
    sleep 2
    log "server ready"
}

run_one() {
    local label="$1" binary="$2"
    [[ -x "$binary" ]] || { error "binary missing or not executable: $binary"; return 1; }

    header "▶ $label  ($binary)"
    cleanup_servers
    if ! start_server_with_http "$binary" "${label}"; then
        error "server failed to start for $label"
        return 1
    fi
    # liveness check (HTTP)
    if ! curl -fsS "http://127.0.0.1:${HTTP_PORT}/v1/health" >/dev/null; then
        error "HTTP not responding at :$HTTP_PORT for $label — log tail:"
        tail -30 "$BENCH_DIR/logs/mode3_${label}.log" >&2
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
