## Policy Files — README

These YAML files define [OpenShell sandbox policies](https://docs.nvidia.com/openshell/latest) that control what the OpenClaw agent is allowed to do inside its sandbox.

### Files

| File | Purpose |
|------|---------|
| `base-policy.yaml` | Minimal — Anthropic/OpenAI/OpenRouter + local Ollama only |
| `extended-policy.yaml` | Extended — base + Ollama Cloud + GitHub read-only + npm + Telegram |

### Policy Domains

| Domain | When it applies | Reloadable? |
|--------|----------------|-------------|
| `filesystem_policy` | Locked at sandbox creation | No — recreate sandbox |
| `process` | Locked at sandbox creation | No — recreate sandbox |
| `network_policies` | Hot-reloadable at runtime | Yes — `openshell policy set` |

### Applying a Policy

```bash
# Apply base (minimal) policy
openshell policy set openclaw --policy policies/base-policy.yaml --wait

# Check active policy
openshell policy get openclaw

# Temporarily extend for a dev task, then revert
openshell policy set openclaw --policy policies/extended-policy.yaml --wait
# ... do work ...
openshell policy set openclaw --policy policies/base-policy.yaml --wait
```

### Generating Custom Policies

Use the OpenShell policy generator skill (point your agent at the OpenShell repo):

```bash
git clone https://github.com/NVIDIA/OpenShell.git _openshell-src
# Point your agent at _openshell-src — it will find the generate-sandbox-policy skill
```

Or describe what you need in plain English: `openshell sandbox connect openclaw` then ask the agent to generate a policy.

### Security Principle

**Start with `base-policy.yaml`.** Only widen access when necessary, for the duration it's needed. Narrow back when done. All policy changes are logged by OpenShell.
