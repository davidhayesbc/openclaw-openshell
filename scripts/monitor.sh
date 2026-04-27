#!/usr/bin/env bash
# =============================================================================
# monitor.sh — Unified monitoring dashboard for OpenClaw + OpenShell
# =============================================================================
# Launches multiple views depending on what's running:
#   - openshell term  (TUI dashboard — gateways, sandboxes, providers)
#   - docker stats    (resource usage)
#   - live logs
#
# Usage:
#   scripts/monitor.sh             # OpenShell TUI (default)
#   scripts/monitor.sh --logs      # Tail gateway logs
#   scripts/monitor.sh --stats     # Docker resource stats
#   scripts/monitor.sh --status    # Quick status snapshot (non-interactive)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:---tui}"

if [[ -f .env ]]; then
  set -o allexport
  source .env 2>/dev/null || true
  set +o allexport
fi

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
GW_EXEC_LOG="/tmp/openclaw-gw-exec.log"

case "$MODE" in
  --tui|-t)
    if ! command -v openshell >/dev/null 2>&1; then
      echo "[monitor] ERROR: OpenShell not installed. Run scripts/install.sh first."
      exit 1
    fi
    echo "[monitor] Launching OpenShell TUI (press q to quit)..."
    echo "  Tab = switch panels  |  j/k = navigate  |  Enter = select  |  : = command"
    echo ""
    openshell term
    ;;

  --logs|-l)
    echo "[monitor] Tailing OpenClaw gateway logs (Ctrl+C to stop)..."
    echo ""
    if [[ -f "${GW_EXEC_LOG}" ]]; then
      echo "[monitor] Source: ${GW_EXEC_LOG}"
      tail -f "${GW_EXEC_LOG}"
      exit 0
    fi

    echo "[monitor] WARN: ${GW_EXEC_LOG} not found; falling back to OpenShell sandbox logs."
    if ! command -v openshell >/dev/null 2>&1; then
      echo "[monitor] ERROR: OpenShell not installed. Run scripts/install.sh first."
      exit 1
    fi
    if ! openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}"; then
      echo "[monitor] ERROR: Sandbox '${SANDBOX_NAME}' is not running. Start it with scripts/start.sh."
      exit 1
    fi
    openshell logs "${SANDBOX_NAME}" --tail
    ;;

  --stats|-s)
    echo "[monitor] Docker resource usage (Ctrl+C to stop)..."
    docker stats --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}"
    ;;

  --status)
    echo "================================================================"
    echo "OpenClaw + OpenShell — Status Snapshot"
    echo "$(date)"
    echo "================================================================"
    echo ""

    echo "--- OpenShell ---"
    if command -v openshell >/dev/null 2>&1; then
      openshell status 2>/dev/null || echo "(gateway not running)"
      echo ""
      echo "Sandboxes:"
      openshell sandbox list 2>/dev/null || echo "(none)"
    else
      echo "OpenShell not installed"
    fi

    echo ""
    echo "--- Docker ---"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "(docker not running)"

    echo ""
    echo "--- Health Check ---"
    if curl -fsS "http://127.0.0.1:${GATEWAY_PORT}/healthz" >/dev/null 2>&1; then
      echo "Gateway health: OK (http://127.0.0.1:${GATEWAY_PORT}/healthz)"
    else
      echo "Gateway health: UNREACHABLE (is it running?)"
    fi

    echo ""
    echo "--- Policies (OpenShell) ---"
    if command -v openshell >/dev/null 2>&1; then
      openshell policy get "${SANDBOX_NAME}" 2>/dev/null || echo "(no active policy or sandbox not running)"
    fi
    ;;

  *)
    echo "Usage: $0 [--tui|--logs|--stats|--status]"
    echo "  --tui     OpenShell terminal UI dashboard (default)"
    echo "  --logs    Tail live gateway logs"
    echo "  --stats   Docker resource usage"
    echo "  --status  Quick non-interactive status snapshot"
    exit 1
    ;;
esac
