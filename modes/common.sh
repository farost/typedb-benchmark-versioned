#!/bin/bash
# Common functions for all benchmark modes.
# Sourced by benchmark.sh — do not execute directly.

PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$PACKAGE_DIR/bin"
CONFIG_DIR="$PACKAGE_DIR/configs"
LOG_DIR="$PACKAGE_DIR/logs"
DATA_DIR="$PACKAGE_DIR/data"
TPCC_DIR="$PACKAGE_DIR/pytpcc"
RESULTS_DIR="$LOG_DIR/results"
VENV_DIR="$PACKAGE_DIR/venvs"

# ── Colors ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn()  { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
error() { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; }
header(){ echo -e "\n${BOLD}${CYAN}$*${NC}"; }

# ── Server management ─────────────────────────────────────────────

cleanup_servers() {
    # Kill any TypeDB server processes — match both the binary name and our bin/ paths
    pkill -9 -f "typedb_server" 2>/dev/null || true
    pkill -9 -f "server_[ab]" 2>/dev/null || true
    pkill -9 -f "$BIN_DIR" 2>/dev/null || true
    sleep 2
    # Verify key ports are free
    local port
    for port in 1729 11729 21729 31729; do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            warn "Port $port still in use after cleanup — killing process on it"
            fuser -k "$port/tcp" 2>/dev/null || true
            sleep 1
        fi
    done
}

wait_for_port() {
    local port=$1
    local timeout=${2:-60}
    local i
    for i in $(seq 1 "$timeout"); do
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    error "Port $port did not open within ${timeout}s"
    return 1
}

require_binary() {
    local path="$1"
    local label="$2"
    if [ ! -x "$path" ]; then
        error "Binary not found or not executable: $path"
        error "Expected: $label"
        error "See README.md for instructions on building binaries."
        exit 1
    fi
}

# ── Virtual environment ───────────────────────────────────────────

activate_venv() {
    local venv_path="$1"
    if [ ! -d "$venv_path" ]; then
        error "Virtual environment not found: $venv_path"
        error "Run:  ./setup.sh $MODE"
        exit 1
    fi
    # shellcheck disable=SC1091
    source "$venv_path/bin/activate"
}

# ── TPC-C helpers ─────────────────────────────────────────────────

run_tpcc_load() {
    local config_file="$1"
    local driver_name="$2"
    log "Loading TPC-C data (warehouses=$WAREHOUSES, scalefactor=$SCALEFACTOR)..."
    local load_log="$LOG_DIR/tpcc_load.log"
    (
        cd "$TPCC_DIR"
        python3 tpcc.py \
            --warehouses "$WAREHOUSES" \
            --scalefactor "$SCALEFACTOR" \
            --clients 1 \
            --reset --no-execute \
            --config "$config_file" "$driver_name" 2>&1
    ) > "$load_log" 2>&1
    local rc=$?
    tail -5 "$load_log"
    if [ $rc -ne 0 ]; then
        error "TPC-C data loading FAILED (exit code $rc). Full log: $load_log"
        error "Last 20 lines:"
        tail -20 "$load_log"
        cleanup_servers
        exit 1
    fi
    # Verify the load actually completed (look for "Finished loading")
    if ! grep -q "Finished loading" "$load_log" 2>/dev/null; then
        error "TPC-C data loading did not complete. Full log: $load_log"
        error "Last 20 lines:"
        tail -20 "$load_log"
        cleanup_servers
        exit 1
    fi
    log "Data loaded successfully."
}

