# Testnet add-ons

Three optional, testnet-only capabilities that let the Telcoin Association help you
run your node. Every one is **off by default**, **additive** (turning it on changes
nothing else about your node), and **reversible**. None of them apply on mainnet.

| Add-on | What the Association gets | What it touches on your box |
|---|---|---|
| **Health monitoring** | A TCP health probe to alert you when your node drops | Opens port `43174` to one monitor IP only |
| **Centralized logging** | Your node's logs in their Loki, to help you debug | Runs a Grafana Alloy log shipper; node writes JSON logs |
| **VPN admin SSH** | SSH into your node over a private overlay to recover it | Adds a `tnadmin` user reachable only over WireGuard |

You can opt in during `setup-validator.sh` / `setup-observer.sh` (you're asked right
after picking the network), or any time afterward with `setup-observability.sh` and
`setup-vpn.sh`. Opting out, or never opting in, leaves your node byte-for-byte as it
would be without these scripts.

---

## Trust model

Read this before enabling anything — especially the VPN.

- **Health monitoring** is the lowest-stakes. It exposes a port that returns `OK`
  over plain HTTP and carries no node data. The firewall rule restricts it to the
  Association's single monitor IP (`104.155.184.201/32`), so nobody else can reach it.

- **Centralized logging** ships your node's logs off the box. reth logs are
  operational (block numbers, peer counts, errors) — they do **not** contain key
  material. Logs go only to the URL baked into `lib/testnet-addons.env`
  (`https://obs.adiri.telcoin.network/loki/api/v1/push`) and authenticate with a
  per-operator token you paste at setup. The token is stored only in a mode-`600`
  file (`/etc/telcoin/alloy/telcoin-alloy.env`); it is never committed or written to
  `.node-meta`.

- **VPN admin SSH** is the one that needs real consent. It grants the Association a
  sudo-capable `tnadmin` login to a machine that may hold your validator BLS keys.
  It is deliberately narrow:
  - `tnadmin` is reachable **only** over the WireGuard overlay (`10.100.0.0/16`),
    never from the public internet.
  - Your own SSH/login configuration is **not** changed. The global sshd hardening
    that the upstream bootstrap would apply is skipped (`WG_NODE_SSHD_HARDEN=0`); a
    scoped `Match User tnadmin` drop-in is added instead, validated with `sshd -t`
    before reload. `setup-vpn.sh` confirms your `passwordauthentication` and
    `permitrootlogin` are unchanged afterward.
  - The host firewall table the bootstrap installs is **dormant** (`WG_NODE_ENFORCE=0`);
    ufw stays your only active firewall.
  - `wg0` is brought up with `Table=off` and a single overlay route, so your default
    route and the consensus QUIC path are untouched.
  - It's reversible: `sudo bash setup-vpn.sh --disable` removes everything and leaves
    your own SSH intact.

Enabling the VPN requires typing `I CONSENT` — there is no silent or `-y` path.

---

## Operator quickstart

### During node setup

Run `setup-validator.sh` or `setup-observer.sh` as usual. After you select the network
you'll be asked, one at a time, whether to enable health monitoring, log shipping, and
VPN admin SSH. The node-launch flags are baked in on the first pass, so there's no
restart later. If you enable logging you'll paste your ingest token (hidden) at the end.
VPN is recorded as *pending* and finished separately (it needs an overlay IP from the
Association — see below).

### Afterward (standalone)

```bash
# Logging + health monitoring (enable/disable/status)
sudo bash setup-observability.sh

# VPN admin SSH
sudo bash setup-vpn.sh                 # interactive enable
sudo bash setup-vpn.sh --disable       # tear it all down
```

`setup-observability.sh` enabling logging on an already-running node will add the
JSON-log flags to your node's launch config and offer to restart it (Alloy has nothing
to tail until reth writes JSON logs).

### Health monitoring

The Association runs an uptime monitor that TCP-probes port `43174`. Enabling health
monitoring adds `--healthcheck 43174` to the node and restricts the firewall rule to
the monitor's IP. If you'd rather expose it more widely (your own monitoring), the
firewall tool offers an "open to anyone" choice:

```bash
sudo bash firewall-setup.sh   # → "Manage node ports" → health port choice
```

### VPN admin SSH

1. Ask the Association for your assigned **overlay IP** (a `/32` in `10.100.20.0/24`+).
2. Run `sudo bash setup-vpn.sh`, consent, and enter that IP.
3. The script prints an **enrollment payload** — three values:

   ```
   node_name:  <your-hostname>
   overlay_ip: 10.100.20.7
   wg_pubkey:  <generated on your node>
   ```

4. Send those to the Association. They enroll your node at the hub. Until they do,
   your tunnel is up on your side but the hub won't accept your peer.
5. After they confirm, verify the handshake:

   ```bash
   sudo wg show wg0        # peer 34.20.198.253:51820, nonzero transfer
   ```

---

## Verifying it works

