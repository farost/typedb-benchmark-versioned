#!/bin/bash
# Mode 2: OLD Cluster binary (typedb/typedb-cluster master — release 3.10.x)
#
# Single TypeDB Cluster server, no actual clustering.
# The old cluster binary (master) is just a core server wrapper —
# the only extra flag is --diagnostics.deployment-id.
# Uses the released typedb-driver from PyPI.
#
# Binaries:
#   bin/mode2/server_a   — e.g. baseline cluster build
#   bin/mode2/server_b   — e.g. optimized cluster build (optional)
#
# Driver: typedb3 (Core edition, pip install typedb-driver)

MODE_NAME="Mode 2 — OLD Cluster binary (3.10.x release)"
MODE_DRIVER="typedb3"
MODE_VENV="$VENV_DIR/old"
MODE_TPCC_CONFIG="$CONFIG_DIR/tpcc/core.cfg"

GRPC_PORT=1729

mode2_binary_path() {
    local variant="$1"
    echo "$BIN_DIR/mode2/server_${variant}"
}

mode2_start_server() {
    local binary="$1"
    local variant_tag="$2"

    require_binary "$binary" "Mode 2 server"
    cleanup_servers

    local data_dir="$DATA_DIR/mode2"
    local log_file="$LOG_DIR/mode2_${variant_tag}.log"
    rm -rf "$data_dir"
    mkdir -p "$data_dir" "$(dirname "$log_file")"

    local config
    config=$(mode2_generate_config "$data_dir")

    log "Starting OLD Cluster binary, single node (port $GRPC_PORT)..."
    "$binary" \
        --config "$config" \
        --development-mode.enabled true \
        --diagnostics.deployment-id "benchmark" \
        > "$log_file" 2>&1 &

    if ! wait_for_port "$GRPC_PORT" 30; then
        error "Server failed to start. Log:"
        tail -20 "$log_file"
        return 1
    fi
    sleep 5
    log "Server ready on port $GRPC_PORT"
}

mode2_generate_config() {
    local data_dir="$1"
    local wal_dir="$LOG_DIR/mode2_wal"
    mkdir -p "$wal_dir"

    local config_file="$CONFIG_DIR/generated/mode2.yml"
    mkdir -p "$(dirname "$config_file")"
    sed -e "s|DATA_DIR_PLACEHOLDER|$data_dir|g" \
        -e "s|LOG_DIR_PLACEHOLDER|$wal_dir|g" \
        -e "s|GRPC_PORT|$GRPC_PORT|g" \
        -e "s|HTTP_PORT|8001|g" \
        -e "s|MONITORING_PORT|4104|g" \
        "$CONFIG_DIR/cluster_node.yml.template" > "$config_file"
    echo "$config_file"
}

mode2_stop_server() {
    cleanup_servers
}
