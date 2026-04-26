## Config Files — README

This directory contains committed OpenClaw configuration files. **No secrets live here.** All sensitive values are injected at runtime via environment variables defined in `.env` (which is gitignored).

### Files

| File | Purpose |
|------|---------|
| `openclaw.json` | OpenClaw gateway hardened config — committed, no secrets |

### How Config is Loaded

OpenClaw reads `~/.openclaw/openclaw.json` (inside the container: `/home/node/.openclaw/openclaw.json`). This file is bind-mounted from `OPENCLAW_CONFIG_DIR` on the host.

**To apply config changes:**

```bash
# Copy config to the openclaw config directory
cp config/openclaw.json ${OPENCLAW_CONFIG_DIR:-~/.openclaw}/openclaw.json

# Restart the gateway
docker compose restart openclaw-gateway
# OR (OpenShell path):
openshell sandbox connect openclaw   # then restart daemon inside
```

Or use `scripts/start.sh` which does this automatically.

### Adding Channels

Edit `openclaw.json` to uncomment and configure the channel blocks (Telegram, Discord, WhatsApp). Then add the bot token to `.env`. Never put tokens directly in this file.

### Rollback

Because `openclaw.json` is committed to git, you can always roll back:

```bash
git log --oneline config/openclaw.json   # see history
git checkout <sha> -- config/openclaw.json  # restore a version
```