```bash
# Health: returns OK once the node is up; rule restricted to the monitor
curl -s http://127.0.0.1:43174
sudo ufw status | grep 43174          # → 104.155.184.201/32, not Anywhere

# Logging: first reth log line is JSON, Alloy is up and shipping bytes
sudo head -1 /var/log/telcoin/telcoin-network-logs/reth.log    # binary install
journalctl -u telcoin-alloy -n 20
curl -s 127.0.0.1:12345/metrics | grep loki_write_sent_bytes_total

# VPN: tunnel up, your own SSH still works, default route unchanged
sudo wg show wg0
id tnadmin
ip route | head -1
```

`bash check-node.sh` reports all three under "testnet add-ons".

---

## For maintainers (Telcoin Association)

### Issuing an obs ingest token

Logs are gated at the Caddy edge in front of Loki, which checks an exact
`Authorization: Bearer <token>`. To issue a token for an external operator:

1. Generate one: `openssl rand -hex 32`.
2. Register it on the obs VM so Caddy accepts it. The current Adiri obs VM gates on a
   single shared token (`adiri-genesis/common/observability/obs-vm/Caddyfile`,
   `OBS_INGEST_TOKEN`); admitting per-operator tokens means extending that gate to
   match a set of tokens. Coordinate with the obs-stack owner before handing tokens
   to operators.
3. Give the operator the token over a private channel. They paste it into
   `setup-observability.sh`.

Keep these limits in mind on the obs-VM side (they are the reason logging is
low-risk to accept from outside operators):

- **Fixed, low-cardinality labels only.** The node sets `node`, `region`,
  `validator_address`, `chain`, `image_version` — no operator-defined labels. Don't
  add high-cardinality labels; it multiplies Loki streams across operators.
- **Rate / retention** (from `loki-config.yaml`): ingestion ~16 MB/s (32 MB burst),
  ~14-day retention. Consider per-token stream/rate limits as the operator count grows.
- Treat the token as **log-push only**. Rotating it is cheap (re-issue + re-paste).

### Enrolling a node on the WireGuard overlay

The operator can't be reached over IAP, so `enroll-node.sh` (which reads the pubkey
over IAP) doesn't apply. Enroll with the operator-supplied values instead. On your
`adiri-genesis` checkout:

```bash
source common/wgvpn/lib/hub-admin-lib.sh    # registry_append, hub_redeploy
registry_append node "<node_name>" "<overlay_ip>" "<wg_pubkey>" "external operator"
hub_redeploy                                # re-renders + applies the hub (wg syncconf)
git -C common add peers/registry.csv        # commit the registry; bump the parent pointer
```

Pick the operator's `overlay_ip` from the **external band `10.100.20.0/24`+**, one
`/32` per node. Reserved nets stay off-limits: `0` hub, `1` adiri core, `2` devnet,
`9` maintainers. `sync-access.sh` is **not** needed — the maintainer SSH keys were
baked into the node at bootstrap from the vendored `peers/ssh/*.pub`.

Verify the node is reachable once your own tunnel is up:

```bash
source common/wgvpn/lib/wg-ssh-lib.sh && tn_ssh <node_name> hostname
```

To de-enroll: `registry_remove "<node_name>"` then `hub_redeploy`, and tell the
operator they can run `setup-vpn.sh --disable`.

---

## Sync note (vendored files)

These files are **vendored** from `adiri-genesis` and must stay in sync:

| Here (`tn-node-deployment`) | Upstream (`adiri-genesis`) |
|---|---|
| `observability/config.alloy` (functional blocks) | `common/observability/node-agent/config.alloy` |
| `lib/wgvpn/wg-node-bootstrap.sh` (below the header) | `common/wgvpn/node/wg-node-bootstrap.sh` |
| `lib/wgvpn/hub-coordinates.env` | `common/wgvpn/hub/hub-coordinates.env` |
| `lib/wgvpn/peers/ssh/*.pub` | `common/wgvpn/peers/ssh/*.pub` |
| Hub coords / Kuma IP / obs URL in `lib/testnet-addons.env` | `config.sh`, `hub-coordinates.env` |

**config.alloy** — the log-shipping blocks (`local.file_match` through `loki.write`)
must be byte-identical to upstream so external logs land in the same Loki schema and
dashboards. The dormant metrics block is a tn-node-deployment-only addition. Verify:

```bash
diff <(sed -n '18,$p' <adiri>/common/observability/node-agent/config.alloy) \
     <(sed -n '18,79p' observability/config.alloy)
```

**wg-node-bootstrap.sh** — a verbatim copy with one upstream-pushed change already
present: the `WG_NODE_SSHD_HARDEN` guard (default `1` = upstream behavior).
`setup-vpn.sh` calls it with `WG_NODE_SSHD_HARDEN=0`. The vendored file's header
records the upstream `sha256`. To re-vendor after an upstream change, strip the
14-line provenance header and diff the body against the new upstream, then update the
sha. Bump `OBSERVABILITY_VERSION` (or another add-on version var) when you change any
of these so `update-scripts.sh` pulls the companion bundle to operators.
