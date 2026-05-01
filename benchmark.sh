#!/bin/bash
set -e

# ══════════════════════════════════════════════════════════════════
# TypeDB TPC-C Benchmark Runner
# ══════════════════════════════════════════════════════════════════
#
# Usage:
#   ./benchmark.sh MODE VARIANT [RUNS] [DURATION]
#
# MODE:     mode1 | mode2 | mode3 | mode4 | mode5
# VARIANT:  a | b | compare
#
# Arguments:
#   RUNS      Number of benchmark iterations (default: 5)
#   DURATION  Seconds per iteration (default: 120)
#
# Environment variables:
#   CLIENTS=2           Parallel TPC-C worker processes
#   WAREHOUSES=1        TPC-C warehouse count
#   SCALEFACTOR=100     TPC-C scale factor (higher = less data)
#   CLUSTER_NODES=3     Nodes for cluster modes (2, 5)
#
# Examples:
#   ./benchmark.sh mode1 a 5 120           # OLD Core, single run
#   ./benchmark.sh mode2 compare 3 60      # OLD Cluster, compare A vs B
#   ./benchmark.sh mode4 b 5 120           # NEW Cluster, variant B only
#   CLIENTS=4 ./benchmark.sh mode3 a 3 60  # NEW Core, 4 clients
#
# ══════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Parse arguments ───────────────────────────────────────────────

MODE="${1:-}"
VARIANT="${2:-}"
RUNS="${3:-5}"
DURATION="${4:-120}"
CLIENTS="${CLIENTS:-2}"
WAREHOUSES="${WAREHOUSES:-1}"
SCALEFACTOR="${SCALEFACTOR:-100}"
DRIVER_VARIANT="${DRIVER_VARIANT:-a}"

if [ -z "$MODE" ] || [ -z "$VARIANT" ]; then
    echo "TypeDB TPC-C Benchmark Runner"
    echo ""
    echo "Usage: $0 MODE VARIANT [RUNS] [DURATION]"
    echo ""
    echo "Modes:"
    echo "  mode1   OLD Core           (typedb master, release 3.10.x)"
    echo "  mode2   OLD Cluster binary (typedb-cluster master, release 3.10.x, single node)"
    echo "  mode3   NEW Core           (typedb cluster-support-feature-branch)"
    echo "  mode4   NEW Cluster 1-node (typedb-cluster cluster-support-feature-branch)"
    echo "  mode5   NEW Cluster 3-node (typedb-cluster cluster-support-feature-branch, admin registration)"
    echo ""
    echo "Variants:"
    echo "  a        Run only variant A (baseline / single build)"
    echo "  b        Run only variant B (optimized / alternative build)"
    echo "  compare  Run both A and B, then show comparison"
    echo ""
    echo "Examples:"
    echo "  $0 mode1 a 5 120           # 5 runs of 120s on OLD Core"
    echo "  $0 mode2 compare 3 60      # Compare baseline vs optimized, OLD Cluster"
    echo "  $0 mode4 b 5 120           # NEW Cluster, optimized only"
    echo ""
    echo "Environment: CLIENTS=$CLIENTS  WAREHOUSES=$WAREHOUSES  SCALEFACTOR=$SCALEFACTOR"
    exit 1
fi

# ── Validate mode ─────────────────────────────────────────────────

MODE_SCRIPT="$SCRIPT_DIR/modes/${MODE}.sh"
if [ ! -f "$MODE_SCRIPT" ]; then
    echo "Error: Unknown mode '$MODE'. Available: mode1, mode2, mode3, mode4, mode5"
    exit 1
fi

# ── Load shared functions and mode-specific script ────────────────

source "$SCRIPT_DIR/modes/common.sh"
source "$MODE_SCRIPT"

# Override MODE_VENV when DRIVER_VARIANT=b: switch venvs/new → venvs/new_b for
# modes that use the locally-built driver. mode1 / mode2 (pip-installed driver)
# are unaffected — DRIVER_VARIANT=b on those modes is a no-op.
case "$DRIVER_VARIANT" in
    a) ;;
    b)
        case "$MODE_VENV" in
            */new) MODE_VENV="${MODE_VENV%/new}/new_b" ;;
        esac
        ;;
    *)
        error "Unknown DRIVER_VARIANT: $DRIVER_VARIANT (expected: a, b)"
        exit 1
        ;;
esac

export MODE VARIANT RUNS DURATION CLIENTS WAREHOUSES SCALEFACTOR DRIVER_VARIANT

# ── Resolve binary and function names from mode ───────────────────

# Each mode script defines: ${MODE}_binary_path, ${MODE}_start_server, ${MODE}_stop_server
binary_path() { "${MODE}_binary_path" "$@"; }
start_server() { "${MODE}_start_server" "$@"; }
stop_server() { "${MODE}_stop_server"; }

# ── Core benchmark workflow ───────────────────────────────────────

run_single_variant() {
    local variant_label="$1"   # "a" or "b"
    local binary
    binary=$(binary_path "$variant_label")

    require_binary "$binary" "$MODE_NAME variant $variant_label"

    print_banner "$MODE_NAME" "$variant_label"

    # Start server
    if ! start_server "$binary" "$variant_label"; then
        error "Failed to start server for variant $variant_label"
        return 1
    fi

    # Activate the right Python environment
    activate_venv "$MODE_VENV"

    # Load data
    run_tpcc_load "$MODE_TPCC_CONFIG" "$MODE_DRIVER"

    # Run benchmark iterations
    run_benchmark_iterations "$MODE_TPCC_CONFIG" "$MODE_DRIVER" "$variant_label"

    # Stop server
    stop_server

    # Display and save
    print_single_result "Variant $variant_label" "${RESULT_VALUES[@]}"
    save_results "$MODE" "$variant_label" "${RESULT_VALUES[@]}"
}

# ── Main ──────────────────────────────────────────────────────────

INTERRUPTED=false
cleanup_and_exit() {
    INTERRUPTED=true
    # Prevent re-entry from recursive signals
    trap - INT TERM
    echo ""
    error "Interrupted — cleaning up servers..."
    cleanup_servers
    # Kill any remaining child processes (Python TPC-C runners, etc.)
    kill -- -$$ 2>/dev/null || true
    exit 130
}
trap cleanup_and_exit INT TERM

header "TypeDB TPC-C Benchmark"
log "Mode:           $MODE_NAME"
log "Server variant: $VARIANT"
log "Driver variant: $DRIVER_VARIANT  (venv: $MODE_VENV)"
log "Runs:           $RUNS × ${DURATION}s"
log "Clients:        $CLIENTS"
log "Warehouses:     $WAREHOUSES (scalefactor=$SCALEFACTOR)"
echo ""

case "$VARIANT" in
    a)
        run_single_variant "a"
        ;;
    b)
        run_single_variant "b"
        ;;
    compare)
        # Run A
        run_single_variant "a"
        RESULTS_A=("${RESULT_VALUES[@]}")

        echo ""
        header "Switching to variant B..."
        echo ""

        # Run B
        run_single_variant "b"
        RESULTS_B=("${RESULT_VALUES[@]}")

        # Print comparison
        print_comparison "A (baseline)" "B (optimized)" \
            "${RESULTS_A[@]}" "---" "${RESULTS_B[@]}"
        ;;
    *)
        error "Unknown variant: $VARIANT (expected: a, b, compare)"
        exit 1
        ;;
esac

header "Done."
