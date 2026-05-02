#!/usr/bin/env bash
# =============================================================================
# start.sh — Start OpenClaw inside an OpenShell sandbox
# =============================================================================
# Usage:
#   scripts/start.sh
#
# Architecture:
#   - Sandbox pod is created via 'openshell sandbox create' (no initial command
#     needed; the pod persists without --no-keep).
#   - Port 18789 forwarding uses a plain SSH tunnel via 'openshell sandbox
#     ssh-config', allowing it to be set up independently of sandbox create.
#   - The openclaw gateway runs in a *persistent exec session*: we nohup the
#     HOST-side 'openshell sandbox exec' process so it survives start.sh exit,
#     keeping the exec SSH session (and the gateway inside) alive.
#   - PID files track the host-side SSH forward and exec processes so stop.sh
#     can cleanly tear everything down.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

log()  { echo "[start] $*"; }
warn() { echo "[start] WARN: $*" >&2; }
die()  { echo "[start] ERROR: $*" >&2; exit 1; }

if [[ $# -gt 0 ]]; then
  die "Unsupported arguments: $*. Use scripts/start.sh with no arguments."
fi

# ---------------------------------------------------------------------------
# Load and validate environment
# ---------------------------------------------------------------------------
[[ -f .env ]] || die ".env not found. Run scripts/install.sh first."
set -o allexport; source .env; set +o allexport

log "Validating environment..."
bash scripts/validate-env.sh

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

# Host-side PID files for long-lived processes we start
SSH_FWD_PID_FILE="/tmp/openclaw-ssh-fwd.pid"
GW_EXEC_PID_FILE="/tmp/openclaw-gw-exec.pid"
SSH_CONFIG_FILE="/tmp/openclaw-ssh.conf"

command -v openshell >/dev/null 2>&1 || die "OpenShell CLI not found. Run scripts/install.sh first."
command -v ssh      >/dev/null 2>&1 || die "ssh not found. Install openssh-client and retry."
command -v curl     >/dev/null 2>&1 || die "curl not found. Install curl and retry."

# ---------------------------------------------------------------------------
# Validate Docker service is running
# ---------------------------------------------------------------------------
log "Checking Docker service..."
if command -v docker >/dev/null 2>&1; then
  docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start the Docker service and retry."
else
  die "Docker not found. Install Docker and ensure the service is running before starting OpenClaw."
fi

# Verify openclaw:local Docker image was built by update.sh
log "Checking openclaw:local image..."
docker image inspect openclaw:local >/dev/null 2>&1 \
  || die "Docker image 'openclaw:local' not found. Run scripts/update.sh first."

# Verify repo config exists
[[ -f config/openclaw.json ]] \
  || die "config/openclaw.json not found. Run scripts/install.sh first."

# ---------------------------------------------------------------------------
# Validate OpenShell gateway connectivity
# ---------------------------------------------------------------------------
log "Checking OpenShell gateway..."
if ! openshell gateway info >/dev/null 2>&1; then
  warn "OpenShell gateway is not reachable. Attempting to start it..."
  if ! openshell gateway start > /tmp/openclaw-gateway-start.log 2>&1; then
    tail -30 /tmp/openclaw-gateway-start.log >&2 || true
    die "OpenShell gateway failed to start. See /tmp/openclaw-gateway-start.log"
  fi
fi

GATEWAY_REACHABLE=false
for i in $(seq 1 30); do
  if openshell sandbox list >/dev/null 2>&1; then
    GATEWAY_REACHABLE=true
    break
  fi
  sleep 1
done

if [[ "${GATEWAY_REACHABLE}" != true ]]; then
  warn "OpenShell gateway still unreachable. Recreating gateway..."
  openshell gateway destroy --name openshell > /tmp/openclaw-gateway-recover.log 2>&1 || true
  if ! openshell gateway start >> /tmp/openclaw-gateway-recover.log 2>&1; then
    tail -30 /tmp/openclaw-gateway-recover.log >&2 || true
    die "OpenShell gateway recovery failed. See /tmp/openclaw-gateway-recover.log"
  fi

  for i in $(seq 1 30); do
    if openshell sandbox list >/dev/null 2>&1; then
      GATEWAY_REACHABLE=true
      break
    fi
    sleep 1
  done
fi

$GATEWAY_REACHABLE || die "OpenShell gateway is not responding. See /tmp/openclaw-gateway-recover.log"

# ---------------------------------------------------------------------------
# Detect if sandbox is already running and healthy
# ---------------------------------------------------------------------------
SANDBOX_EXISTS=false
# Try list first; if the gateway is momentarily flaky, also probe with 'info'
if openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}" \
    || openshell sandbox info "${SANDBOX_NAME}" >/dev/null 2>&1; then
  SANDBOX_EXISTS=true
  log "Sandbox '${SANDBOX_NAME}' is already running."
  log "Resuming gateway/bootstrap steps for the existing sandbox."
fi

if [[ "${SANDBOX_EXISTS}" != true ]]; then
  log "Creating OpenClaw sandbox '${SANDBOX_NAME}' in OpenShell..."
  log "(This may take several minutes while the image is pulled — output below)"
fi

# ---------------------------------------------------------------------------
# Determine LLM provider (openclaw onboard --non-interactive needs --auth-choice)
# ---------------------------------------------------------------------------
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  OPENCLAW_AUTH_CHOICE="anthropic-api-key"
elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
  OPENCLAW_AUTH_CHOICE="openai-api-key"
elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  OPENCLAW_AUTH_CHOICE="openrouter-api-key"
elif [[ -n "${OLLAMA_API_KEY:-}" ]]; then
  OPENCLAW_AUTH_CHOICE="ollama"
else
  die "No LLM API key found in .env (ANTHROPIC_API_KEY, OPENAI_API_KEY, OPENROUTER_API_KEY, or OLLAMA_API_KEY required)."
fi

# ---------------------------------------------------------------------------
# Step 1: Create the sandbox pod
#
# We run with a no-op command in no-TTY mode so create is always
# non-interactive and returns immediately after the pod is created.
# Connectivity to the OpenShell gateway can be transient, so we retry create
# and recover by restarting the gateway when transport errors are detected.
# ---------------------------------------------------------------------------
CREATE_LOG="/tmp/openclaw-create.log"
if [[ "${SANDBOX_EXISTS}" != true ]]; then
  CREATE_OK=false
  for attempt in $(seq 1 3); do
    if openshell sandbox create \
      --name "${SANDBOX_NAME}" \
      --from openclaw \
      --no-tty \
      </dev/null \
      -- true \
      2>&1 | tee "${CREATE_LOG}"; then
      CREATE_OK=true
      break
    fi

    warn "Sandbox create attempt ${attempt}/3 failed."
    # If the sandbox already exists (created on a prior attempt or run),
    # treat it as success rather than retrying.
    if grep -q "already exists" "${CREATE_LOG}" 2>/dev/null; then
      log "Sandbox already exists — treating as successful create."
      SANDBOX_EXISTS=true
      CREATE_OK=true
      break
    fi
    if grep -qiE "Gateway .*not reachable|transport error|tls handshake|Connection reset|Connection refused" "${CREATE_LOG}"; then
      warn "Detected gateway connectivity error; restarting OpenShell gateway and retrying..."
      openshell gateway start > /tmp/openclaw-gateway-start.log 2>&1 || true
    fi
    sleep 2
  done

  $CREATE_OK || die "Failed to create sandbox '${SANDBOX_NAME}'. See ${CREATE_LOG}"
fi

# ---------------------------------------------------------------------------
# Step 2: Wait for the pod to be Ready
# ---------------------------------------------------------------------------
log "Waiting for sandbox pod to be Ready..."
for i in $(seq 1 120); do
  if openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}.*Ready"; then
    log "Sandbox pod is Ready (${i}s)"
    break
  fi
  sleep 1
