# localhost2cloud

Turn your laptop into a temporary cloud host. One command boots your local app stack and
gives you a single shareable `https://` link your team can open in a browser — no deploy, no
screen share, no account with a tunnel provider.

```
$ ./scripts/start.sh

======================================================================
  SHARE THIS LINK

  https://read-valium-singh-registrar.trycloudflare.com

======================================================================
  All checks passed from the public internet.
  When they are done:  ./stop.sh
```

Built as an [Agent Skill](https://agentskills.io/specification) for
[Command Code](https://commandcode.ai), but the scripts work standalone in any shell.

---

## The problem it actually solves

Exposing `localhost:3000` with a tunnel is the easy part. The part that breaks is that real
apps talk to more than one port: a frontend served the page on `3100` while the browser opened
its WebSocket to `7500`. A tunnel points at **one** local address, so remote viewers got a
page that loaded fine and then silently failed to connect — working locally, broken in the
cloud, and nothing in the logs said why.

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

Because everything shares one origin, **WebSockets and SSE work with no extra configuration** —
Caddy upgrades them transparently. This is verified end to end: a real `101 Switching
Protocols` handshake through the public URL, with a round-tripped echo frame.

---

## Quick start

Works on **macOS, Linux and Windows**. Two equivalent implementations ship in `scripts/` —
bash for macOS/Linux, PowerShell for Windows. Same config, same behaviour, interchangeable
state file.

**1. Install the two tools** (cloudflared + caddy, one time):

```bash
./scripts/install-tools.sh          # macOS / Linux
```
```powershell
.\scripts\Install-Tools.ps1         # Windows
```

**2. Describe your stack.** Copy the annotated template to your project root:

```bash
cp assets/demo.config.example.json /path/to/YourProject/demo.config.json
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

```bash
cd /path/to/YourProject
/path/to/localhost2cloud/scripts/start.sh        # or Start-Demo.ps1 on Windows
```

Share the link. When feedback is done:

```bash
/path/to/localhost2cloud/scripts/stop.sh         # or Stop-Demo.ps1
```

Scripts find `demo.config.json` by walking up from the current directory, so they work in any
project without flags.

---

## Commands

macOS / Linux:

| Command | What it does |
|---|---|
| `scripts/start.sh` | Boot the stack, open a tunnel, print the link, verify it publicly |
| `scripts/status.sh` | Check processes, ports, routing and the public URL; re-print the link |
| `scripts/stop.sh` | Close the link and stop what this skill started |
| `scripts/install-tools.sh` | Install `cloudflared` and `caddy` (brew/apt/dnf, else release binary) |

Windows: `Start-Demo.ps1`, `Status-Demo.ps1`, `Stop-Demo.ps1`, `Install-Tools.ps1`.

Useful flags:

```bash
./start.sh --provider none    # local only, no public exposure  (-Provider none on Windows)
./start.sh --dev              # use each service's devMode args (-DevMode)
./start.sh --force            # tear down a stale session and restart (-Force)
./stop.sh  --include-reused   # also stop services that were already running
```

Also supports `--provider ngrok` — see [`references/providers.md`](references/providers.md)
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
| `devMode` | `{ "startArgs": [...] }` used with `--dev` / `-DevMode` |

`.demo-state/` holds the session, logs and generated Caddyfile. It is gitignored.

---

## Using it as an Agent Skill

The repo root *is* a skill (`SKILL.md` + `scripts/` + `assets/` + `references/`). To let an
agent drive it, install it where your tool looks for skills:

```bash
git clone https://github.com/Bhishaj9/localhost2cloud.git ~/.commandcode/skills/localhost2cloud
```

Then just say "boot it up" / "give me a demo link" / "stop the demo". The `SKILL.md` carries
the agent-facing playbook, including the preflight checks that catch the app-level problems a
tunnel exposes (client code hardcoding `127.0.0.1`, framework dev-server origin guards,
secrets that become public the moment the link is shared).

Skills are indexed at agent startup, so a freshly cloned skill becomes invocable on the next
session. Until then, the scripts run fine by hand.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Page loads, but live/chat/voice data never arrives | Client code dials `127.0.0.1` or a different port | Make the socket same-origin (empty host / relative path), then rebuild |
| `403` from the dev server, or "Blocked cross-origin request" | Framework host guard | Add the tunnel domain to `allowedDevOrigins` / `allowedHosts`, or use a production build |
| Public URL returns `530` right after boot | Cloudflare edge DNS hasn't propagated | Wait 30–75s; both `start` and `status` retry |
| `Port N is held by X but health is not responding` | A leftover or hung process owns the port | The tool won't kill it. Identify it, then stop it yourself |
| Tunnel exits immediately | `cloudflared` missing or blocked | Run `install-tools.sh` / `Install-Tools.ps1` |
| Link worked, then died mid-demo | Laptop slept, VPN flipped, or Wi-Fi changed | `status`, then `stop` + `start` (new URL — reshare it) |
| Health OK but the page is blank | Absolute base URL or a 404 on bundled assets | Check `curl -I <url>/assets/...`; fix the base path |

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
has no such guard. Use `--dev` / `-DevMode` only when you want hot reload, and allowlist the
tunnel domain first.

---

## Security

A free quick tunnel is **public with no authentication** — anyone with the URL gets in. Treat
the link as a password, keep demo windows short, and always run `./stop.sh` /
`Stop-Demo.ps1` afterwards.

Do not demo screens showing customer data, credentials, or secrets. Anything the app injects
server-side stays server-side; anything in a client bundle is public.

For more than a casual demo, put an auth wall in front — Cloudflare Access or `oauth2-proxy`
behind Caddy. See [`references/providers.md`](references/providers.md).

---

## Platform support

Fully supported on **macOS, Linux and Windows**:

| Platform | Implementation | Verified |
|---|---|---|
| Linux | `scripts/*.sh` (bash) | End to end on Ubuntu 26.04 with a live Cloudflare tunnel |
| Windows | `scripts/*.ps1` (PowerShell 5.1+) | End to end on Windows 11; no PowerShell 7 dependency |
| macOS | `scripts/*.sh` (bash) | Same code path as Linux and `install-tools.sh` prefers brew, but **not yet run on a Mac** |

The bash port needs `bash` 4+, `curl`, and either `python3` or `jq` for JSON. Port ownership
uses `lsof`, falling back to `ss` then `netstat`, so it works on minimal containers too.

---

## Contributing

Issues and PRs welcome. Guidelines:

- Keep the single-origin invariant. A second tunnel is never the answer.
- New config fields need a matching line in `assets/demo.config.example.json`, both
  implementations (`common.sh` and `common.ps1`), and this README.
- Test the full cycle before opening a PR: `start` → `status` → `stop`, and confirm nothing
  is left listening and the public URL is dead.

## License

MIT — see [LICENSE](LICENSE).
