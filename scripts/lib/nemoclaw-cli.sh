#!/usr/bin/env bash

# Shared helpers for managing a runnable NemoClaw CLI inside WSL/Linux.

NODE_BIN_DIR=""

load_env_file() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  # Strip CRLF line endings so .env works in WSL/bash.
  set -o allexport
  # shellcheck disable=SC1090
  source <(sed 's/\r$//' "$env_file") 2>/dev/null || true
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
  command -v nemoclaw >/dev/null 2>&1 || die "NemoClaw not installed. Run scripts/install.sh first."
  if ! is_real_nemoclaw_cli "$(command -v nemoclaw)"; then
    repair_nemoclaw_cli
    is_real_nemoclaw_cli "$(command -v nemoclaw)" || die "NemoClaw is still not runnable after repair."
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
