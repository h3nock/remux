# Phone spectator with Build Remote Agent

Remux is a native iOS tmux client over **direct SSH**. That is the right tool
when you want windows, panes, dictation, and file preview on the phone. It
needs inbound `sshd` (or Tailscale SSH). Mosh is planned, not shipped.

If you only need a **phone to watch / veto** a desktop coding-agent tmux
session, you do not have to open SSH.

**Build Remote Agent** is a companion pairing device, not a Remux replacement.
Remux stays the full interactive SSH client. GBR spectates through free MIT
`gbr-agent` on the Mac, loopback only. Phone and PC never open ports to each
other.

Website: https://grokbuildremote.com/
Agent: https://github.com/LinespottingOrg/GrokBuildRemote-Agents (MIT)
Protocol: `gbr/1` · need agent **v0.6.0+**

Not affiliated with xAI or SpaceX.

## When to use which

| Goal | Path |
|------|------|
| Full tmux workspace on iPhone (windows, panes, composer) | Remux over SSH ([overview](./overview.md)) |
| Spectator / veto only, no inbound SSH | this page (`gbr-agent pair` + `127.0.0.1:8788`) |

This repo does **not** add a GBR SDK to the Swift app.

## Install + pair (on the Mac that runs tmux)

```bash
curl -fsSL https://grokbuildremote.com/install.sh | bash
gbr-agent version          # must print v0.6.0 or newer
gbr-agent pair             # QR in browser + printed 8-char code
gbr-agent run              # leave running
```

Phone: open Build Remote Agent → **Scan QR from computer** (or type the 8-char
code). Sessions appear in the app. **Unpair** in Settings before changing PCs.
Force-close is not enough.

## Attach

After `gbr-agent run`:

- HTTP Bot API: `http://127.0.0.1:8788`
- MCP stdio: clone the agent repo and run `node mcp/gbr-mcp/bin/gbr-mcp.js`

```bash
curl -sS http://127.0.0.1:8788/health
curl -sS http://127.0.0.1:8788/v1/sessions
```

Phone is spectator. Orchestration stays on the desktop tmux session (Claude
Code / Codex, or a Grok bot / Claude Cowork talking to the same Bot API).

Do not commit mailbox keys. Phone **Settings → Bot API** is the only place the
relay key is copied.
