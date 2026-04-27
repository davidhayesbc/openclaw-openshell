#!/usr/bin/env bash
# =============================================================================
# update.sh — Update OpenShell CLI and OpenClaw image
# =============================================================================
# Safely updates components with version awareness:
#   - Checks current versions before upgrading
#   - Warns if OPENSHELL_VERSION is pinned to a specific version
#   - Rebuilds Docker image from cloned source
#   - Restarts services after update
#
# Usage:
#   scripts/update.sh              # Update all components
#   scripts/update.sh --check      # Check for updates (no changes)
#   scripts/update.sh --openshell  # Update OpenShell CLI only
#   scripts/update.sh --openclaw   # Update OpenClaw image only
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:---all}"

log()  { echo "[update] $*"; }
warn() { echo "[update] WARN: $*" >&2; }

if [[ -f .env ]]; then
  set -o allexport
  source .env 2>/dev/null || true
  set +o allexport
fi

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"
OPENSHELL_VERSION="${OPENSHELL_VERSION:-latest}"

update_openshell() {
  if ! command -v openshell >/dev/null 2>&1; then
    warn "OpenShell not installed — run scripts/install.sh first"
    return
  fi

  CURRENT=$(openshell --version 2>/dev/null || echo "unknown")
  log "Current OpenShell version: $CURRENT"

  if [[ "$OPENSHELL_VERSION" != "latest" ]]; then
    warn "OPENSHELL_VERSION is pinned to '$OPENSHELL_VERSION' in .env"
    warn "Review the release notes before changing the pin: https://github.com/NVIDIA/OpenShell/releases"
    read -r -p "[update] Proceed with update to ${OPENSHELL_VERSION}? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log "Skipping OpenShell update."; return; }
  fi

  log "Updating OpenShell CLI..."
  if command -v uv >/dev/null 2>&1; then
    uv tool install -U openshell
  else
    OPENSHELL_VERSION="$OPENSHELL_VERSION" \
      curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
  fi
  log "Updated to: $(openshell --version 2>/dev/null || echo 'unknown')"
}

update_openclaw() {
  if [[ ! -d _openclaw-src ]]; then
    log "Cloning openclaw/openclaw..."
    git clone https://github.com/openclaw/openclaw.git _openclaw-src
  else
    log "Pulling latest openclaw/openclaw..."
    git -C _openclaw-src fetch origin
    git -C _openclaw-src checkout main 2>/dev/null || git -C _openclaw-src checkout -B main origin/main
    git -C _openclaw-src reset --hard origin/main
  fi

  log "Rebuilding openclaw:local image..."
  docker build -t openclaw:local _openclaw-src

  if command -v openshell >/dev/null 2>&1 && \
     openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}"; then
    log "Note: OpenShell sandbox is running. Recreate it to pick up the new image:"
    log "  scripts/stop.sh && scripts/start.sh"
  fi

  log "OpenClaw updated."
}

check_only() {
  log "=== Update check (read-only) ==="

  log "OpenShell: $(openshell --version 2>/dev/null || echo 'not installed')"
  LATEST_OS=$(curl -sS "https://api.github.com/repos/NVIDIA/OpenShell/releases/latest" | \
    grep '"tag_name"' | cut -d'"' -f4 2>/dev/null || echo "unknown")
  log "OpenShell latest release: $LATEST_OS"

  OPENCLAW_IMG=$(docker image inspect openclaw:local --format '{{.Created}}' 2>/dev/null || echo "not built")
  log "openclaw:local image created: $OPENCLAW_IMG"
  LATEST_CLAW=$(git -C _openclaw-src rev-parse --short HEAD 2>/dev/null || echo "not cloned")
  log "openclaw/openclaw local HEAD: $LATEST_CLAW"
}

case "$MODE" in
  --check)     check_only ;;
  --openshell) update_openshell ;;
  --openclaw)  update_openclaw ;;
  --all)
    log "Updating all components..."
    update_openshell
    echo ""
    update_openclaw
    log "Update complete."
    ;;
  *)
    echo "Usage: $0 [--all|--check|--openshell|--openclaw]"
    exit 1
    ;;
esac
