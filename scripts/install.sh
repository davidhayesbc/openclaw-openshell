#!/usr/bin/env bash
# =============================================================================
# install.sh — One-time setup for OpenShell CLI and OpenClaw
# =============================================================================
# Run this once on a new machine. Idempotent — safe to re-run.
#
# What it does:
#   1. Validates prerequisites (Docker)
#   2. Installs the OpenShell CLI (pinned version)
#   3. Pulls the published OpenClaw sandbox image
#   4. Creates required local directories for OpenClaw data
#   5. Copies config template if not already present
#   6. Optionally sets up git pre-commit hooks (gitleaks)
#
# Supported: Linux, macOS. On Windows use WSL2.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f .env ]]; then
  set -o allexport
  source .env 2>/dev/null || true
  set +o allexport
fi

OPENSHELL_VERSION="${OPENSHELL_VERSION:-latest}"
OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-ghcr.io/nvidia/openshell-community/sandboxes/openclaw:latest}"

log()  { echo "[install] $*"; }
warn() { echo "[install] WARN: $*" >&2; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

# --- 1. Check prerequisites ---
log "Checking prerequisites..."

command -v docker  >/dev/null 2>&1 || die "Docker is not installed. Install Docker Desktop or Docker Engine first."
docker info >/dev/null 2>&1        || die "Docker daemon is not running. Start Docker Desktop or 'sudo systemctl start docker'."

log "Docker: $(docker --version)"

# --- 2. Install OpenShell CLI ---
log ""
log "Installing OpenShell CLI (version: ${OPENSHELL_VERSION})..."

if command -v openshell >/dev/null 2>&1; then
  CURRENT_VERSION=$(openshell --version 2>/dev/null || echo "unknown")
  log "OpenShell already installed: $CURRENT_VERSION"
  log "To update, run: scripts/update.sh"
else
  if [[ "$OPENSHELL_VERSION" == "latest" ]]; then
    curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
  else
    OPENSHELL_VERSION="$OPENSHELL_VERSION" \
      curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
  fi
  log "OpenShell installed: $(openshell --version 2>/dev/null || echo 'installed')"
fi

# --- 3. Pull OpenClaw image ---
log ""
log "Pulling OpenClaw sandbox image: ${OPENCLAW_IMAGE}"
docker pull "$OPENCLAW_IMAGE"

# --- 4. Create OpenClaw data directories ---
log ""
log "Creating OpenClaw data directories..."

OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"

mkdir -p "$OPENCLAW_CONFIG_DIR"
mkdir -p "$OPENCLAW_WORKSPACE_DIR"
chmod 700 "$OPENCLAW_CONFIG_DIR"    # owner-only access
chmod 700 "$OPENCLAW_WORKSPACE_DIR"

log "Config dir:     $OPENCLAW_CONFIG_DIR"
log "Workspace dir:  $OPENCLAW_WORKSPACE_DIR"

# --- 5. Create config/openclaw.json from example if not present ---
if [[ ! -f config/openclaw.json ]]; then
  cp config/openclaw.example.json config/openclaw.json
  log "Created config/openclaw.json from config/openclaw.example.json"
  warn "Edit config/openclaw.json — add your Telegram/Discord user IDs etc."
else
  log "config/openclaw.json already exists (not overwriting)"
fi

# --- 6. Set up .env ---
log ""
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env 2>/dev/null || true
  log "Created .env from .env.example — EDIT IT BEFORE STARTING"
  warn "Fill in your API keys and token in .env before running start.sh"
else
  log ".env already exists"
fi

# --- 7. Optional: git pre-commit hooks ---
log ""
if command -v pre-commit >/dev/null 2>&1; then
  log "Installing git pre-commit hooks (gitleaks secret scanner)..."
  pre-commit install
  log "Pre-commit hooks installed."
else
  log "Tip: Install gitleaks pre-commit hooks to prevent accidental secret commits:"
  log "  pip install pre-commit && pre-commit install"
  log "  (pre-commit config is in .pre-commit-config.yaml)"
fi

# --- Done ---
log ""
log "============================================================"
log "Setup complete!"
log ""
log "Next steps:"
log "  1. Edit .env with your API keys and a strong gateway token:"
log "       openssl rand -hex 32   (for OPENCLAW_GATEWAY_TOKEN)"
log "  2. Validate your .env:"
log "       scripts/validate-env.sh"
log "  3. Start OpenClaw:"
log "       scripts/start.sh"
log "  4. Monitor:"
log "       scripts/monitor.sh"
log "============================================================"