done
openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}.*Ready" \
  || die "Sandbox '${SANDBOX_NAME}' did not become Ready within 120s."

# ---------------------------------------------------------------------------
# Step 3: Wait for the supervisor session to accept exec connections
#
# The openshell-sandbox supervisor inside the pod can take 30-60s to start
# after the pod is Ready (especially when the container image is cached and
# the pod starts faster than the supervisor initialises). We retry until exec
# works rather than using a fixed sleep.
# ---------------------------------------------------------------------------
log "Waiting for supervisor session (may take up to 90s on cached image)..."
SUPERVISOR_READY=false
for i in $(seq 1 45); do
  if openshell sandbox exec --name "${SANDBOX_NAME}" -- echo ready 2>/dev/null | grep -q "^ready$"; then
    log "Supervisor ready (checked at ~$((i * 2))s)"
    SUPERVISOR_READY=true
    break
  fi
  sleep 2
done
$SUPERVISOR_READY || die "Supervisor session did not become ready within 90s."

# ---------------------------------------------------------------------------
# Step 4: Write Node.js networkInterfaces patch
#
# OpenShell's seccomp profile blocks getifaddrs() (returns EPERM). openclaw's
# gateway calls os.networkInterfaces() unconditionally at ESM module load time,
# which throws ERR_SYSTEM_ERROR before any CLI args are parsed. This preload
# script wraps the call in a try/catch so the gateway starts cleanly.
#
# Note: heredocs in 'bash -c' strings don't work reliably over openshell exec;
# printf is used instead.
# ---------------------------------------------------------------------------
log "Writing Node.js networkInterfaces patch..."
openshell sandbox exec --name "${SANDBOX_NAME}" -- bash -c \
  "printf \"'use strict';\\nconst os=require('os');\\nconst orig=os.networkInterfaces.bind(os);\\nObject.defineProperty(os,'networkInterfaces',{value:function(){try{return orig();}catch(e){return{};}},writable:true,configurable:true});\\n\" > /tmp/patch-net.cjs && echo patch_written" \
  | grep -q "patch_written" \
  || die "Failed to write networkInterfaces patch. Check sandbox exec connectivity."

