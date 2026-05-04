#!/usr/bin/env bash
# =============================================================================
# setup-gateway.sh — Declarative OpenClaw gateway configuration
# =============================================================================
# Purpose:
#   Configures the OpenClaw gateway inside the OpenShell sandbox using the
#   openclaw CLI (config set, models, agents, channels, etc.) rather than
#   direct JSON file patching.
#
#   This is the single authoritative source for gateway configuration.
#   Edit this file to change tools policy, provider settings, agents,
#   channel behaviour, or model defaults.  Run with --full after any
#   structural change to propagate it to the sandbox.
#
# Usage:
#   source .env && bash scripts/setup-gateway.sh [--full|--update|--reset] [--saved-model JSON]
#
# Modes:
#   --full    Apply complete configuration.  Idempotent: safe to re-run; the
#             user's chosen primary model is preserved if already set.  Writes
#             a sentinel file so subsequent starts use --update automatically.
#
#   --update  (Default on subsequent restarts.)  Re-apply secrets, provider
#             URLs, and the Ollama models list only.  Does not touch agents,
#             bindings, channels, tools policy, or model selection.
#
#   --reset   Clear the setup sentinel so the next run (or an explicit --full)
#             re-applies the complete configuration from scratch.
#
#   (none)    Auto-detect: --full if no sentinel found, --update otherwise.
#
# Options:
#   --saved-model JSON  Model config to restore after onboard wipes it.
#                       Passed by start.sh to preserve user's model selection.
#
# Called by:
#   scripts/start.sh  (Step 5c) after openclaw onboard and before gateway
#   launch.  Can also be run standalone: source .env && bash scripts/setup-gateway.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[setup-gw] $*"; }
warn() { echo "[setup-gw] WARN: $*" >&2; }
die()  { echo "[setup-gw] ERROR: $*" >&2; exit 1; }

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"
SENTINEL='~/.openclaw/.setup-done'

# ── Parse arguments ──────────────────────────────────────────────────────────
_SAVED_MODEL_JSON=""
_ARGS=("$@")
_RAW_MODE="auto"

for _arg in "${_ARGS[@]}"; do
  case "$_arg" in
    --saved-model)
      # Next arg is the JSON
      ;;
    --full|--update|--reset|auto)
      _RAW_MODE="$_arg"
      ;;
    *)
      # Assume it's JSON from --saved-model
      _SAVED_MODEL_JSON="$_arg"
      ;;
  esac
done

case "$_RAW_MODE" in
  --full)   MODE=full ;;
  --update) MODE=update ;;
  --reset)
    log "Clearing setup sentinel..."
    openshell sandbox exec --name "$SANDBOX_NAME" -- \
      bash -lc "rm -f $SENTINEL && echo 'Sentinel cleared.'" 2>/dev/null || true
    log "Next run will apply full configuration. Re-run without --reset to proceed."
    exit 0
    ;;
  auto) MODE=auto ;;
  *)    die "Unknown argument: $_RAW_MODE. Use --full, --update, --reset, or omit for auto-detect." ;;
esac

if [[ "$MODE" == "auto" ]]; then
  if openshell sandbox exec --name "$SANDBOX_NAME" -- \
       bash -lc "test -f $SENTINEL && echo yes" 2>/dev/null | grep -q "^yes$"; then
    MODE=update
    log "Existing setup detected → update mode (pass --full to re-apply all settings)"
  else
    MODE=full
    log "No setup sentinel → full mode"
  fi
fi

log "Mode: $MODE"

# ── Local LLM model discovery (host-side) ──────────────────────────────────────
# Discovers models from both Ollama and LM Studio providers
_OLLAMA_MODELS_JSON='[]'
_LMSTUDIO_MODELS_JSON='[]'
_AGENTS_DEFAULTS_MODELS_JSON='{}'
_RESOLVED_DEFAULT_MODEL=''
_HOST_OLLAMA_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
_HOST_LMSTUDIO_URL="${LMSTUDIO_BASE_URL:-http://127.0.0.1:1234/v1}"

