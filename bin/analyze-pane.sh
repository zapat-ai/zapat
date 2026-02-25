#!/usr/bin/env bash
# Zapat — CLI wrapper for pane analysis
# Analyzes a single tmux pane and outputs JSON with state info.
# Usage: analyze-pane.sh <window.pane> [phase] [job_context]
# Example: analyze-pane.sh "work-myrepo-42.0" "monitoring" "implementing issue #42"
# Output: {"state":"working","keys":"","reason":"..."}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/pane-analyzer.sh"

PANE_TARGET="${1:-}"
PHASE="${2:-monitoring}"
JOB_CONTEXT="${3:-health check}"

if [[ -z "$PANE_TARGET" ]]; then
    echo '{"state":"error","keys":"","reason":"No pane target specified"}'
    exit 1
fi

# Fast-path: check if actively working
fast_result=$(_pane_is_active "$PANE_TARGET" "")
activity=$(echo "$fast_result" | head -1)

if [[ "$activity" == "active" ]]; then
    echo '{"state":"working","keys":"","reason":"Fast-path: spinner or content change detected"}'
    exit 0
fi

# Slow path: ask Haiku
analyze_pane "$PANE_TARGET" "$PHASE" "$JOB_CONTEXT"