# ---------------------------------------------------------------------------
# Step 4b: Install Codex CLI (ChatGPT Plus / device-auth model access)
#
# Installs @openai/codex globally so agents can invoke `codex -q "..."` as a
# shell tool, billed to the user's ChatGPT Plus/Pro subscription.
# Policy is not yet applied here, so npm can write to /usr/local/lib/.
# After start.sh, run `scripts/codex-auth.sh` once to authenticate.
# ---------------------------------------------------------------------------
log "Installing @openai/codex in sandbox..."
if openshell sandbox exec --name "${SANDBOX_NAME}" -- bash -lc 'command -v codex >/dev/null 2>&1' 2>/dev/null; then
  log "Codex CLI already installed — skipping."
else
  if openshell sandbox exec --name "${SANDBOX_NAME}" -- \
      bash -lc 'npm install -g @openai/codex 2>&1 | tail -5 && echo codex_installed' \
      | grep -q "codex_installed"; then
    log "Codex CLI installed."
  else
    warn "Codex CLI install failed — skipping. Run manually inside the sandbox:"
    warn "  openshell sandbox exec --name ${SANDBOX_NAME} -- npm install -g @openai/codex"
    warn "Then authenticate: scripts/codex-auth.sh"
  fi
fi

# ---------------------------------------------------------------------------
# Step 5: Onboard openclaw (non-interactive — writes ~/.openclaw/openclaw.json)
#
# Tokens are passed inline; the sandbox has no access to the host env.
# ---------------------------------------------------------------------------
log "Running openclaw onboard (non-interactive)..."
openshell sandbox exec --name "${SANDBOX_NAME}" -- \
  openclaw onboard \
    --non-interactive \
    --accept-risk \
    --gateway-auth token \
    --gateway-token "${OPENCLAW_GATEWAY_TOKEN}" \
    --auth-choice "${OPENCLAW_AUTH_CHOICE}" \
    --skip-channels \
    --skip-daemon \
    --skip-health \
    --skip-search \
    --skip-skills \
  || die "openclaw onboard failed inside sandbox. Check sandbox connectivity and that openclaw is installed in the image."

