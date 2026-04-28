#!/bin/bash
set -e

# ══════════════════════════════════════════════════════════════════
# TypeDB Benchmark — Environment Setup
# ══════════════════════════════════════════════════════════════════
#
# Usage:
#   ./setup.sh old                    # Setup venv for modes 1 & 2 (pip-installed driver)
#   ./setup.sh new                    # Setup venv for modes 3 & 4 (local driver wheel)
#   ./setup.sh new /path/to/wheel     # Setup with specific wheel file
#   ./setup.sh all                    # Setup both venvs
#
# ══════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venvs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[setup]${NC} $*"; }
error() { echo -e "${RED}[setup]${NC} $*" >&2; }

setup_old_venv() {
    local venv_path="$VENV_DIR/old"
    log "Setting up OLD driver environment: $venv_path"

    rm -rf "$venv_path"
    python3 -m venv "$venv_path"
    source "$venv_path/bin/activate"

    pip install --upgrade pip --quiet
    log "Installing typedb-driver from PyPI..."
    if pip install typedb-driver --quiet; then
        log "Installed: $(pip show typedb-driver 2>/dev/null | grep Version)"
    else
        warn "Latest version failed, trying 3.10.0..."
        pip install typedb-driver==3.10.0 --quiet || {
            error "Could not install typedb-driver. Check PyPI for available versions."
            exit 1
        }
    fi

    deactivate
    log "OLD venv ready: $venv_path"
}

setup_new_venv() {
    local wheel_path="$1"
    local venv_path="$VENV_DIR/new"
    log "Setting up NEW driver environment: $venv_path"

    rm -rf "$venv_path"
    python3 -m venv "$venv_path"
    source "$venv_path/bin/activate"

    pip install --upgrade pip --quiet

    if [ -n "$wheel_path" ] && [ -f "$wheel_path" ]; then
        log "Installing driver from wheel: $wheel_path"
        pip install "$wheel_path" --quiet
    else
        echo ""
        echo -e "${BOLD}The NEW driver must be built locally from cluster-support-feature-branch.${NC}"
        echo ""
        echo "Build steps:"
        echo "  1. cd /path/to/typedb-driver"
        echo "  2. git checkout cluster-support-feature-branch"
        echo "  3. bazel build //python:assemble-pip311    # adjust Python version"
        echo "  4. Find the wheel:  ls bazel-bin/python/*.whl"
        echo "  5. Re-run:  ./setup.sh new /path/to/wheel.whl"
        echo ""

        # Try to find a wheel in common locations
        local search_dirs=(
            "$SCRIPT_DIR/../repositories/typedb-driver/bazel-bin/python"
            "$SCRIPT_DIR/../../typedb-driver/bazel-bin/python"
        )
        local found_wheel=""
        for dir in "${search_dirs[@]}"; do
            if [ -d "$dir" ]; then
                found_wheel=$(ls -t "$dir"/typedb_driver-*.whl 2>/dev/null | head -1)
                if [ -n "$found_wheel" ]; then
                    break
                fi
            fi
        done

        if [ -n "$found_wheel" ]; then
            log "Found wheel: $found_wheel"
            read -rp "Install this wheel? [Y/n] " yn
            if [ "$yn" != "n" ] && [ "$yn" != "N" ]; then
                pip install "$found_wheel" --quiet
                log "Installed: $(pip show typedb-driver 2>/dev/null | grep Version)"
            else
                warn "Skipped. Re-run with:  ./setup.sh new /path/to/wheel.whl"
                deactivate
                return
            fi
        else
            warn "No wheel found. Venv created but driver not installed."
            warn "Install manually:  source $venv_path/bin/activate && pip install /path/to/wheel.whl"
            deactivate
            return
        fi
    fi

    deactivate
    log "NEW venv ready: $venv_path"
}

# ── Create directory structure ────────────────────────────────────

setup_dirs() {
    mkdir -p \
        "$SCRIPT_DIR/bin/mode1" \
        "$SCRIPT_DIR/bin/mode2" \
        "$SCRIPT_DIR/bin/mode3" \
        "$SCRIPT_DIR/bin/mode4" \
        "$SCRIPT_DIR/bin/mode5" \
        "$SCRIPT_DIR/logs/results" \
        "$SCRIPT_DIR/data" \
        "$SCRIPT_DIR/configs/generated" \
        "$VENV_DIR"
}

# ── Main ──────────────────────────────────────────────────────────

setup_dirs

case "${1:-}" in
    old)
        setup_old_venv
        ;;
    new)
        setup_new_venv "${2:-}"
        ;;
    all)
        setup_old_venv
        setup_new_venv "${2:-}"
        ;;
    *)
        echo "TypeDB Benchmark — Environment Setup"
        echo ""
        echo "Usage: $0 {old|new|all} [wheel_path]"
        echo ""
        echo "  old               Setup for modes 1 & 2 (pip install typedb-driver)"
        echo "  new [wheel]       Setup for modes 3, 4, 5 (local driver wheel)"
        echo "  all [wheel]       Setup both environments"
        echo ""
        echo "Current state:"
        if [ -d "$VENV_DIR/old" ]; then
            echo -e "  OLD venv: ${GREEN}exists${NC}"
        else
            echo -e "  OLD venv: ${YELLOW}not set up${NC} (run: ./setup.sh old)"
        fi
        if [ -d "$VENV_DIR/new" ]; then
            echo -e "  NEW venv: ${GREEN}exists${NC}"
        else
            echo -e "  NEW venv: ${YELLOW}not set up${NC} (run: ./setup.sh new)"
        fi
        echo ""
        echo "Binary directories:"
        for m in mode1 mode2 mode3 mode4 mode5; do
            local count
            count=$(ls "$SCRIPT_DIR/bin/$m/" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$count" -gt 0 ]; then
                echo -e "  bin/$m/: ${GREEN}${count} file(s)${NC}"
            else
                echo -e "  bin/$m/: ${YELLOW}empty${NC}"
            fi
        done
        exit 1
        ;;
esac

echo ""
log "Setup complete."
