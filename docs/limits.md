# What we deliberately do not support

Written down so nobody has to discover it by trying.

## Raw TCP / UDP tunneling

Tools like frp, Pangolin and gost tunnel arbitrary TCP and UDP. We do not, and that is a
provider limit rather than an unfinished feature:

- **Cloudflare quick tunnels are HTTP(S)-only.** No raw TCP, no UDP. That is the free,
  anonymous path this tool is built around.
- **Stock Caddy has no `layer4`.** Raw TCP forwarding needs the `caddy-l4` plugin, which
  means shipping a custom Caddy build instead of the stock binary. That trades one binary
  for a build pipeline and a supply-chain question on every release.

The honest options if you need TCP/UDP:

1. **Named Cloudflare tunnel + `cloudflared access tcp`** — Cloudflare supports TCP on named
   tunnels, not on quick tunnels. Requires an account and a hostname.
2. **Tailscale** — a private mesh, and the right answer for "reach my database" rather than
   "show my team a web app".
3. **frp / Pangolin** — purpose-built for this, self-hosted. If TCP/UDP is your primary need,
   use one of those instead of this tool.

## Per-user accounts / SSO

`auth` is HTTP basic auth: one shared username and password for the whole audience. It stops
casual link-leaking, not a determined person, and you cannot revoke a single attendee without
changing the password for everyone.

For real identity (named users, audit log, per-person revocation) put Cloudflare Access or
`oauth2-proxy` in front of the gateway. Both are documented in `providers.md`.

## UDP-based media

WebRTC voice/video that needs UDP will not traverse a quick tunnel. The control plane works
(page loads, signalling over WebSocket), but media falls back to TCP or fails. Gemini-Live
style voice demos that stream over WebSocket instead of WebRTC are fine.
