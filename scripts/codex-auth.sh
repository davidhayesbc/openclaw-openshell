#!/usr/bin/env bash
# =============================================================================
# codex-auth.sh — Authenticate Codex CLI with ChatGPT (device auth flow)
# =============================================================================
# Run once after scripts/start.sh to link your ChatGPT Plus/Pro/Teams account.
#
# How it works:
#   1. Codex CLI requests a device code and prints a short URL + user code
#   2. You open the URL in any browser, enter the code, and approve access
#   3. The sandbox polls until you approve, then receives OAuth tokens
#   4. Tokens are saved to ~/.codex/auth.json inside the sandbox
#
# After authentication, agents can use GPT-5 via:
#   codex -q "your task here"
#
# To re-authenticate (token expired or account changed):
#   scripts/codex-auth.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[codex-auth] $*"; }
die()  { echo "[codex-auth] ERROR: $*" >&2; exit 1; }

[[ -f .env ]] || die ".env not found. Run scripts/install.sh first."
set -o allexport; source .env; set +o allexport

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"

command -v openshell >/dev/null 2>&1 \
  || die "OpenShell CLI not found. Run scripts/install.sh first."

openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}" \
  || die "Sandbox '${SANDBOX_NAME}' is not running. Run scripts/start.sh first."

openshell sandbox exec --name "${SANDBOX_NAME}" -- bash -lc 'command -v codex >/dev/null 2>&1' \
  || die "Codex CLI not found in sandbox. Run scripts/start.sh to install it."

log "Starting ChatGPT device authorization..."
log "A verification URL and code will appear below."
log "Open the URL in any browser and approve access to your ChatGPT account."
log ""

openshell sandbox exec --name "${SANDBOX_NAME}" -- codex login --device-auth

log ""
log "Done! Credentials saved to ~/.codex/auth.json in the sandbox."
log ""
log "Agents can now use GPT-5 via the Codex CLI:"
log "  codex exec --skip-git-repo-check 'your task here'"
log ""
log "To verify: openshell sandbox exec --name ${SANDBOX_NAME} -- codex exec --skip-git-repo-check 'say hello'"
