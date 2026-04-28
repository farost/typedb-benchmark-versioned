#!/bin/bash
# Mode 4: NEW Cluster binary, single node (typedb-cluster cluster-support-feature-branch)
#
# Single TypeDB Cluster server running alone (no peer registration).
# Compares cluster binary overhead vs core binary (mode 3).
# Uses locally-built typedb-driver from cluster-support-feature-branch.
#
# Binaries:
#   bin/mode4/server_a   — e.g. baseline cluster build
#   bin/mode4/server_b   — e.g. optimized cluster build (optional)
#
# Driver: typedb3 (Core edition, locally-built typedb-driver)
#
# Build instructions:
#   Server:  cd typedb-cluster && bazel build //:assemble-typedb-all --compilation_mode=opt
#   Driver:  cd typedb-driver && bazel build //python:assemble-pip311

MODE_NAME="Mode 4 — NEW Cluster binary, single node (cluster-support-feature-branch)"
MODE_DRIVER="typedb3"
MODE_VENV="$VENV_DIR/new"
MODE_TPCC_CONFIG="$CONFIG_DIR/tpcc/core.cfg"

GRPC_PORT=1729
HTTP_PORT=8000
ADMIN_PORT=1728
CLUSTERING_PORT=1730
MONITORING_PORT=4104

mode4_binary_path() {
    local variant="$1"
    echo "$BIN_DIR/mode4/server_${variant}"
}

mode4_start_server() {
    local binary="$1"
    local variant_tag="$2"

    require_binary "$binary" "Mode 4 server"
    cleanup_servers

    local data_dir="$DATA_DIR/mode4"
    local cluster_dir="$DATA_DIR/mode4_clustering"
    local log_file="$LOG_DIR/mode4_${variant_tag}.log"
    rm -rf "$data_dir" "$cluster_dir"
    mkdir -p "$data_dir" "$cluster_dir" "$(dirname "$log_file")"

    local config
    config=$(mode4_generate_config "$data_dir")

    log "Starting NEW Cluster server, single node (gRPC=$GRPC_PORT, HTTP=$HTTP_PORT)..."
    "$binary" \
        --config "$config" \
        --development-mode.enabled true \
        --diagnostics.deployment-id "benchmark" \
        --server.admin.enabled true \
        --server.admin.port "$ADMIN_PORT" \
        --server.clustering.id 1 \
        --server.clustering.address "127.0.0.1:$CLUSTERING_PORT" \
        --storage.clustering-directory "$cluster_dir" \
        > "$log_file" 2>&1 &

    if ! wait_for_port "$GRPC_PORT" 30; then
        error "Server failed to start. Log:"
        tail -20 "$log_file"
        return 1
    fi
    sleep 5
    log "Server ready on port $GRPC_PORT"
}

mode4_generate_config() {
    local data_dir="$1"
    local wal_dir="$LOG_DIR/mode4_wal"
    mkdir -p "$wal_dir"

    local config_file="$CONFIG_DIR/generated/mode4.yml"
    mkdir -p "$(dirname "$config_file")"
    sed -e "s|DATA_DIR_PLACEHOLDER|$data_dir|g" \
        -e "s|LOG_DIR_PLACEHOLDER|$wal_dir|g" \
        -e "s|GRPC_PORT|$GRPC_PORT|g" \
        -e "s|HTTP_PORT|$HTTP_PORT|g" \
        -e "s|MONITORING_PORT|$MONITORING_PORT|g" \
        "$CONFIG_DIR/new_server.yml.template" > "$config_file"
    echo "$config_file"
}

mode4_stop_server() {
    cleanup_servers
}
