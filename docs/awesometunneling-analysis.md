# What awesome-tunneling tells us

Cloned `anderspitman/awesome-tunneling` (22k★) and mined its 165 curated entries
into `entries.json` (117 with GitHub repos), then measured capability frequency.

**Correction to the premise:** there is no implementation to reverse engineer. The
repo is a 56 KB README plus `scripts/sort_by_stars.py` (a star-count sorter).
Its value is the *dataset*, not the code.

---

## Finding 1: our headline feature is statistically irrelevant

Across 157 comparable tools:

| Capability | Count | Share | Reading |
|---|---|---|---|
| Automatic HTTPS/TLS | 134 | **85.4%** | Table stakes |
| Open source | 69 | 43.9% | Table stakes, not a differentiator |
| TCP/UDP | 44 | 28.0% | Common |
| Self-hostable | 29 | 18.5% | Common |
| **AI/agent integration** | **8** | **5.1%** | **Rare** |
| No account needed | 7 | 4.5% | Rare |
| Request inspection | 6 | 3.8% | Rare |
| **Multiple services / path routing** | **4** | **2.5%** | **Rare — and we own this** |
| Cross-platform client | 4 | 2.5% | Rare |
| Webhook support | 2 | 1.3% | Rare |

The multi-service single-origin capability that we treated as the headline is
only mentioned by 4 of 157 tools. That cuts two ways:

- It is **not** a crowded battleground (good — less competition on the claim).
- It is **not** a validated pain point (bad — low demand signal, not a proven need).

Combined with the earlier finding that Tailscale `--set-path` already does it for
free, the honest conclusion stands: **do not lead with it.**

## Finding 2: the AI/agent lane is real and thin

Only 8 of 157 tools mention any AI/agent capability, and all 8 are either
commercial or overlay networks:

```
playit.gg, TunnelAPI 2.0, LocalCan, Lokal.so, Buddy Tunnels   (commercial)
Pilot Protocol, Octelium, Narrowlink                          (overlay networks)
```

Not one is an open-source agent skill. Meanwhile a separate search for tunnel
skills in the agent-skill ecosystem returned **6 repos, none above 1 star**.

That is consistent with the market-fit read: the defensible position is
**agent-native demo orchestration**, not tunneling.

---

## Finding 3: our real robustness gaps (self-audit against the data)

The dataset also reframed what "robust" should mean for us. Auditing our own
scripts found three genuine stability defects:

| Gap | Risk | Status |
|---|---|---|
| No PID-reuse guard | On Linux, PIDs are recycled. A stale `session.json` could name a PID now owned by an unrelated process, and `stop.sh` would kill it. This directly violates our "never kill what it didn't start" promise. | **Fixed** |
| No boot lock | Two concurrent `start.sh` runs race between port-check and bind, producing duplicate gateways or half-state. | **Fixed** |
| No interrupt cleanup | Ctrl+C mid-boot leaves orphaned services with no `session.json`, so `stop.sh` cannot find them. | **Fixed** |

These matter more than any feature: they are violations of the exact promises the
README makes.
