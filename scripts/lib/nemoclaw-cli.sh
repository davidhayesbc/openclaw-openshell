#!/usr/bin/env bash

# Shared helpers for managing a runnable NemoClaw CLI inside WSL/Linux.

NODE_BIN_DIR=""

normalize_env_file_line_endings() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0

  # If CRLF is present, rewrite the file as LF so direct `source .env`
  # also works in WSL/Linux shells (not just process-substitution loading).
  if grep -q $'\r' "$env_file" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    sed 's/\r$//' "$env_file" > "$tmp"
    cat "$tmp" > "$env_file"
    rm -f "$tmp"
  fi
}

load_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  normalize_env_file_line_endings "$env_file"
  set -o allexport
  # shellcheck disable=SC1090
  source "$env_file" 2>/dev/null || true
  set +o allexport
}

activate_node_runtime() {
  local node_path=""
  local npm_path=""

  # First try the currently active toolchain if it is Linux-native.
  node_path="$(command -v node 2>/dev/null || true)"
  npm_path="$(command -v npm 2>/dev/null || true)"
  if [[ -n "$node_path" && -n "$npm_path" && "$node_path" != /mnt/* && "$npm_path" != /mnt/* ]]; then
    NODE_BIN_DIR="$(dirname "$node_path")"
  else
    # Fallback: pick the newest Linux nvm runtime directly.
    NODE_BIN_DIR="$(ls -d "$HOME"/.nvm/versions/node/v*/bin 2>/dev/null | sort -V | tail -n 1 || true)"
    [[ -n "$NODE_BIN_DIR" && -x "$NODE_BIN_DIR/node" && -x "$NODE_BIN_DIR/npm" ]] || \
      die "No Linux node/npm runtime found. Install node in WSL (nvm recommended) and retry."
    export PATH="$NODE_BIN_DIR:$PATH"
  fi

  # Avoid inheriting a Windows global npm prefix in WSL.
  unset NPM_CONFIG_PREFIX PREFIX
  export npm_config_prefix="$(dirname "$NODE_BIN_DIR")"

  command -v node >/dev/null 2>&1 || die "Node.js is not runnable in this shell."
  command -v npm >/dev/null 2>&1 || die "npm is not runnable in this shell."
}

resolve_nemoclaw_bin() {
  local candidate=""

  # Prefer the activated node bin dir first.
  candidate="${NODE_BIN_DIR}/nemoclaw"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  # Fallback to npm global prefix bin.
  candidate="$(npm prefix -g)/bin/nemoclaw"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

is_real_nemoclaw_cli() {
  local bin_path="${1:-nemoclaw}"
  local version_output
  version_output="$("$bin_path" --version 2>/dev/null)" || return 1
  [[ "$version_output" =~ ^nemoclaw[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
}

resolve_install_ref() {
  local ref="${NEMOCLAW_INSTALL_TAG:-}"
  if [[ -n "$ref" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi

  ref="$(git ls-remote --tags --refs https://github.com/NVIDIA/NemoClaw.git 'v*' 2>/dev/null | awk '{print $2}' | sed 's|refs/tags/||' | sort -V | tail -n 1)"
  if [[ -n "$ref" ]]; then
    printf '%s\n' "$ref"
    return 0
  fi

  printf 'main\n'
}

install_nemoclaw_from_github() {
  local release_ref src_dir
  release_ref="$(resolve_install_ref)"
  src_dir="$HOME/.nemoclaw/source"

  log "Installing NemoClaw from GitHub ref: $release_ref"
  rm -rf "$src_dir"
  mkdir -p "$(dirname "$src_dir")"
  git -c advice.detachedHead=false clone --depth 1 --branch "$release_ref" https://github.com/NVIDIA/NemoClaw.git "$src_dir"
  patch_nemoclaw_startup_for_agents "$src_dir"
  (cd "$src_dir" && npm install --ignore-scripts)
  (cd "$src_dir" && npm run --if-present build:cli)
  if [[ -d "$src_dir/nemoclaw" ]]; then
    (cd "$src_dir/nemoclaw" && npm install --ignore-scripts && npm run build)
  fi
  (cd "$src_dir" && npm link)
}

patch_nemoclaw_startup_for_agents() {
  local source_root="$1"
  local startup_script="$source_root/scripts/nemoclaw-start.sh"
  [[ -f "$startup_script" ]] || return 0

  # Idempotent patch marker.
  if grep -q "NEMOCLAW_DYNAMIC_AGENT_REGISTRATION_PATCH=1" "$startup_script" 2>/dev/null; then
    return 0
  fi

  python3 - "$startup_script" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
src = path.read_text(encoding="utf-8")

fn_block = r'''
# Dynamically register extra agents staged under /sandbox/.openclaw-data/workspace/#agents.
# NEMOCLAW_DYNAMIC_AGENT_REGISTRATION_PATCH=1
apply_dynamic_agent_registration_override() {
  if [ "$(id -u)" -ne 0 ]; then
    return 0
  fi

  local config_file="/sandbox/.openclaw/openclaw.json"
  local hash_file="/sandbox/.openclaw/.config-hash"
  local agents_root="/sandbox/.openclaw-data/workspace/#agents"
  [ -d "$agents_root" ] || return 0

  if [ -L "$config_file" ] || [ -L "$hash_file" ]; then
    printf '[SECURITY] Refusing dynamic agent registration override — config or hash path is a symlink\n' >&2
    return 1
  fi

  local added_count
  added_count="$(python3 - "$config_file" "$agents_root" <<'PYAGENTS'
import json
import os
import re
import sys

config_file, agents_root = sys.argv[1], sys.argv[2]

with open(config_file, 'r', encoding='utf-8') as f:
    cfg = json.load(f)

agents = cfg.setdefault('agents', {})
existing = agents.get('list')
if not isinstance(existing, list):
    existing = []
    agents['list'] = existing

existing_ids = set()
for entry in existing:
    if isinstance(entry, dict):
        aid = str(entry.get('id', '')).strip()
        if aid:
            existing_ids.add(aid)

valid = re.compile(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')
added = 0
if os.path.isdir(agents_root):
    for name in sorted(os.listdir(agents_root)):
        aid = name.strip()
        if not aid or aid == 'main' or not valid.match(aid):
            continue
        ws = os.path.join(agents_root, aid)
        if not os.path.isdir(ws):
            continue
        if aid in existing_ids:
            continue
        existing.append({'id': aid, 'workspace': ws})
        existing_ids.add(aid)
        added += 1

if added > 0:
    with open(config_file, 'w', encoding='utf-8') as f:
        json.dump(cfg, f, indent=2)

print(added)
PYAGENTS
)" || return 1

  if [ "${added_count:-0}" -gt 0 ]; then
    (cd /sandbox/.openclaw && sha256sum openclaw.json > "$hash_file")
    printf '[agents] Registered %s dynamic agent(s) from #agents\n' "$added_count" >&2
  fi
}
'''

anchor = "# ── Slack token placeholder resolution"
if anchor not in src:
    raise SystemExit("patch anchor not found in nemoclaw-start.sh")

src = src.replace(anchor, fn_block + "\n" + anchor, 1)

# Invoke override in both non-root and root flows near other config mutators.
src = src.replace("  apply_slack_token_override\n", "  apply_slack_token_override\n  apply_dynamic_agent_registration_override\n", 1)
src = src.replace("apply_slack_token_override\n", "apply_slack_token_override\napply_dynamic_agent_registration_override\n", 1)

path.write_text(src, encoding="utf-8")
PY
}

repair_nemoclaw_cli() {
  warn "NemoClaw shim is stale or broken. Reinstalling from GitHub source without re-onboarding..."
  activate_node_runtime
  # Remove placeholder npm package if present, then install real CLI from source.
  npm uninstall -g nemoclaw >/dev/null 2>&1 || true
  install_nemoclaw_from_github

  local nemoclaw_bin
  nemoclaw_bin="$(resolve_nemoclaw_bin)" || die "nemoclaw was not installed in the active node runtime after repair."
  is_real_nemoclaw_cli "$nemoclaw_bin" || die "Installed nemoclaw binary is not the real NemoClaw CLI."

  mkdir -p "$HOME/.local/bin"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$nemoclaw_bin" > "$HOME/.local/bin/nemoclaw"
  chmod +x "$HOME/.local/bin/nemoclaw"
  log "Shim relinked: ~/.local/bin/nemoclaw -> $nemoclaw_bin"
  hash -r
}

ensure_nemoclaw_cli() {
  command -v nemoclaw >/dev/null 2>&1 || die "NemoClaw not installed. Run scripts/install.sh first."
  if ! is_real_nemoclaw_cli "$(command -v nemoclaw)"; then
    repair_nemoclaw_cli
    is_real_nemoclaw_cli "$(command -v nemoclaw)" || die "NemoClaw is still not runnable after repair."
  fi

  # Ensure our dynamic agent-registration patch is present in the local source.
  local startup_script="$HOME/.nemoclaw/source/scripts/nemoclaw-start.sh"
  if [[ ! -f "$startup_script" ]] || ! grep -q "NEMOCLAW_DYNAMIC_AGENT_REGISTRATION_PATCH=1" "$startup_script" 2>/dev/null; then
    warn "NemoClaw source patch for dynamic agent registration is missing. Refreshing local install..."
    repair_nemoclaw_cli
  fi
}

prepare_onboard_environment() {
  # Forward optional messaging tokens from .env to nemoclaw onboard.
  [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] && export TELEGRAM_BOT_TOKEN
  [[ -n "${TELEGRAM_ALLOWED_IDS:-}" ]] && export TELEGRAM_ALLOWED_IDS
  [[ -n "${DISCORD_BOT_TOKEN:-}" ]] && export DISCORD_BOT_TOKEN

  # Forward inference provider vars.
  # COMPATIBLE_API_KEY selects the "Other OpenAI-compatible" provider.
  if [[ -z "${COMPATIBLE_API_KEY:-}" && -n "${OPENROUTER_API_KEY:-}" ]]; then
    export COMPATIBLE_API_KEY="${OPENROUTER_API_KEY}"
  fi

  # Bridge old/new env names used by NemoClaw onboarding.
  if [[ -z "${NEMOCLAW_ENDPOINT_URL:-}" && -n "${NEMOCLAW_INFERENCE_BASE_URL:-}" ]]; then
    export NEMOCLAW_ENDPOINT_URL="${NEMOCLAW_INFERENCE_BASE_URL}"
  fi
  if [[ -z "${NEMOCLAW_INFERENCE_BASE_URL:-}" && -n "${NEMOCLAW_ENDPOINT_URL:-}" ]]; then
    export NEMOCLAW_INFERENCE_BASE_URL="${NEMOCLAW_ENDPOINT_URL}"
  fi

  # Sensible non-interactive defaults for OpenRouter-compatible setup.
  if [[ -n "${COMPATIBLE_API_KEY:-}" ]]; then
    [[ -n "${NEMOCLAW_ENDPOINT_URL:-}" ]] || export NEMOCLAW_ENDPOINT_URL="https://openrouter.ai/api/v1"
    [[ -n "${NEMOCLAW_INFERENCE_BASE_URL:-}" ]] || export NEMOCLAW_INFERENCE_BASE_URL="${NEMOCLAW_ENDPOINT_URL}"
    [[ -n "${NEMOCLAW_MODEL:-}" ]] || export NEMOCLAW_MODEL="openai/gpt-oss-20b:free"
    [[ -n "${NEMOCLAW_PROVIDER:-}" ]] || export NEMOCLAW_PROVIDER="custom"
  fi

  [[ -n "${COMPATIBLE_API_KEY:-}" ]] && export COMPATIBLE_API_KEY
  [[ -n "${NEMOCLAW_ENDPOINT_URL:-}" ]] && export NEMOCLAW_ENDPOINT_URL
  [[ -n "${NEMOCLAW_INFERENCE_BASE_URL:-}" ]] && export NEMOCLAW_INFERENCE_BASE_URL
  [[ -n "${NEMOCLAW_MODEL:-}" ]] && export NEMOCLAW_MODEL
  [[ -n "${NEMOCLAW_PROVIDER:-}" ]] && export NEMOCLAW_PROVIDER
  [[ -n "${NVIDIA_API_KEY:-}" ]] && export NVIDIA_API_KEY
  [[ -n "${OPENAI_API_KEY:-}" ]] && export OPENAI_API_KEY
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && export ANTHROPIC_API_KEY
  [[ -n "${OLLAMA_BASE_URL:-}" ]] && export OLLAMA_BASE_URL
}

build_onboard_flags_from_env() {
  local flags=()
  [[ "${NEMOCLAW_NON_INTERACTIVE:-}" == "1" ]] && flags+=("--non-interactive")
  [[ "${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:-}" == "1" ]] && flags+=("--yes-i-accept-third-party-software")
  echo "${flags[@]:-}"
}

sync_agent_workspaces_to_host() {
  local agents_dir="${OPENCLAW_AGENTS_DIR:-}"
  [[ -n "$agents_dir" && -d "$agents_dir" ]] || return 0

  local config_dir="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
  for agent_dir in "$agents_dir"/*/; do
    local agent_id src dst
    agent_id="$(basename "$agent_dir")"
    src="${agent_dir}workspace"
    dst="${config_dir}/workspace-${agent_id}"
    if [[ -d "$src" ]]; then
      mkdir -p "$dst"
      rsync -a --delete "$src/" "$dst/" 2>/dev/null || cp -r "$src"/* "$dst/"
      log "Synced agent '${agent_id}' workspace -> ${dst}"
    fi
  done
}

sync_agent_workspaces_to_sandbox() {
  local sandbox_name="$1"
  local agents_dir="${OPENCLAW_AGENTS_DIR:-}"
  [[ -n "$agents_dir" && -d "$agents_dir" ]] || return 0

  command -v openshell >/dev/null 2>&1 || {
    warn "openshell not found; skipping sandbox #agents sync."
    return 0
  }

  for agent_dir in "$agents_dir"/*/; do
    local agent_id src dst
    agent_id="$(basename "$agent_dir")"
    src="${agent_dir}workspace"
    [[ -d "$src" ]] || continue

    # main uses the primary workspace; extra agents are staged under #agents.
    [[ "$agent_id" == "main" ]] && continue
    dst="/sandbox/.openclaw-data/workspace/#agents/${agent_id}"

    openshell sandbox exec -n "$sandbox_name" -- mkdir -p "$dst" >/dev/null 2>&1 || true
    openshell sandbox upload "$sandbox_name" "$src" "$dst" >/dev/null 2>&1 || true
    log "Synced sandbox #agents/${agent_id} from ${src}"

    # Best-effort registration. Current NemoClaw sandboxes may keep config read-only.
    openshell sandbox exec -n "$sandbox_name" -- \
      openclaw agents add "$agent_id" --non-interactive --workspace "$dst" --json >/dev/null 2>&1 || true
    if ! openshell sandbox exec -n "$sandbox_name" -- openclaw agents list --json 2>/dev/null | grep -q "\"id\": \"${agent_id}\""; then
      warn "Agent '${agent_id}' copied to #agents but not registered (sandbox config appears read-only)."
    fi
  done
}
