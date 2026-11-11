# Tunnel providers

The skill defaults to **Cloudflare quick tunnels** (`cloudflared tunnel --url`). That choice
is deliberate, but it is not the only option. This file records the trade-offs so the choice
can be re-made per project instead of re-researched.

## Comparison

| | Cloudflare quick tunnel | ngrok (free) | Tailscale Funnel |
|---|---|---|---|
| Account needed | **No** | Yes + authtoken | Yes + tailnet, MagicDNS, HTTPS certs, funnel node attribute |
| URL shape | `https://<random>.trycloudflare.com` | one stable `*.ngrok-free.app` / `.dev` domain | `https://<machine>.<tailnet>.ts.net` |
| New URL each boot | Yes | No (stable hostname) | No (stable hostname) |
| Warning / interstitial for visitors | No | **Yes** on free browser traffic | No |
| Access control | **None** | Traffic policy (OAuth/basic auth; free plan limits) | None on Funnel traffic |
| Free-tier limits | No published request cap | 3 endpoints, 1 GB/month, 20k requests/month | Non-configurable bandwidth caps, **beta** |
| Platforms allowed | `443`, `8443`, `10000` only (Funnel) | any | any |
| Setup cost | one binary, zero config | install + token | enable HTTPS + edit ACL policy |

## Why Cloudflare quick tunnel is the default

1. **Zero account friction.** A demo link should not require the user to sign up anywhere
   mid-workday. `cloudflared tunnel --url http://127.0.0.1:8081` is the entire setup.
2. **No interstitial.** ngrok's free tier renders a "You are about to visit" warning page on
   first browser hit, which looks unpolished when a manager opens the link cold.
3. **No request cap.** 20k requests/month is easy to hit with a chatty frontend or a
   WebSocket reconnect loop; Cloudflare publishes no equivalent cap for quick tunnels.

## When to pick something else

- **Use ngrok** when the link must stay the same across reboots (a recurring standup demo) and
  the audience tolerates the interstitial, or when you want real access control via a traffic
  policy. Needs an authtoken; the skill accepts `-Provider ngrok`.
- **Use Tailscale Funnel** when the audience is already on the tailnet and you would rather
  not expose anything publicly, or when you want a stable `*.ts.net` name. Caveats: beta, port
  restricted to 443/8443/10000, requires enabling HTTPS certificates and a funnel node
  attribute, and on Windows Funnel must be run from an Administrator console.
- **Use `-Provider none`** when the team is on the same LAN/VPN. No public exposure at all —
  bind the gateway and share `http://<lan-ip>:<gateway.port>`. Safest option; try this first
  if the audience can reach the laptop directly.

## Things that are true of all three

- The tunnel bypasses "localhost only" assumptions: anything reachable on the tunnel is
  reachable by anyone with the URL unless you add auth in front.
- WebSockets/SSE survive, but only if the client dials the same origin as the page.
- The tunnel dies with the process, the session, or the network. A link is not a deployment.

## Hardening, if a demo must be more than one-off

Front the gateway with Cloudflare Access (zero-trust, identity-based) or put `oauth2-proxy`
behind Caddy. Both add a login wall before the app. That converts the workflow from "share a
secret link" to "invite specific people", at the cost of setup — worth it for anything beyond
a same-day team demo, and required if third-party or personal data is on screen.
