#!/usr/bin/env bash
# =============================================================================
# monitor.sh -- Monitor OpenClaw sandbox activity via NemoClaw
# =============================================================================
# Usage:
#   scripts/monitor.sh             # OpenShell TUI (live dashboard, default)
#   scripts/monitor.sh --status    # Status snapshot for all sandboxes
#   scripts/monitor.sh --logs      # Stream sandbox logs
#   scripts/monitor.sh --policy    # Show active network policy presets
#   scripts/monitor.sh --debug     # Collect diagnostics tarball
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:---tui}"

if [[ -f .env ]]; then
  set -o allexport; source .env 2>/dev/null || true; set +o allexport
fi

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-openclaw}"

command -v nemoclaw >/dev/null 2>&1 || { echo "[monitor] ERROR: NemoClaw not installed."; exit 1; }

case "$MODE" in
  --tui|-t)
    echo "[monitor] Launching OpenShell TUI (press q to quit)..."
    echo "  Tab = switch panels  |  j/k = navigate  |  Enter = select"
    echo "  Blocked network requests appear here for interactive approval."
    echo ""
    openshell term
    ;;
  --status)
    echo "================================================================"
    echo "NemoClaw + OpenClaw -- Status Snapshot"
    echo "$(date)"
    echo "================================================================"
    echo ""
    echo "--- All sandboxes ---"
    nemoclaw list
    echo ""
    echo "--- Sandbox '${SANDBOX_NAME}' ---"
    nemoclaw "${SANDBOX_NAME}" status 2>/dev/null || echo "(not running)"
    ;;
  --logs|-l)
    echo "[monitor] Streaming logs for '${SANDBOX_NAME}' (Ctrl+C to stop)..."
    nemoclaw "${SANDBOX_NAME}" logs --follow
    ;;
  --policy|-p)
    echo "[monitor] Active policy presets for '${SANDBOX_NAME}':"
    nemoclaw "${SANDBOX_NAME}" policy-list
    ;;
  --debug)
    OUTFILE="/tmp/nemoclaw-debug-$(date +%Y%m%d-%H%M%S).tar.gz"
    echo "[monitor] Collecting diagnostics -> ${OUTFILE}"
    nemoclaw debug --sandbox "${SANDBOX_NAME}" --output "${OUTFILE}"
    echo "[monitor] Diagnostics saved to ${OUTFILE}"
    ;;
  *)
    echo "[monitor] Unknown mode: $MODE"
    echo "Usage: $0 [--tui|--status|--logs|--policy|--debug]"
    exit 1
    ;;
esac