# localhost2cloud

Turn your laptop into a temporary cloud host. One command boots your local app stack and
gives you a single shareable `https://` link your team can open in a browser — no deploy, no
screen share, no account with a tunnel provider.

```
$ .\Start-Demo.ps1

======================================================================
  SHARE THIS LINK

  https://read-valium-singh-registrar.trycloudflare.com

======================================================================
  All checks passed from the public internet.
  When they are done:  .\Stop-Demo.ps1
```

Built as an [Agent Skill](https://agentskills.io/specification) for
[Command Code](https://commandcode.ai), but the scripts work standalone in any shell.

---

## The problem it actually solves

Exposing `localhost:3000` with a tunnel is the easy part. The part that breaks is that real
apps talk to more than one port: our frontend served the page on `3100` while the browser
opened its WebSocket to `7500`. A tunnel points at **one** local address, so remote viewers
got a page that loaded fine and then silently failed to connect — working locally, broken in
the cloud, and nothing in the logs said why.

`localhost2cloud` puts every service behind **one local origin** and tunnels that:

```
browser ──▶ https://<random>.trycloudflare.com     (cloudflared)
                     │
                     ▼
            127.0.0.1:<gateway.port>               (caddy, generated per boot)
               │                    │
        /api/v1/* → engine     everything else → app
```

The gateway config is **generated from `demo.config.json` on every boot**, so routes can
never drift from what the app actually needs.

---

## Quick start

**1. Install the two tools** (cloudflared + caddy, one time):

```powershell
.\scripts\Install-Tools.ps1
```

**2. Describe your stack.** Copy the annotated template to your project root:

```powershell
Copy-Item .\assets\demo.config.example.json D:\YourProject\demo.config.json
```

```json
{
  "services": [
    {
      "name": "app",
      "command": "node",
      "startArgs": ["node_modules/next/dist/bin/next", "start", "-p", "3000"],
      "buildCommand": "npx",
      "buildArgs": ["next", "build"],
      "port": 3000,
      "healthUrl": "http://127.0.0.1:3000/",
      "default": true
    }
  ],
  "gateway": { "port": 8081 }
}
```

**3. Boot it:**

```powershell
cd D:\YourProject
.\path\to\localhost2cloud\scripts\Start-Demo.ps1
```

Share the link. When feedback is done:

```powershell
.\path\to\localhost2cloud\scripts\Stop-Demo.ps1
```

Scripts find `demo.config.json` by walking up from the current directory, so they work in any
project without flags.

---

## Commands

| Command | What it does |
|---|---|
| `Start-Demo.ps1` | Boot the stack, open a tunnel, print the link, verify it publicly |
| `Status-Demo.ps1` | Check processes, ports, routing and the public URL; re-print the link |
| `Stop-Demo.ps1` | Close the link and stop what this skill started |
| `Install-Tools.ps1` | Install `cloudflared` and `caddy` (winget, else direct download) |

Useful flags:

```powershell
Start-Demo.ps1 -Provider none   # local only, no public exposure
Start-Demo.ps1 -DevMode         # use each service's devMode args (hot reload)
Start-Demo.ps1 -Force           # tear down a stale session and restart
Stop-Demo.ps1   -IncludeReused  # also stop services that were already running
```

Also supports `-Provider ngrok` — see [`references/providers.md`](references/providers.md)
for when that is the better choice.

---

## Config reference

| Field | Meaning |
|---|---|
| `name` | Unique id, used for logs and session state |
| `command` | Executable to run (`node`, `npx`, `dotnet`, `python`, …) |
| `startArgs` | Arguments for a production start |
| `buildCommand` / `buildArgs` | Optional build step, run before start in production mode |
| `dir` | Working directory, relative to the config file |
| `port` | Local port the service listens on |
| `healthUrl` | Polled until it answers; the boot waits on this |
| `expose` | URL path prefixes that belong to this service (e.g. `["/api/v1/*"]`) |
| `default` | `true` on the one service that serves everything else |
| `verifyPath` | Optional path probed through the public URL |
| `acceptStatus` | Non-2xx codes that still mean "reachable" (e.g. `[401]` for an auth-gated API) |
| `managed` | `false` to declare a service the skill must never start |
| `note` | Printed after a successful boot |
| `devMode` | `{ "startArgs": [...] }` used with `-DevMode` |

`.demo-state/` holds the session, logs and generated Caddyfile. It is gitignored.

---

## Design decisions worth knowing

**Never kill what it didn't start.** If a port is held by a process the skill didn't launch, it
aborts and names the process. It will not `kill -9` your database because a port matched.

**A stale bundle fails loudly.** Declaring `buildArgs` without `buildCommand` is rejected
rather than silently demoing old code.

**Verification is real.** After booting it fetches the public URL from outside, so "the link is
up" is measured, not assumed. Auth-gated endpoints count a `401` as success — it proves the
proxy reached the service.

**Production builds by default.** Framework dev servers block unknown `Host`/`Origin` headers
(Next.js `allowedDevOrigins`, Vite `allowedHosts`), which breaks through tunnels. `next start`
has no such guard. Use `-DevMode` only when you want hot reload, and allowlist the tunnel
domain first.

---

## Security

A free quick tunnel is **public with no authentication** — anyone with the URL gets in. Treat
the link as a password, keep demo windows short, and always run `Stop-Demo.ps1` afterwards.

Do not demo screens showing customer data, credentials, or secrets. Anything the app injects
server-side stays server-side; anything in a client bundle is public.

For more than a casual demo, put an auth wall in front — Cloudflare Access or `oauth2-proxy`
behind Caddy. See [`references/providers.md`](references/providers.md).

---

## Platform support

Written for **Windows + PowerShell 5.1+** (no PowerShell 7 dependency). The design is
platform-neutral — the only OS-specific parts are `Start-LoggedProcess` and the port probing in
[`scripts/common.ps1`](scripts/common.ps1). A POSIX `bash` port is a welcome contribution: the
tmux-equivalent is backgrounding with `nohup`/`setsid` plus `ss`/`lsof` for port ownership.

---

## Contributing

Issues and PRs welcome. Guidelines:

- Keep the single-origin invariant. A second tunnel is never the answer.
- New config fields need a matching line in `assets/demo.config.example.json` and this README.
- Test the full cycle before opening a PR: `Start-Demo.ps1` → `Status-Demo.ps1` → `Stop-Demo.ps1`,
  and confirm nothing is left listening.

## License

MIT — see [LICENSE](LICENSE).
