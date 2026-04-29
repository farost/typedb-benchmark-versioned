#!/bin/bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════
# TypeDB Version Regression Sweep
# ══════════════════════════════════════════════════════════════════
#
# Builds and benchmarks multiple TypeDB releases to detect regressions.
# Each version is built from source with cargo, then benchmarked 3 times
# using mode1 (Core, 10 runs of 120s each).
#
# Usage:
#   ./run.sh <GITHUB_TOKEN>
#
# The token is used for authenticated git clone of the private TypeDB repo.
#
# Output:
#   results/regression_sweep_<timestamp>.txt   — full report
#   results/raw/                               — per-version raw benchmark logs
#
# ══════════════════════════════════════════════════════════════════

SWEEP_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCHMARK_DIR="$(cd "$SWEEP_DIR/.." && pwd)"
WORK_DIR="$SWEEP_DIR/work"
RESULTS_DIR="$SWEEP_DIR/results"
RAW_DIR="$RESULTS_DIR/raw"

# ── Versions to benchmark ────────────────────────────────────────
# Highest stable patch per minor version, all using proto VERSION 7
# (compatible with the same typedb-driver).
VERSIONS=(
    "3.4.4"
    "3.5.5"
    "3.7.3"
    "3.8.3"
    "3.10.3"
)

RUNS_PER_VERSION=3
BENCHMARK_ARGS="mode1 a 10 120"

# ── Colors ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn()   { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*"; }
error()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}$*${NC}"; }

# ── Parse arguments ───────────────────────────────────────────────

TOKEN="${1:-}"
if [ -z "$TOKEN" ]; then
    echo "Usage: $0 <GITHUB_TOKEN>"
    echo ""
    echo "Builds and benchmarks TypeDB versions: ${VERSIONS[*]}"
    echo "Each version is benchmarked $RUNS_PER_VERSION times with: ./benchmark.sh $BENCHMARK_ARGS"
    exit 1
fi

# ── Setup ─────────────────────────────────────────────────────────

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$RESULTS_DIR/regression_sweep_${TIMESTAMP}.txt"

mkdir -p "$WORK_DIR" "$RAW_DIR"

# Ensure benchmark bin directory exists
mkdir -p "$BENCHMARK_DIR/bin/mode1"

header "TypeDB Version Regression Sweep"
log "Versions:  ${VERSIONS[*]}"
log "Runs each: $RUNS_PER_VERSION x ($BENCHMARK_ARGS)"
log "Report:    $REPORT_FILE"
echo ""

# ── Clone / update repo ──────────────────────────────────────────

REPO_DIR="$WORK_DIR/typedb"
REPO_URL="https://${TOKEN}@github.com/typedb/typedb.git"

if [ -d "$REPO_DIR/.git" ]; then
    log "Updating existing clone..."
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
    git -C "$REPO_DIR" fetch --tags --force origin
else
    log "Cloning TypeDB repository..."
    git clone --no-checkout "$REPO_URL" "$REPO_DIR"
    git -C "$REPO_DIR" fetch --tags --force origin
fi

# ── Detect binary name from Cargo.toml at a given checkout ────────

detect_binary_name() {
    local cargo_toml="$REPO_DIR/Cargo.toml"
    if [ -f "$cargo_toml" ]; then
        # Look for [[bin]] section's name field
        grep -A2 '^\[\[bin\]\]' "$cargo_toml" | grep 'name' | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo ""
    fi
}

# ── Build a version ──────────────────────────────────────────────

build_version() {
    local version="$1"
    local tag="$version"
    local build_log="$RAW_DIR/build_${version}.log"

    header "Building TypeDB $version"

    # Checkout the tag (force to discard any local changes from previous build)
    log "Checking out tag $tag..."
    if ! git -C "$REPO_DIR" checkout -f "$tag" 2>/dev/null; then
        error "Tag $tag not found. Skipping."
        return 1
    fi
    git -C "$REPO_DIR" submodule update --init --recursive 2>/dev/null || true

    # Detect binary name
    local bin_name
    bin_name=$(detect_binary_name)
    if [ -z "$bin_name" ]; then
        # Fallback names
        bin_name="typedb_server_bin"
    fi
    log "Binary name: $bin_name"

    # Build with cargo
    log "Building with cargo (release mode)... (log: $build_log)"
    if ! (cd "$REPO_DIR" && cargo build --release --bin "$bin_name" 2>&1) > "$build_log" 2>&1; then
        error "Cargo build failed for $version. See: $build_log"
        tail -20 "$build_log"
        return 1
    fi

    # Find and copy binary
    local binary="$REPO_DIR/target/release/$bin_name"
    if [ ! -f "$binary" ]; then
        error "Binary not found at $binary after build."
        return 1
    fi

    # Kill any lingering server processes before overwriting the binary
    (cd "$BENCHMARK_DIR" && source modes/common.sh && cleanup_servers 2>/dev/null) || true

    local dest="$BENCHMARK_DIR/bin/mode1/server_a"
    rm -f "$dest"
    if ! cp "$binary" "$dest"; then
        error "Failed to copy binary to $dest"
        return 1
    fi
    chmod +x "$dest"
    log "Installed binary: $dest ($(du -h "$dest" | cut -f1))"
}

