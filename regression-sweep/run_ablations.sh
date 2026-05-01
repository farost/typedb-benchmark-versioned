#!/bin/bash
set -Eeuo pipefail

# ══════════════════════════════════════════════════════════════════
# Ablation Runner — one branch at a time, build + bench + record.
#
# For each row in ablations.conf, this script:
#   1. Asserts no typedb_server is running.
#   2. cd's to the right repo (typedb or typedb-driver), `git fetch`s, and
#      checks out the branch listed in the row.
#   3. Builds:
#       - typedb         : cargo build --release --bin typedb_server_bin
#                          → cp to BENCH_DIR/bin/mode3/server_b
#       - typedb-driver  : bazel build //python:assemble-pipNNN
#                          → pip install --force-reinstall into venvs/new_b
#   4. Runs the appropriate ./benchmark.sh cell:
#       - server side : DRIVER_VARIANT=a ./benchmark.sh mode3 b RUNS DURATION
#       - driver side : DRIVER_VARIANT=b ./benchmark.sh mode3 a RUNS DURATION
#      with TYPEDB_PERF_DUMP / TYPEDB_DRIVER_PERF_DUMP set when requested.
#   5. Saves stdout/stderr + extracts mean tpmC into the results dir.
#
# Hard-fails on any error. Always cleans up the server between rows.
#
# ── Required env ──────────────────────────────────────────────────
#   TYPEDB_REPO        absolute path to the typedb checkout
#   TYPEDB_DRIVER_REPO absolute path to the typedb-driver checkout
#
# ── Optional env ──────────────────────────────────────────────────
#   PYTHON_VERSION     310 | 311 | 312 | 313  (default 310)
#   FORK_REMOTE        git remote name for the user's fork (default "farost")
#   RUNS               benchmark.sh runs argument (default 5)
#   DURATION           benchmark.sh duration argument (default 120)
#   ABLATIONS_CONF     path to the config file (default: alongside this script)
#   ONLY               whitespace-separated allow-list of labels to run
#                      (e.g. ONLY="S1 D1" ./run_ablations.sh)
#   SKIP_BUILD         if set to 1, skip rebuild (for re-running a bench
#                      against an artifact you've already produced)
#
# Run from anywhere; paths are resolved against the script's own location.
# ══════════════════════════════════════════════════════════════════

# ── Resolve dirs ──────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ABLATIONS_CONF="${ABLATIONS_CONF:-$SCRIPT_DIR/ablations.conf}"

# ── Required ──────────────────────────────────────────────────────
: "${TYPEDB_REPO:?TYPEDB_REPO env var must be set (path to typedb checkout)}"
: "${TYPEDB_DRIVER_REPO:?TYPEDB_DRIVER_REPO env var must be set (path to typedb-driver checkout)}"
[[ -d "$TYPEDB_REPO/.git" ]]        || { echo "TYPEDB_REPO=$TYPEDB_REPO is not a git checkout" >&2; exit 1; }
[[ -d "$TYPEDB_DRIVER_REPO/.git" ]] || { echo "TYPEDB_DRIVER_REPO=$TYPEDB_DRIVER_REPO is not a git checkout" >&2; exit 1; }

# ── Defaults ──────────────────────────────────────────────────────
PYTHON_VERSION="${PYTHON_VERSION:-310}"
FORK_REMOTE="${FORK_REMOTE:-farost}"
RUNS="${RUNS:-5}"
DURATION="${DURATION:-120}"
ONLY="${ONLY:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

# ── Output dirs ───────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="$SCRIPT_DIR/results/ablations_${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"
SUMMARY="$RESULTS_DIR/SUMMARY.txt"

