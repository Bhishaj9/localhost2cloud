# localhost2cloud

Turn your laptop into a temporary cloud host. One command boots your local app stack and
gives you a single shareable `https://` link your team can open in a browser — no deploy, no
screen share, no account with a tunnel provider.

```
PS> .\scripts\Start-Demo.ps1

======================================================================
  SHARE THIS LINK

  https://read-valium-singh-registrar.trycloudflare.com

======================================================================
  All checks passed from the public internet.
  When they are done:  .\Stop-Demo.ps1
```

Built as an [Agent Skill](https://agentskills.io/specification) for
[Command Code](https://commandcode.ai), but the scripts work standalone in any shell.

## Status

**Stable on Windows**, verified end to end rather than asserted. A release gate boots a real
two-service stack, checks the one-origin routing, stops it, and confirms every port, process,
session file and lock is gone:

```
RELEASE GATE: PASS   (20/20 checks)
```

| Area | State |
|---|---|
| Windows (PowerShell 5.1+) | **Supported.** Full lifecycle verified on Windows 11 Pro, build 26200 |
| Linux (bash) | Works; same lifecycle tested on Ubuntu 26.04 |
| macOS | **Untested.** Same code path as Linux, but never executed — treat as experimental |
| MCP interface | 16/16 protocol conformance checks pass; full boot/status/stop driven through it |
| Process identity | Verified: a recycled PID is reported as **not running**, and the unrelated process is never touched |
| `stop` honesty | Verified: if anything still holds a port, `stop` names it with the PID and exits non-zero instead of claiming success |
| Auth | Verified through a live tunnel: anonymous `401`, correct `200`, wrong password `401` |
| WebSockets | Verified: real `101 Switching Protocols` through the public URL, echo round-tripped |
| Raw TCP/UDP, per-user accounts | **Not supported** — see [`docs/limits.md`](docs/limits.md) |

Testing is the only claim worth making, so it ships with the repo:

```bash
node tests/release-gate.mjs        # full lifecycle: boot, route, status, stop, leak check
node tests/mcp-conformance.mjs     # MCP protocol: handshake, tools/list, error codes
node tests/identity-test.mjs       # recycled-PID safety and stop honesty
```

Both are self-contained — the gate builds its own two-service fixture and removes it after —
and both need nothing but Node plus the two CLI tools already required.


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

Works on **Windows** (primary). Linux uses the same bash scripts and is tested; macOS is
untested. Two equivalent implementations ship in `scripts/` — bash for Linux/macOS, PowerShell
for Windows. Same config, same behaviour, interchangeable state file.

**1. Install the two tools** (cloudflared + caddy, one time):

```powershell
.\scripts\Install-Tools.ps1         # Windows (supported platform)
```
```bash
./scripts/install-tools.sh          # Linux (macOS untested)
```

**2. Describe your stack.** Copy the annotated template to your project root:

```powershell
Copy-Item .\assets\demo.config.example.json D:\YourProject\demo.config.json
```
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

```powershell
cd D:\YourProject
D:\path\to\localhost2cloud\scripts\Start-Demo.ps1
```

Share the link. When feedback is done:

```powershell
D:\path\to\localhost2cloud\scripts\Stop-Demo.ps1
```

Scripts find `demo.config.json` by walking up from the current directory, so they work in any
project without flags.

---

## Commands

Windows:

| Command | What it does |
|---|---|
| `Start-Demo.ps1` | Boot the stack, open a tunnel, print the link, verify it publicly |
| `Status-Demo.ps1` | Check processes, ports, routing and the public URL; re-print the link |
| `Stop-Demo.ps1` | Close the link and stop what this skill started |
| `Install-Tools.ps1` | Install `cloudflared` and `caddy` (winget, else direct download) |

Linux (macOS untested): `start.sh`, `status.sh`, `stop.sh`, `install-tools.sh`, `gen-password.sh` —
same behaviour, same config, interchangeable state file.

Useful flags (bash spelling first, PowerShell equivalent in brackets):

```bash
./start.sh --provider none    # local only, no public exposure   [-Provider none]
./start.sh --dev              # use each service's devMode args  [-DevMode]
./start.sh --force            # tear down a stale session        [-Force]
./stop.sh  --include-reused   # also stop services already running [-IncludeReused]
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

### Optional `auth` block

Require a login before anything reaches your app. Implemented with Caddy's
`basic_auth` — no extra dependency, and the password is never written to disk.

```json
"auth": { "enabled": true, "username": "demo", "passwordHash": "$2a$14$..." }
```

Generate the hash (and get a strong password) with:

```bash
./scripts/gen-password.sh                       # print a password + hash
./scripts/gen-password.sh -c ../demo.config.json  # write auth{} into your config
```

`auth.password` (plaintext) also works — it is hashed at boot and never persisted. Verified
behaviour: anonymous requests get `401`, correct credentials get the app, wrong credentials
get `401`.

### Optional `tunnel` block — stable hostname

By default you get a new random URL every boot. For a recurring demo, create a named tunnel
in the Cloudflare dashboard and pin it:

```json
"tunnel": { "token": "<tunnel token>", "hostname": "demo.example.com" }
```

The link is then the same every time, so you can send it once and reuse it. Without this
block, the anonymous quick-tunnel path is used unchanged.

`.demo-state/` holds the session, logs and generated Caddyfile. It is gitignored.

---

## Using it as an Agent Skill

The repo root *is* a skill (`SKILL.md` + `scripts/` + `assets/` + `references/`). Install it
with Command Code's native installer:

```bash
cmdc skills add Bhishaj9/localhost2cloud --global
```

Verified: this installs to `~/.commandcode/skills/localhost2cloud` and registers immediately
in `cmdc skills list`. A manual clone to the same path works identically, which also means an
install **overwrites local edits** in that directory — keep edits in your clone.

> On Windows run **`cmdc`**, not `cmd`: `cmd` is `cmd.exe` and just opens a shell.

Then just say "boot it up" / "give me a demo link" / "stop the demo". The `SKILL.md` carries
the agent-facing playbook, including the preflight checks that catch the app-level problems a
tunnel exposes (client code hardcoding `127.0.0.1`, framework dev-server origin guards,
secrets that become public the moment the link is shared).

Skills are indexed at agent startup, so a freshly cloned or updated skill becomes invocable on
the next session. The scripts themselves run immediately.

### Other agents

`SKILL.md` follows the open [Agent Skills standard](https://agentskills.io), so the same
directory works in other agents that implement it — nothing to rewrite. It uses
`${COMMANDCODE_SKILL_DIR}` for its own path, with `${CLAUDE_SKILL_DIR}` accepted as an alias
by Claude Code and equivalents.

## MCP interface (optional)

For agents that prefer structured tool calls over shelling out, `servers/mcp-server.mjs`
exposes the same scripts as three MCP tools:

| Tool | Returns |
|---|---|
| `localhost2cloud_boot` | `{ ok, url, provider, auth_enabled, services[] }` |
| `localhost2cloud_status` | `{ running, complete, url, services[], healthy }` |
| `localhost2cloud_stop` | `{ ok, previous_url, stopped[], still_running[], link_closed }` |

```bash
cmdc mcp add localhost2cloud -- node <path-to-skill>/servers/mcp-server.mjs
```

Zero dependencies (Node built-ins only), so there is nothing to install. The scripts stay the
source of truth — the server shells out to them and reads their session file. Health is probed
directly against each `healthUrl`, so a `401` from an auth-gated API counts as healthy.
Protocol conformance is covered by `node tests/mcp-conformance.mjs`. Details and the two
transport bugs it surfaced: [`servers/README.md`](servers/README.md).

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
| Boot was killed / terminal closed / PC rebooted mid-demo | A hard kill cannot run cleanup | Just run `start` again — it reclaims the orphans from its journal automatically, or run `stop` first to only tear down |
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

**A killed boot cleans itself up.** What the tool starts is journalled to disk *as each
process launches*, not only at the end. If the terminal is closed, the process killed with
`taskkill /F`, or the machine reboots mid-boot, the next run reads that journal, stops the
orphans it names, and clears the stale lock before booting. A hard kill cannot run cleanup
code, so recovery happens on the next run rather than never.

**Production builds by default.** Framework dev servers block unknown `Host`/`Origin` headers
(Next.js `allowedDevOrigins`, Vite `allowedHosts`), which breaks through tunnels. `next start`
has no such guard. Use `--dev` / `-DevMode` only when you want hot reload, and allowlist the
tunnel domain first.

---

## Security

A free quick tunnel is **public with no authentication at the edge** — anyone with the URL
reaches your gateway. Treat the link as a password, keep demo windows short, and always run
`./stop.sh` / `Stop-Demo.ps1` afterwards.

Add a login instead of relying on obscurity:

```bash
./scripts/gen-password.sh -c /path/to/YourProject/demo.config.json
```

That writes an `auth` block into your config. From the next boot the gateway answers `401`
until the right credentials arrive, so the link alone is not enough — share the password
separately from the link. The password is stored only as a bcrypt hash.

Do not demo screens showing customer data, credentials, or secrets. Anything the app injects
server-side stays server-side; anything in a client bundle is public.

For identity-aware access (per-person logins, audit trail) rather than a single shared
password, put Cloudflare Access or `oauth2-proxy` in front. See
[`references/providers.md`](references/providers.md).

### What this does not cover

Basic auth is one shared credential, not per-user accounts: everyone in the demo shares a
login, and there is no way to revoke one person without changing it for all. It also does not
encrypt the app's own data at rest, and it does not stop someone with the password from
sharing it. For a short team demo that is the right trade; for anything longer lived, use an
identity-aware proxy.

---

## Platform support

**Windows is the supported platform.** PowerShell 5.1+ (ships with Windows 10/11 — no
PowerShell 7 needed).

| Platform | Implementation | Status |
|---|---|---|
| Windows | `scripts/*.ps1` | **Supported.** Verified end to end on Windows 11 (build 26200) |
| Linux | `scripts/*.sh` | Works; kept in sync and tested on Ubuntu 26.04 |
| macOS | `scripts/*.sh` | Untested. The code paths match Linux but nobody has run it — treat as experimental |

The bash port needs `bash` 4+, `curl`, and either `python3` or `jq`. Port ownership uses
`lsof`, falling back to `ss` then `netstat`.

### Known limits

Raw **TCP/UDP tunneling** and **per-user accounts** are out of scope by design — the first is
a limitation of free HTTP-only tunnels, the second needs an identity provider. Both, plus what
to use instead, are documented in [`docs/limits.md`](docs/limits.md). Written down so you do
not have to discover them by trying.

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
