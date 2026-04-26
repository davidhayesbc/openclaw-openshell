# OpenClaw + OpenShell — Secure Self-Hosted Setup

A security-hardened, git-tracked setup for running [OpenClaw](https://openclaw.ai/) (AI personal assistant) inside [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) (sandboxed agent runtime).

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Host Machine                                            │
│                                                          │
│  ┌─────────────────────────────────────────────────┐    │
│  │  OpenShell Gateway (K3s-in-Docker)               │    │
│  │                                                  │    │
│  │  ┌──────────────────────────────────────────┐   │    │
│  │  │  OpenClaw Sandbox                        │   │    │
│  │  │                                          │   │    │
│  │  │  ┌──────────┐  ┌──────────────────────┐ │   │    │
│  │  │  │ OpenClaw │  │  Policy Engine       │ │   │    │
│  │  │  │ Gateway  │  │  - Network: block all│ │   │    │
│  │  │  │ :18789   │  │    except LLM APIs   │ │   │    │
│  │  │  │          │  │  - FS: workspace only│ │   │    │
│  │  │  │          │  │  - Process: no privesc│ │   │    │
│  │  │  └──────────┘  └──────────────────────┘ │   │    │
│  │  └──────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────┘    │
│                           │                              │
│              port-forward ↓ (127.0.0.1:18789)            │
│                    Browser / CLI                          │
└──────────────────────────────────────────────────────────┘
```

**OpenShell** wraps OpenClaw in a container with policy-enforced egress. All outbound connections go through OpenShell's policy engine. **Network and filesystem access are deny-by-default.**

## Quick Start

### 1. Prerequisites

- Docker Desktop (or Docker Engine + Compose v2)
- Git
- Linux or macOS (Windows: use WSL2)

### 2. First-time setup

```bash
git clone <this-repo> openclaw-openshell
cd openclaw-openshell

# Install OpenShell CLI and set up directories
bash scripts/install.sh

# Edit .env with your API keys and a strong gateway token
nano .env
# Generate a token: openssl rand -hex 32

# Validate
bash scripts/validate-env.sh
```

### 3. Start

```bash
bash scripts/start.sh
```

### 4. Open Control UI

Visit **http://127.0.0.1:18789/** — use the gateway token from your `.env`.

### 5. Monitor

```bash
bash scripts/monitor.sh            # OpenShell TUI (live cluster dashboard)
bash scripts/monitor.sh --logs     # Tail gateway logs
bash scripts/monitor.sh --status   # Quick snapshot
```

### 6. Security audit

```bash
bash scripts/audit.sh
bash scripts/audit.sh --deep
```

---

## Security Model

### What OpenShell Provides

| Layer | What it protects | Reloadable? |
|-------|-----------------|-------------|
| **Network policy** | Blocks all outbound except allowed LLM APIs | ✅ Hot-reload |
| **Filesystem policy** | Restricts reads/writes to workspace only | ❌ Locked at creation |
| **Process policy** | Blocks privilege escalation, restricts syscalls | ❌ Locked at creation |
| **Inference router** | Can route LLM calls to controlled backends | ✅ Hot-reload |

### What OpenClaw Config Provides

- `gateway.bind: loopback` — control UI localhost-only
- `tools.exec.security: deny` — no shell execution
- `tools.fs.workspaceOnly: true` — no host filesystem access
- `tools.elevated.enabled: false` — no privileged operations
- `session.dmScope: per-channel-peer` — session isolation

---

## Network Policies

Policies live in `policies/` and are tracked in git.

| Policy | Allows |
|--------|--------|
| `base-policy.yaml` | Anthropic API, OpenAI API, OpenRouter only |
| `extended-policy.yaml` | Base + GitHub read-only, npm |

```bash
# Apply base (minimal) policy
openshell policy set openclaw --policy policies/base-policy.yaml --wait

# Check what's active
openshell policy get openclaw

# Temporarily extend, then revert
openshell policy set openclaw --policy policies/extended-policy.yaml --wait
# ... do work ...
openshell policy set openclaw --policy policies/base-policy.yaml --wait
```

---

## Git Rollback

All configs are version-controlled. To roll back:

```bash
# See config history
git log --oneline config/openclaw.json
git log --oneline policies/

# Restore a specific version
git checkout <sha> -- config/openclaw.json
git checkout <sha> -- policies/base-policy.yaml

# Apply the restored config
cp config/openclaw.json ~/.openclaw/openclaw.json
openshell policy set openclaw --policy policies/base-policy.yaml --wait
scripts/stop.sh && scripts/start.sh
```

---

## Directory Structure

```
.
├── .env.example          # Secrets template (committed — no real values)
├── .gitignore            # Ignores .env, credentials, workspace data
├── .gitleaks.toml        # Secret scanning configuration
├── .pre-commit-config.yaml  # Git pre-commit hooks (gitleaks)
├── docker-compose.yml    # Optional local compose resources (not used by scripts)
├── policies/
│   ├── base-policy.yaml     # Minimal OpenShell network policy
│   ├── extended-policy.yaml # Extended access for dev tasks
│   └── README.md
├── config/
│   ├── openclaw.json        # Hardened OpenClaw gateway config (no secrets)
│   └── README.md
├── scripts/
│   ├── install.sh           # One-time setup
│   ├── start.sh             # Start OpenShell sandbox
│   ├── stop.sh              # Stop
│   ├── monitor.sh           # Monitoring dashboard
│   ├── audit.sh             # Security audit
│   ├── update.sh            # Update components
│   ├── rotate-token.sh      # Rotate gateway token
│   └── validate-env.sh      # Validate .env before startup
└── docs/
    └── security.md          # Detailed security guide
```

---

## Updating

```bash
bash scripts/update.sh --check     # Check for available updates
bash scripts/update.sh             # Update all components
bash scripts/update.sh --openshell # OpenShell CLI only
bash scripts/update.sh --openclaw  # OpenClaw image only
```

## Rotating Credentials

```bash
bash scripts/rotate-token.sh    # Generate new gateway token + restart
```

## Stopping

```bash
bash scripts/stop.sh            # Stop OpenShell sandbox
```

---

## Further Reading

- [OpenShell Documentation](https://docs.nvidia.com/openshell/latest)
- [OpenClaw Documentation](https://docs.openclaw.ai)
- [OpenClaw Security Guide](https://docs.openclaw.ai/gateway/security)
- [OpenShell GitHub](https://github.com/NVIDIA/OpenShell)
- [OpenClaw GitHub](https://github.com/openclaw/openclaw)
- [Security Details](docs/security.md)
