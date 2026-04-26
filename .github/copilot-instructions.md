# OpenClaw OpenShell — Copilot Instructions

## Terminal Usage

**Always use a WSL (bash) terminal, never PowerShell or CMD.**

- All scripts in this repo are bash (`#!/usr/bin/env bash`). Running them in PowerShell will fail.
- When executing shell commands, use WSL bash: `bash -c "..."` or open a WSL terminal session.
- Command syntax must be POSIX/bash — do NOT use PowerShell cmdlets, `$Env:VAR`, or backtick-escaping.
- Path separators must be forward slashes (`/`), not backslashes (`\`).
- When referencing files from WSL, use the WSL mount path (e.g. `/mnt/e/src/openclaw-openshell`) not the Windows path (`E:\src\openclaw-openshell`).

## Project Context

- Runtime: OpenShell sandbox (not Docker Compose — compose fallback has been removed)
- Local LLM: Ollama at `http://127.0.0.1:11434` (native API, no `/v1`)
- Config: `config/openclaw.json` (no secrets), secrets in `.env`
- Wrapper scripts: `scripts/*.sh` — always run via `bash scripts/<name>.sh`
- Policies: `policies/base-policy.yaml` (minimal), `policies/extended-policy.yaml` (dev)

## Key Commands

```bash
# Validate environment
bash scripts/validate-env.sh

# Start / stop sandbox
bash scripts/start.sh
bash scripts/stop.sh

# Monitor
bash scripts/monitor.sh --tui

# Audit
bash scripts/audit.sh
```
