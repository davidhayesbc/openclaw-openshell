#!/usr/bin/env bash
# =============================================================================
# stop.sh -- Manage the NemoClaw-managed OpenClaw sandbox lifecycle
# =============================================================================
# NemoClaw sandboxes run persistently inside OpenShell's embedded k3s cluster.
# Disconnecting from the sandbox (exiting 'nemoclaw <name> connect') leaves the
# sandbox running in the background; that is the expected operating mode.
#
# Usage:
#   scripts/stop.sh               # Show status and help
#   scripts/stop.sh --snapshot    # Take a workspace snapshot
#   scripts/stop.sh --destroy     # Destroy sandbox (irreversible, prompts first)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[stop] $*"; }
warn() { echo "[stop] WARN: $*" >&2; }
die()  { echo "[stop] ERROR: $*" >&2; exit 1; }

if [[ -f .env ]]; then
  set -o allexport; source .env 2>/dev/null || true; set +o allexport
fi

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-openclaw}"
MODE="${1:-}"

command -v nemoclaw >/dev/null 2>&1 || die "NemoClaw not installed. Run scripts/install.sh first."

case "$MODE" in
  --destroy)
    warn "This permanently deletes sandbox '${SANDBOX_NAME}' and all workspace files."
    warn "Run 'scripts/stop.sh --snapshot' first to preserve workspace state."
    nemoclaw "${SANDBOX_NAME}" destroy
    ;;
  --snapshot)
    log "Creating workspace snapshot for sandbox '${SANDBOX_NAME}'..."
    nemoclaw "${SANDBOX_NAME}" snapshot create
    log "Snapshot created. List snapshots: nemoclaw ${SANDBOX_NAME} snapshot list"
    ;;
  *)
    log "Sandbox '${SANDBOX_NAME}' status:"
    nemoclaw "${SANDBOX_NAME}" status 2>/dev/null || log "(sandbox not running)"
    log ""
    log "NemoClaw sandboxes run persistently. To exit an active session, type"
    log "'exit' or '/exit' inside the sandbox shell."
    log ""
    log "Options:"
    log "  scripts/stop.sh --snapshot   Create a workspace snapshot"
    log "  scripts/stop.sh --destroy    Destroy the sandbox (irreversible)"
    ;;
esac