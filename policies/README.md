# Policies — NemoClaw Network Presets

NemoClaw uses a preset-based policy system rather than raw OpenShell policy YAML.
Inference traffic is automatically routed through the OpenShell L7 gateway proxy,
so explicit egress rules for LLM providers (Anthropic, OpenAI, OpenRouter) are
no longer needed in the sandbox policy.

## Managing Presets

```bash
# Add a built-in preset
nemoclaw openclaw policy-add <preset-name>

# Available built-in presets:
#   brave  brew  discord  github  huggingface  jira
#   npm  outlook  pypi  slack  telegram

# Remove a preset
nemoclaw openclaw policy-remove <preset-name>

# List active presets
nemoclaw openclaw policy-list

# Apply a custom preset from a YAML file
nemoclaw openclaw policy-add --from-file policies/my-preset.yaml
```

## Custom Preset Format

```yaml
name: my-service
description: Allow access to my-service API

policies:
  - name: my-service-api-write
    match:
      - host: api.my-service.com
        port: 443
        protocol: tcp
    allow: true
```

Save as `policies/my-preset.yaml` (committed to git, no secrets) and apply:

```bash
nemoclaw openclaw policy-add --from-file policies/my-preset.yaml
```

## Legacy Files

`base-policy.yaml` and `extended-policy.yaml` in this directory are **legacy
references** from before the NemoClaw migration. They document the old OpenShell
raw policy format. They are not applied automatically and are kept only for
historical reference.

## Policy Tiers

The base tier is set during `nemoclaw onboard`. To change it:

| Tier | Access level |
|------|-------------|
| `restricted` | LLM inference only (default) |
| `balanced` | Inference + curated dev presets |
| `open` | Inference + broad internet (dev use) |

```bash
nemoclaw openclaw policy-set-tier balanced
```