# Runs one TPC-C iteration. Sets ITER_TPMC to the tpmC value (or "FAILED").
# Uses background process + wait so Ctrl+C is not blocked.
run_tpcc_iteration() {
    local config_file="$1"
    local driver_name="$2"
    local iter_log="$LOG_DIR/tpcc_iteration.log"
    ITER_TPMC="FAILED"

    cd "$TPCC_DIR"
    timeout $((DURATION + 120)) python3 tpcc.py \
        --warehouses "$WAREHOUSES" \
        --scalefactor "$SCALEFACTOR" \
        --clients "$CLIENTS" \
        --duration "$DURATION" \
        --no-load \
        --config "$config_file" "$driver_name" > "$iter_log" 2>&1 &
    local pid=$!
    cd "$PACKAGE_DIR"

    # wait is interruptible by signals (unlike command substitution)
    wait $pid 2>/dev/null || true

    # If interrupted, bail out
    if [ "${INTERRUPTED:-false}" = true ]; then
        return
    fi

    # Extract tpmC from output like:  'tpmc': 245.67
    local tpmc
    tpmc=$(grep -oP "'tpmc':\s*\K[0-9]+\.[0-9]+" "$iter_log" || true)
    if [ -z "$tpmc" ]; then
        # Fallback: try the older format
        tpmc=$(grep "'tpmc'" "$iter_log" | grep -oP "[0-9]+\.[0-9]+" || true)
    fi
    ITER_TPMC="${tpmc:-FAILED}"
}

# ── Result collection ─────────────────────────────────────────────

# Run $RUNS iterations, collecting tpmC values into the RESULT_VALUES array.
run_benchmark_iterations() {
    local config_file="$1"
    local driver_name="$2"
    local label="$3"
    RESULT_VALUES=()

    log "Running $RUNS iterations (${DURATION}s each, $CLIENTS clients)..."
    local i
    local consecutive_failures=0
    for i in $(seq 1 "$RUNS"); do
        # Check if interrupted between runs
        if [ "${INTERRUPTED:-false}" = true ]; then
            break
        fi
        printf "  Run %d/%d: " "$i" "$RUNS"
        run_tpcc_iteration "$config_file" "$driver_name"
        if [ "${INTERRUPTED:-false}" = true ]; then
            echo -e "${RED}INTERRUPTED${NC}"
            break
        fi
        if [ "$ITER_TPMC" = "FAILED" ]; then
            echo -e "${RED}FAILED${NC}"
            warn "Run $i failed — check server logs in $LOG_DIR/"
            consecutive_failures=$((consecutive_failures + 1))
            if [ "$consecutive_failures" -ge 3 ]; then
                error "3 consecutive failures — aborting benchmark."
                cleanup_servers
                exit 1
            fi
        else
            echo -e "${GREEN}${ITER_TPMC} tpmC${NC}"
            RESULT_VALUES+=("$ITER_TPMC")
            consecutive_failures=0
        fi
    done
}

# ── Statistics ────────────────────────────────────────────────────

# Compute avg, min, max from a space-separated list of numbers.
# Usage: read avg min max <<< "$(compute_stats "1.0 2.0 3.0")"
compute_stats() {
    local values="$1"
    python3 -c "
import sys
vals = [float(x) for x in '$values'.split()]
if not vals:
    print('0.00 0.00 0.00')
else:
    print(f'{sum(vals)/len(vals):.2f} {min(vals):.2f} {max(vals):.2f}')
"
}

# ── Result persistence ────────────────────────────────────────────

save_results() {
    local mode="$1"
    local variant="$2"
    shift 2
    local values=("$@")

    mkdir -p "$RESULTS_DIR"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local filename="${mode}_${variant}_${timestamp}.txt"
    local filepath="$RESULTS_DIR/$filename"

    local values_str="${values[*]}"
    local stats
    stats=$(compute_stats "$values_str")
    local avg min max
    read -r avg min max <<< "$stats"

    cat > "$filepath" <<EOF
mode=$mode
variant=$variant
timestamp=$timestamp
runs=$RUNS
duration=$DURATION
clients=$CLIENTS
warehouses=$WAREHOUSES
scalefactor=$SCALEFACTOR
values=($values_str)
avg=$avg
min=$min
max=$max
EOF
    log "Results saved: $filepath"
    echo "$filepath"
}

# ── Display ───────────────────────────────────────────────────────

