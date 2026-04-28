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

source "${REPO_ROOT}/scripts/lib/nemoclaw-cli.sh"

load_env_file .env

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-openclaw}"
MODE="${1:-}"

ensure_nemoclaw_cli
command -v docker   >/dev/null 2>&1 || die "Docker not found."
docker info >/dev/null 2>&1         || die "Docker is not running. Start Docker and retry."

# Sync agent workspace files from OPENCLAW_AGENTS_DIR each run so edits
# to identity/soul/tools files are picked up without re-onboarding.
sync_agent_workspaces() {
  local agents_dir="${OPENCLAW_AGENTS_DIR:-}"
  [[ -n "$agents_dir" && -d "$agents_dir" ]] || return 0
  local config_dir="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
  for agent_dir in "$agents_dir"/*/; do
    local agent_id
    agent_id="$(basename "$agent_dir")"
    local src="${agent_dir}workspace"
    local dst="${config_dir}/workspace-${agent_id}"
    if [[ -d "$src" ]]; then
      mkdir -p "$dst"
      rsync -a --delete "$src/" "$dst/" 2>/dev/null \
        || cp -r "$src"/* "$dst/"
      log "Synced agent '${agent_id}' workspace -> ${dst}"
    fi
  done
}
sync_agent_workspaces

prepare_onboard_environment

case "$MODE" in
  --onboard)
    log "Launching NemoClaw onboard wizard..."
    # shellcheck disable=SC2046
    nemoclaw onboard $(build_onboard_flags_from_env)
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
      if [[ "${NEMOCLAW_NON_INTERACTIVE:-}" == "1" ]]; then
        log "No sandbox found. Starting non-interactive onboard (driven by .env)..."
      else
        log "No sandbox found. Launching NemoClaw onboard wizard..."
        log "The wizard will prompt for inference provider, model, policy tier,"
        log "and optional messaging channels (Telegram, Discord, Slack)."
        log ""
      fi
      # shellcheck disable=SC2046
      nemoclaw onboard $(build_onboard_flags_from_env)
    fi
    ;;
esac