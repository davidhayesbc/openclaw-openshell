#!/usr/bin/env bash
# =============================================================================
# update.sh -- Update NemoClaw CLI and upgrade sandbox images
# =============================================================================
# Usage:
#   scripts/update.sh              # Update CLI + upgrade stale sandboxes
#   scripts/update.sh --check      # Check for stale sandbox images (no changes)
#   scripts/update.sh --cli        # Update NemoClaw CLI only
#   scripts/update.sh --sandboxes  # Upgrade sandbox images only
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[update] $*"; }
warn() { echo "[update] WARN: $*" >&2; }
die()  { echo "[update] ERROR: $*" >&2; exit 1; }

load_env() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  # Strip CRLF line endings so .env works in WSL/bash.
  set -o allexport
  # shellcheck disable=SC1090
  source <(sed 's/\r$//' "$env_file") 2>/dev/null || true
  set +o allexport
}

repair_nemoclaw() {
  warn "NemoClaw command is installed but not runnable. Attempting repair..."
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.nvm/nvm.sh"
  fi
  hash -r
}

ensure_nemoclaw() {
  command -v nemoclaw >/dev/null 2>&1 || die "NemoClaw not installed. Run scripts/install.sh first."
  if ! nemoclaw --version >/dev/null 2>&1; then
    repair_nemoclaw
    nemoclaw --version >/dev/null 2>&1 || die "NemoClaw is still not runnable after repair."
  fi
}

load_env .env

MODE="${1:---all}"

update_cli() {
  ensure_nemoclaw
  log "Current NemoClaw: $(nemoclaw --version 2>/dev/null || echo 'unknown')"
  log "Updating NemoClaw CLI..."
  # Re-source nvm if available
  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.nvm/nvm.sh"
  fi
  npm install -g nemoclaw@latest
  hash -r
  if ! nemoclaw --version >/dev/null 2>&1; then
    repair_nemoclaw
  fi
  log "Updated to: $(nemoclaw --version 2>/dev/null || echo 'unknown')"
}

upgrade_sandboxes() {
  ensure_nemoclaw
  log "Checking for sandbox image updates..."
  nemoclaw upgrade-sandboxes
}

case "$MODE" in
  --check)
    ensure_nemoclaw
    log "Checking for stale sandbox images (no changes will be made)..."
    nemoclaw upgrade-sandboxes --check
    ;;
  --cli)
    update_cli
    ;;
  --sandboxes)
    upgrade_sandboxes
    ;;
  --all)
    update_cli
    log ""
    upgrade_sandboxes
    ;;
  *)
    echo "[update] Unknown mode: $MODE"
    echo "Usage: $0 [--check|--cli|--sandboxes|--all]"
    exit 1
    ;;
esac