# ---------------------------------------------------------------------------
# Step 5b-pre: Enumerate available Ollama models → update config/openclaw.json
#
# Queries /api/tags on the Ollama server (OLLAMA_BASE_URL env var, or the
# baseUrl already set in config/openclaw.json) and rewrites the
# models.providers.ollama.models array so the running gateway sees every
# locally available model. Failures are non-fatal: the existing list is kept.
# ---------------------------------------------------------------------------
_OLLAMA_QUERY_URL="${OLLAMA_BASE_URL:-}"
if [[ -z "${_OLLAMA_QUERY_URL}" ]]; then
  _OLLAMA_QUERY_URL=$(python3 -c "
import json, sys
try:
    cfg = json.load(open('config/openclaw.json'))
    print(cfg.get('models',{}).get('providers',{}).get('ollama',{}).get('baseUrl',''))
except Exception:
    pass
" 2>/dev/null || true)
fi

if [[ -n "${_OLLAMA_QUERY_URL}" ]]; then
  log "Enumerating Ollama models from ${_OLLAMA_QUERY_URL}..."
  _OLLAMA_TAGS_TMP=$(mktemp)
  if curl -sf --max-time 8 "${_OLLAMA_QUERY_URL}/api/tags" > "${_OLLAMA_TAGS_TMP}" 2>/dev/null \
      && [[ -s "${_OLLAMA_TAGS_TMP}" ]]; then
    _OLLAMA_RESULT=$(python3 - "${_OLLAMA_TAGS_TMP}" config/openclaw.json <<'PYEOF'
import json, sys

tags_file, config_file = sys.argv[1], sys.argv[2]
with open(tags_file) as f:
    tags = json.load(f)
with open(config_file) as f:
    cfg = json.load(f)

model_names = [
    m.get('name') or m.get('model', '')
    for m in tags.get('models', [])
]
model_names = [n for n in model_names if n]

if model_names and cfg.get('models', {}).get('providers', {}).get('ollama'):
    cfg['models']['providers']['ollama']['models'] = [
        {
            'id': name, 'name': name,
            'input': ['text'], 'reasoning': False,
            'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
            'contextWindow': 131072, 'maxTokens': 8192
        }
        for name in model_names
    ]

    # Register each model in agents.defaults.models so the web UI lists them.
    # Key format: "ollama/<model-id>", alias: model name without tag/version.
    cfg.setdefault('agents', {}).setdefault('defaults', {}).setdefault('models', {})
    agent_models = cfg['agents']['defaults']['models']
    # Remove stale ollama entries from a previous run
    for k in list(agent_models.keys()):
        if k.startswith('ollama/'):
            del agent_models[k]
    for name in model_names:
        alias = name.split(':')[0].split('/')[-1]  # e.g. "phi3.5:latest" → "phi3.5"
        agent_models[f'ollama/{name}'] = {'alias': alias}

    with open(config_file, 'w') as f:
        json.dump(cfg, f, indent=2)
    print('updated:' + ','.join(model_names))
else:
    print('skipped')
PYEOF
    2>/dev/null || true)
    if [[ "${_OLLAMA_RESULT}" == updated:* ]]; then
      _OLLAMA_MODEL_LIST="${_OLLAMA_RESULT#updated:}"
      log "Ollama models written to config/openclaw.json: ${_OLLAMA_MODEL_LIST}"
    else
      warn "Ollama model discovery returned no models — keeping existing list."
    fi
  else
    warn "Could not reach Ollama at ${_OLLAMA_QUERY_URL}/api/tags — keeping existing model list."
  fi
  rm -f "${_OLLAMA_TAGS_TMP}"
else
  warn "No Ollama base URL configured — skipping model discovery."
fi

# ---------------------------------------------------------------------------
# Step 5b: Sync committed gateway config into the sandbox
#
# The onboard step seeds ~/.openclaw/openclaw.json inside the sandbox. We then
# overwrite it with the repo-managed config so channel and model settings from
# config/openclaw.json actually apply to the running gateway.
# ---------------------------------------------------------------------------
log "Syncing repo config into sandbox OpenClaw home..."
openshell sandbox exec --name "${SANDBOX_NAME}" -- bash -lc 'mkdir -p "$HOME/.openclaw"'
# Inject the gateway token from .env into the config before writing it to the
# sandbox. config/openclaw.json sets auth.mode="token" but deliberately omits
# the token value (it's a secret). We merge inside the sandbox via node so
# startup does not depend on host-side node being installed.
cat config/openclaw.json \
  | openshell sandbox exec --name "${SANDBOX_NAME}" -- \
      env \
        OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN}" \
        OLLAMA_BASE_URL="${OLLAMA_SANDBOX_URL:-${OLLAMA_BASE_URL:-}}" \
        LMSTUDIO_BASE_URL="${LMSTUDIO_BASE_URL:-}" \
        LM_API_TOKEN="${LM_API_TOKEN:-}" \
        OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
        node -e 'let raw="";process.stdin.setEncoding("utf8");process.stdin.on("data",(chunk)=>{raw+=chunk;});process.stdin.on("end",()=>{const cfg=JSON.parse(raw);cfg.gateway=cfg.gateway||{};cfg.gateway.auth=cfg.gateway.auth||{};cfg.gateway.auth.token=process.env.OPENCLAW_GATEWAY_TOKEN;const ollamaBaseUrl=process.env.OLLAMA_BASE_URL;if(ollamaBaseUrl&&cfg.models&&cfg.models.providers&&cfg.models.providers.ollama){cfg.models.providers.ollama.baseUrl=ollamaBaseUrl;}const lmstudioBaseUrl=process.env.LMSTUDIO_BASE_URL;if(lmstudioBaseUrl&&cfg.models&&cfg.models.providers&&cfg.models.providers.lmstudio){cfg.models.providers.lmstudio.baseUrl=lmstudioBaseUrl;}const lmApiToken=process.env.LM_API_TOKEN;if(lmApiToken&&cfg.models&&cfg.models.providers&&cfg.models.providers.lmstudio){cfg.models.providers.lmstudio.apiKey=lmApiToken;}const openrouterKey=process.env.OPENROUTER_API_KEY;if(openrouterKey&&cfg.models&&cfg.models.providers&&cfg.models.providers.openai){cfg.models.providers.openai.apiKey=openrouterKey;}process.stdout.write(JSON.stringify(cfg,null,2));});' \
  | openshell sandbox exec --name "${SANDBOX_NAME}" -- bash -lc 'cat > "$HOME/.openclaw/openclaw.json"'
