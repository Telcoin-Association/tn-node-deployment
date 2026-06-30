# Testnet add-ons

Four optional, testnet-only capabilities that let the Telcoin Association help you
run your node. Every one is **off by default**, **additive** (turning it on changes
nothing else about your node), and **reversible**. None of them apply on mainnet.

| Add-on | What the Association gets | What it touches on your box |
|---|---|---|
| **Health monitoring** | A TCP health probe to alert you when your node drops | Opens port `43174` to the Association monitor (plus any IPs you choose to add) |
| **Centralized logging** | Your node's logs in their Loki, to help you debug | Runs a Grafana Alloy log shipper; node writes JSON logs |
| **Metrics shipping** | Your node's Prometheus metrics in their dashboards | Runs the Alloy metrics pipeline; node serves a loopback `--metrics` endpoint |
| **VPN admin SSH** | SSH into your node over a private overlay to recover it | Adds a `tnadmin` user reachable only over WireGuard |

Logging and metrics are **independent** — pick either, both, or neither — and they
share a single ingest token. You can opt in during `setup-validator.sh` /
`setup-observer.sh` (you're asked right after picking the network), or any time afterward
with `setup-observability.sh` and `setup-vpn.sh`. Opting out, or never opting in, leaves
your node byte-for-byte as it would be without these scripts.

---

## Trust model

Read this before enabling anything — especially the VPN.

- **Health monitoring** is the lowest-stakes. It exposes a port that returns `OK`
  over plain HTTP and carries no node data. By default the firewall rule restricts it
  to the Association's monitor IP (`104.155.184.201/32`), so nobody else can reach it.
  You may additionally allow your own monitoring hosts (see Health monitoring below).

- **Centralized logging** ships your node's logs off the box. reth logs are
  operational (block numbers, peer counts, errors) — they do **not** contain key
  material. Logs go only to the URL baked into `lib/testnet-addons.env`
  (`https://obs.adiri.telcoin.network/loki/api/v1/push`) and authenticate with a
  per-operator token you paste at setup. The token is stored only in a mode-`600`
  file (`/etc/telcoin/alloy/telcoin-alloy.env`); it is never committed or written to
  `.node-meta`.

- **Metrics shipping** sends your node's Prometheus metrics (block height, peer counts,
  CPU/memory) to the Association's central Prometheus
  (`https://obs.adiri.telcoin.network/api/v1/write`). The node serves these on a
  **loopback-only** endpoint (`127.0.0.1:9101`) that Alloy scrapes locally — nothing new
  is exposed to the network, and no port is opened. Metrics reuse the **same** ingest
  token as logging (the obs hub gates `/loki/api/v1/push` and `/api/v1/write` on one
  shared token), so enabling metrics adds no second secret. Like logs, the metrics carry
  no key material.

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
you'll be asked, one at a time, whether to enable health monitoring, log shipping,
metrics shipping, and VPN admin SSH. The node-launch flags are baked in on the first
pass, so there's no restart later. If you enable logging and/or metrics you'll paste your
ingest token (hidden — one token covers both) at the end. VPN is recorded as *pending*
and finished separately (it needs an overlay IP from the Association — see below).

### Afterward (standalone)

```bash
# Logs, metrics + health monitoring (enable/disable/status, each independent)
sudo bash setup-observability.sh

# VPN admin SSH
sudo bash setup-vpn.sh                 # interactive enable
sudo bash setup-vpn.sh --disable       # tear it all down
```

`setup-observability.sh` is a menu that enables/disables **log shipping** and **metrics
shipping** independently (plus health monitoring). Enabling either on an already-running
node adds the matching reth flags to your launch config (`--log.file.*` for logs,
`--metrics` for metrics) and offers **one** restart. The two share a single ingest token;
if you enable the second pipeline after the first, the token is reused automatically — no
re-paste.

### Logs and metrics

Two independent pipelines, four valid states — **neither**, **logs only**, **metrics
only**, or **both**:

