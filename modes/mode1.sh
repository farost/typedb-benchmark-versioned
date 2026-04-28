#!/bin/bash
# Mode 1: OLD Core (typedb/typedb master — release 3.10.x)
#
# Single TypeDB Core server, no clustering.
# Uses the released typedb-driver from PyPI.
#
# Binaries:
#   bin/mode1/server_a   — e.g. release build
#   bin/mode1/server_b   — e.g. alternative build (optional, for comparison)
#
# Driver: typedb3 (Core edition, pip install typedb-driver)

MODE_NAME="Mode 1 — OLD Core (3.10.x release)"
MODE_DRIVER="typedb3"
MODE_VENV="$VENV_DIR/old"
MODE_TPCC_CONFIG="$CONFIG_DIR/tpcc/core.cfg"

GRPC_PORT=1729

mode1_binary_path() {
    local variant="$1"
    echo "$BIN_DIR/mode1/server_${variant}"
}

mode1_start_server() {
    local binary="$1"
    local variant_tag="$2"

    require_binary "$binary" "Mode 1 server"
    cleanup_servers

    local data_dir="$DATA_DIR/mode1"
    local log_file="$LOG_DIR/mode1_${variant_tag}.log"
    rm -rf "$data_dir"
    mkdir -p "$data_dir" "$(dirname "$log_file")"

    local config
    config=$(mode1_generate_config "$data_dir")

    log "Starting OLD Core server (port $GRPC_PORT)..."
    "$binary" \
        --config "$config" \
        --development-mode.enabled true \
        > "$log_file" 2>&1 &

    if ! wait_for_port "$GRPC_PORT" 30; then
        error "Server failed to start. Log:"
        tail -20 "$log_file"
        return 1
    fi
    sleep 5
    log "Server ready on port $GRPC_PORT"
}

mode1_generate_config() {
    local data_dir="$1"
    local wal_dir="$LOG_DIR/mode1_wal"
    mkdir -p "$wal_dir"

    local config_file="$CONFIG_DIR/generated/mode1.yml"
    mkdir -p "$(dirname "$config_file")"
    sed -e "s|DATA_DIR_PLACEHOLDER|$data_dir|g" \
        -e "s|LOG_DIR_PLACEHOLDER|$wal_dir|g" \
        -e "s|GRPC_PORT|$GRPC_PORT|g" \
        -e "s|HTTP_PORT|8001|g" \
        -e "s|MONITORING_PORT|4104|g" \
        "$CONFIG_DIR/core.yml.template" > "$config_file"
    echo "$config_file"
}

mode1_stop_server() {
    cleanup_servers
}
