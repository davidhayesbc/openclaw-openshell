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

if [[ -f .env ]]; then
  set -o allexport; source .env 2>/dev/null || true; set +o allexport
fi

MODE="${1:---all}"

update_cli() {
  if ! command -v nemoclaw >/dev/null 2>&1; then
    warn "NemoClaw not installed -- run scripts/install.sh first"
    return
  fi
  log "Current NemoClaw: $(nemoclaw --version 2>/dev/null || echo 'unknown')"
  log "Updating NemoClaw CLI..."
  # Re-source nvm if available
  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.nvm/nvm.sh"
  fi
  npm install -g nemoclaw@latest
  log "Updated to: $(nemoclaw --version 2>/dev/null || echo 'unknown')"
}

upgrade_sandboxes() {
  log "Checking for sandbox image updates..."
  nemoclaw upgrade-sandboxes
}

case "$MODE" in
  --check)
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