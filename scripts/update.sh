#!/usr/bin/env bash
# =============================================================================
# update.sh -- Update NemoClaw CLI and upgrade sandbox images
# =============================================================================
# Usage:
#   scripts/update.sh              # Update CLI + upgrade stale sandboxes
#   scripts/update.sh --check      # Check for stale sandbox images (no changes)
#   scripts/update.sh --cli        # Update NemoClaw CLI only
#   scripts/update.sh --sandboxes  # Upgrade sandbox images only
#   scripts/update.sh --fresh      # Start fresh onboarding session
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[update] $*"; }
warn() { echo "[update] WARN: $*" >&2; }
die()  { echo "[update] ERROR: $*" >&2; exit 1; }

source "${REPO_ROOT}/scripts/lib/nemoclaw-cli.sh"

load_env_file .env

MODE="${1:---all}"

update_cli() {
  if command -v nemoclaw >/dev/null 2>&1 && is_real_nemoclaw_cli "$(command -v nemoclaw)"; then
    log "Current NemoClaw: $(nemoclaw --version 2>/dev/null || echo 'unknown')"
  else
    log "Current NemoClaw: unavailable or invalid (will reinstall)"
  fi
  log "Updating NemoClaw CLI..."
  repair_nemoclaw_cli
  log "Updated to: $(nemoclaw --version 2>/dev/null || echo 'unknown')"
}

upgrade_sandboxes() {
  ensure_nemoclaw_cli
  log "Checking for sandbox image updates..."
  nemoclaw upgrade-sandboxes
}

fresh_onboard() {
  ensure_nemoclaw_cli
  sync_agent_workspaces_to_host
  prepare_onboard_environment
  warn "Starting fresh onboarding. Any resumable onboarding session will be discarded."
  # shellcheck disable=SC2046
  nemoclaw onboard --fresh $(build_onboard_flags_from_env)
  local sandbox_name="${NEMOCLAW_SANDBOX_NAME:-openclaw}"
  sync_agent_workspaces_to_sandbox "$sandbox_name"
}

case "$MODE" in
  --check)
    ensure_nemoclaw_cli
    log "Checking for stale sandbox images (no changes will be made)..."
    nemoclaw upgrade-sandboxes --check
    ;;
  --cli)
    update_cli
    ;;
  --sandboxes)
    upgrade_sandboxes
    ;;
  --fresh)
    fresh_onboard
    ;;
  --all)
    update_cli
    log ""
    upgrade_sandboxes
    ;;
  *)
    echo "[update] Unknown mode: $MODE"
    echo "Usage: $0 [--check|--cli|--sandboxes|--fresh|--all]"
    exit 1
    ;;
esac