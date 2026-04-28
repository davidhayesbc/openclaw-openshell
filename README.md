# OpenClaw + NemoClaw — Secure Self-Hosted Setup

A git-tracked setup for running [OpenClaw](https://openclaw.ai/) (AI personal assistant) via [NemoClaw](https://github.com/NVIDIA/NemoClaw) — NVIDIA's reference stack that wraps OpenClaw + OpenShell with a managed CLI, onboard wizard, and built-in credential management.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Host Machine                                            │
│                                                          │
│  ┌─────────────────────────────────────────────────┐     │
│  │  NemoClaw                                       │     │
│  │                                                 │     │
│  │  ┌──────────────────────────────────────────┐   │     │
│  │  │  OpenShell Gateway (k3s-in-Docker)       │   │     │
│  │  │                                          │   │     │
│  │  │  ┌──────────────────────────────────┐    │   │     │
│  │  │  │  OpenClaw Sandbox                │    │   │     │
│  │  │  │  - Landlock + seccomp + netns    │    │   │     │
│  │  │  │  - Inference proxied via gateway │    │   │     │
│  │  │  │  - Network: deny-by-default      │    │   │     │
│  │  │  └──────────────────────────────────┘    │   │     │
│  │  │                                          │   │     │
│  │  │  L7 Inference Proxy                      │   │     │
│  │  │  - Injects credentials at network edge   │   │     │
│  │  │  - Sandbox uses inference.local only     │   │     │
│  │  └──────────────────────────────────────────┘   │     │
│  └─────────────────────────────────────────────────┘     │
│                           │                              │
│                   nemoclaw <name> connect                │
│                    Browser / CLI                         │
└──────────────────────────────────────────────────────────┘
```

**NemoClaw** manages the full lifecycle. The sandbox never holds raw provider keys — credentials are injected by the OpenShell L7 gateway at the network boundary.

## Quick Start

### 1. Prerequisites

- Docker Desktop (or Docker Engine) running
- Git
- Linux or macOS (Windows: WSL2)

### 2. Install

```bash
git clone <this-repo> openclaw-openshell
cd openclaw-openshell

# Installs NemoClaw CLI (Node.js via nvm + nemoclaw npm package, no sudo)
bash scripts/install.sh
```

### 3. Configure (optional)

```bash
cp .env.example .env
# Edit NEMOCLAW_SANDBOX_NAME, messaging tokens, etc.
nano .env

bash scripts/validate-env.sh
```

### 4. Onboard + launch

```bash
bash scripts/start.sh
# First run: guided onboard wizard (provider, model, policy tier, optional channels)
# Subsequent runs: auto-connects to the running sandbox
```

### 5. Monitor

```bash
bash scripts/monitor.sh                # OpenShell TUI (live dashboard, default)
bash scripts/monitor.sh --status       # Status snapshot
bash scripts/monitor.sh --logs         # Stream sandbox logs
bash scripts/monitor.sh --policy       # Show active network policy presets
```

### 6. Security audit

```bash
bash scripts/audit.sh
bash scripts/audit.sh --deep           # Full diagnostics tarball
```

---

## Security Model

### What NemoClaw / OpenShell Provides

| Layer | Enforcement |
|-------|-------------|
| **Inference credentials** | Injected by gateway L7 proxy; sandbox never holds raw keys |
| **Network policy** | Deny-by-default + preset-based allow rules (hot-reloadable) |
| **Filesystem isolation** | Landlock: workspace-only access |
| **Process isolation** | seccomp + netns; no privilege escalation |
| **Token management** | `nemoclaw <name> gateway-token` (no `.env` token needed) |

### What OpenClaw Config Provides (`config/openclaw.json`)

- `tools.exec.security: deny` — no shell execution
- `tools.fs.workspaceOnly: true` — no host filesystem access
- `session.dmScope: per-channel-peer` — session isolation
- `models.providers.ollama` — local Ollama inference (via inference proxy)

---

## Network Policies

NemoClaw uses a tiered policy system with built-in presets.

### Policy tiers (set during onboard)

| Tier | Access |
|------|--------|
| `restricted` | LLM inference only |
| `balanced` | Inference + curated dev tools |
| `open` | Inference + broad internet (developer use) |

### Built-in presets

```bash
# Add a preset
nemoclaw openclaw policy-add github
nemoclaw openclaw policy-add npm
nemoclaw openclaw policy-add telegram

# Available: brave brew discord github huggingface jira npm outlook pypi slack telegram

# List active presets
nemoclaw openclaw policy-list
```

### Custom presets

```bash
# Apply a custom preset from file
nemoclaw openclaw policy-add --from-file policies/my-preset.yaml
```

See `policies/README.md` for custom preset format and `policies/base-policy.yaml` for the legacy OpenShell policy (retained as reference).

---

## Ollama (Local Inference)

NemoClaw routes Ollama calls through the inference proxy. Select Ollama during the onboard wizard or:

```bash
# Pull model on host
ollama pull llama3.1:8b

# NemoClaw will proxy inference.local -> host Ollama
# The OLLAMA_BASE_URL in .env pre-seeds the wizard with the endpoint
```

---

## Git Rollback

All configs are version-controlled. To roll back:

```bash
git log --oneline config/openclaw.json

# Restore a specific version
git checkout <sha> -- config/openclaw.json

# Apply to sandbox (NemoClaw snapshots on next onboard)
cp config/openclaw.json ~/.openclaw/openclaw.json
```

---

## Directory Structure

```
.
├── .env.example              # Template (committed — no real values)
├── .gitignore
├── .gitleaks.toml            # Secret scanning config
├── .pre-commit-config.yaml   # Git pre-commit hooks (gitleaks)
├── docker-compose.yml        # SUPERSEDED — legacy reference only
├── policies/
│   ├── base-policy.yaml      # LEGACY OpenShell policy — see README inside
│   ├── extended-policy.yaml  # LEGACY — see README inside
│   └── README.md             # NemoClaw preset guide
├── config/
│   ├── openclaw.json         # OpenClaw agent config (no secrets)
│   └── README.md
├── scripts/
│   ├── install.sh            # One-time NemoClaw install
│   ├── start.sh              # Onboard or connect
│   ├── stop.sh               # Snapshot or destroy sandbox
│   ├── update.sh             # Update NemoClaw CLI + sandbox images
│   ├── monitor.sh            # TUI, logs, policy, diagnostics
│   ├── audit.sh              # Security audit
│   ├── validate-env.sh       # Validate environment
│   └── rotate-token.sh       # Print gateway token
└── docs/
    └── security.md
```

---

## Updating

```bash
bash scripts/update.sh --check       # Check for stale sandbox images
bash scripts/update.sh               # Update CLI + sandbox images
bash scripts/update.sh --cli         # NemoClaw CLI only
bash scripts/update.sh --sandboxes   # Sandbox images only
```

## Stopping / Lifecycle

```bash
bash scripts/stop.sh                 # Show status + help
bash scripts/stop.sh --snapshot      # Create workspace snapshot
bash scripts/stop.sh --destroy       # Destroy sandbox (irreversible)
```

## Gateway Token

```bash
bash scripts/rotate-token.sh         # Print current gateway token
```

---

## Further Reading

- [NemoClaw GitHub](https://github.com/NVIDIA/NemoClaw)
- [NemoClaw Documentation](https://docs.nvidia.com/nemoclaw/latest)
- [OpenShell GitHub](https://github.com/NVIDIA/OpenShell)
- [OpenClaw Documentation](https://docs.openclaw.ai)
- [Security Details](docs/security.md)