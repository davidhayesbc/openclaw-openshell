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
if [[ -z "${OLD_TOKEN}" ]]; then
  log "No existing gateway token was found in .env"
else
  log "Existing gateway token found in .env"
fi
echo ""
read -r -p "[rotate] Apply new token and restart gateway? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { log "Aborted."; exit 0; }

# Update .env (portable across GNU/BSD systems)
TMP_ENV=$(mktemp)
awk -v token="$NEW_TOKEN" '
  BEGIN { updated=0 }
  /^OPENCLAW_GATEWAY_TOKEN=/ {
    print "OPENCLAW_GATEWAY_TOKEN=" token
    updated=1
    next
  }
  { print }
  END {
    if (!updated) {
      print "OPENCLAW_GATEWAY_TOKEN=" token
    }
  }
' .env > "$TMP_ENV"
mv "$TMP_ENV" .env
chmod 600 .env 2>/dev/null || true

log "Token updated in .env"

# Restart to apply
if command -v openshell >/dev/null 2>&1 && \
   openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}"; then
  log "Restarting OpenShell sandbox..."
  scripts/stop.sh
  scripts/start.sh
else
  log "OpenShell sandbox is not currently running."
  log "Start it with scripts/start.sh to apply the new token."
fi

log "Token rotation complete."
log "Update any connected clients (Telegram, Discord bots) with the new token if needed."
