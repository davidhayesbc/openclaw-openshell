#!/usr/bin/env bash
# =============================================================================
# audit.sh -- Security audit for NemoClaw + OpenClaw
# =============================================================================
# Usage:
#   scripts/audit.sh          # Standard audit
#   scripts/audit.sh --deep   # Deep audit (saves full diagnostics tarball)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DEPTH="${1:-}"

if [[ -f .env ]]; then
  set -o allexport; source .env 2>/dev/null || true; set +o allexport
fi

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-openclaw}"

echo "================================================================"
echo "Security Audit -- $(date)"
echo "================================================================"
echo ""

# --- 1. Git secret scan ---
echo "--- [1/5] Git secret scan (gitleaks) ---"
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --source . --config .gitleaks.toml --no-banner 2>&1 \
    && echo "No secrets detected." \
    || echo "WARNING: Potential secrets found. Review the output above."
elif command -v pre-commit >/dev/null 2>&1 && [[ -f .pre-commit-config.yaml ]]; then
  pre-commit run gitleaks --all-files 2>&1 \
    && echo "No secrets detected." \
    || echo "WARNING: Potential secrets found."
else
  echo "SKIP: gitleaks not installed."
  echo "  brew install gitleaks  OR  https://github.com/gitleaks/gitleaks/releases"
fi
echo ""

# --- 2. NemoClaw installation check ---
echo "--- [2/5] NemoClaw installation ---"
if command -v nemoclaw >/dev/null 2>&1; then
  echo "OK: NemoClaw $(nemoclaw --version 2>/dev/null || echo 'installed')"
else
  echo "FAIL: NemoClaw not installed. Run scripts/install.sh."
fi
echo ""

# --- 3. Sandbox status + active policy ---
echo "--- [3/5] Sandbox status + policy ---"
if nemoclaw "${SANDBOX_NAME}" status >/dev/null 2>&1; then
  nemoclaw "${SANDBOX_NAME}" status
  echo ""
  echo "Policy presets:"
  nemoclaw "${SANDBOX_NAME}" policy-list 2>/dev/null || echo "(could not retrieve policy)"
else
  echo "WARN: Sandbox '${SANDBOX_NAME}' is not running."
fi
echo ""

# --- 4. Credentials inventory ---
echo "--- [4/5] Stored credentials (names only) ---"
if command -v nemoclaw >/dev/null 2>&1; then
  nemoclaw credentials list 2>/dev/null \
    || echo "(no credentials stored or NemoClaw not fully configured)"
fi
echo ""

# --- 5. Diagnostics ---
echo "--- [5/5] Diagnostics ---"
if [[ "$DEPTH" == "--deep" ]]; then
  OUTFILE="/tmp/nemoclaw-audit-$(date +%Y%m%d-%H%M%S).tar.gz"
  echo "Collecting full diagnostics -> ${OUTFILE}"
  nemoclaw debug --sandbox "${SANDBOX_NAME}" --output "${OUTFILE}" 2>/dev/null \
    || nemoclaw debug --quick --output "${OUTFILE}" 2>/dev/null \
    || echo "WARN: Could not collect full diagnostics."
  [[ -f "$OUTFILE" ]] && echo "Saved: ${OUTFILE}"
else
  nemoclaw debug --quick 2>/dev/null || echo "WARN: Could not collect diagnostics."
  echo "(run with --deep to save a full diagnostics tarball)"
fi
echo ""
echo "================================================================"
echo "Audit complete."
echo "================================================================"