openshell sandbox exec --name "${SANDBOX_NAME}" -- bash -lc \
  'test -s "$HOME/.openclaw/openclaw.json" && echo config_synced' \
  | grep -q "config_synced" \
  || die "Failed to sync config/openclaw.json into sandbox — config file missing or empty."

# ---------------------------------------------------------------------------
# Step 5c: Sync agent workspace files into the sandbox
#
# Looks for agent workspaces in this order:
#   1) OPENCLAW_AGENTS_DIR (explicit override)
#   2) sibling 'openclaw-agents' repo (../openclaw-agents/agents/)
#   3) sibling 'agents' repo (../agents/)
#   4) local agents/ directory in this repo
# Each agent's workspace/ subfolder is tar-piped into
# ~/.openclaw/workspace-<agentId> inside the sandbox, preserving file
# permissions and structure.
# ---------------------------------------------------------------------------
_AGENTS_OVERRIDE="${OPENCLAW_AGENTS_DIR:-}"
_AGENTS_REPO="${REPO_ROOT}/../openclaw-agents/agents"
_AGENTS_REPO_ALT="${REPO_ROOT}/../agents"
_AGENTS_LOCAL="${REPO_ROOT}/agents"
if [[ -n "${_AGENTS_OVERRIDE}" ]]; then
  _AGENTS_DIR="${_AGENTS_OVERRIDE}"
  log "Agent workspaces: OPENCLAW_AGENTS_DIR=${_AGENTS_DIR}"
elif [[ -d "${_AGENTS_REPO}" ]]; then
  _AGENTS_DIR="${_AGENTS_REPO}"
  log "Agent workspaces: sibling repo ${_AGENTS_DIR}"
elif [[ -d "${_AGENTS_REPO_ALT}" ]]; then
  _AGENTS_DIR="${_AGENTS_REPO_ALT}"
  log "Agent workspaces: sibling repo ${_AGENTS_DIR}"
elif [[ -d "${_AGENTS_LOCAL}" ]]; then
  _AGENTS_DIR="${_AGENTS_LOCAL}"
  log "Agent workspaces: local agents/ directory"
else
  _AGENTS_DIR=""
fi

