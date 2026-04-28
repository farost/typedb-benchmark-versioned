#!/bin/bash
# Mode 2: OLD Cluster (typedb/typedb-cluster master — release 3.10.x)
#
# 3-node TypeDB Cluster using the OLD clustering architecture.
# Uses the released typedb-driver from PyPI.
# Clustering is configured server-side; the driver connects to node 1.
#
# Binaries:
#   bin/mode2/server_a   — e.g. baseline cluster build
#   bin/mode2/server_b   — e.g. optimized cluster build (optional)
#
# Driver: typedb3cluster (Cluster edition, pip install typedb-driver)

MODE_NAME="Mode 2 — OLD Cluster (3.10.x release)"
MODE_DRIVER="typedb3cluster"
MODE_VENV="$VENV_DIR/old"
MODE_TPCC_CONFIG="$CONFIG_DIR/tpcc/cluster.cfg"

CLUSTER_NODES=${CLUSTER_NODES:-3}

mode2_binary_path() {
    local variant="$1"
    echo "$BIN_DIR/mode2/server_${variant}"
}

mode2_start_server() {
    local binary="$1"
    local variant_tag="$2"

    require_binary "$binary" "Mode 2 server"
    cleanup_servers

    local i
    for i in $(seq 1 "$CLUSTER_NODES"); do
        local data_dir="$DATA_DIR/mode2_node${i}"
        local cluster_dir="$DATA_DIR/mode2_cluster_${i}"
        local wal_dir="$LOG_DIR/mode2_wal_${i}"
        rm -rf "$data_dir" "$cluster_dir"
        mkdir -p "$data_dir" "$cluster_dir" "$wal_dir"
    done

    log "Starting ${CLUSTER_NODES}-node OLD cluster..."
    for i in $(seq 1 "$CLUSTER_NODES"); do
        local grpc_port=$((i * 10000 + 1729))
        local cluster_port=$((i * 10000 + 1730))
        local data_dir="$DATA_DIR/mode2_node${i}"
        local cluster_dir="$DATA_DIR/mode2_cluster_${i}"
        local wal_dir="$LOG_DIR/mode2_wal_${i}"
        local log_file="$LOG_DIR/mode2_${variant_tag}_node${i}.log"

        local config_file="$CONFIG_DIR/generated/mode2_node${i}.yml"
        mkdir -p "$(dirname "$config_file")"
        local http_port=$((i * 10000 + 8001))
        local monitoring_port=$((i * 10000 + 4104))
        sed -e "s|DATA_DIR_PLACEHOLDER|$data_dir|g" \
            -e "s|LOG_DIR_PLACEHOLDER|$wal_dir|g" \
            -e "s|GRPC_PORT|$grpc_port|g" \
            -e "s|HTTP_PORT|$http_port|g" \
            -e "s|MONITORING_PORT|$monitoring_port|g" \
            "$CONFIG_DIR/cluster_node.yml.template" > "$config_file"

        "$binary" \
            --config "$config_file" \
            --development-mode.enabled true \
            --diagnostics.deployment-id "node$i" \
            --server.clustering.id "$i" \
            --server.clustering.address "127.0.0.1:$cluster_port" \
            --storage.clustering-directory "$cluster_dir" \
            > "$log_file" 2>&1 &

        log "  Node $i started (gRPC=$grpc_port, cluster=$cluster_port)"
    done

    log "Waiting for cluster to form..."
    sleep 20

    for i in $(seq 1 "$CLUSTER_NODES"); do
        local grpc_port=$((i * 10000 + 1729))
        if nc -z 127.0.0.1 "$grpc_port" 2>/dev/null; then
            log "  Node $i: ${GREEN}OK${NC}"
        else
            error "  Node $i: FAILED (port $grpc_port)"
            tail -20 "$LOG_DIR/mode2_${variant_tag}_node${i}.log"
            cleanup_servers
            return 1
        fi
    done
    log "Cluster ready."
}

mode2_stop_server() {
    cleanup_servers
}
