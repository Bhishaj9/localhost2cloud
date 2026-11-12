# MCP interface (optional)

`servers/mcp-server.mjs` exposes the same scripts as three MCP tools, for agents that
prefer structured tool calls over shelling out. **The scripts remain the source of truth** —
the server shells out to them and reads their session file; it never reimplements tunnel or
proxy logic. Nothing here is required for the CLI to work.

Zero dependencies: it uses only Node built-ins, so there is no `npm install` to fail at the
wrong moment.

## Tools

| Tool | Returns |
|---|---|
| `localhost2cloud_boot` | `{ ok, url, provider, auth_enabled, login_user, services[] }` |
| `localhost2cloud_status` | `{ running, complete, url, provider, started_at, services[], healthy }` |
| `localhost2cloud_stop` | `{ ok, previous_url, stopped[], already_gone[], still_running[], link_closed }` |

`services[]` entries are `{ name, port, healthy, status }`, where `status` is the literal
`HTTP 401` / `unreachable` / `no-health-url`. Health is probed by the server directly against
each `healthUrl` (honouring `acceptStatus`), rather than scraped from the script's prose —
so a 401 from an auth-gated engine correctly counts as **healthy**.

All three accept `config_path` and `working_directory`; `boot` also takes `provider`,
`dev_mode` and `force`; `stop` takes `include_reused`.

## Registering it

```bash
cmdc mcp add localhost2cloud -- node <path-to-skill>/servers/mcp-server.mjs
cmdc mcp list | grep localhost2cloud
```

Add `--scope user` to make it available in every project. On Windows use `cmdc`, not `cmd`.

To bundle it in a project instead, put the same entry in `.mcp.json`:

```json
{
  "mcpServers": {
    "localhost2cloud": {
      "transport": "stdio",
      "command": "node",
      "args": ["<path-to-skill>/servers/mcp-server.mjs"]
    }
  }
}
```

## Verifying it

```bash
node tests/mcp-conformance.mjs    # protocol: handshake, tools/list, error codes
```

The conformance test speaks raw MCP over stdio with no client library, so it also proves the
transport framing (newline-delimited JSON-RPC, nothing else on stdout).

## Two bugs this interface surfaced, worth knowing about

Both were found by testing, not reasoning, and both are documented here because they are
easy to reintroduce:

1. **Resolve on `exit`, never on `close`.** The boot script starts long-lived services as
   children; those inherit the stdio pipes, so the pipes stay open after the script exits and
   Node's `close` event never fires. A server waiting on `close` hangs the tool call forever.
   Verified: `exit` at ~4.5s, `close` never.

2. **Strip the UTF-8 BOM before parsing.** PowerShell's `Set-Content -Encoding UTF8` writes a
   BOM, and `JSON.parse` rejects it. Every read of a Windows-written `session.json` failed
   silently, so `status` reported `running: false` while the demo was up.