- **Logs** → Alloy tails reth's JSON log file and ships to Loki (`/loki/api/v1/push`).
  The node is given `--log.file.*` flags so it writes the JSON log.
- **Metrics** → reth serves a Prometheus registry on loopback `127.0.0.1:9101` (the
  `--metrics` flag); Alloy scrapes it and remote-writes to Prometheus (`/api/v1/write`).

Both ride the same host and the same ingest token, and attach the same identity labels
(`node`, `region`, `validator_address`, `chain`, `network`, `image_version`) so your node
lights up the shared Grafana dashboards. A node with **neither** enabled passes no
`--metrics` / `--log.file` flags — byte-identical to a node installed without these
scripts (reth runs its zero-overhead noop metrics recorder).

### Health monitoring

The Association runs an uptime monitor that TCP-probes port `43174`. Enabling health
monitoring adds `--healthcheck 43174` to the node and restricts the firewall rule to
the monitor's IP (`104.155.184.201/32`).

You can expose the endpoint to **the Association monitor AND your own monitoring
hosts** — the TA rule stays as the always-on baseline and your IPs layer on top:

```bash
sudo bash firewall-setup.sh   # → "Manage node ports" → health port choice
```

- **Choice 1 — Association monitor only** (recommended): just the TA monitor.
- **Choice 2 — Association monitor + your IPs**: keeps the TA baseline and opens an
  add/remove sub-menu for your own sources. Each accepts a single IPv4, IPv6, or CIDR
  (e.g. `203.0.113.5` or `203.0.113.0/24`). Your list is persisted in `.node-meta`
  (`KUMA_EXTRA_SRC`) and **reapplied automatically** — so it survives "Enable
  recommended defaults", which resets the firewall.
- **Choice 3 — Open to anyone**: any source IP (not recommended; your persisted
  sources become redundant but stay harmless).

Disabling health monitoring removes both the TA and your extra firewall rules (the
port stops listening), but keeps `KUMA_EXTRA_SRC` so re-enabling restores your set.

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

# Metrics: node serves its loopback registry; Alloy is remote-writing samples
curl -s 127.0.0.1:9101/metrics | grep -E '^(tn_|reth_)' | head
curl -s 127.0.0.1:12345/metrics | grep prometheus_remote_storage_samples_total

