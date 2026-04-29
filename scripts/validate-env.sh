#!/usr/bin/env bash
# =============================================================================
# validate-env.sh -- Validate environment for NemoClaw
# =============================================================================
# NemoClaw manages inference credentials in ~/.nemoclaw/credentials.json.
# This script checks runtime prerequisites and optional .env overrides.
# =============================================================================
set -euo pipefail

ENV_FILE="${1:-.env}"
ERRORS=0

normalize_env_file_line_endings() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  if grep -q $'\r' "$env_file" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    sed 's/\r$//' "$env_file" > "$tmp"
    cat "$tmp" > "$env_file"
    rm -f "$tmp"
    echo "INFO: Normalized CRLF to LF in $env_file"
  fi
}

echo "Validating environment for NemoClaw..."
echo ""

# --- Docker ---
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    echo "OK: Docker is running ($(docker --version))"
  else
    echo "FAIL: Docker is installed but not running. Start Docker and retry."
    ERRORS=$((ERRORS + 1))
  fi
else
  echo "FAIL: Docker not installed."
  ERRORS=$((ERRORS + 1))
fi

# --- NemoClaw ---
if command -v nemoclaw >/dev/null 2>&1; then
  echo "OK: NemoClaw $(nemoclaw --version 2>/dev/null || echo 'installed')"
else
  echo "WARN: NemoClaw not installed. Run scripts/install.sh."
fi

# --- Optional .env overrides ---
if [[ -f "$ENV_FILE" ]]; then
  normalize_env_file_line_endings "$ENV_FILE"
  set -o allexport; source "$ENV_FILE" 2>/dev/null || true; set +o allexport

  check_placeholder() {
    local var="$1"
    local value="${!var:-}"
    if [[ -n "$value" ]] && echo "$value" | grep -qiE "REPLACE_WITH|YOUR_KEY|PLACEHOLDER|CHANGE_ME|TODO|EXAMPLE"; then
      echo "PLACEHOLDER: $var still has a placeholder value in $ENV_FILE"
      ERRORS=$((ERRORS + 1))
    elif [[ -n "$value" ]]; then
      echo "OK: $var is set"
    fi
  }

  check_placeholder "TELEGRAM_BOT_TOKEN"
  check_placeholder "DISCORD_BOT_TOKEN"
  check_placeholder "NEMOCLAW_SANDBOX_NAME"
fi

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "Validation failed with ${ERRORS} error(s). Fix the above before running scripts/start.sh."
  exit 1
else
  echo "Validation passed."
fi