# ─ Ollama discovery
log "Enumerating Ollama models from ${_HOST_OLLAMA_URL}..."
_OLLAMA_TAGS_TMP=$(mktemp)
if curl -sf --max-time 8 "${_HOST_OLLAMA_URL}/api/tags" > "$_OLLAMA_TAGS_TMP" 2>/dev/null \
    && [[ -s "$_OLLAMA_TAGS_TMP" ]]; then
  _DISCOVERY=$(python3 - "$_OLLAMA_TAGS_TMP" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    tags = json.load(f)
models, aliases = [], {}
for m in tags.get('models', []):
    name = m.get('name') or m.get('model', '')
    if not name:
        continue
    models.append({
        'id': name, 'name': name, 'input': ['text'], 'reasoning': False,
        'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
        'contextWindow': 131072, 'maxTokens': 8192,
    })
    alias = name.split(':')[0].split('/')[-1]
    aliases[f'ollama/{name}'] = {'alias': alias}
print(json.dumps({'models': models, 'aliases': aliases}))
PYEOF
  )
  _OLLAMA_MODELS_JSON=$(echo "$_DISCOVERY" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['models']))")
  _AGENTS_DEFAULTS_MODELS_JSON=$(echo "$_DISCOVERY" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['aliases']))")
  _RESOLVED_DEFAULT_MODEL=$(python3 -c "import json; import os; models=json.loads('''$_OLLAMA_MODELS_JSON'''); preferred=os.environ.get('OLLAMA_DEFAULT_MODEL','').strip(); preferred = preferred.removeprefix('ollama/') if preferred.startswith('ollama/') else preferred; available=[m.get('id','') for m in models if m.get('id')]; print(f'ollama/{preferred}' if preferred and preferred in available else (f'ollama/{available[0]}' if available else ''))" )
  _COUNT=$(echo "$_OLLAMA_MODELS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
  log "Discovered ${_COUNT} Ollama models"
  if [[ -n "${_RESOLVED_DEFAULT_MODEL}" ]] && [[ "${_RESOLVED_DEFAULT_MODEL}" != "${OLLAMA_DEFAULT_MODEL:-}" ]]; then
    warn "OLLAMA_DEFAULT_MODEL (${OLLAMA_DEFAULT_MODEL:-unset}) is not available locally; using ${_RESOLVED_DEFAULT_MODEL}"
  fi
else
  warn "Could not reach Ollama at ${_HOST_OLLAMA_URL} — keeping empty model list"
fi
rm -f "$_OLLAMA_TAGS_TMP"

# ─ LM Studio discovery
log "Enumerating LM Studio models from ${_HOST_LMSTUDIO_URL}..."
_LMSTUDIO_MODELS_TMP=$(mktemp)
if curl -sf --max-time 8 "${_HOST_LMSTUDIO_URL}/models" > "$_LMSTUDIO_MODELS_TMP" 2>/dev/null \
    && [[ -s "$_LMSTUDIO_MODELS_TMP" ]]; then
  _LMSTUDIO_DISCOVERY=$(python3 - "$_LMSTUDIO_MODELS_TMP" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
models, aliases = [], {}
for m in data.get('data', []):
    model_id = m.get('id', '')
    if not model_id:
        continue
    models.append({
        'id': model_id, 'name': model_id, 'input': ['text'], 'reasoning': False,
        'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
        'contextWindow': 131072, 'maxTokens': 8192,
    })
    alias = model_id.split('/')[-1].split(':')[0]
    aliases[f'lmstudio/{model_id}'] = {'alias': alias}
print(json.dumps({'models': models, 'aliases': aliases}))
PYEOF
  )
  _LMSTUDIO_MODELS_JSON=$(echo "$_LMSTUDIO_DISCOVERY" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['models']))")
  _LMSTUDIO_ALIASES=$(echo "$_LMSTUDIO_DISCOVERY" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['aliases']))")
  # Merge LM Studio aliases into agents defaults
  _AGENTS_DEFAULTS_MODELS_JSON=$(python3 -c "import sys,json; a=json.loads('''$_AGENTS_DEFAULTS_MODELS_JSON'''); b=json.loads('''$_LMSTUDIO_ALIASES'''); a.update(b); print(json.dumps(a))")
  _COUNT=$(echo "$_LMSTUDIO_MODELS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?")
  log "Discovered ${_COUNT} LM Studio models"
else
  warn "Could not reach LM Studio at ${_HOST_LMSTUDIO_URL} — keeping empty model list"
fi
rm -f "$_LMSTUDIO_MODELS_TMP"

