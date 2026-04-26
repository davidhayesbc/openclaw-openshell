#!/usr/bin/env bash
# =============================================================================
# start.sh — Start OpenClaw inside an OpenShell sandbox
# =============================================================================
# Usage:
#   scripts/start.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[start] $*"; }
die()  { echo "[start] ERROR: $*" >&2; exit 1; }

if [[ $# -gt 0 ]]; then
  die "Unsupported arguments: $*. Use scripts/start.sh with no arguments."
fi

# Load environment
if [[ ! -f .env ]]; then
  die ".env not found. Run scripts/install.sh first."
fi
set -o allexport
source .env
set +o allexport

# Validate env
log "Validating environment..."
scripts/validate-env.sh

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

command -v openshell >/dev/null 2>&1 || die "OpenShell CLI not found. Run scripts/install.sh first."

# Check if sandbox already running
if openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}"; then
  log "Sandbox '${SANDBOX_NAME}' is already running."
  log "Connect:  openshell sandbox connect ${SANDBOX_NAME}"
  log "Monitor:  scripts/monitor.sh"
  exit 0
fi

log "Creating OpenClaw sandbox '${SANDBOX_NAME}' in OpenShell..."
log "(This downloads the community sandbox image on first run)"
log ""

# Create sandbox with:
# --forward: forward the gateway port to host loopback
# --from openclaw: use the official OpenClaw community sandbox image
# --policy: apply the base (minimal) network policy immediately
openshell sandbox create \
  --name "${SANDBOX_NAME}" \
  --forward "${GATEWAY_PORT}" \
  --from openclaw \
  --policy "policies/base-policy.yaml" \
  -- openclaw-start

log ""
log "============================================================"
log "OpenClaw is running in an OpenShell sandbox!"
log ""
log "Control UI:  http://127.0.0.1:${GATEWAY_PORT}/"
log "Health:      curl http://127.0.0.1:${GATEWAY_PORT}/healthz"
log ""
log "Apply base (minimal) policy — already applied at creation."
log "To extend policy:  openshell policy set ${SANDBOX_NAME} --policy policies/extended-policy.yaml --wait"
log "To revert:         openshell policy set ${SANDBOX_NAME} --policy policies/base-policy.yaml --wait"
log ""
log "Monitor:   scripts/monitor.sh"
log "Audit:     scripts/audit.sh"
log "Stop:      scripts/stop.sh"
log "============================================================"