# ── Colors ────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
log()    { echo "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn()   { echo "${YELLOW}[$(date +%H:%M:%S)] WARN:${NC} $*" >&2; }
error()  { echo "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*" >&2; }
header() { echo; echo "${BOLD}${CYAN}$*${NC}"; }

abort() {
    error "$*"
    cleanup_servers || true
    exit 1
}
trap 'abort "interrupted (line $LINENO)"' INT TERM
trap 'abort "command failed (line $LINENO): $BASH_COMMAND"' ERR

# ── Server / port helpers ─────────────────────────────────────────
cleanup_servers() {
    pkill -9 -f "typedb_server"     2>/dev/null || true
    pkill -9 -f "typedb_server_bin" 2>/dev/null || true
    pkill -9 -f "$BENCH_DIR/bin/"   2>/dev/null || true
    sleep 2
    for port in 1729 11729 21729 31729; do
        if command -v nc >/dev/null && nc -z 127.0.0.1 "$port" 2>/dev/null; then
            warn "port $port still busy, forcing"
            fuser -k "$port/tcp" 2>/dev/null || true
            sleep 1
        fi
    done
}

assert_no_server() {
    if command -v nc >/dev/null && nc -z 127.0.0.1 1729 2>/dev/null; then
        cleanup_servers
        if nc -z 127.0.0.1 1729 2>/dev/null; then
            abort "could not free port 1729"
        fi
    fi
}

# ── Build helpers ─────────────────────────────────────────────────

build_server() {
    local branch="$1"
    log "[server] checkout $branch"
    git -C "$TYPEDB_REPO" fetch "$FORK_REMOTE" --quiet "$branch" || \
        git -C "$TYPEDB_REPO" fetch --quiet
    git -C "$TYPEDB_REPO" checkout --quiet "$branch" 2>/dev/null || \
        git -C "$TYPEDB_REPO" checkout --quiet "$FORK_REMOTE/$branch"
    git -C "$TYPEDB_REPO" --no-pager log -1 --pretty=format:'    HEAD %h %s%n'

    if [[ "$SKIP_BUILD" == "1" ]]; then
        log "[server] SKIP_BUILD=1 — reusing $BENCH_DIR/bin/mode3/server_b"
        [[ -x "$BENCH_DIR/bin/mode3/server_b" ]] || abort "SKIP_BUILD set but server_b missing"
        return
    fi

    log "[server] cargo build --release --bin typedb_server_bin"
    ( cd "$TYPEDB_REPO" && cargo build --release --bin typedb_server_bin )
    local binary="$TYPEDB_REPO/target/release/typedb_server_bin"
    [[ -x "$binary" ]] || abort "build did not produce $binary"

    install -m 0755 "$binary" "$BENCH_DIR/bin/mode3/server_b"
    log "[server] installed → $BENCH_DIR/bin/mode3/server_b"
}

build_driver() {
    local branch="$1"
    log "[driver] checkout $branch"
    git -C "$TYPEDB_DRIVER_REPO" fetch "$FORK_REMOTE" --quiet "$branch" || \
        git -C "$TYPEDB_DRIVER_REPO" fetch --quiet
    git -C "$TYPEDB_DRIVER_REPO" checkout --quiet "$branch" 2>/dev/null || \
        git -C "$TYPEDB_DRIVER_REPO" checkout --quiet "$FORK_REMOTE/$branch"
    git -C "$TYPEDB_DRIVER_REPO" --no-pager log -1 --pretty=format:'    HEAD %h %s%n'

    if [[ "$SKIP_BUILD" == "1" ]]; then
        log "[driver] SKIP_BUILD=1 — reusing whatever is in venvs/new_b"
        [[ -d "$BENCH_DIR/venvs/new_b" ]] || abort "SKIP_BUILD set but venvs/new_b missing"
        return
    fi

    local target="//python:assemble-pip${PYTHON_VERSION}"
    log "[driver] bazel build $target"
    ( cd "$TYPEDB_DRIVER_REPO" && bazel build "$target" )

    local wheel
    wheel=$(ls -t "$TYPEDB_DRIVER_REPO/bazel-bin/python/"typedb_driver-*.whl 2>/dev/null | head -1) \
        || abort "no wheel produced under bazel-bin/python/"
    log "[driver] wheel: $wheel"

    if [[ ! -d "$BENCH_DIR/venvs/new_b" ]]; then
        log "[driver] creating venvs/new_b"
        ( cd "$BENCH_DIR" && ./setup.sh new_b "$wheel" )
    else
        log "[driver] reinstalling into venvs/new_b"
        # shellcheck disable=SC1091
        ( source "$BENCH_DIR/venvs/new_b/bin/activate" && \
          pip install --force-reinstall --quiet "$wheel" )
    fi
}

# ── Run one ablation row ──────────────────────────────────────────
run_one() {
    local label="$1" side="$2" branch="$3" perf_dump="$4"

    header "═══ $label ($side / $branch) ═══"
    assert_no_server

    local stdout_file="$RESULTS_DIR/${label}.stdout"
    local stderr_file="$RESULTS_DIR/${label}.stderr"
    local meta_file="$RESULTS_DIR/${label}.meta"

    {
        echo "label=$label"
        echo "side=$side"
        echo "branch=$branch"
        echo "perf_dump=$perf_dump"
        echo "started_at=$(date -Iseconds)"
        echo "runs=$RUNS"
        echo "duration=$DURATION"
    } > "$meta_file"

    local server_variant driver_variant perf_env=""
    case "$side" in
        server)
            build_server "$branch"
            server_variant="b"
            driver_variant="a"
            [[ "$perf_dump" == "1" ]] && perf_env="TYPEDB_PERF_DUMP=1"
            ;;
        driver)
            build_driver "$branch"
            server_variant="a"
            driver_variant="b"
            [[ "$perf_dump" == "1" ]] && perf_env="TYPEDB_DRIVER_PERF_DUMP=1"
            ;;
        *)
            abort "unknown side '$side' for label '$label'"
            ;;
    esac

    git -C "$TYPEDB_REPO"        rev-parse HEAD >> "$meta_file" 2>/dev/null \
        | sed 's/^/typedb_head=/'        || true
    git -C "$TYPEDB_DRIVER_REPO" rev-parse HEAD >> "$meta_file" 2>/dev/null \
        | sed 's/^/typedb_driver_head=/' || true

    log "running:  ${perf_env:+$perf_env }DRIVER_VARIANT=$driver_variant ./benchmark.sh mode3 $server_variant $RUNS $DURATION"

    set +e
    ( cd "$BENCH_DIR" && \
      env ${perf_env:+$perf_env} \
          DRIVER_VARIANT="$driver_variant" \
          ./benchmark.sh mode3 "$server_variant" "$RUNS" "$DURATION" \
        > "$stdout_file" 2> "$stderr_file" )
    local rc=$?
    set -e

    cleanup_servers

    if [[ $rc -ne 0 ]]; then
        error "[$label] benchmark.sh exited $rc — see $stderr_file"
        echo "result=FAIL exit=$rc" >> "$meta_file"
        return 1
    fi

    # Extract tpmC values + mean from the stdout
    local mean
    mean=$(grep -oE 'Avg:\s*[0-9]+\.[0-9]+' "$stdout_file" | tail -1 | awk '{print $2}') || true
    mean="${mean:-NA}"
    echo "result=OK mean_tpmc=$mean" >> "$meta_file"

    log "[$label] ${BOLD}mean ${mean} tpmC${NC}"
}

