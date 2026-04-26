# Security Guide

This document covers the security model, threat mitigations, and operational security procedures for this OpenClaw + OpenShell setup.

---

## Threat Model

OpenClaw is an AI agent with the ability to:
- Receive messages from external platforms (Telegram, Discord, WhatsApp)
- Execute shell commands (if enabled)
- Access the local filesystem (if enabled)
- Make outbound HTTP requests (LLM API calls, webhooks)

The primary threats are:

| Threat | Mitigation |
|--------|-----------|
| Prompt injection causing shell exec | `tools.exec.security: deny` + OpenShell process policy |
| Data exfiltration via outbound requests | OpenShell network policy (deny all except LLM APIs) |
| Unauthorized access to the Control UI | Loopback-only binding + strong auth token |
| Credentials leaked into config/git | No secrets in committed files + gitleaks pre-commit hook |
| Container escape | `cap_drop: ALL` + `no-new-privileges` + `pids_limit` |
| Malicious message sender triggering tools | `dmPolicy: pairing` + per-channel allowlists |
| Token stolen from logs | `logging.redactSensitive: tools` + log rotation |

---

## Host Security (Baseline)

Before deploying, harden the host:

1. **Dedicated machine or VM** — Do not run this on a shared system.
2. **Keep OS and Docker updated** — Enable automatic security updates.
3. **Firewall: default-deny inbound** — Only open ports you explicitly need.
   ```bash
   # Example: allow SSH and nothing else inbound
   sudo ufw default deny incoming
   sudo ufw allow ssh
   sudo ufw enable
   ```
4. **Non-root user** — Don't run Docker or OpenShell as root.
5. **Disk encryption** — If credentials or workspace data persists on disk, encrypt the volume.
6. **No Docker socket exposure** — Never expose `/var/run/docker.sock` unless strictly required and isolated.

---

## Credentials and Secrets

### What to Never Commit

- `.env` (gitignored — real API keys and tokens live here)
- `~/.openclaw/` (gitignored — contains session data, OAuth credentials)
- Any `*.key`, `*.pem`, or `*.p12` files

### What IS Committed (no secrets)

- `config/openclaw.json` — Uses env var references, no inline tokens
- `policies/*.yaml` — Network and filesystem policies, no credentials
- `.env.example` — Placeholder values only

### Secret Scanning

This repo has a `.gitleaks.toml` config. Enable scanning with:

```bash
pip install pre-commit
pre-commit install       # runs gitleaks on every git commit
pre-commit run --all-files  # scan all existing files
```

Install gitleaks standalone for CI:
```bash
# macOS
brew install gitleaks
# Linux
curl -L https://github.com/gitleaks/gitleaks/releases/latest/download/gitleaks_linux_amd64.tar.gz | tar xz
```

---

## Network Access

### OpenShell Policy (Primary Security Layer)

Network access in the OpenShell sandbox is **deny-by-default**. Only policies you explicitly allow go through.

**Start with `base-policy.yaml`**. Only open the minimum needed.

```bash
# View active policy
openshell policy get openclaw

# Apply minimal policy (LLM APIs only)
openshell policy set openclaw --policy policies/base-policy.yaml --wait

# Apply extended policy only when needed, revert after
openshell policy set openclaw --policy policies/extended-policy.yaml --wait
# ... do the task ...
openshell policy set openclaw --policy policies/base-policy.yaml --wait
```

All policy changes are logged. To review:
```bash
openshell logs openclaw --tail
```

### Docker Compose Network (Fallback)

The `docker-compose.yml` uses a named internal network (`openclaw-net`). The container has outbound internet access but is isolated from other Docker containers.

