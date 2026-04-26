#!/usr/bin/env bash
# =============================================================================
# stop.sh — Stop OpenClaw (OpenShell sandbox or Docker Compose)
# =============================================================================
# Usage:
#   scripts/stop.sh              # Stop OpenShell sandbox (default)
#   scripts/stop.sh --compose    # Stop Docker Compose stack
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-openshell}"

log() { echo "[stop] $*"; }

# Load .env for sandbox name
if [[ -f .env ]]; then
  set -o allexport
  source .env 2>/dev/null || true
  set +o allexport
fi

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"

if [[ "$MODE" != "--compose" ]]; then
  command -v openshell >/dev/null 2>&1 || { log "OpenShell not found."; exit 1; }
  log "Stopping OpenShell sandbox '${SANDBOX_NAME}'..."
  openshell sandbox delete "${SANDBOX_NAME}" 2>/dev/null || log "Sandbox not running or already stopped."
  log "Done."
else
  log "Stopping Docker Compose stack..."
  docker compose down
  log "Done."
fi
