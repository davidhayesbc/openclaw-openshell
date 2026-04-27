## Config Files — README

This directory contains OpenClaw configuration. No secrets live here.

| File | Committed? | Purpose |
|------|-----------|---------|
| `openclaw.example.json` | ✅ yes | Public template — no personal data |
| `openclaw.json` | ❌ gitignored | Your live config — add your user IDs here |

### First-time setup

`scripts/install.sh` creates `config/openclaw.json` from the example automatically. Or do it manually:

```bash
cp config/openclaw.example.json config/openclaw.json
# then edit: add your Telegram user ID to allowFrom, etc.
```

### How Config is Loaded

`scripts/start.sh` syncs `config/openclaw.json` into the running sandbox before the gateway starts. Any change to this file takes effect on the next `bash scripts/stop.sh && bash scripts/start.sh`.

### Adding Channels

Edit `config/openclaw.json` to enable channel blocks (Telegram, Discord, WhatsApp). Add bot tokens to `.env`. Never put tokens in the config file.

### Rollback

The example file is version-controlled. To reset your live config to the template:

```bash
cp config/openclaw.example.json config/openclaw.json
# re-add your personal values, then restart
```
