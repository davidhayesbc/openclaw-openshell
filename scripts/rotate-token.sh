#!/usr/bin/env bash
# =============================================================================
# rotate-token.sh -- Retrieve the OpenClaw gateway token for a sandbox
# =============================================================================
# NemoClaw manages gateway tokens internally; they are not stored in .env.
# Use this script to print the current token (e.g. for the OpenClaw dashboard
# URL or to inject into automation).
#
# Usage:
#   scripts/rotate-token.sh                  # token for default sandbox
#   scripts/rotate-token.sh <sandbox-name>   # token for named sandbox
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f .env ]]; then
  set -o allexport; source .env 2>/dev/null || true; set +o allexport
fi

SANDBOX_NAME="${1:-${NEMOCLAW_SANDBOX_NAME:-openclaw}}"

command -v nemoclaw >/dev/null 2>&1 || { echo "[token] ERROR: NemoClaw not installed."; exit 1; }

echo "[token] Retrieving gateway token for sandbox '${SANDBOX_NAME}'..."
echo "[token] Treat this token like a password. Do not log or commit it."
echo ""
nemoclaw "${SANDBOX_NAME}" gateway-token