# VPN: tunnel up, your own SSH still works, default route unchanged
sudo wg show wg0
id tnadmin
ip route | head -1
```

`bash check-node.sh` reports them all under "testnet add-ons".

---

## For maintainers (Telcoin Association)

### Issuing an obs ingest token

One token covers **both** telemetry pipelines: the Caddy edge gates the Loki push
(`/loki/api/v1/push`) and the Prometheus remote-write (`/api/v1/write`) on the same exact
`Authorization: Bearer <token>`. To issue a token for an external operator:

1. Generate one: `openssl rand -hex 32`.
2. Register it on the obs VM so Caddy accepts it. The current Adiri obs VM gates on a
   single shared token (`adiri-genesis/common/observability/obs-vm/Caddyfile`,
   `OBS_INGEST_TOKEN`) for both the `/loki/api/v1/push` and `/api/v1/write` routes;
   admitting per-operator tokens means extending that gate to match a set of tokens.
   Coordinate with the obs-stack owner before handing tokens to operators.
3. Give the operator the token over a private channel. They paste it into
   `setup-observability.sh` (it covers logs and metrics — they need not paste it twice).

Keep these limits in mind on the obs-VM side (they are the reason this telemetry is
low-risk to accept from outside operators):

- **Fixed, low-cardinality labels only.** The node sets `node`, `region`,
  `validator_address`, `chain`, `image_version` (plus `network` on the metrics path) —
  no operator-defined labels. Don't add high-cardinality labels; it multiplies Loki
  streams / Prometheus series across operators.
- **Rate / retention** (from `loki-config.yaml`): ingestion ~16 MB/s (32 MB burst),
  ~14-day retention. The Prometheus `/api/v1/write` route has its own Caddy rate-limit
  zone. Consider per-token stream/rate limits as the operator count grows.
- Treat the token as **telemetry-push only** (logs + metrics). Rotating it is cheap
  (re-issue + re-paste).

### Enrolling a node on the WireGuard overlay

The operator can't be reached over IAP, so `enroll-node.sh` (which reads the pubkey
over IAP) doesn't apply. Use `add-node.sh` with the operator-supplied values instead. On
your `adiri-genesis` checkout, hand them a free IP first, then register what they send
back (`setup-vpn.sh` prints the exact command — you can just run that):

```bash
./common/wgvpn/add-node.sh --next-ip        # e.g. 10.100.20.9 — give this to the operator first
./common/wgvpn/add-node.sh "<node_name>" "<overlay_ip>" "<wg_pubkey>" "external <vendor>"
git -C common add peers/registry.csv        # commit the registry; bump the parent pointer
```

`add-node.sh` validates the values for you: it rejects the reserved nets (`0` hub, `1` adiri
core, `2` devnet, `9` maintainers — pick from the **external band `10.100.20.0/24`+**, one
`/32` per node) and refuses a duplicate name or IP. It appends the `node` row (stamping the
run-date) and re-renders the hub (`wg syncconf`). `sync-access.sh` is **not** needed — the
maintainer SSH keys were baked into the node at bootstrap from the vendored `peers/ssh/*.pub`.

Verify the node is reachable once your own tunnel is up:

```bash
source common/wgvpn/lib/wg-ssh-lib.sh && tn_ssh <node_name> hostname
```

To de-enroll: `./common/wgvpn/remove-peer.sh "<node_name>"` (drops the row + re-renders the
hub, severing the overlay route), and tell the operator they can run `setup-vpn.sh --disable`.

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

> **`peers/ssh/*.pub` is kept in sync for you.** `add-peer.sh` / `remove-peer.sh` in
> `adiri-genesis` mirror the whole maintainer key set into `lib/wgvpn/peers/ssh/` on every
> (de)registration and print the `tn-node-deployment` commit command — so that row rarely
> needs a manual re-vendor. The other rows below still do.

**config.alloy** — BOTH the log-shipping blocks (`local.file_match` through
`loki.write`) AND the metrics blocks (`prometheus.scrape` through
`prometheus.remote_write`) must be byte-identical to upstream so external telemetry lands
in the same Loki/Prometheus schema and dashboards. `lib/observability.sh` slices this file
on the `local.file_match` / `// --- Metrics pipeline` anchors to deploy only the
pipeline(s) the operator opted into. The current vendored copy hashes to the value below
(recompute with `sha256sum observability/config.alloy` and update this line whenever you
re-vendor, so unexpected drift is detectable):

```
sha256(observability/config.alloy) = 3ed01c5d95c2d47c4d41c8f1ef06e73ecbd19b4776b5347eb681779a453426b4
```

Verify the functional blocks against upstream (the file headers differ by design; from
the first River component to EOF must match exactly — this diff should be empty):

```bash
diff <(sed -n '/^local\.file_match/,$p' <adiri>/common/observability/node-agent/config.alloy) \
     <(sed -n '/^local\.file_match/,$p' observability/config.alloy)
```

**wg-node-bootstrap.sh** — a verbatim copy with one upstream-pushed change already
present: the `WG_NODE_SSHD_HARDEN` guard (default `1` = upstream behavior).
`setup-vpn.sh` calls it with `WG_NODE_SSHD_HARDEN=0`. The vendored file's header
records the upstream `sha256`. To re-vendor after an upstream change, strip the
16-line provenance header and diff the body against the new upstream, then update the
sha. Bump `OBSERVABILITY_VERSION` (or another add-on version var) when you change any
of these so `update-scripts.sh` pulls the companion bundle to operators.
