#!/usr/bin/env bash

# Shared helpers for managing a runnable NemoClaw CLI inside WSL/Linux.

if ! declare -F log >/dev/null 2>&1; then
  log() { echo "[nemoclaw-cli] $*"; }
fi
if ! declare -F warn >/dev/null 2>&1; then
  warn() { echo "[nemoclaw-cli] WARN: $*" >&2; }
fi
if ! declare -F die >/dev/null 2>&1; then
  die() { echo "[nemoclaw-cli] ERROR: $*" >&2; exit 1; }
fi

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
  (cd "$src_dir" && npm install --ignore-scripts)
  (cd "$src_dir" && npm run --if-present build:cli)
  if [[ -d "$src_dir/nemoclaw" ]]; then
    (cd "$src_dir/nemoclaw" && npm install --ignore-scripts && npm run build)
  fi
  (cd "$src_dir" && npm link)
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
  # Ensure nvm node and ~/.local/bin are in PATH so we can find the shim.
  activate_node_runtime
  export PATH="$HOME/.local/bin:$PATH"
  hash -r 2>/dev/null || true

  local nemoclaw_bin
  nemoclaw_bin="$(command -v nemoclaw 2>/dev/null || resolve_nemoclaw_bin 2>/dev/null)" || true
  [[ -n "$nemoclaw_bin" ]] || die "NemoClaw not installed. Run scripts/install.sh first."

  if ! is_real_nemoclaw_cli "$nemoclaw_bin"; then
    repair_nemoclaw_cli
    nemoclaw_bin="$(command -v nemoclaw 2>/dev/null)" || die "NemoClaw is still not runnable after repair."
    is_real_nemoclaw_cli "$nemoclaw_bin" || die "NemoClaw is still not runnable after repair."
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

resolve_committed_openclaw_config_source() {
  local repo_root="${1:-.}"
  local candidate=""

  if [[ -n "${OPENCLAW_CONFIG_SOURCE:-}" ]]; then
    candidate="${OPENCLAW_CONFIG_SOURCE}"
    [[ "$candidate" = /* ]] || candidate="${repo_root}/${candidate}"
    [[ -f "$candidate" ]] || die "Configured OPENCLAW_CONFIG_SOURCE not found: $candidate"
    printf '%s\n' "$candidate"
    return 0
  fi

  if [[ -n "${OPENCLAW_AGENTS_DIR:-}" ]]; then
    candidate="${OPENCLAW_AGENTS_DIR%/}/config/openclaw.json"
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  candidate="${repo_root}/config/openclaw.json"
  if [[ -f "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

sync_committed_openclaw_config_to_host() {
  local repo_root="${1:-.}"
  local source_file config_dir dest_file

  source_file="$(resolve_committed_openclaw_config_source "$repo_root")" || {
    warn "No committed openclaw.json found; leaving host config unchanged."
    return 0
  }

  config_dir="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
  dest_file="${config_dir}/openclaw.json"
  mkdir -p "$config_dir"
  chmod 700 "$config_dir" 2>/dev/null || true
  cp "$source_file" "$dest_file"
  chmod 600 "$dest_file" 2>/dev/null || true
  log "Staged committed OpenClaw config: ${source_file} -> ${dest_file}"
}

export_sandbox_openclaw_config() {
  local sandbox_name="$1"
  local repo_root="${2:-.}"
  local dest_file="${3:-}"

  if [[ -z "$dest_file" ]]; then
    dest_file="$(resolve_committed_openclaw_config_source "$repo_root")" || \
      dest_file="${repo_root}/config/openclaw.json"
  fi
  [[ "$dest_file" = /* ]] || dest_file="${repo_root}/${dest_file}"
  mkdir -p "$(dirname "$dest_file")"

  command -v openshell >/dev/null 2>&1 || die "openshell not found; cannot export sandbox config."

  local tmp_raw tmp_clean
  tmp_raw="$(mktemp)"
  tmp_clean="$(mktemp)"

  if ! openshell sandbox exec -n "$sandbox_name" -- cat /sandbox/.openclaw/openclaw.json >"$tmp_raw"; then
    rm -f "$tmp_raw" "$tmp_clean"
    die "Failed to read /sandbox/.openclaw/openclaw.json from sandbox '$sandbox_name'."
  fi

  python3 - "$tmp_raw" "$tmp_clean" <<'PY'
import json
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])

with src.open('r', encoding='utf-8') as f:
    data = json.load(f)

gateway = data.get('gateway')
if isinstance(gateway, dict):
    auth = gateway.get('auth')
    if isinstance(auth, dict) and 'token' in auth:
        auth.pop('token', None)

control_ui = gateway.get('controlUi') if isinstance(gateway, dict) else None
if isinstance(control_ui, dict):
    control_ui.pop('allowInsecureAuth', None)
    control_ui.pop('dangerouslyDisableDeviceAuth', None)

update_cfg = data.get('update')
if isinstance(update_cfg, dict) and not update_cfg:
    data.pop('update', None)

with dst.open('w', encoding='utf-8', newline='\n') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY

  mv "$tmp_clean" "$dest_file"
  rm -f "$tmp_raw"
  log "Exported sanitized sandbox config -> ${dest_file}"
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

    # main uses the primary workspace; extra agents use workspace-<id> dirs.
    [[ "$agent_id" == "main" ]] && continue
    dst="/sandbox/.openclaw-data/workspace-${agent_id}"

    openshell sandbox exec -n "$sandbox_name" -- mkdir -p "$dst" >/dev/null 2>&1 || true
    openshell sandbox upload "$sandbox_name" "$src" "$dst" >/dev/null 2>&1 || true
    log "Synced sandbox workspace-${agent_id} from ${src}"
  done
}
