## Policy Files — README

These YAML files define [OpenShell sandbox policies](https://docs.nvidia.com/openshell/latest) that control what the OpenClaw agent is allowed to do inside its sandbox.

### Files

| File | Purpose |
|------|---------|
| `policy.yaml` | Single policy — all LLM APIs, local Ollama & LM Studio, Telegram, GitHub read-only, npm |

### Policy Domains

| Domain | When it applies | Reloadable? |
|--------|----------------|-------------|
| `filesystem_policy` | Locked at sandbox creation | No — recreate sandbox |
| `process` | Locked at sandbox creation | No — recreate sandbox |
| `network_policies` | Hot-reloadable at runtime | Yes — `openshell policy set` |

### Applying the Policy

```bash
# Apply (also done automatically by start.sh)
openshell policy set openclaw --policy policies/policy.yaml --wait

# Check active policy
openshell policy get openclaw
```

### Generating Custom Policies

Use the OpenShell policy generator skill (point your agent at the OpenShell repo):

```bash
git clone https://github.com/NVIDIA/OpenShell.git _openshell-src
# Point your agent at _openshell-src — it will find the generate-sandbox-policy skill
```

Or describe what you need in plain English: `openshell sandbox connect openclaw` then ask the agent to generate a policy.