# ── Generate inner setup script ──────────────────────────────────────────────
# This script runs inside the sandbox via `bash -s`.
# Static config values are embedded at generation time (single-quoted heredoc
# prevents host-side expansion); secrets / dynamic values are passed as env
# vars and expanded at runtime inside the sandbox.
# shellcheck disable=SC2016
_INNER=$(cat <<'SETUP_INNER'
#!/usr/bin/env bash
set -euo pipefail
log()  { echo "[gw-inner] $*"; }
warn() { echo "[gw-inner] WARN: $*" >&2; }
run_quiet() {
  local output status
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  if (( status != 0 )); then
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
    return "$status"
  fi
}
config_set_quiet() {
  local path="$1"
  local value="$2"
  local output status
  set +e
  output=$(openclaw config set --strict-json "$path" "$value" 2>&1)
  status=$?
  set -e
  if (( status != 0 )); then
    [[ -n "$output" ]] && printf '%s\n' "$output" >&2
    return "$status"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# ALWAYS: provider routing (sandbox-specific URLs and API secrets)
# Must set entire provider objects atomically — field-by-field causes validation
# failures because openclaw config set validates the entire config on each call.
# ──────────────────────────────────────────────────────────────────────────────
log "Configuring providers..."

# Ollama (local inference via inference.local) — set as complete object
_OLLAMA_PROVIDER=$(node -e "process.stdout.write(JSON.stringify({
  api: 'openai-completions',
  baseUrl: process.env.OLLAMA_SANDBOX_URL,
  apiKey: 'unused',
  models: JSON.parse(process.env.OLLAMA_MODELS_JSON || '[]')
}))")
config_set_quiet models.providers.ollama "$_OLLAMA_PROVIDER"

# OpenRouter (cloud fallback — skip if no API key)
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  _OPENROUTER_PROVIDER=$(node -e "process.stdout.write(JSON.stringify({
    api: 'openai-completions',
    baseUrl: 'https://openrouter.ai/api/v1',
    apiKey: process.env.OPENROUTER_API_KEY,
    models: []
  }))")
  config_set_quiet models.providers.openai "$_OPENROUTER_PROVIDER"
fi

# LM Studio (optional local provider with GPU acceleration)
if [[ -n "${LMSTUDIO_BASE_URL:-}" ]]; then
  _LMSTUDIO_PROVIDER=$(node -e "process.stdout.write(JSON.stringify({
    api: 'openai-completions',
    baseUrl: process.env.LMSTUDIO_BASE_URL,
    apiKey: process.env.LM_API_TOKEN || null,
    models: JSON.parse(process.env.LMSTUDIO_MODELS_JSON || '[]')
  }))")
  config_set_quiet models.providers.lmstudio "$_LMSTUDIO_PROVIDER"
fi

# ──────────────────────────────────────────────────────────────────────────────
# ALWAYS: model aliases (rebuilt from fresh Ollama discovery)
# ──────────────────────────────────────────────────────────────────────────────
log "Syncing model aliases..."
config_set_quiet agents.defaults.models "${AGENTS_DEFAULTS_MODELS_JSON}"

# Optional explicit default model override (for cloud-first setups).
if [[ -n "${EXPLICIT_DEFAULT_MODEL:-}" ]]; then
  log "Applying explicit default model: ${EXPLICIT_DEFAULT_MODEL}"
  config_set_quiet agents.defaults.model.primary \
    "$(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "${EXPLICIT_DEFAULT_MODEL}")"
fi

# Always honor requested gateway bind mode so loopback/lan changes apply on
# restart without requiring a full reset.
_GW_BIND="${OPENCLAW_GATEWAY_BIND:-loopback}"
case "${_GW_BIND}" in
  loopback|lan) ;;
  *)
    warn "Invalid OPENCLAW_GATEWAY_BIND='${_GW_BIND}' (expected loopback|lan); falling back to loopback"
    _GW_BIND="loopback"
    ;;
esac
_GW_BIND_JSON="\"${_GW_BIND}\""
config_set_quiet gateway.bind "${_GW_BIND_JSON}"

