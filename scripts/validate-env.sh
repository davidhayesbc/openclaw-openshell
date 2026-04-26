#!/usr/bin/env bash
# =============================================================================
# validate-env.sh — Checks .env for placeholder/example values before startup
# =============================================================================
set -euo pipefail

ENV_FILE="${1:-.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Copy and fill in the template:"
  echo "  cp .env.example .env && nano .env"
  exit 1
fi

ERRORS=0

check_var() {
  local var="$1"
  local value
  value=$(grep -E "^${var}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")

  if [[ -z "$value" ]]; then
    echo "MISSING: $var is not set in $ENV_FILE"
    ERRORS=$((ERRORS + 1))
    return
  fi

  # Check for obvious placeholder values
  if echo "$value" | grep -qiE "REPLACE_WITH|YOUR_KEY|PLACEHOLDER|CHANGE_ME|TODO|EXAMPLE"; then
    echo "PLACEHOLDER: $var still contains a placeholder value — set a real value"
    ERRORS=$((ERRORS + 1))
    return
  fi

  # Check OPENCLAW_GATEWAY_TOKEN is long enough
  if [[ "$var" == "OPENCLAW_GATEWAY_TOKEN" ]] && [[ ${#value} -lt 32 ]]; then
    echo "WEAK TOKEN: OPENCLAW_GATEWAY_TOKEN is too short (${#value} chars, need ≥32)"
    echo "  Generate one: openssl rand -hex 32"
    ERRORS=$((ERRORS + 1))
    return
  fi

  echo "OK: $var"
}

echo "Validating $ENV_FILE..."
echo ""

# Required
check_var "OPENCLAW_GATEWAY_TOKEN"

# At least one LLM key must be set
ANTHROPIC=$(grep -E "^ANTHROPIC_API_KEY=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
OPENAI=$(grep -E "^OPENAI_API_KEY=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")
OPENROUTER=$(grep -E "^OPENROUTER_API_KEY=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")

if [[ -z "$ANTHROPIC" || "$ANTHROPIC" == *REPLACE* ]] && \
   [[ -z "$OPENAI"    || "$OPENAI"    == *REPLACE* ]] && \
   [[ -z "$OPENROUTER"|| "$OPENROUTER"== *REPLACE* ]]; then
  echo "MISSING: At least one of ANTHROPIC_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY must be set"
  ERRORS=$((ERRORS + 1))
else
  echo "OK: at least one LLM provider key is set"
fi

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "Found $ERRORS issue(s). Fix them in $ENV_FILE before starting."
  exit 1
else
  echo "All checks passed. Safe to start."
fi
