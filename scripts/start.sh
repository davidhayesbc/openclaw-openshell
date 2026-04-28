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

load_env() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  # Strip CRLF line endings so .env works in WSL/bash.
  set -o allexport
  # shellcheck disable=SC1090
  source <(sed 's/\r$//' "$env_file")
  set +o allexport
}

load_env .env

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-openclaw}"
MODE="${1:-}"

command -v nemoclaw >/dev/null 2>&1 || die "NemoClaw not installed. Run scripts/install.sh first."
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

# Forward optional messaging tokens from .env to nemoclaw onboard
[[ -n "${TELEGRAM_BOT_TOKEN:-}"   ]] && export TELEGRAM_BOT_TOKEN
[[ -n "${TELEGRAM_ALLOWED_IDS:-}" ]] && export TELEGRAM_ALLOWED_IDS
[[ -n "${DISCORD_BOT_TOKEN:-}"    ]] && export DISCORD_BOT_TOKEN

# Forward inference provider vars.
# COMPATIBLE_API_KEY selects the "Other OpenAI-compatible" provider (e.g. OpenRouter).
# If not set but OPENROUTER_API_KEY is, derive it automatically.
if [[ -z "${COMPATIBLE_API_KEY:-}" && -n "${OPENROUTER_API_KEY:-}" ]]; then
  export COMPATIBLE_API_KEY="${OPENROUTER_API_KEY}"
fi
[[ -n "${COMPATIBLE_API_KEY:-}"          ]] && export COMPATIBLE_API_KEY
[[ -n "${NEMOCLAW_INFERENCE_BASE_URL:-}" ]] && export NEMOCLAW_INFERENCE_BASE_URL
[[ -n "${NEMOCLAW_MODEL:-}"              ]] && export NEMOCLAW_MODEL
[[ -n "${NVIDIA_API_KEY:-}"              ]] && export NVIDIA_API_KEY
[[ -n "${OPENAI_API_KEY:-}"              ]] && export OPENAI_API_KEY
[[ -n "${ANTHROPIC_API_KEY:-}"           ]] && export ANTHROPIC_API_KEY
[[ -n "${OLLAMA_BASE_URL:-}"             ]] && export OLLAMA_BASE_URL

# Build onboard flags from env vars so .env can drive a non-interactive run.
build_onboard_flags() {
  local flags=()
  [[ "${NEMOCLAW_NON_INTERACTIVE:-}" == "1" ]] && flags+=("--non-interactive")
  [[ "${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:-}" == "1" ]] && flags+=("--yes-i-accept-third-party-software")
  echo "${flags[@]:-}"
}

case "$MODE" in
  --onboard)
    log "Launching NemoClaw onboard wizard..."
    # shellcheck disable=SC2046
    nemoclaw onboard $(build_onboard_flags)
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
      nemoclaw onboard $(build_onboard_flags)
    fi
    ;;
esac