# ── Parse config ──────────────────────────────────────────────────

[[ -f "$ABLATIONS_CONF" ]] || abort "config file not found: $ABLATIONS_CONF"

declare -a ROWS=()
while IFS= read -r line; do
    line="${line%%#*}"            # strip trailing comments
    line="$(echo "$line" | xargs)" # collapse whitespace
    [[ -z "$line" ]] && continue
    ROWS+=("$line")
done < "$ABLATIONS_CONF"

[[ ${#ROWS[@]} -gt 0 ]] || abort "no rows in $ABLATIONS_CONF"

# ── Main loop ─────────────────────────────────────────────────────

header "Ablation sweep — ${#ROWS[@]} rows"
log "results dir: $RESULTS_DIR"
log "TYPEDB_REPO=$TYPEDB_REPO"
log "TYPEDB_DRIVER_REPO=$TYPEDB_DRIVER_REPO"
log "RUNS=$RUNS DURATION=$DURATION PYTHON_VERSION=$PYTHON_VERSION"
[[ -n "$ONLY" ]] && log "ONLY filter: $ONLY"

declare -a SUMMARY_LINES=()
for row in "${ROWS[@]}"; do
    # shellcheck disable=SC2206
    parts=($row)
    [[ ${#parts[@]} -ge 4 ]] || abort "malformed row: $row"
    label="${parts[0]}"
    side="${parts[1]}"
    branch="${parts[2]}"
    perf_dump="${parts[3]}"

    if [[ -n "$ONLY" ]] && ! [[ " $ONLY " =~ " $label " ]]; then
        log "skipping $label (not in ONLY filter)"
        continue
    fi

    if run_one "$label" "$side" "$branch" "$perf_dump"; then
        meta="$RESULTS_DIR/${label}.meta"
        m=$(grep -oE 'mean_tpmc=[^ ]+' "$meta" | cut -d= -f2)
        SUMMARY_LINES+=("$(printf '  %-6s %-7s %-40s mean=%s tpmC' "$label" "$side" "$branch" "$m")")
    else
        SUMMARY_LINES+=("$(printf '  %-6s %-7s %-40s %s' "$label" "$side" "$branch" "${RED}FAIL${NC}")")
    fi
done

# ── Summary ───────────────────────────────────────────────────────
{
    echo "Ablation sweep $TIMESTAMP"
    echo "  TYPEDB_REPO        = $TYPEDB_REPO"
    echo "  TYPEDB_DRIVER_REPO = $TYPEDB_DRIVER_REPO"
    echo "  RUNS=$RUNS DURATION=${DURATION}s PYTHON_VERSION=$PYTHON_VERSION"
    echo
    echo "Results:"
    for line in "${SUMMARY_LINES[@]}"; do
        # strip color codes for the file
        echo "$line" | sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g'
    done
} > "$SUMMARY"

header "DONE"
for line in "${SUMMARY_LINES[@]}"; do echo "$line"; done
echo
log "summary: $SUMMARY"
