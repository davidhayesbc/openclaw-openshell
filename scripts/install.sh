#!/usr/bin/env bash
# =============================================================================
# install.sh — Install NemoClaw (NVIDIA reference stack for OpenClaw)
# =============================================================================
# Installs NemoClaw via the official installer, which handles Node.js (nvm) and
# the nemoclaw npm package. After installation, run scripts/start.sh to onboard.
#
# Usage:
#   scripts/install.sh
#
# Requirements:
#   - Docker installed and running
#   - Internet access
#   - Linux / macOS / WSL2
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[install] $*"; }
warn() { echo "[install] WARN: $*" >&2; }
die()  { echo "[install] ERROR: $*" >&2; exit 1; }

# --- 1. Check prerequisites ---
log "Checking prerequisites..."
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install Docker Desktop or Docker Engine first."
docker info >/dev/null 2>&1        || die "Docker daemon is not running. Start Docker and retry."
log "Docker: $(docker --version)"

# --- 2. Install NemoClaw ---
if command -v nemoclaw >/dev/null 2>&1; then
  log "NemoClaw already installed: $(nemoclaw --version 2>/dev/null || echo 'installed')"
  log "To upgrade, run: scripts/update.sh"
else
  log ""
  log "Installing NemoClaw via official installer..."
  log "Installs Node.js (via nvm) and nemoclaw into user-local directories. No sudo required."
  log ""
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
  # Re-source nvm so nemoclaw is findable in this session
  if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.nvm/nvm.sh"
  fi
  if command -v nemoclaw >/dev/null 2>&1; then
    log "NemoClaw installed: $(nemoclaw --version 2>/dev/null || echo 'ok')"
  else
    log ""
    log "Installation complete. If 'nemoclaw' is not found, reload your shell:"
    log "  source ~/.bashrc    (bash)"
    log "  source ~/.zshrc     (zsh)"
  fi
fi

# --- 3. Seed ~/.openclaw/openclaw.json from repo config ---
# NemoClaw snapshots this during 'nemoclaw onboard' as the base agent config.
if [[ -f .env ]]; then
  set -o allexport; source .env 2>/dev/null || true; set +o allexport
fi
OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
mkdir -p "$OPENCLAW_CONFIG_DIR"
chmod 700 "$OPENCLAW_CONFIG_DIR"

if [[ -f config/openclaw.json ]]; then
  if [[ ! -f "${OPENCLAW_CONFIG_DIR}/openclaw.json" ]]; then
    cp config/openclaw.json "${OPENCLAW_CONFIG_DIR}/openclaw.json"
    log "Copied config/openclaw.json -> ${OPENCLAW_CONFIG_DIR}/openclaw.json"
  else
    log "Existing ${OPENCLAW_CONFIG_DIR}/openclaw.json preserved (not overwritten)."
    log "To replace with the repo config: cp config/openclaw.json ${OPENCLAW_CONFIG_DIR}/openclaw.json"
  fi
fi

# --- 4. Seed agent workspaces ---
# If OPENCLAW_AGENTS_DIR is set, copy each <dir>/<agent-id>/workspace/ into
# ~/.openclaw/workspace-<agent-id>/ so NemoClaw snapshots the right files.
# The coder agent workspace (IDENTITY.md, SOUL.md, etc.) must exist before onboard.
seed_agent_workspaces() {
  local agents_dir="${OPENCLAW_AGENTS_DIR:-}"
  [[ -n "$agents_dir" && -d "$agents_dir" ]] || return 0
  local config_dir="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
  log "Seeding agent workspaces from ${agents_dir}..."
  for agent_dir in "$agents_dir"/*/; do
    local agent_id
    agent_id="$(basename "$agent_dir")"
    local src="${agent_dir}workspace"
    local dst="${config_dir}/workspace-${agent_id}"
    if [[ -d "$src" ]]; then
      mkdir -p "$dst"
      cp -r "$src"/* "$dst/"
      log "  Seeded agent '${agent_id}': ${src} -> ${dst}"
    fi
  done
}
seed_agent_workspaces

# --- 5. Set up .env ---
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env 2>/dev/null || true
  log "Created .env from .env.example"
  warn "Edit .env: set NEMOCLAW_SANDBOX_NAME and any messaging tokens before onboarding."
else
  log ".env already exists"
fi

# --- 5. Optional: git pre-commit hooks ---
if command -v pre-commit >/dev/null 2>&1; then
  pre-commit install
  log "Pre-commit hooks installed (gitleaks secret scanner)."
else
  log "Tip: install pre-commit for secret scanning: pip install pre-commit && pre-commit install"
fi

log ""
log "============================================================"
log "Setup complete!"
log ""
log "Next: run scripts/start.sh to launch the guided onboard wizard."
log "  The wizard sets up inference provider, policy tier, and sandbox."
log "============================================================"
