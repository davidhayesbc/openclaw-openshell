#!/usr/bin/env bash
# =============================================================================
# audit.sh — Security audit: OpenClaw + OpenShell + Docker
# =============================================================================
# Runs all available security checks and summarises findings.
#
# Usage:
#   scripts/audit.sh          # Standard audit
#   scripts/audit.sh --deep   # Deep audit (attempts live gateway probe)
#   scripts/audit.sh --fix    # Auto-fix common issues
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEPTH="${1:-}"

if [[ -f .env ]]; then
  set -o allexport
  source .env 2>/dev/null || true
  set +o allexport
fi

SANDBOX_NAME="${OPENSHELL_SANDBOX_NAME:-openclaw}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

echo "================================================================"
echo "Security Audit — $(date)"
echo "================================================================"
echo ""

# --- 1. Validate .env ---
echo "--- [1/6] Environment validation ---"
scripts/validate-env.sh && echo "" || { echo "FAIL: Fix .env issues before continuing."; }

# --- 2. Git secret scan ---
echo "--- [2/6] Git secret scan (gitleaks) ---"
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --source . --config .gitleaks.toml --no-banner 2>&1 \
    && echo "No secrets detected." \
    || echo "WARNING: Potential secrets found! Review the output above."
elif command -v pre-commit >/dev/null 2>&1 && [[ -f .pre-commit-config.yaml ]]; then
  pre-commit run gitleaks --all-files 2>&1 \
    && echo "No secrets detected." \
    || echo "WARNING: Potential secrets found!"
else
  echo "SKIP: gitleaks not installed. Install it to scan for committed secrets:"
  echo "  brew install gitleaks  OR  https://github.com/gitleaks/gitleaks/releases"
fi
echo ""

# --- 3. OpenClaw security audit ---
echo "--- [3/6] OpenClaw security audit ---"
if command -v openshell >/dev/null 2>&1 && \
   openshell sandbox list 2>/dev/null | grep -q "^${SANDBOX_NAME}"; then
  # Run openclaw security audit inside the sandbox
  echo "Running inside OpenShell sandbox '${SANDBOX_NAME}'..."
  openshell sandbox connect "${SANDBOX_NAME}" -- \
    openclaw security audit ${DEPTH/--deep/--deep} 2>/dev/null || true
elif docker compose ps --services --status running 2>/dev/null | grep -q "openclaw-gateway"; then
  # Docker Compose path
  docker compose exec openclaw-gateway \
    node dist/index.js security audit ${DEPTH/--deep/--deep} \
    --token "$OPENCLAW_GATEWAY_TOKEN" 2>/dev/null || true
else
  echo "OpenClaw not running — start it first for a live audit."
  echo "Static config check: reviewing config/openclaw.json..."
  grep -E '"bind"\s*:\s*"lan"' config/openclaw.json \
    && echo "WARNING: gateway.bind is 'lan' — ensure reverse proxy + auth are configured" \
    || echo "OK: gateway.bind is not 'lan' (loopback or default)"
  grep -E '"security"\s*:\s*"full"' config/openclaw.json \
    && echo "WARNING: tools.exec.security is 'full' — consider 'deny' for hardened setup" \
    || echo "OK: tools.exec.security is not 'full'"
fi
echo ""

# --- 4. OpenShell sandbox policy ---
echo "--- [4/6] OpenShell policy check ---"
if command -v openshell >/dev/null 2>&1; then
  echo "Active policy for sandbox '${SANDBOX_NAME}':"
  openshell policy get "${SANDBOX_NAME}" 2>/dev/null \
    || echo "(sandbox not running or no policy set)"
else
  echo "OpenShell not installed — skipping sandbox policy check."
fi
echo ""

# --- 5. Docker security checks ---
echo "--- [5/6] Docker container checks ---"
if docker compose ps --services --status running 2>/dev/null | grep -q "openclaw-gateway"; then
  echo "Container: openclaw-gateway"

  # Check if running as root
  CONTAINER_USER=$(docker compose exec openclaw-gateway id -un 2>/dev/null || echo "unknown")
  if [[ "$CONTAINER_USER" == "root" ]]; then
    echo "  WARNING: Running as root — check 'user:' in docker-compose.yml"
  else
    echo "  OK: Running as $CONTAINER_USER (non-root)"
  fi

  # Check port binding
  PORTS=$(docker compose port openclaw-gateway 18789 2>/dev/null || echo "")
  if echo "$PORTS" | grep -qE "^0\.0\.0\.0:"; then
    echo "  WARNING: Port 18789 is bound to 0.0.0.0 — exposed to all interfaces"
    echo "    Change OPENCLAW_GATEWAY_BIND to 'loopback' in .env"
  elif echo "$PORTS" | grep -qE "^127\.0\.0\.1:"; then
    echo "  OK: Port 18789 is bound to loopback only"
  fi

  # Check capabilities
  echo "  Capabilities: $(docker compose exec openclaw-gateway cat /proc/1/status 2>/dev/null | grep CapEff || echo 'unknown')"
else
  echo "Docker Compose stack not running — skipping container checks."
fi
echo ""

# --- 6. File permission check ---
echo "--- [6/6] Credential file permissions ---"
if [[ -f .env ]]; then
  PERMS=$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env 2>/dev/null || echo "unknown")
  if [[ "$PERMS" =~ ^[67][04][04]$ ]] || [[ "$PERMS" == "600" ]] || [[ "$PERMS" == "640" ]]; then
    echo "OK: .env permissions are $PERMS"
  else
    echo "WARNING: .env permissions are $PERMS — should be 600 (owner read/write only)"
    echo "  Fix: chmod 600 .env"
  fi
fi

OPENCLAW_CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$HOME/.openclaw}"
if [[ -d "$OPENCLAW_CONFIG_DIR" ]]; then
  CDIR_PERMS=$(stat -c '%a' "$OPENCLAW_CONFIG_DIR" 2>/dev/null || stat -f '%Lp' "$OPENCLAW_CONFIG_DIR" 2>/dev/null || echo "unknown")
  if [[ "$CDIR_PERMS" == "700" ]]; then
    echo "OK: $OPENCLAW_CONFIG_DIR permissions are $CDIR_PERMS"
  else
    echo "WARNING: $OPENCLAW_CONFIG_DIR permissions are $CDIR_PERMS — should be 700"
    echo "  Fix: chmod 700 $OPENCLAW_CONFIG_DIR"
  fi
fi
echo ""

echo "================================================================"
echo "Audit complete. Review any WARNING lines above."
echo "Docs: docs/security.md | OpenClaw: https://docs.openclaw.ai/gateway/security"
echo "================================================================"
