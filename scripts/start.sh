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
scripts/validate-env.sh

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

# Host-side PID files for long-lived processes we start
SSH_FWD_PID_FILE="/tmp/openclaw-ssh-fwd.pid"
GW_EXEC_PID_FILE="/tmp/openclaw-gw-exec.pid"
SSH_CONFIG_FILE="/tmp/openclaw-ssh.conf"

command -v openshell >/dev/null 2>&1 || die "OpenShell CLI not found. Run scripts/install.sh first."

# ---------------------------------------------------------------------------
# Detect if sandbox is already running and healthy
# ---------------------------------------------------------------------------
if openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}"; then
  log "Sandbox '${SANDBOX_NAME}' is already running."
  log "Connect:  openshell sandbox connect ${SANDBOX_NAME}"
  log "Monitor:  scripts/monitor.sh"
  exit 0
fi

log "Creating OpenClaw sandbox '${SANDBOX_NAME}' in OpenShell..."
log "(This downloads the community sandbox image on first run)"
log ""

# ---------------------------------------------------------------------------
# Determine LLM provider (openclaw onboard --non-interactive needs --auth-choice)
# ---------------------------------------------------------------------------
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  OPENCLAW_AUTH_CHOICE="anthropic-api-key"
elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
  OPENCLAW_AUTH_CHOICE="openai-api-key"
elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  OPENCLAW_AUTH_CHOICE="openrouter-api-key"
else
  die "No LLM API key found in .env (ANTHROPIC_API_KEY, OPENAI_API_KEY, or OPENROUTER_API_KEY required)."
fi

# ---------------------------------------------------------------------------
# Step 1: Create the sandbox pod
#
# We run WITHOUT a command so 'openshell sandbox create' just creates the pod
# and exits immediately (the interactive shell gets EOF from redirected stdin).
# The sandbox persists without --no-keep. Output is redirected to suppress the
# TUI spinner (which would cause SIGTSTP if backgrounded with a live terminal).
# ---------------------------------------------------------------------------
CREATE_LOG="/tmp/openclaw-create.log"
openshell sandbox create \
  --name "${SANDBOX_NAME}" \
  --from openclaw \
  > "${CREATE_LOG}" 2>&1 &

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
    --skip-skills

# ---------------------------------------------------------------------------
# Step 6: Set up SSH port forward (host → sandbox:18789)
#
# 'openshell sandbox create --forward' only maintains the tunnel while its
# process is alive, and exits immediately if command delivery fails (502).
# Instead, we use 'openshell sandbox ssh-config' to get SSH connection details
# and run a plain 'ssh -N -L' tunnel — fully independent of sandbox create.
# ---------------------------------------------------------------------------
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
log "Starting openclaw gateway (persistent exec session)..."
GW_EXEC_LOG="/tmp/openclaw-gw-exec.log"
nohup openshell sandbox exec \
  --name "${SANDBOX_NAME}" \
  -- bash -c "NODE_OPTIONS='--require /tmp/patch-net.cjs' exec openclaw gateway run" \
  > "${GW_EXEC_LOG}" 2>&1 &
GW_EXEC_PID=$!
echo "${GW_EXEC_PID}" > "${GW_EXEC_PID_FILE}"
log "Gateway exec PID ${GW_EXEC_PID} (log: ${GW_EXEC_LOG})"

# ---------------------------------------------------------------------------
# Step 8: Apply security policy (deny-all except LLM APIs)
# ---------------------------------------------------------------------------
log "Applying security policy..."
openshell policy set "${SANDBOX_NAME}" \
  --policy "policies/base-policy.yaml" \
  --wait \
&& log "Base policy applied (all outbound blocked except configured LLM APIs)." \
|| warn "Policy apply failed. Run manually: openshell policy set ${SANDBOX_NAME} --policy policies/base-policy.yaml --wait"

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
$GATEWAY_HEALTHY || warn "Gateway not responding on port ${GATEWAY_PORT}. Check: ${GW_EXEC_LOG}"

# ---------------------------------------------------------------------------
log ""
log "============================================================"
log "OpenClaw is running inside an OpenShell sandbox!"
log ""
log "Control UI:  http://127.0.0.1:${GATEWAY_PORT}/"
log "Health:      curl http://127.0.0.1:${GATEWAY_PORT}/healthz"
log "Gateway log: ${GW_EXEC_LOG}"
log ""
log "To extend policy:  openshell policy set ${SANDBOX_NAME} --policy policies/extended-policy.yaml --wait"
log "To revert policy:  openshell policy set ${SANDBOX_NAME} --policy policies/base-policy.yaml --wait"
log ""
log "Monitor:  scripts/monitor.sh"
log "Audit:    scripts/audit.sh"
log "Stop:     scripts/stop.sh"
log "============================================================"
