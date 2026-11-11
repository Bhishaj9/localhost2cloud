---
name: localhost2cloud
description: Boot a local app on this laptop and hand the user ONE public link their team can open like a cloud-hosted app, then tear it down on request. Use when the user says "boot it up", "start the demo", "give me a shareable link", "host this for my team", "make my laptop an EC2", "demo remotely", "stop the demo", or asks to expose a localhost app to remote viewers.
argument-hint: "[boot|stop|status|setup] [path-to-demo.config.json]"
license: MIT
compatibility: Windows (PowerShell 5.1+) or macOS/Linux (bash 4+, curl, python3 or jq). Needs cloudflared (tunnel) and caddy (single-origin gateway); install-tools.sh / Install-Tools.ps1 provision both.
metadata:
  author: command-code
  version: "1.0.0"
---

# localhost2cloud

Turn this laptop into a temporary "EC2" for a remote demo: boot the app stack, produce
one `https://...` link, share it, and close it when the audience is done. No Google Meet
screen share, nothing deployed to a cloud.

All the mechanics live in `scripts/`. Your job is to know *which* script to run, and to
catch the app-level things that silently break through a tunnel before the user finds out
in front of their team.

## The one rule that makes this work

**Every browser request must reach one local origin.** A tunnel points at exactly one
local address. If the page is served from port 3000 but the browser opens a WebSocket to
port 7500, remote viewers will fail — and the app will look "broken in the cloud but fine
locally".

So the topology is always:

```
browser  ->  https://<random>.trycloudflare.com      (cloudflared)
                     |
                     v
            127.0.0.1:<gateway.port>                 (caddy, generated from config)
               |                    |
        /api/v1/* to engine     everything else to app
```

The gateway is generated on every boot from `demo.config.json`, so routes can never drift
from the config. Never hand-write the Caddyfile; never add a second tunnel.

## Commands

Two equivalent implementations ship in `scripts/`:
**`*.ps1`** (Windows PowerShell) and **`*.sh`** (macOS/Linux bash). Pick by platform; the
behaviour and config format are identical, and the state file is interchangeable.

Run these from the project root (they auto-discover `demo.config.json` upward).

**macOS / Linux**

| Intent | Command |
|---|---|
| Boot and print the link | `<skill>/scripts/start.sh` |
| Boot, local only (no public URL) | `... start.sh --provider none` |
| Rebuild/restart cleanly | `... start.sh --force` |
| Boot with hot reload | `... start.sh --dev` |
| Re-print / health-check the link | `... status.sh` |
| Close the link | `... stop.sh` |
| First-time tool install | `... install-tools.sh` |

**Windows**

| Intent | Command |
|---|---|
| Boot and print the link | `powershell -File <skill>\scripts\Start-Demo.ps1` |
| Boot, local only (no public URL) | `... Start-Demo.ps1 -Provider none` |
| Rebuild/restart cleanly | `... Start-Demo.ps1 -Force` |
| Boot with hot reload | `... Start-Demo.ps1 -DevMode` |
| Re-print / health-check the link | `... Status-Demo.ps1` |
| Close the link | `... Stop-Demo.ps1` |
| First-time tool install | `... Install-Tools.ps1` |

`<skill>` is this skill's directory, e.g. `~/.commandcode/skills/localhost2cloud`.

## Workflow: "boot it up"

1. **Read the config.** `demo.config.json` in the project root. If it does not exist, go to
   "First-time setup", then come back.
2. **Preflight the app-level traps** (below). Do this *before* booting — a demo link that
   loads a page which cannot connect is worse than no link.
3. **Run the start script for this platform** (`start.sh` or `Start-Demo.ps1`). It verifies
   each service, reuses what is already healthy, generates the gateway, opens the tunnel, and
   probes the public URL end to end. The last line is the link.
4. **Report the link to the user** on its own line, and state plainly that anyone holding it
   can open it, and that it dies when the user stops the demo.
5. **Do not paste the link into anything external** (email, chat tool, issue, PR) on your own.
   The user shares it.
6. **After feedback, run the stop script** (`stop.sh` / `Stop-Demo.ps1`) as soon as the user
   says they are done. Confirm the link is dead. Leave the user's pre-existing services alone
   (the stop script does this by default).

Never leave the tunnel running after the demo ends — an anonymous public URL pointed at the
user's laptop is exactly the thing to forget about.

## Workflow: "stop it" / "they're done"

`stop.sh` / `Stop-Demo.ps1`, then report what was stopped. If the user wants the whole stack
down too, add `--include-reused` / `-IncludeReused` — but it still refuses to kill services it
never started, and will name any port still held so the user can decide.

## Preflight: the traps that only show up remotely

Check these in the app before booting. Each one has bitten a real demo.

