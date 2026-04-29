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

source "${REPO_ROOT}/scripts/lib/nemoclaw-cli.sh"

load_env_file .env

# --- 1. Check prerequisites ---
log "Checking prerequisites..."
command -v docker >/dev/null 2>&1 || die "Docker is not installed. Install Docker Desktop or Docker Engine first."
docker info >/dev/null 2>&1        || die "Docker daemon is not running. Start Docker and retry."
log "Docker: $(docker --version)"

# --- 2. Install NemoClaw ---
if command -v nemoclaw >/dev/null 2>&1 && is_real_nemoclaw_cli "$(command -v nemoclaw)"; then
  log "NemoClaw already installed: $(nemoclaw --version 2>/dev/null || echo 'installed')"
  log "To upgrade, run: scripts/update.sh"
else
  if command -v nemoclaw >/dev/null 2>&1; then
    warn "Found an invalid/non-NemoClaw 'nemoclaw' binary on PATH. Repairing..."
    repair_nemoclaw_cli
  fi

  log ""
  log "Installing NemoClaw via official installer..."
  log "Installs Node.js (via nvm) and prepares NemoClaw dependencies. No sudo required."
  log ""
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
  # Ensure the runnable CLI is the real NemoClaw binary and local source patch is present.
  if command -v nemoclaw >/dev/null 2>&1 && is_real_nemoclaw_cli "$(command -v nemoclaw)"; then
    ensure_nemoclaw_cli
    log "NemoClaw installed: $(nemoclaw --version 2>/dev/null || echo 'ok')"
  else
    warn "Installer did not leave a runnable NemoClaw CLI in this shell. Repairing from GitHub source..."
    repair_nemoclaw_cli
    log "NemoClaw installed: $(nemoclaw --version 2>/dev/null || echo 'ok')"
  fi
fi

# --- 3. Stage committed OpenClaw config into ~/.openclaw/openclaw.json ---
# NemoClaw snapshots this during 'nemoclaw onboard' as the base agent config.
sync_committed_openclaw_config_to_host "$REPO_ROOT"

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
