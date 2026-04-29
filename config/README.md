## Config Files — README

This directory contains the public OpenClaw configuration template. No secrets live here.

| File | Committed? | Purpose |
|------|-----------|---------|
| `openclaw.example.json` | ✅ yes | Public template — safe for reuse by other users |
| `openclaw.json` | ❌ gitignored | Optional local override in this repo |

### Recommended layout

For a mixed public/private setup, keep your real deployed config in a private repo such as:

```bash
../agents/config/openclaw.json
```

`scripts/install.sh`, `scripts/start.sh`, and `scripts/update.sh --fresh` now stage the committed config into `~/.openclaw/openclaw.json` before onboard using this precedence:

```text
1. OPENCLAW_CONFIG_SOURCE
2. $OPENCLAW_AGENTS_DIR/config/openclaw.json
3. config/openclaw.json
```

### First-time setup

You can either keep your real config in the private agents repo, or create a local repo-scoped override:

```bash
cp config/openclaw.example.json config/openclaw.json
# then edit: add your Telegram user ID to allowFrom, etc.
```

### Exporting UI changes back to Git

If you change settings through the OpenClaw UI, export the live sandbox config back into the committed source path with:

```bash
bash scripts/export-config.sh
```

This strips runtime-only fields such as the live gateway token before writing the file.

### Adding Channels

Edit your committed `openclaw.json` to enable channel blocks (Telegram, Discord, WhatsApp). Add bot tokens to `.env`. Never put tokens in the config file.

### Rollback

The example file is version-controlled. To reset a local repo override to the template:

```bash
cp config/openclaw.example.json config/openclaw.json
```
