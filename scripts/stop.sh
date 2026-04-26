#!/usr/bin/env bash
# =============================================================================
# stop.sh — Stop OpenClaw OpenShell sandbox
# =============================================================================
# Usage:
#   scripts/stop.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log() { echo "[stop] $*"; }

if [[ $# -gt 0 ]]; then
  log "ERROR: Unsupported arguments: $*. Use scripts/stop.sh with no arguments."
  exit 1
fi

# Load .env for sandbox name
if [[ -f .env ]]; then
  set -o allexport
  source .env 2>/dev/null || true
  set +o allexport
fi

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"

command -v openshell >/dev/null 2>&1 || { log "OpenShell not found."; exit 1; }
log "Stopping OpenShell sandbox '${SANDBOX_NAME}'..."
openshell sandbox delete "${SANDBOX_NAME}" 2>/dev/null || log "Sandbox not running or already stopped."
log "Done."
