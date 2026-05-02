---
name: codex
description: Delegate complex coding tasks to OpenAI Codex (GPT-5.4) using the user's ChatGPT Plus subscription. Use when the user asks you to write, refactor, debug, review, or explain code — especially multi-file or multi-step tasks. Trigger keywords - codex, write code, refactor, implement, debug, code review, build feature, create function, fix bug.
---

Use the `codex exec` CLI to delegate coding tasks to GPT-5.4, billed to the user's ChatGPT Plus subscription. Codex runs non-interactively and can read and write files in its working directory.

## Basic Usage

```bash
codex exec --skip-git-repo-check 'your task description here'
```

## Key Flags

| Flag | Purpose |
|------|---------|
| `--skip-git-repo-check` | Required when not inside a git repo |
| `-m <model>` | Override model (default: `gpt-5.4`) |
| `-c 'sandbox_permissions=["disk-full-read-access"]'` | Allow Codex to read all files |
| `-c 'sandbox_permissions=["disk-full-read-write-access"]'` | Allow Codex to read and write files |

## Shell Permissions

Always use `required_permissions: ["full_network"]` for `codex exec` commands — Codex must reach `chatgpt.com`.

## Working with Files

To let Codex read and modify files in the current working directory:

```bash
codex exec \
  --skip-git-repo-check \
  -c 'sandbox_permissions=["disk-full-read-write-access"]' \
  'refactor auth.js to use async/await throughout'
```

## Inside a Git Repo

If the working directory is a git repo, omit `--skip-git-repo-check`:

```bash
cd /path/to/project
codex exec -c 'sandbox_permissions=["disk-full-read-write-access"]' 'add unit tests for the parser module'
```

## Model Selection

The default model is `gpt-5.4`. To use a different model:

```bash
codex exec --skip-git-repo-check -m gpt-5 'explain this codebase'
codex exec --skip-git-repo-check -m codex-mini-latest 'add a docstring to each function'
```

Available models (via ChatGPT Plus subscription):
- `gpt-5.4` — default, best for complex tasks
- `gpt-5` — latest GPT-5
- `gpt-5-codex` — Codex-tuned variant
- `codex-mini-latest` — faster, good for smaller tasks

## Authentication

Codex reads OAuth credentials from `~/.codex/auth.json`. If you see auth errors, re-run:

```bash
codex login --device-auth
```

Or ask the user to run `scripts/codex-auth.sh` from the repo root on the host.

## Checking Auth Status

```bash
codex login status
```

## Typical Patterns

### Review and explain code
```bash
codex exec --skip-git-repo-check \
  -c 'sandbox_permissions=["disk-full-read-access"]' \
  'review the code in /sandbox and explain what it does'
```

### Implement a feature
```bash
codex exec \
  --skip-git-repo-check \
  -c 'sandbox_permissions=["disk-full-read-write-access"]' \
  'implement a retry wrapper around the HTTP client in src/client.js'
```

### Fix a bug
```bash
codex exec \
  --skip-git-repo-check \
  -c 'sandbox_permissions=["disk-full-read-write-access"]' \
  'the login endpoint returns 500 when the email has uppercase letters — find and fix the bug'
```