if [[ -n "${_AGENTS_DIR}" ]]; then
  for _agent_workspace in "${_AGENTS_DIR}"/*/workspace; do
    [[ -d "${_agent_workspace}" ]] || continue
    _agent_id="$(basename "$(dirname "${_agent_workspace}")")"
    log "Syncing workspace for agent '${_agent_id}'..."
    openshell sandbox exec --name "${SANDBOX_NAME}" -- \
      bash -lc "mkdir -p ~/.openclaw/workspace-${_agent_id}"
    tar -C "${_agent_workspace}" -cf - . \
      | openshell sandbox exec --name "${SANDBOX_NAME}" -- \
          bash -lc "tar -C ~/.openclaw/workspace-${_agent_id} -xf -"
    log "Agent '${_agent_id}' workspace → ~/.openclaw/workspace-${_agent_id}"
  done
else
  warn "No agent workspace source directory found; skipping agent workspace sync."
fi

# ---------------------------------------------------------------------------
# Step 5d: Sync .agents skills directory into the sandbox
#
# The _openclaw-src/.agents folder contains skill definitions used by coding
# agents. It is tar-piped into ~/.agents inside the sandbox so openclaw can
# discover and use the skills at runtime.
# ---------------------------------------------------------------------------
_AGENTS_SKILLS_DIR="${REPO_ROOT}/_openclaw-src/.agents"
if [[ -d "${_AGENTS_SKILLS_DIR}" ]]; then
  log "Syncing .agents skills directory into sandbox ~/.agents..."
  openshell sandbox exec --name "${SANDBOX_NAME}" -- \
    bash -lc "mkdir -p ~/.agents"
  tar -C "${_AGENTS_SKILLS_DIR}" -cf - . \
    | openshell sandbox exec --name "${SANDBOX_NAME}" -- \
        bash -lc "tar -C ~/.agents -xf -"
  log ".agents skills → ~/.agents"
else
  warn "_openclaw-src/.agents not found at ${_AGENTS_SKILLS_DIR}; skipping skills sync."
fi

# ---------------------------------------------------------------------------
# Step 5e: Sync repo skills/ directory into the sandbox ~/.agents/skills/
#
# skills/<name>/SKILL.md files are merged into ~/.agents/skills/ so agents
# can discover and use them alongside the bundled openclaw skills.
# ---------------------------------------------------------------------------
_REPO_SKILLS_DIR="${REPO_ROOT}/skills"
if [[ -d "${_REPO_SKILLS_DIR}" ]]; then
  log "Syncing repo skills/ into sandbox ~/.agents/skills/..."
  openshell sandbox exec --name "${SANDBOX_NAME}" -- bash -lc 'mkdir -p ~/.agents/skills'
  tar -C "${_REPO_SKILLS_DIR}" -cf - . \
    | openshell sandbox exec --name "${SANDBOX_NAME}" -- \
        bash -lc "tar -C ~/.agents/skills -xf -"
  log "skills/ → ~/.agents/skills"
fi

# ---------------------------------------------------------------------------
# Step 6: Set up SSH port forward (host → sandbox:18789)
#
# 'openshell sandbox create --forward' only maintains the tunnel while its
# process is alive, and exits immediately if command delivery fails (502).
# Instead, we use 'openshell sandbox ssh-config' to get SSH connection details
# and run a plain 'ssh -N -L' tunnel — fully independent of sandbox create.
# ---------------------------------------------------------------------------
# Clean up stale SSH forward and gateway exec processes from any previous run
for _pid_file in "${SSH_FWD_PID_FILE}" "${GW_EXEC_PID_FILE}"; do
  if [[ -f "${_pid_file}" ]]; then
    _old_pid=$(cat "${_pid_file}" 2>/dev/null || true)
    if [[ -n "${_old_pid}" ]] && kill -0 "${_old_pid}" 2>/dev/null; then
      log "Stopping stale process (PID ${_old_pid}) from previous run..."
      kill "${_old_pid}" 2>/dev/null || true
      sleep 1
    fi
    rm -f "${_pid_file}"
  fi
done

log "Setting up port forward localhost:${GATEWAY_PORT} → sandbox:${GATEWAY_PORT}..."
openshell sandbox ssh-config "${SANDBOX_NAME}" > "${SSH_CONFIG_FILE}"

nohup ssh \
  -F "${SSH_CONFIG_FILE}" \
  -N \
  -o ExitOnForwardFailure=yes \
  -L "${GATEWAY_PORT}:localhost:${GATEWAY_PORT}" \
  "openshell-${SANDBOX_NAME}" \
  > /tmp/openclaw-ssh-fwd.log 2>&1 &
SSH_FWD_PID=$!
echo "${SSH_FWD_PID}" > "${SSH_FWD_PID_FILE}"
log "SSH forward PID ${SSH_FWD_PID} (log: /tmp/openclaw-ssh-fwd.log)"

# Brief pause to let the SSH tunnel establish before starting the gateway
sleep 2

# ---------------------------------------------------------------------------
# Step 7: Start openclaw gateway in a persistent exec session
#
# Processes started via 'openshell sandbox exec' are killed when that exec
# session ends. To keep the gateway alive after start.sh exits, we nohup the
# HOST-side 'openshell sandbox exec' process (and disown it). This keeps the
# SSH exec session open, which keeps the gateway running in its foreground.
#
# To stop: kill the PID in GW_EXEC_PID_FILE (terminates the exec session,
# which signals the gateway inside the sandbox).
# ---------------------------------------------------------------------------

# If the gateway is already responding (previous run left it running and the
# SSH tunnel is back up), skip re-launching to avoid the "already running" error.
GW_EXEC_LOG="/tmp/openclaw-gw-exec.log"
if curl -sf --max-time 3 "http://127.0.0.1:${GATEWAY_PORT}/healthz" > /dev/null 2>&1; then
  log "Gateway already healthy on port ${GATEWAY_PORT} — skipping launch."
else
  # Stop any gateway process still running inside the sandbox from a previous
  # exec session (the gateway daemonizes and outlives the host-side exec PID).
  log "Stopping any existing gateway inside sandbox..."
  openshell sandbox exec --name "${SANDBOX_NAME}" -- bash -lc \
    'pkill -f "openclaw gateway" 2>/dev/null; rm -f ~/.openclaw/gateway.pid; true' \
    2>/dev/null || true
  sleep 1

  log "Starting openclaw gateway (persistent exec session)..."
  nohup openshell sandbox exec \
    --name "${SANDBOX_NAME}" \
    -- env \
      NODE_OPTIONS="--require /tmp/patch-net.cjs" \
      TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}" \
      OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
      LM_API_TOKEN="${LM_API_TOKEN:-}" \
      openclaw gateway run \
    > "${GW_EXEC_LOG}" 2>&1 &
  GW_EXEC_PID=$!
  echo "${GW_EXEC_PID}" > "${GW_EXEC_PID_FILE}"
  log "Gateway exec PID ${GW_EXEC_PID} (log: ${GW_EXEC_LOG})"
fi

# ---------------------------------------------------------------------------
# Step 8: Apply security policy (deny-all except LLM APIs)
# ---------------------------------------------------------------------------
POLICY_FILE="${OPENSHELL_POLICY_FILE:-policies/policy.yaml}"

log "Applying security policy from ${POLICY_FILE}..."
openshell policy set "${SANDBOX_NAME}" \
  --policy "${POLICY_FILE}" \
  --wait \
&& log "Policy applied from ${POLICY_FILE}." \
|| warn "Policy apply failed. Run manually: openshell policy set ${SANDBOX_NAME} --policy ${POLICY_FILE} --wait"

# ---------------------------------------------------------------------------
# Step 9: Wait for gateway to become healthy
# ---------------------------------------------------------------------------
log "Waiting for gateway to start (up to 60s)..."
GATEWAY_HEALTHY=false
for i in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${GATEWAY_PORT}/healthz" > /dev/null 2>&1; then
    log "Gateway is healthy!"
    GATEWAY_HEALTHY=true
    break
  fi
  sleep 1
done
if ! $GATEWAY_HEALTHY; then
  warn "Gateway not responding on port ${GATEWAY_PORT}. Last gateway log:"
  tail -30 "${GW_EXEC_LOG}" >&2
  die "Gateway failed to start. Full log: ${GW_EXEC_LOG}"
fi

# ---------------------------------------------------------------------------
log ""
log "============================================================"
log "OpenClaw is running inside an OpenShell sandbox!"
log ""
log "Control UI:  http://127.0.0.1:${GATEWAY_PORT}/"
log "Health:      curl http://127.0.0.1:${GATEWAY_PORT}/healthz"
log "Gateway log: ${GW_EXEC_LOG}"
log ""
log "Policy:      openshell policy set ${SANDBOX_NAME} --policy policies/policy.yaml --wait"
log ""
log "Monitor:  scripts/monitor.sh"
log "Audit:    scripts/audit.sh"
log "Stop:     scripts/stop.sh"
log ""
log "ChatGPT Plus (run once to link your account):"
log "  scripts/codex-auth.sh"
log "============================================================"
