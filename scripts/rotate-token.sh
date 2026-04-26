#!/usr/bin/env bash
# =============================================================================
# rotate-token.sh — Safely rotate the OpenClaw gateway token
# =============================================================================
# Generates a new token, updates .env, and restarts the gateway.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[rotate] $*"; }
die()  { echo "[rotate] ERROR: $*" >&2; exit 1; }

[[ -f .env ]] || die ".env not found"

command -v openssl >/dev/null 2>&1 || die "openssl not found"

if [[ -f .env ]]; then
  set -o allexport
  source .env 2>/dev/null || true
  set +o allexport
fi

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"
OLD_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
NEW_TOKEN=$(openssl rand -hex 32)

log "Generating new gateway token..."
log "Old token (last 8 chars): ...${OLD_TOKEN: -8}"
log "New token (last 8 chars): ...${NEW_TOKEN: -8}"
echo ""
read -r -p "[rotate] Apply new token and restart gateway? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

# Update .env
if grep -q "^OPENCLAW_GATEWAY_TOKEN=" .env; then
  sed -i "s/^OPENCLAW_GATEWAY_TOKEN=.*/OPENCLAW_GATEWAY_TOKEN=${NEW_TOKEN}/" .env
else
  echo "OPENCLAW_GATEWAY_TOKEN=${NEW_TOKEN}" >> .env
fi

log "Token updated in .env"

# Restart to apply
if command -v openshell >/dev/null 2>&1 && \
   openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}"; then
  log "Restarting OpenShell sandbox..."
  scripts/stop.sh
  scripts/start.sh
elif docker compose ps --services --status running 2>/dev/null | grep -q "openclaw-gateway"; then
  log "Restarting Docker Compose gateway..."
  docker compose restart openclaw-gateway
fi

log "Token rotation complete."
log "Update any connected clients (Telegram, Discord bots) with the new token if needed."
