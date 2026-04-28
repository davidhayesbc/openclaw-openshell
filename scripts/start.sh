#!/usr/bin/env bash
# =============================================================================
# start.sh -- Onboard or connect to OpenClaw via NemoClaw
# =============================================================================
# First run:   Launches 'nemoclaw onboard' (guided setup wizard). The wizard
#              creates the OpenShell gateway, sandbox, and inference routing.
# Subsequent:  Connects to the running sandbox via 'nemoclaw <name> connect'.
#
# Usage:
#   scripts/start.sh              # auto-detect: onboard or connect
#   scripts/start.sh --onboard    # force re-onboard (recreates sandbox)
#   scripts/start.sh --connect    # connect to existing sandbox only
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[start] $*"; }
die()  { echo "[start] ERROR: $*" >&2; exit 1; }

if [[ -f .env ]]; then
  set -o allexport; source .env; set +o allexport
fi

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-openclaw}"
MODE="${1:-}"

command -v nemoclaw >/dev/null 2>&1 || die "NemoClaw not installed. Run scripts/install.sh first."
command -v docker   >/dev/null 2>&1 || die "Docker not found."
docker info >/dev/null 2>&1         || die "Docker is not running. Start Docker and retry."

# Forward optional messaging tokens from .env to nemoclaw onboard
[[ -n "${TELEGRAM_BOT_TOKEN:-}"   ]] && export TELEGRAM_BOT_TOKEN
[[ -n "${TELEGRAM_ALLOWED_IDS:-}" ]] && export TELEGRAM_ALLOWED_IDS
[[ -n "${DISCORD_BOT_TOKEN:-}"    ]] && export DISCORD_BOT_TOKEN

case "$MODE" in
  --onboard)
    log "Launching NemoClaw onboard wizard..."
    nemoclaw onboard
    ;;
  --connect)
    log "Connecting to sandbox '${SANDBOX_NAME}'..."
    nemoclaw "${SANDBOX_NAME}" connect
    ;;
  *)
    # Auto-detect: onboard if sandbox does not exist, otherwise connect
    if nemoclaw "${SANDBOX_NAME}" status >/dev/null 2>&1; then
      log "Sandbox '${SANDBOX_NAME}' found. Connecting..."
      nemoclaw "${SANDBOX_NAME}" connect
    else
      log "No sandbox found. Launching NemoClaw onboard wizard..."
      log "The wizard will prompt for inference provider, model, policy tier,"
      log "and optional messaging channels (Telegram, Discord, Slack)."
      log ""
      nemoclaw onboard
    fi
    ;;
esac