# ── Run benchmarks for a version ─────────────────────────────────

# Global arrays to accumulate results
declare -A VERSION_ALL_TPMC    # version -> space-separated tpmC values across all runs
declare -A VERSION_RUN_AVGS    # version -> space-separated per-run averages

benchmark_version() {
    local version="$1"
    local all_tpmc=""
    local run_avgs=""

    header "Benchmarking TypeDB $version ($RUNS_PER_VERSION runs)"

    for run_num in $(seq 1 "$RUNS_PER_VERSION"); do
        log "=== Version $version — Run $run_num/$RUNS_PER_VERSION ==="
        local run_log="$RAW_DIR/bench_${version}_run${run_num}.log"

        # Run benchmark, capture output
        if ! (cd "$BENCHMARK_DIR" && ./benchmark.sh $BENCHMARK_ARGS) > "$run_log" 2>&1; then
            error "Benchmark run $run_num failed for $version. See: $run_log"
            tail -20 "$run_log"
            warn "Skipping this run."
            continue
        fi

        # Extract tpmC values from benchmark output
        # Lines like: "  Run 1/10: <ANSI>665.400194350527 tpmC<ANSI>"
        # Strip ANSI escape codes before matching
        local values
        values=$(sed 's/\x1b\[[0-9;]*m//g' "$run_log" | grep -oP 'Run \d+/\d+: \K[0-9]+\.[0-9]+(?= tpmC)' || true)
        if [ -z "$values" ]; then
            warn "No tpmC values found in run $run_num output."
            continue
        fi

        # Compute this run's average
        local run_avg
        run_avg=$(echo "$values" | python3 -c "
import sys
vals = [float(l.strip()) for l in sys.stdin if l.strip()]
print(f'{sum(vals)/len(vals):.2f}' if vals else '0.00')
")
        local values_oneline
        values_oneline=$(echo "$values" | tr '\n' ' ')
        log "Run $run_num values: $values_oneline"
        log "Run $run_num average: $run_avg tpmC"

        all_tpmc="$all_tpmc $values_oneline"
        run_avgs="$run_avgs $run_avg"
    done

    VERSION_ALL_TPMC["$version"]="${all_tpmc# }"
    VERSION_RUN_AVGS["$version"]="${run_avgs# }"
}

# ── Generate report ──────────────────────────────────────────────

generate_report() {
    header "Generating report..."

    python3 "$SWEEP_DIR/report.py" \
        --output "$REPORT_FILE" \
        --versions "${VERSIONS[@]}" \
        --raw-dir "$RAW_DIR" \
        --runs-per-version "$RUNS_PER_VERSION" \
        --benchmark-args "$BENCHMARK_ARGS"

    log "Report saved: $REPORT_FILE"
    echo ""
    cat "$REPORT_FILE"
}

# ── Signal handling ───────────────────────────────────────────────

INTERRUPTED=false
cleanup_and_exit() {
    INTERRUPTED=true
    trap - INT TERM
    echo ""
    error "Interrupted — cleaning up..."
    # Kill benchmark servers if any
    (cd "$BENCHMARK_DIR" && source modes/common.sh && cleanup_servers 2>/dev/null) || true
    exit 130
}
trap cleanup_and_exit INT TERM

# ── Main loop ─────────────────────────────────────────────────────

SKIPPED_VERSIONS=()
COMPLETED_VERSIONS=()

for version in "${VERSIONS[@]}"; do
    if [ "$INTERRUPTED" = true ]; then
        break
    fi

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}║  %-56s ║${NC}\n" "TypeDB $version"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"

    # Build
    if ! build_version "$version"; then
        warn "Skipping $version due to build failure."
        SKIPPED_VERSIONS+=("$version")
        continue
    fi

    # Benchmark
    benchmark_version "$version"
    COMPLETED_VERSIONS+=("$version")

    # Write intermediate results so we don't lose data on crash
    {
        echo "# Intermediate results — $version"
        echo "# timestamp=$(date +%Y-%m-%d_%H:%M:%S)"
        echo "version=$version"
        echo "all_tpmc=${VERSION_ALL_TPMC[$version]}"
        echo "run_avgs=${VERSION_RUN_AVGS[$version]}"
        echo ""
    } >> "$RAW_DIR/intermediate_results.txt"
done

# ── Final report ──────────────────────────────────────────────────

if [ "${#COMPLETED_VERSIONS[@]}" -eq 0 ]; then
    error "No versions completed successfully. Nothing to report."
    exit 1
fi

generate_report

if [ "${#SKIPPED_VERSIONS[@]}" -gt 0 ]; then
    warn "Skipped versions (build failures): ${SKIPPED_VERSIONS[*]}"
fi

header "Regression sweep complete."
log "Report: $REPORT_FILE"
log "Raw logs: $RAW_DIR/"