print_banner() {
    local mode_name="$1"
    local variant="$2"
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}║  %-56s ║${NC}\n" "$mode_name"
    printf "${BOLD}║  %-56s ║${NC}\n" "Variant: $variant"
    printf "${BOLD}║  %-56s ║${NC}\n" "Runs: $RUNS × ${DURATION}s  |  Clients: $CLIENTS  |  WH: $WAREHOUSES"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
}

print_single_result() {
    local label="$1"
    shift
    local values=("$@")

    local values_str="${values[*]}"
    local stats
    stats=$(compute_stats "$values_str")
    local avg min max
    read -r avg min max <<< "$stats"

    echo ""
    echo -e "  ${BOLD}$label${NC}"
    echo -e "  Values: ${values_str} tpmC"
    echo -e "  Avg: ${BOLD}${avg}${NC}  Min: ${min}  Max: ${max}"
}

print_comparison() {
    local label_a="$1"; shift
    local label_b="$1"; shift
    # Remaining args: values_a... --- values_b...
    local values_a=()
    local values_b=()
    local in_b=false
    for arg in "$@"; do
        if [ "$arg" = "---" ]; then
            in_b=true
            continue
        fi
        if $in_b; then
            values_b+=("$arg")
        else
            values_a+=("$arg")
        fi
    done

    local stats_a stats_b
    stats_a=$(compute_stats "${values_a[*]}")
    stats_b=$(compute_stats "${values_b[*]}")
    local avg_a min_a max_a avg_b min_b max_b
    read -r avg_a min_a max_a <<< "$stats_a"
    read -r avg_b min_b max_b <<< "$stats_b"

    local delta pct
    delta=$(python3 -c "print(f'{$avg_b - $avg_a:.2f}')")
    pct=$(python3 -c "
a, d = $avg_a, $delta
print(f'{(d/a)*100:.1f}' if a != 0 else '0.0')
")

    echo ""
    echo -e "${BOLD}┌──────────────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}│  COMPARISON                                              │${NC}"
    echo -e "${BOLD}├──────────────────────────────────────────────────────────┤${NC}"
    printf "│  %-12s avg ${BOLD}%-8s${NC} tpmC  [%s]\n" "$label_a" "$avg_a" "${values_a[*]}"
    printf "│  %-12s avg ${BOLD}%-8s${NC} tpmC  [%s]\n" "$label_b" "$avg_b" "${values_b[*]}"
    echo -e "${BOLD}├──────────────────────────────────────────────────────────┤${NC}"
    if python3 -c "exit(0 if $delta > 0 else 1)" 2>/dev/null; then
        echo -e "│  Delta: ${GREEN}+${delta} tpmC (+${pct}%)  ▲ $label_b is FASTER${NC}"
    elif python3 -c "exit(0 if $delta < 0 else 1)" 2>/dev/null; then
        echo -e "│  Delta: ${RED}${delta} tpmC (${pct}%)  ▼ $label_b is SLOWER${NC}"
    else
        echo -e "│  Delta: ${YELLOW}0 tpmC  ═ No measurable difference${NC}"
    fi
    echo -e "${BOLD}└──────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# ── Comparison tool (file-based) ──────────────────────────────────

compare_result_files() {
    local file_a="$1"
    local file_b="$2"

    if [ ! -f "$file_a" ] || [ ! -f "$file_b" ]; then
        error "Result file not found."
        [ ! -f "$file_a" ] && error "  Missing: $file_a"
        [ ! -f "$file_b" ] && error "  Missing: $file_b"
        exit 1
    fi

    # Source files in subshells to avoid variable collision
    local va vb la lb
    va=$(bash -c "source '$file_a'; echo \${values[*]}")
    vb=$(bash -c "source '$file_b'; echo \${values[*]}")
    la=$(bash -c "source '$file_a'; echo \$mode/\$variant")
    lb=$(bash -c "source '$file_b'; echo \$mode/\$variant")

    print_comparison "$la" "$lb" $va "---" $vb
}