# ──────────────────────────────────────────────────────────────────────────────
# FULL MODE: structural settings, agents, channels, model defaults
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${SETUP_MODE}" == "full" ]]; then
  log "Applying full structural configuration..."

  # Gateway
  config_set_quiet gateway.mode '"local"'
  _GW_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
  _GW_ALLOWED_ORIGINS="[\"http://localhost:${_GW_PORT}\",\"http://127.0.0.1:${_GW_PORT}\"]"
  config_set_quiet gateway.controlUi.allowedOrigins \
    "${_GW_ALLOWED_ORIGINS}"

  # Session
  config_set_quiet session.dmScope '"per-channel-peer"'

  # Tools
  config_set_quiet tools.profile '"messaging"'
  config_set_quiet tools.deny \
    '["group:automation","group:runtime","group:fs","sessions_spawn","sessions_send"]'
  config_set_quiet tools.fs.workspaceOnly  'true'
  config_set_quiet tools.exec.security     '"deny"'
  config_set_quiet tools.exec.ask          '"always"'
  config_set_quiet tools.elevated.enabled  'false'

  # Logging
  config_set_quiet logging.redactSensitive '"tools"'
  config_set_quiet logging.level           '"info"'

  # Telegram channel (requires bot token; skipped silently if absent)
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    log "Configuring Telegram channel..."
    config_set_quiet channels.telegram.enabled   'true'
    config_set_quiet channels.telegram.dmPolicy  '"pairing"'
    if [[ -n "${TELEGRAM_ALLOWED_PEER:-}" ]]; then
      config_set_quiet channels.telegram.allowFrom "[\"${TELEGRAM_ALLOWED_PEER}\"]"
    fi
    config_set_quiet channels.telegram.groups '{"*":{"requireMention":true}}'
  fi

  # Agents
  log "Configuring agents..."
  run_quiet openclaw agents add main  --workspace ~/.openclaw/workspace       --non-interactive \
    2>/dev/null || log "  Agent 'main' already exists"
  run_quiet openclaw agents add coder --workspace ~/.openclaw/workspace-coder --non-interactive \
    2>/dev/null || log "  Agent 'coder' already exists"

  # Bindings: route Telegram DMs from allowed peer → main agent
  if [[ -n "${TELEGRAM_ALLOWED_PEER:-}" ]]; then
    config_set_quiet bindings \
      "[{\"agentId\":\"main\",\"match\":{\"channel\":\"telegram\",\"peer\":{\"kind\":\"direct\",\"id\":\"${TELEGRAM_ALLOWED_PEER}\"}}}]"
  fi

  # Primary model — preserve existing user selection; only set on first run
  # Try to restore from saved model (passed by start.sh before onboard wiped it)
  _saved_primary=""
  if [[ -n "${SAVED_MODEL_JSON:-}" ]]; then
    _saved_primary=$(echo "${SAVED_MODEL_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('primary',''))" 2>/dev/null || true)
  fi
  
  _current=$(openclaw config get agents.defaults.model.primary 2>/dev/null \
    | tr -d '"' | xargs 2>/dev/null || true)
  
  if [[ -n "$_saved_primary" && "$_saved_primary" != "null" ]]; then
    log "Restoring saved primary model: $_saved_primary"
    config_set_quiet agents.defaults.model.primary "$(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "$_saved_primary")"
    # Also restore fallbacks if they were saved
    _saved_fallbacks=$(echo "${SAVED_MODEL_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('fallbacks',[])))" 2>/dev/null || true)
    if [[ -n "$_saved_fallbacks" && "$_saved_fallbacks" != "null" ]]; then
      config_set_quiet agents.defaults.model.fallbacks "$_saved_fallbacks"
    fi
  elif [[ -z "$_current" || "$_current" == "null" || "$_current" == "undefined" ]]; then
    log "Setting initial primary model: ${DEFAULT_MODEL}"
    config_set_quiet agents.defaults.model.primary "$(node -e "process.stdout.write(JSON.stringify(process.argv[1]))" "${DEFAULT_MODEL}")"
    config_set_quiet agents.defaults.model.fallbacks \
      '["openai/openai/gpt-oss-20b:free","ollama/llama3.1:8b"]'
  else
    log "Preserving existing primary model: $_current"
  fi

  # Mark setup complete so future starts use --update mode
  touch ~/.openclaw/.setup-done
  log "Full setup complete ✓"
fi

log "Setup done ✓"
SETUP_INNER
)

# ── Execute inner script inside sandbox ─────────────────────────────────────
log "Running setup script inside sandbox..."
printf '%s\n' "$_INNER" \
  | openshell sandbox exec --name "${SANDBOX_NAME}" -- \
      env \
        SETUP_MODE="${MODE}" \
        SAVED_MODEL_JSON="${_SAVED_MODEL_JSON}" \
        OPENCLAW_GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-loopback}" \
        OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}" \
        OLLAMA_SANDBOX_URL="${OLLAMA_SANDBOX_URL:-https://inference.local/v1}" \
        OLLAMA_MODELS_JSON="${_OLLAMA_MODELS_JSON}" \
        LMSTUDIO_MODELS_JSON="${_LMSTUDIO_MODELS_JSON}" \
        AGENTS_DEFAULTS_MODELS_JSON="${_AGENTS_DEFAULTS_MODELS_JSON}" \
        OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
        LMSTUDIO_BASE_URL="${LMSTUDIO_BASE_URL:-http://127.0.0.1:1234/v1}" \
        LM_API_TOKEN="${LM_API_TOKEN:-}" \
        TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
        TELEGRAM_ALLOWED_PEER="${TELEGRAM_ALLOWED_PEER:-}" \
        EXPLICIT_DEFAULT_MODEL="${OPENCLAW_DEFAULT_MODEL:-}" \
        DEFAULT_MODEL="${_RESOLVED_DEFAULT_MODEL:-${OLLAMA_DEFAULT_MODEL:-ollama/qwen3:latest}}" \
      bash -s

log "Gateway configuration applied."