**If you need to restrict outbound on the Compose path**, consider adding an egress proxy (e.g., [squid](http://www.squid-cache.org/) or [tinyproxy](https://tinyproxy.github.io/)) as a Docker service with an allow-only config.

---

## Remote Access (HTTPS / Reverse Proxy)

By default, the gateway is loopback-only (`127.0.0.1`). **Do not expose it directly** to a public network.

### If you need remote access

Use one of these patterns:

**Option A — Tailscale (recommended for personal use)**
```bash
# Install Tailscale on the host and your devices
# The gateway is only accessible from your Tailscale network
# No inbound ports needed on the host firewall
```

**Option B — Caddy reverse proxy with HTTPS**

Create `caddy/Caddyfile`:
```
openclaw.yourdomain.com {
    basicauth / {
        # bcrypt hash of password: caddy hash-password --plaintext yourpassword
        admin $2a$14$...
    }
    reverse_proxy openclaw-gateway:18789
}
```

Add to `docker-compose.yml`:
```yaml
  caddy:
    image: caddy:2-alpine
    ports:
      - "443:443"
      - "80:80"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
    networks:
      - openclaw-net
```

Change the gateway port binding to internal-only:
```yaml
# Remove the host port binding for the gateway (Caddy proxies internally)
# ports:
#   - "127.0.0.1:${OPENCLAW_GATEWAY_PORT:-18789}:18789"
```

**Option C — SSH tunnel**
```bash
# From your remote machine:
ssh -L 18789:127.0.0.1:18789 user@your-server
# Then access http://127.0.0.1:18789/ locally
```

---

## Messaging Channel Security

### Principle: Minimize Who Can Trigger the Bot

Every person who can send a DM to the bot has the bot's full tool permission set. Be strict about who can send messages.

**Recommended settings** (already in `config/openclaw.json`):

```json5
{
  session: { dmScope: "per-channel-peer" },
  channels: {
    telegram: { dmPolicy: "pairing" },  // only accept DMs from paired users
    discord:  { dmPolicy: "pairing", servers: { "*": { requireMention: true } } },
  }
}
```

After starting, pair your account:
```bash
# Inside the sandbox or container
openclaw channels pair --channel telegram
```

### Context Visibility

Set `contextVisibility: "allowlist"` to prevent prompt injection from forwarded/quoted messages from non-allowlisted senders:

```json5
channels: {
  telegram: {
    contextVisibility: "allowlist",
    dmPolicy: "pairing",
  }
}
```

---

## Tool Blast Radius

The hardened `openclaw.json` disables shell execution and filesystem access by default. If you need to enable them temporarily:

1. **Scope it to one agent** — Don't enable globally
2. **Use `ask: "always"`** — The agent asks before running any command
3. **Enable OpenShell sandbox mode** — Uncomment the Docker socket mount in `docker-compose.yml` and enable agent sandboxing in `openclaw.json`
4. **Revert when done** — Re-commit the restricted config

```json5
// ONLY enable if needed, for a specific agent:
tools: {
  exec: {
    security: "ask",   // "deny" -> "ask" (still requires approval)
    ask: "always",
  },
}
```

---

## Log Management

### What's Logged

- Gateway requests and tool calls (with sensitive values redacted)
- OpenShell policy decisions (allows and denies)
- Health check results

### Retention

Docker Compose logs are rotated: 10MB × 5 files = 50MB max per service.

To view logs:
```bash
docker compose logs -f --tail=100 openclaw-gateway    # Docker path
openshell logs openclaw --tail                        # OpenShell path
```

---

## Incident Response

If you suspect a compromise:

### Immediate containment

```bash
bash scripts/stop.sh         # Kill the sandbox immediately
# OR
docker compose down          # If using Compose path
```

### Token rotation

```bash
bash scripts/rotate-token.sh
```

### Assess damage

1. Review logs: `docker compose logs openclaw-gateway > /tmp/incident-logs.txt`
2. Review OpenShell policy decisions: `openshell logs openclaw`
3. Check `~/.openclaw/` for unexpected files
4. Review workspace: `ls -la ~/.openclaw/workspace/`
5. Check for outbound connections that may have exfiltrated data

### Rebuild from clean state

```bash
# Remove all OpenClaw data (this deletes memory and credentials)
docker compose down -v
rm -rf ~/.openclaw

# Re-run setup from known-good git state
git checkout main
git log --oneline   # verify you're on a good commit
bash scripts/install.sh
# Set fresh credentials in .env
bash scripts/start.sh
```

---

## Regular Maintenance

| Task | Frequency | Command |
|------|-----------|---------|
| Security audit | Weekly | `bash scripts/audit.sh` |
| Check for updates | Weekly | `bash scripts/update.sh --check` |
| Apply updates | Monthly | `bash scripts/update.sh` |
| Rotate gateway token | Monthly | `bash scripts/rotate-token.sh` |
| Review git log for config drift | After any change | `git log --oneline` |
| Review OpenShell policy | After any task | `openshell policy get openclaw` |

---

## References

- [OpenShell Security Model](https://github.com/NVIDIA/OpenShell#protection-layers)
- [OpenClaw Security Guide](https://docs.openclaw.ai/gateway/security)
- [OpenClaw Security Audit](https://docs.openclaw.ai/gateway/security#quick-check-openclaw-security-audit)
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [gitleaks](https://github.com/gitleaks/gitleaks)
