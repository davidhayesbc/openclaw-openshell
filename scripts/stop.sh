#!/usr/bin/env bash
# =============================================================================
# stop.sh — Stop OpenClaw OpenShell sandbox
# =============================================================================
# Usage:
#   scripts/stop.sh
#
# Stops (in order):
#   1. The openclaw gateway (kills the persistent exec session host process)
#   2. The SSH port forward (kills the ssh -N -L tunnel host process)
#   3. The OpenShell sandbox pod
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[stop] $*"; }
warn() { echo "[stop] WARN: $*" >&2; }

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
SSH_FWD_PID_FILE="/tmp/openclaw-ssh-fwd.pid"
GW_EXEC_PID_FILE="/tmp/openclaw-gw-exec.pid"

# ---------------------------------------------------------------------------
# Kill the gateway exec session (host-side openshell sandbox exec process)
# Terminating this process closes the SSH exec session → gateway is killed
# ---------------------------------------------------------------------------
if [[ -f "${GW_EXEC_PID_FILE}" ]]; then
  GW_PID=$(cat "${GW_EXEC_PID_FILE}")
  if kill -0 "${GW_PID}" 2>/dev/null; then
    log "Stopping gateway (exec session PID ${GW_PID})..."
    kill "${GW_PID}" 2>/dev/null || warn "Could not kill PID ${GW_PID}"
    sleep 1
  else
    log "Gateway exec session PID ${GW_PID} already gone."
  fi
  rm -f "${GW_EXEC_PID_FILE}"
else
  log "No gateway PID file found (may already be stopped)."
fi

# ---------------------------------------------------------------------------
# Kill the SSH port forward
# ---------------------------------------------------------------------------
if [[ -f "${SSH_FWD_PID_FILE}" ]]; then
  SSH_PID=$(cat "${SSH_FWD_PID_FILE}")
  if kill -0 "${SSH_PID}" 2>/dev/null; then
    log "Stopping SSH port forward (PID ${SSH_PID})..."
    kill "${SSH_PID}" 2>/dev/null || warn "Could not kill PID ${SSH_PID}"
  else
    log "SSH forward PID ${SSH_PID} already gone."
  fi
  rm -f "${SSH_FWD_PID_FILE}"
fi
rm -f /tmp/openclaw-ssh.conf

# ---------------------------------------------------------------------------
# Delete the sandbox pod
# ---------------------------------------------------------------------------
command -v openshell >/dev/null 2>&1 || { warn "OpenShell not found; sandbox may still be running."; exit 1; }

log "Deleting OpenShell sandbox '${SANDBOX_NAME}'..."
openshell sandbox delete "${SANDBOX_NAME}" 2>/dev/null \
  && log "Sandbox deleted." \
  || log "Sandbox not found or already deleted."

log "Done."