1. **Hardcoded `127.0.0.1` / `localhost` in browser code.** The browser runs on the *viewer's*
   machine, so `ws://127.0.0.1:7500` dials their own laptop. Client-side sockets and API URLs
   must be same-origin (empty host / relative path) or a public hostname.
   - Grep the frontend for `127.0.0.1`, `localhost`, `ws://`, `wss://`, and any
     `NEXT_PUBLIC_*_HOST`-style variable, and confirm each resolves to the page's own origin.
2. **Framework dev-server host/origin guards.** Next.js ≥15.2 blocks cross-origin dev requests;
   Vite ≥5.4.12 blocks unknown `Host` headers. Tunnel hostnames are random, so allowlist the
   whole tunnel domain, not one hostname:
   - Next: `allowedDevOrigins: ['*.trycloudflare.com', ...]` in `next.config.*`
   - Vite: `server.allowedHosts: ['.trycloudflare.com', ...]` (leading dot = all subdomains)
   - Only relevant in dev mode; a production build (`next start` / `vite preview`) has no
     such guard, which is why production mode is the default for demos.
3. **Secrets now have a public audience.** Tunnels bypass localhost-only assumptions. If the
   app injects an API key server-side (a BFF or proxy route), that is fine. If the key is in
   client bundle, it is public. Flag it before sharing.
4. **No access control on the free tunnel.** Anyone with the URL gets in. Say so, keep the
   demo window short, and never expose admin or customer data.
5. **Absolute asset/base URLs.** Anything baked to `http://localhost:3000` breaks. Prefer
   relative paths.
6. **Cookies and HTTPS.** The public URL is `https`, so `Secure` cookies work; but an app that
   *requires* http will misbehave. Note it.
7. **Long-lived connections.** WebSockets and SSE work through the tunnel, but only if they
   are same-origin per rule 1. Audio/voice features are the usual casualty.

Report preflight findings as findings, not blockers: state what is fine, and what will break
if left alone.

## First-time setup for a new project

1. Copy `assets/demo.config.example.json` to the project root as `demo.config.json`.
2. Fill in `services[]`:
   - `command` + `startArgs` for a **production** start, plus `buildCommand` + `buildArgs` if
     the app needs compiling. A `buildArgs` without `buildCommand` is rejected on purpose —
     otherwise a stale bundle gets demoed silently.
   - `dir` relative to the config file, `port`, and a `healthUrl` that returns 2xx.
   - `default: true` on the service that serves the page.
   - `expose: ["/api/v1/*"]` on any other service the browser must reach, mapping the exact
     path prefixes that belong to it.
   - `verifyPath` + `acceptStatus` when the only reachable path is auth-gated: a `401` through
     the tunnel proves the proxy reached the service. Without this, verification reports a
     false failure on a perfectly routed API.
   - `managed: false` for anything the skill must never start (shared DB, already-running
     backend).
   - `note` for per-service caveats worth surfacing after a boot.
3. Pick a free `gateway.port` (default 8081). Check it first — Docker Desktop and Hyper-V
   reserve ranges, and a hung process can hold a port while accepting connections without
   answering HTTP.
4. Boot once with `-Provider none` and fix routing before exposing anything publicly.
5. Commit `demo.config.json`; `.demo-state/` is local scratch — make sure it is gitignored.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Page loads but no live/chat/voice data | Client socket points at `127.0.0.1` or another port | Same-origin socket path (preflight #1), then rebuild |
| `403 Forbidden` from dev server, or "Blocked cross-origin request" | Framework host guard | Add the tunnel domain to `allowedDevOrigins` / `allowedHosts`, or use production mode |
| Public URL returns `530` right after boot | Cloudflare edge DNS not propagated yet | Wait 30–75s; the boot check and `status` both retry |
| `Port ... is held by ... but health is not responding` | A leftover/hung process owns the port (often Docker Desktop) | The skill will not kill it. Identify it, ask the user, then stop it |
| Tunnel process exits immediately | `cloudflared` binary missing or blocked | `Install-Tools.ps1` |
| Link works, then dies mid-demo | Laptop slept, VPN flip, or Wi-Fi change | `Status-Demo.ps1`; if the tunnel is down, `Stop-Demo.ps1` then `Start-Demo.ps1` (new URL — reshare) |
| Health OK through tunnel but page blank | Absolute base URL or asset 404 | Check `curl -I <url>/_next/static/...`; fix base path |
| Two demos at once on one laptop | Different projects, same gateway port | Give each project its own `gateway.port` |

## Reference

- `scripts/common.ps1` / `scripts/common.sh` — discovery, probing, state, Caddyfile
  generation. Read before changing behaviour; every script depends on its contracts.
- `assets/demo.config.example.json` — annotated config template with every field explained.
- Provider alternatives and their trade-offs: `references/providers.md`.
