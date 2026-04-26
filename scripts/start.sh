#!/usr/bin/env bash
# =============================================================================
# start.sh — Start OpenClaw inside an OpenShell sandbox (recommended path)
#            OR via Docker Compose (fallback path)
# =============================================================================
# Usage:
#   scripts/start.sh             # OpenShell sandbox path (default, most secure)
#   scripts/start.sh --compose   # Docker Compose path
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-openshell}"   # "openshell" or "--compose"

log()  { echo "[start] $*"; }
die()  { echo "[start] ERROR: $*" >&2; exit 1; }

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

# =============================================================================
# Path A: OpenShell sandbox (recommended — hardware-enforced security)
# =============================================================================
if [[ "$MODE" != "--compose" ]]; then
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

# =============================================================================
# Path B: Docker Compose (fallback — no OpenShell runtime hardening)
# =============================================================================
else
  command -v docker >/dev/null 2>&1 || die "Docker not found."

  OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
  OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"
  mkdir -p "$OPENCLAW_CONFIG_DIR" "$OPENCLAW_WORKSPACE_DIR"
  chmod 700 "$OPENCLAW_CONFIG_DIR" "$OPENCLAW_WORKSPACE_DIR"

  # Copy latest config
  cp config/openclaw.json "$OPENCLAW_CONFIG_DIR/openclaw.json"
  log "Copied openclaw.json to $OPENCLAW_CONFIG_DIR"

  # Check image exists
  if ! docker image inspect "${OPENCLAW_IMAGE:-openclaw:local}" >/dev/null 2>&1; then
    log "openclaw:local image not found. Building from source..."
    if [[ ! -d _openclaw-src ]]; then
      git clone https://github.com/openclaw/openclaw.git _openclaw-src
    else
      log "_openclaw-src already cloned — using existing (run 'git pull' to update)"
    fi
    docker build -t openclaw:local _openclaw-src
  fi

  log "Starting OpenClaw via Docker Compose..."
  docker compose up -d openclaw-gateway

  log ""
  log "============================================================"
  log "OpenClaw is running via Docker Compose (fallback mode)."
  log "NOTE: For maximum security, use the OpenShell path instead."
  log ""
  log "Control UI:  http://127.0.0.1:${GATEWAY_PORT}/"
  log "Health:      curl http://127.0.0.1:${GATEWAY_PORT}/healthz"
  log ""
  log "Logs:    docker compose logs -f openclaw-gateway"
  log "Audit:   scripts/audit.sh"
  log "Stop:    scripts/stop.sh --compose"
  log "============================================================"
fi
