#!/bin/bash
# Mode 5: NEW Cluster, 3-node (typedb-cluster cluster-support-feature-branch)
#
# 3-node TypeDB Cluster using the NEW clustering architecture.
# Nodes are registered via the admin tool after startup.
# Uses locally-built typedb-driver from cluster-support-feature-branch.
#
# Binaries:
#   bin/mode5/server_a   — cluster server binary (variant A)
#   bin/mode5/server_b   — cluster server binary (variant B, optional)
#   bin/mode5/admin      — admin tool binary (shared across variants)
#
# Driver: typedb3cluster (Cluster edition, locally-built typedb-driver)
#
# Build instructions:
#   Server:  cd typedb-cluster && bazel build //:assemble-typedb-all --compilation_mode=opt
#   Admin:   Built as part of the TypeDB distribution (admin/typedb_admin_bin)
#   Driver:  cd typedb-driver && bazel build //python:assemble-pip311
#
# Port scheme (node N):
#   admin     = N*10000 + 1728   (11728, 21728, 31728)
#   gRPC      = N*10000 + 1729   (11729, 21729, 31729)
#   clustering= N*10000 + 1730   (11730, 21730, 31730)
#   monitoring= N*10000 + 1731   (11731, 21731, 31731)
#   HTTP      = N*10000 + 8000   (18000, 28000, 38000)

MODE_NAME="Mode 5 — NEW Cluster, 3-node (cluster-support-feature-branch)"
MODE_DRIVER="typedb3cluster"
MODE_VENV="$VENV_DIR/new"
MODE_TPCC_CONFIG="$CONFIG_DIR/tpcc/cluster_new.cfg"

CLUSTER_NODES=${CLUSTER_NODES:-3}
REGISTER_MAX_RETRIES=10
REGISTER_RETRY_INTERVAL=2

mode5_binary_path() {
    local variant="$1"
    echo "$BIN_DIR/mode5/server_${variant}"
}

mode5_admin_path() {
    echo "$BIN_DIR/mode5/admin"
}

mode5_start_server() {
    local binary="$1"
    local variant_tag="$2"
    local admin_binary
    admin_binary=$(mode5_admin_path)

    require_binary "$binary" "Mode 5 server"
    require_binary "$admin_binary" "Mode 5 admin tool"
    cleanup_servers

    # Create directories for all nodes
    local i
    for i in $(seq 1 "$CLUSTER_NODES"); do
        local data_dir="$DATA_DIR/mode5_node${i}"
        local cluster_dir="$DATA_DIR/mode5_clustering_${i}"
        local wal_dir="$LOG_DIR/mode5_wal_${i}"
        rm -rf "$data_dir" "$cluster_dir"
        mkdir -p "$data_dir" "$cluster_dir" "$wal_dir"
    done

    # Start all nodes
    log "Starting ${CLUSTER_NODES}-node NEW cluster..."
    for i in $(seq 1 "$CLUSTER_NODES"); do
        local grpc_port=$((i * 10000 + 1729))
        local clustering_port=$((i * 10000 + 1730))
        local admin_port=$((i * 10000 + 1728))
        local http_port=$((i * 10000 + 8000))
        local monitoring_port=$((i * 10000 + 1731))
        local data_dir="$DATA_DIR/mode5_node${i}"
        local cluster_dir="$DATA_DIR/mode5_clustering_${i}"
        local wal_dir="$LOG_DIR/mode5_wal_${i}"
        local log_file="$LOG_DIR/mode5_${variant_tag}_node${i}.log"

        local config_file="$CONFIG_DIR/generated/mode5_node${i}.yml"
        mkdir -p "$(dirname "$config_file")"
        sed -e "s|DATA_DIR_PLACEHOLDER|$data_dir|g" \
            -e "s|LOG_DIR_PLACEHOLDER|$wal_dir|g" \
            -e "s|GRPC_PORT|$grpc_port|g" \
            -e "s|HTTP_PORT|$http_port|g" \
            -e "s|MONITORING_PORT|$monitoring_port|g" \
            "$CONFIG_DIR/new_server.yml.template" > "$config_file"

        "$binary" \
            --config "$config_file" \
            --development-mode.enabled true \
            --diagnostics.deployment-id "benchmark" \
            --server.admin.enabled true \
            --server.admin.port "$admin_port" \
            --server.clustering.id "$i" \
            --server.clustering.address "127.0.0.1:$clustering_port" \
            --storage.clustering-directory "$cluster_dir" \
            > "$log_file" 2>&1 &

        log "  Node $i started (gRPC=$grpc_port, cluster=$clustering_port, admin=$admin_port)"
    done

    # Wait for all nodes to be ready
    log "Waiting for all nodes to start..."
    for i in $(seq 1 "$CLUSTER_NODES"); do
        local grpc_port=$((i * 10000 + 1729))
        if ! wait_for_port "$grpc_port" 30; then
            error "Node $i failed to start (port $grpc_port). Log:"
            tail -20 "$LOG_DIR/mode5_${variant_tag}_node${i}.log"
            cleanup_servers
            return 1
        fi
        log "  Node $i: ${GREEN}OK${NC}"
    done

    # Register peer replicas via admin tool on node 1
    if [ "$CLUSTER_NODES" -gt 1 ]; then
        log "Registering peer replicas via admin tool..."
        local node1_admin_port=$((1 * 10000 + 1728))
        for i in $(seq 2 "$CLUSTER_NODES"); do
            local clustering_port=$((i * 10000 + 1730))
            local registered=false
            for attempt in $(seq 1 "$REGISTER_MAX_RETRIES"); do
                if "$admin_binary" \
                    --address="127.0.0.1:$node1_admin_port" \
                    --command "servers register $i 127.0.0.1:$clustering_port" 2>&1; then
                    log "  Registered replica $i (clustering=127.0.0.1:$clustering_port)"
                    registered=true
                    break
                fi
                if [ "$attempt" -lt "$REGISTER_MAX_RETRIES" ]; then
                    log "  Retrying registration of replica $i (attempt $attempt/$REGISTER_MAX_RETRIES)..."
                    sleep "$REGISTER_RETRY_INTERVAL"
                fi
            done
            if [ "$registered" = false ]; then
                error "Failed to register replica $i after $REGISTER_MAX_RETRIES attempts"
                cleanup_servers
                return 1
            fi
        done
    fi

    sleep 10
    log "Cluster ready (${CLUSTER_NODES} nodes)."
}

mode5_stop_server() {
    cleanup_servers
}
