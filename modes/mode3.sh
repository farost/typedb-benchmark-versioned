#!/bin/bash
# Mode 3: NEW Core (typedb/typedb cluster-support-feature-branch)
#
# Single TypeDB server from the new codebase, running without clustering.
# Uses locally-built typedb-driver from cluster-support-feature-branch.
#
# Binaries:
#   bin/mode3/server_a   — e.g. baseline build
#   bin/mode3/server_b   — e.g. optimized build (optional)
#
# Driver: typedb3 (Core edition, locally-built typedb-driver)
#
# Build instructions:
#   Server:  cd typedb && bazel build //:assemble-typedb-all --compilation_mode=opt
#   Driver:  cd typedb-driver && bazel build //python:assemble-pip311

MODE_NAME="Mode 3 — NEW Core (cluster-support-feature-branch)"
MODE_DRIVER="typedb3"
MODE_VENV="$VENV_DIR/new"
MODE_TPCC_CONFIG="$CONFIG_DIR/tpcc/core.cfg"

GRPC_PORT=1729

mode3_binary_path() {
    local variant="$1"
    echo "$BIN_DIR/mode3/server_${variant}"
}

mode3_start_server() {
    local binary="$1"
    local variant_tag="$2"

    require_binary "$binary" "Mode 3 server"
    cleanup_servers

    local data_dir="$DATA_DIR/mode3"
    local log_file="$LOG_DIR/mode3_${variant_tag}.log"
    rm -rf "$data_dir"
    mkdir -p "$data_dir" "$(dirname "$log_file")"

    local config
    config=$(mode3_generate_config "$data_dir")

    log "Starting NEW Core server (port $GRPC_PORT)..."
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

mode3_generate_config() {
    local data_dir="$1"
    local wal_dir="$LOG_DIR/mode3_wal"
    mkdir -p "$wal_dir"

    local config_file="$CONFIG_DIR/generated/mode3.yml"
    mkdir -p "$(dirname "$config_file")"
    sed -e "s|DATA_DIR_PLACEHOLDER|$data_dir|g" \
        -e "s|LOG_DIR_PLACEHOLDER|$wal_dir|g" \
        -e "s|GRPC_PORT|$GRPC_PORT|g" \
        "$CONFIG_DIR/core.yml.template" > "$config_file"
    echo "$config_file"
}

mode3_stop_server() {
    cleanup_servers
}
