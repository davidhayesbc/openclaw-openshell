#!/usr/bin/env bash
# =============================================================================
# export-config.sh -- Export sanitized OpenClaw config from a running sandbox
# =============================================================================
# Usage:
#   bash scripts/export-config.sh                 # export to committed source path
#   bash scripts/export-config.sh path/to/file    # export to a specific file
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[export-config] $*"; }
die()  { echo "[export-config] ERROR: $*" >&2; exit 1; }

source "${REPO_ROOT}/scripts/lib/nemoclaw-cli.sh"

load_env_file .env

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-openclaw}"
DEST_PATH="${1:-}"

command -v openshell >/dev/null 2>&1 || die "openshell not found."

export_sandbox_openclaw_config "$SANDBOX_NAME" "$REPO_ROOT" "$DEST_PATH"
log "Review and commit the exported config in git."
