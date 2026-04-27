#!/bin/bash
set -e

# Compare two benchmark result files.
#
# Usage: ./compare.sh RESULT_FILE_A RESULT_FILE_B
#
# Result files are saved by benchmark.sh in logs/results/.
# Example:
#   ./compare.sh logs/results/mode2_a_20260427_143200.txt \
#                logs/results/mode2_b_20260427_144500.txt

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/modes/common.sh"

if [ $# -lt 2 ]; then
    echo "Usage: $0 RESULT_FILE_A RESULT_FILE_B"
    echo ""
    echo "Compare two benchmark result files."
    echo ""
    echo "Available result files:"
    if [ -d "$RESULTS_DIR" ]; then
        ls -1t "$RESULTS_DIR"/*.txt 2>/dev/null | head -10 || echo "  (none)"
    else
        echo "  (no results directory yet)"
    fi
    exit 1
fi

compare_result_files "$1" "$2"
