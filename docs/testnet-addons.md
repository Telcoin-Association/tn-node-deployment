# Testnet add-ons

Four optional, testnet-only capabilities that let the Telcoin Association help you
run your node. Every one is **off by default**, **additive** (turning it on changes
nothing else about your node), and **reversible**. None of them runs on mainnet; see
[Mainnet: every add-on refuses](#mainnet-every-add-on-refuses).

| Add-on | What the Association gets | What it touches on your box |
|---|---|---|
| **Health monitoring** | A TCP health probe to alert you when your node drops | Opens port `43174` to the Association monitor (plus any sources you add); needs an active ufw firewall |
| **Centralized logging** | Your node's logs in their Loki, to help you debug | Runs a Grafana Alloy log shipper under its own `telcoin-alloy` account; the node writes JSON logs |
| **Metrics shipping** | Your node's Prometheus metrics in their dashboards | Runs the Alloy metrics pipeline; the node serves a loopback `--metrics` endpoint |
| **VPN admin SSH** | SSH into your node over a private overlay to recover it | Adds a `tnadmin` user that can log in only from the maintainers' overlay range, with sudo for a short list of recovery commands |

Private alerts are not a testnet add-on. `setup-alerts.sh` pushes a heartbeat from your
host to a monitor you own, on every network, and the Association is not involved; see
[OPERATOR.md §4.14](../OPERATOR.md#414-private-alerts).

Logging and metrics are independent (pick either, both, or neither) and they share a
single ingest token. You can opt in during `setup-node.sh` (you're asked right after
picking the network), or any time afterward with `setup-observability.sh` and
`setup-vpn.sh`. Opting out, or never opting in, leaves your node exactly as it would be
without these scripts.

This page also covers the two scripts the add-ons lean on:
[firewall-setup.sh](#firewall-source-lists-and-sshd-hardening), which keeps SSH, P2P and
the health port behind source lists, and
[install-caddy.sh](#caddy-edge-dashboard-and-public-rpc), whose managed Caddyfile counts
as an add-on when you move a host to mainnet.

---

## Mainnet: every add-on refuses

The add-ons act only on a node whose `.node-meta` says `NETWORK=testnet` (devnet hosts
take the same paths). On mainnet, or when the network cannot be read, they refuse or
clean up after themselves:

- `setup-vpn.sh` refuses to enable, to `--sync-keys` and to `--apply-firewall`.
  `--status` and `--disable` work on any network, even with no node installed, so you
  can always inspect and remove the VPN. `--selfheal` and the boot-time self-heal helper
  remove the self-heal units and the helper itself.
- `setup-observability.sh` refuses to run. The Alloy push URLs resolve to empty on any
  network other than testnet and devnet, even when you pass `--push-url`, so a mainnet
  node's logs and metrics never leave the box.
- The health-port rule is never added. firewall-setup.sh deletes the monitor rule and
  any extra health sources instead, and TCP `43174` stays closed. If one of those
  deletes fails, the firewall run stops and puts the old rules back (exit 2).
- The overlay SSH rule is never added; the helper that adds it on testnet deletes it
  instead.
- `install-caddy.sh` refuses the dashboard and public RPC on a mainnet node that is a
  staked validator, whose stake cannot be read (from the local node, then from the
  network's public RPC), that has no `VALIDATOR_ADDRESS` in `.node-meta`, or whose
  network cannot be told (no `NETWORK` and no readable genesis). Serve the dashboard
  over the SSH tunnel and public RPC from a separate RPC node.
- `setup-node.sh` shows the add-on prompts on testnet only, and refuses a mainnet
  install while any add-on is still on the host: the VPN (`/etc/wireguard/wg0.conf`,
  `/etc/sudoers.d/90-tnadmin`, the self-heal units or helper), observability
  (`telcoin-alloy.service`), or a Caddyfile written by install-caddy.sh. Remove them
  first; see [Removing the add-ons](#removing-the-add-ons).
- Private alerts (`setup-alerts.sh`) are not an add-on and work on mainnet too. They do
  not count as an add-on when setup-node checks a host for a mainnet install.

---

## Trust model

Read this before enabling anything, especially the VPN.

- **Health monitoring** is the lowest-stakes. It exposes a port that returns `OK`
  over plain HTTP and carries no node data. The firewall rule restricts it to the
  Association's monitor IP (`104.155.184.201/32`). You may also allow your own
  monitoring hosts (see [Health monitoring](#health-monitoring)), but the port is never
  opened to every address. The health server listens on every interface, so enabling
  it is refused while ufw is missing or inactive.

- **Centralized logging** ships your node's logs off the box. reth logs are
  operational (block numbers, peer counts, errors); they do **not** contain key
  material. Logs go only to the URL in `lib/testnet-addons.env`
  (`https://obs.adiri.telcoin.network/loki/api/v1/push`) and authenticate with the
  ingest token you paste at setup. Today the hub accepts one token that the Association
  hands to every operator, so the token identifies the hub, not you. It is stored only in
  `/etc/telcoin/alloy/ingest-token` (root:telcoin-alloy, mode 0640), which Alloy reads as
  a file; it is never in Alloy's environment, a unit file, a command line, `.node-meta`
  or git. Alloy pushes over TLS 1.3 only, checked against the push URL's host name. On
  binary and source installs Alloy runs as its own `telcoin-alloy` account and cannot see
  the node's data directory, the passphrase credential
  (`/etc/telcoin/bls-passphrase.cred`) or the passphrase file.

- **Metrics shipping** sends your node's Prometheus metrics (block height, peer counts,
  CPU/memory) to the Association's central Prometheus
  (`https://obs.adiri.telcoin.network/api/v1/write`). The node serves these on a
  **loopback-only** endpoint (`127.0.0.1:9101`) that Alloy scrapes locally: nothing new
  is exposed to the network, and no port is opened. Metrics reuse the **same** ingest
  token as logging (the obs hub gates `/loki/api/v1/push` and `/api/v1/write` on one
  shared token), so enabling metrics adds no second secret. Like logs, the metrics carry
  no key material.

- **VPN admin SSH** is the one that needs real consent. It gives the Association a
  `tnadmin` login to a machine that may hold your validator BLS keys. It is deliberately
  narrow:
  - `tnadmin` logs in only from the maintainers' overlay range, `TN_OVERLAY_ADMIN_CIDR`
    (default `10.100.9.0/24`, set in `lib/testnet-addons.env`), over the WireGuard
    overlay, never from the public internet. A scoped sshd drop-in lets only `tnadmin`
    log in from that range, with a public key only; `tnadmin` connecting from anywhere
    else is offered no keys at all.
  - Only the maintainer keys listed with their fingerprints in
    `lib/wgvpn/peers/ssh/KEYS` are installed, and you can block any of them on your
    host. See [WGVPN.md](../WGVPN.md#maintainer-keys).
  - `tnadmin`'s sudo covers status, start, stop and restart of the node unit, two
    journal views and `check-node.sh` (when the scripts directory is root-owned), each
    with exact arguments. Full root needs your explicit `--grant-maintainer-root`.
  - Your own SSH settings are not changed. The global sshd hardening the upstream
    bootstrap would apply is skipped (`WG_NODE_SSHD_HARDEN=0`), the scoped drop-in is
    checked with `sshd -t` before the reload, and `setup-vpn.sh` confirms your
    `passwordauthentication` and `permitrootlogin` are unchanged afterward. The one edit
    to `/etc/ssh/sshd_config` itself: when it has no
    `Include /etc/ssh/sshd_config.d/*.conf` line, sshd would ignore the drop-in, so
    `setup-vpn.sh` appends that line, checks it with `sshd -t`, and puts the file back
    if the check fails.
  - The host firewall table the bootstrap installs is **dormant** (`WG_NODE_ENFORCE=0`);
    ufw stays your only active firewall.
  - `wg0` is brought up with `Table=off` and a single overlay route, so your default
    route and the consensus QUIC path are untouched.
  - It's reversible: `sudo bash setup-vpn.sh --disable` removes everything and leaves
    your own SSH intact.

Enabling the VPN asks you to type `I CONSENT`. The only way past that prompt is the
`--accept-vpn-consent` flag, meant for a scripted run by an operator who has read this
page.

---

## Operator quickstart

### During node setup

Run `setup-node.sh` as usual. After you select the network you'll be asked, one at a
time, whether to enable health monitoring, log shipping, metrics shipping, and VPN admin
SSH. Health monitoring is offered only when ufw is already active; otherwise setup says
so, and you can turn it on later with `setup-observability.sh` once `firewall-setup.sh`
has enabled the firewall. The node-launch flags are baked in on the first pass, so
there's no restart later. If you enable logging and/or metrics you'll paste your ingest
token (hidden; one token covers both) at the end. VPN is recorded as *pending* and
finished separately (it needs an overlay IP from the Association; see below).

### Afterward (standalone)

```bash
# Logs, metrics + health monitoring (enable/disable/status, each independent)
sudo bash setup-observability.sh

# The same, scripted: the token goes on stdin, never on the command line
printf '%s\n' "$TOKEN" | sudo bash setup-observability.sh --json --enable-logs --enable-metrics --token-stdin

# Replace the ingest token; restarts Alloy, not the node
printf '%s\n' "$NEW_TOKEN" | sudo bash setup-observability.sh --rotate-token --token-stdin

# VPN admin SSH
sudo bash setup-vpn.sh                 # interactive enable
sudo bash setup-vpn.sh --disable       # tear it all down
```

`setup-observability.sh` is a menu that enables and disables **log shipping**, **metrics
shipping** and health monitoring independently. It holds the update lock for the whole
menu session, so update-node.sh, edit-config.sh and the other node scripts cannot change
the node while the menu is open (and the menu refuses to start while one of them holds
the lock). On a host still on the old ownership layout, the first change you make
migrates it to the root-owned layout. `--token VALUE` still works in `--json` runs but
warns: the command line is visible to other local users while the script runs.

Enabling either pipeline on an already-running node adds the matching reth flags to the
launch config (`--log.file.*` for logs, `--metrics` for metrics) and offers **one**
restart. That restart first checks that taking this node down will not leave the
committee without a quorum, then, when the node votes in the current committee, waits
for the epoch boundary. A failed check or wait skips the restart and says how to restart
later (edit-config.sh's Restart node, which waits the same way). `TN_ALLOW_QUORUM_RISK=1`
lets a coordinated restart through the check, and `TN_SKIP_EPOCH_WAIT=1` skips the wait.
The two pipelines share a single ingest token; if you enable the second after the first,
the stored token is reused, with no re-paste.

### Logs and metrics

Two independent pipelines, four valid states: **neither**, **logs only**, **metrics
only**, or **both**.

- **Logs**: the node is given `--log.file.*` flags so it writes JSON logs, and Alloy
  tails them and ships to Loki (`/loki/api/v1/push`). Binary and source installs write
  under the node log directory, `/var/log/telcoin/node/telcoin-network-logs/`. That
  directory is recorded in `.node-meta` as `NODE_LOG_DIR` and created inside the
  root-owned `/var/log/telcoin`, owned by the node's service account with group
  `telcoin-log`, mode 2750 (setgid: the files the node writes take the group, and its
  unit's `UMask=0027` keeps them group-readable). The node's unit joins `telcoin-log` to
  reach it and lists it in `ReadWritePaths=`; enabling rewrites the unit. Docker installs write to `<data dir>/logs/telcoin-network-logs/`
  from inside the container.
- **Metrics**: reth serves a Prometheus registry on loopback `127.0.0.1:9101` (the
  `--metrics` flag); Alloy scrapes it and remote-writes to Prometheus (`/api/v1/write`).

Binary and source hosts that enabled logging before the node log directory existed
still point `--log.file.directory` at `/var/log/telcoin`, which the node can no longer
write. Enabling logs again moves the flag to the node log directory, and the next
update-node.sh update does the same.

### The ingest token file

The token lives in `/etc/telcoin/alloy/ingest-token`: one line, root:telcoin-alloy 0640.
Alloy reads it with `bearer_token_file`, from `$CREDENTIALS_DIRECTORY/ingest-token`, on
both push endpoints. `/etc/telcoin/alloy/telcoin-alloy.env` (root 0600) keeps the identity
labels, the push URLs and their host names (`OBS_PUSH_HOST`, `OBS_METRICS_PUSH_HOST`), and
no token. Both endpoints pin TLS: `tls_config` sets `server_name` to the push URL's host
and `min_version = "TLS13"`, so a hub that offers TLS 1.2 or another certificate name is
refused.

To replace the token, run `--rotate-token` (or menu entry 8, "Rotate the ingest token"):

```bash
printf '%s\n' "$NEW_TOKEN" | sudo bash setup-observability.sh --rotate-token --token-stdin
sudo bash setup-observability.sh --rotate-token      # asks for it, hidden, on a terminal
```

`--token VALUE` and `TN_OBS_TOKEN` work too; the stored token is never reused. Add
`--json` for JSON events (the done event carries `"applied":["token:rotated"]`). The
rotation writes the token file, renders `config.alloy`, the env file and the unit again,
restarts Alloy only (the node keeps running, so there is no quorum check or epoch wait)
and checks that Alloy stays active for 5 seconds. If it does not, the previous token
file, env file, `config.alloy` and unit go back, Alloy restarts on them, and the run
exits 1. It refuses, with nothing changed, when both pipelines are off or Alloy's unit
is not installed, and it cannot be combined with an enable or disable flag. A wrong
token keeps Alloy running while the hub answers 401 to every push, so check the counters
the success message names (`loki_write_sent_bytes_total`,
`prometheus_remote_storage_samples_total` on `127.0.0.1:12345/metrics`) and look for 401
lines in `journalctl -u telcoin-alloy.service -n 20`.

A host set up with an older script release still has `OBS_INGEST_TOKEN=` in
`telcoin-alloy.env`. It keeps working until the next enable, partial disable or
`--rotate-token`, which moves the token into the token file and says so once. The
status screen (and `check-node.sh`) warns until then; run `--rotate-token` with the same
token to move it now. A full disable (both pipelines off) shreds the token file, so
enabling either pipeline again asks for the token. `remove-node.sh` shreds the token
file and the env file.

A push URL given with `--push-url` / `--metrics-push-url` (or `OBS_PUSH_URL` /
`OBS_METRICS_PUSH_URL`) is an override: `telcoin-alloy.env` records it with a marker
(`OBS_PUSH_URL_SOURCE=override`), and a rotation or the other pipeline's enable keeps it.
Without an override the URL follows the script release's default hub in
`lib/testnet-addons.env`, so a hub change in a later release reaches the host at the next
enable, rotation or partial disable (the log says "The logs push URL follows the release
default: ..."). An env file written by a 2.0.x release counts as the default, so a 2.0.x
install that pointed at its own hub moves to the release default at its next render and
the log says to pass `--push-url` again. To drop an override, pass `--push-url default`
(or `--metrics-push-url default`). Disabling a pipeline forgets its override: pass the
flag again when enabling it. A render that would leave an enabled pipeline with no URL is
refused before anything is written.

Both pipelines ride the same host and the same ingest token, and attach the same identity
labels (`node`, `region`, `validator_address`, `chain`, `network`, `image_version`) so
your node lights up the shared Grafana dashboards. A node with **neither** enabled passes
no `--metrics` / `--log.file` flags, the same as a node installed without these scripts
(reth runs its zero-overhead noop metrics recorder).

### How Alloy runs

On binary and source installs Alloy is a native binary under `telcoin-alloy.service`:

- It runs as the `telcoin-alloy` system account (no home, no login shell) and joins the
  `telcoin-log` group to read the node logs. If that group does not exist yet, run
  update-node.sh or edit-config.sh once (they move the host to the root-owned layout and
  create it), then enable logging again.
- The unit keeps the filesystem read-only apart from Alloy's state directory
  `/var/lib/telcoin-alloy`, and makes `/var/lib/telcoin`, the node's data directory,
  the passphrase credential `/etc/telcoin/bls-passphrase.cred` and the passphrase file
  `/etc/telcoin/bls-passphrase` inaccessible to it. It hands the token over with
  `LoadCredential=ingest-token:/etc/telcoin/alloy/ingest-token` (Alloy reads
  `/run/credentials/telcoin-alloy.service/ingest-token`) and sets `LimitCORE=0`, so a
  crash writes no core dump holding the token.
- Its configuration, `/etc/telcoin/alloy/config.alloy`, is root:telcoin-alloy 0640 in a
  root:telcoin-alloy 0750 directory. The token file beside it is root:telcoin-alloy
  0640; the env file is root 0600.
- A partial disable (logs off while metrics stay on, or the reverse) renders
  `config.alloy` exactly as the enable does (same owner, group and node log path),
  restarts Alloy, then watches the unit for 5 seconds; the enable runs the same check.
  When the restart fails or Alloy does not stay running, the disable says so (with
  `--json` the run ends with `ok:false`). The choice is already recorded in `.node-meta`,
  so once Alloy is fixed run the disable again (or restart the unit).
- Alloy 1.5.1 comes from Grafana's apt repository, pinned to that version, and only after
  the repository key's fingerprint matches `B53AE77BADB630A683046005963FA27710458545`.
  When apt cannot deliver it, the script downloads the release zip from GitHub and
  installs it only when its SHA-256 matches the line for that file in the release's
  `SHA256SUMS`. No matching line, no install.

Docker installs run Alloy as the sidecar container `telcoin-alloy`
(`grafana/alloy:v1.5.1`) under the same unit name. The token file is bind-mounted
read-only at `/run/credentials/telcoin-alloy/ingest-token` (`--mount ...,readonly`, so a
missing file stops the start), the env file sets `CREDENTIALS_DIRECTORY` to that
directory, and the container runs with `--group-add <gid of telcoin-alloy>` and
`--ulimit core=0`; the unit also sets `LimitCORE=0`. The `telcoin-alloy` account is
created on Docker installs too, because its group owns the token file. There
`config.alloy` is root:telcoin-alloy 0640 with the container's log path; a partial
disable writes it as the enable does and checks the unit for 5 seconds after the
restart in the same way.

### Health monitoring

The push heartbeat of private alerts is the way forward for watching a node: a timer on
your host pushes the node's status to a monitor you own, on every network, with no port
opened, and it alerts you, not the Association. See
[OPERATOR.md §4.14](../OPERATOR.md#414-private-alerts). The pull probe below stays for
the Association's monitor on testnet and devnet.

The Association runs an uptime monitor that TCP-probes port `43174`. Enabling health
monitoring adds `--healthcheck 43174` to the node and restricts the firewall rule to
the monitor's IP (`104.155.184.201/32`). It is refused while ufw is missing or inactive,
because the health server listens on every interface.

You can expose the endpoint to **the Association monitor and your own monitoring
hosts**: the Association rule stays as the always-on baseline and your sources layer on
top.

```bash
sudo bash firewall-setup.sh   # → "Manage node ports" → health port choice
```

- **Choice 1, Association monitor only** (recommended): just the monitor.
- **Choice 2, Association monitor + your IPs**: keeps the baseline and opens an
  add/remove sub-menu for your own sources. Each is a single IPv4 or IPv6 address or a
  CIDR (e.g. `203.0.113.5` or `203.0.113.0/24`), checked by the
  [source rules](#source-rules) below. Your list is kept in `.node-meta`
  (`KUMA_EXTRA_SRC`) and **reapplied automatically**, so it survives "Enable
  recommended defaults", even with a reset.
- **Choice 3, leave as-is**.

There is no "open to anyone" choice any more. If an older open-to-anywhere rule for
`43174/tcp` is still there, choices 1 and 2 offer to delete it by number. An entry in
`KUMA_EXTRA_SRC` that fails the source rules stops "Enable recommended defaults" before
it changes anything, and a `KUMA_EXTRA_SRC` key written on more than one line is not
applied until you remove the extra lines.

Disabling health monitoring removes both the Association rule and your extra rules (the
port stops listening), but keeps `KUMA_EXTRA_SRC` so re-enabling restores your set.

Health monitoring is a testnet and devnet add-on. On any other network
`firewall-setup.sh`'s status screen shows one line instead of the monitor block: "Health
port TCP 43174 stays closed", or a warning when a rule opens it anyway, which "Manage
node ports" (or `--enable`) removes.

### VPN admin SSH

1. Ask the Association for your assigned **overlay IP** (a `/32` in `10.100.20.0/24`+).
2. Run `sudo bash setup-vpn.sh`, consent, and enter that IP.
3. The script prints an **enrollment payload** of three values:

   ```
   node_name:  <your-hostname>
   overlay_ip: 10.100.20.7
   wg_pubkey:  <generated on your node>
   ```

4. Send those to the Association. They enroll your node at the hub. Until they do,
   your tunnel is up on your side but the hub won't accept your peer.
5. After they confirm, check the tunnel, keys, drop-in and firewall in one go:

   ```bash
   sudo bash setup-vpn.sh --status
   ```

[WGVPN.md](../WGVPN.md) has the rest: the maintainer key list and how to block a key,
the sudo scope, the self-heal helper, and every `setup-vpn.sh` flag.

---

## Firewall source lists and sshd hardening

`firewall-setup.sh` is not an add-on, but every add-on rule above lives in the ufw
firewall it manages. Besides the interactive menu it has two non-interactive runs that
re-apply the recommended rules: `--enable` (keeps your custom rules) and `--reset`
(wipes every ufw rule first).

### SSH and P2P source lists

By default SSH and the node's P2P ports are open to every address. Give a source list to
restrict them:

```bash
sudo bash firewall-setup.sh --enable --ssh-from 203.0.113.10,198.51.100.0/24
sudo bash firewall-setup.sh --enable --p2p-from /root/p2p-peers.txt
```

- `--ssh-from` and `--p2p-from` take a comma list of addresses or CIDRs, or the path of
  a file holding them (one or more per line, comma separated, `#` starts a comment).
  They go with `--enable` or `--reset`; the interactive "Enable firewall with
  recommended defaults" asks for the SSH list instead.
- A list you give is saved in `.node-meta` as `SSH_ALLOW_FROM` / `P2P_ALLOW_FROM` (comma
  lists), so every later enable or reset keeps it. `--ssh-anywhere` / `--p2p-anywhere`
  remove the saved list and open the ports to every address again. A list and its
  `-anywhere` flag in one run are refused. Saving a list takes the update lock and, on
  a host still on the old ownership layout, migrates it first.
- With an SSH list, the per-source rules go in before the open SSH rule is deleted, so
  SSH is never closed in between. On a Google Compute Engine VM the IAP TCP forwarding
  range `35.235.240.0/20` is added to the list, so the console SSH path keeps working.
  On a testnet host with the VPN enabled (`wg0` up or `ENABLE_VPN=true`), the
  maintainers' range `TN_OVERLAY_ADMIN_CIDR` is added too.
- With a P2P list, every P2P port (the primary and each worker, read from the launch
  file, `/etc/telcoin/node.env` and `node-info.yaml`) gets one UDP rule per source, and
  the open rule for that port is deleted. Leave P2P open unless you know every peer that
  must reach you.
- A replaced list drops the rules of the sources it no longer holds, after the new rules
  are in. The GCE and overlay ranges stay.
- On mainnet, `--enable`, `--reset` and the UI's enable refuse to run without an SSH
  source list, saved or given, unless you pass `--ssh-anywhere`. The interactive enable
  asks for an explicit yes before it keeps SSH open to every address there.

### P2P new-flow limit

When P2P is open to every source (no `--p2p-from`, no `P2P_ALLOW_FROM`, or
`--p2p-anywhere`) and a node is installed, every enable (`--enable`, `--reset`,
`--json --enable`, "Enable recommended defaults") and "Manage node ports" load the
nftables table `inet tn_p2p` after the ufw rules are in place. It drops UDP packets of
new, not yet answered flows to the node's P2P ports from one source above 20 per minute
after a burst of 40. A source is one IPv4 address or one IPv6 /64. Once the node answers,
the flow is established and is never limited. When the loaded table and its boot copy
already match what the run would write, nothing is rewritten and the run says the limit
is unchanged. The chain runs at priority -10, before
ufw's chains, and only drops: every other packet goes on to ufw, which still decides.
Each set holds at most 65535 sources; a source that sent nothing for 120 seconds (at the
defaults) leaves it.

```bash
sudo nft list table inet tn_p2p
sudo TN_P2P_NEW_FLOW_RATE=30 TN_P2P_NEW_FLOW_BURST=60 bash firewall-setup.sh --enable
```

`TN_P2P_NEW_FLOW_RATE` and `TN_P2P_NEW_FLOW_BURST` take a whole number from 1 to 100000
and apply to that run only: nothing stores them, so a later enable without them goes back
to 20 and 40. A bad value stops the run before anything changes. With a P2P source list,
or without a node, the table is deleted. Without `nft` the run warns and applies the ufw
rules as before.

The table comes back at boot from `/etc/telcoin/p2p-limit.nft` (root 0640), which
`telcoin-p2p-limit.service` (a oneshot unit ordered after `ufw.service`) loads; stopping
the unit deletes the table. The status screen has a "New-flow limit" line and a "New-flow
limit at boot" line, and `--json --status` a `p2p_new_flow_limit` object (`active`,
`rate`, `burst`, `reason`, `persistent`, `persistent_reason`). Every enable and every
"Manage node ports" change takes the update lock (`/run/telcoin/update.lock`) around ufw,
the table and its boot copy. `remove-node.sh` removes the unit, the boot copy and the
table with the last node; while another node unit remains on the host they stay whole for
it.

### Source rules

Every source (SSH, P2P and the extra health sources) must be one IPv4 or IPv6 address
or a CIDR. Refused: a `/0` mask, the unspecified address (`0.0.0.0`, `::`), any mask
shorter than `/8`, a mask written with a leading zero, and an IPv4 octet with a leading
zero (`010.0.0.1`). An invalid entry stops the run before any rule changes.

### What happens when a step fails

Before changing anything the script checks every input: ufw is present, the sshd ports
and every P2P port are valid, and both source lists and the saved health sources pass
the source rules. Then it copies ufw's rule files, `ufw.conf` and `/etc/default/ufw` into
a root-only directory under `/run`, adds the allow rules, sets the default deny, and
enables ufw last. If a step fails, or the run gets TERM, INT or HUP while the rules are
being applied, it puts the saved files back and returns ufw to the state it had.

Exit codes for `--enable` and `--reset`:

| Code | Meaning |
|---|---|
| 0 | Done |
| 1 | Refused by the checks; nothing was changed |
| 2 | A step failed; the previous rules and ufw state are back |
| 3 | A step failed and putting the old rules back failed too: ufw may now be **disabled**. The message names the directory holding the saved files; fix the cause and run `sudo bash firewall-setup.sh --reset` |

`--json --enable` (the Node Manager UI) puts a failure's code in its `done` event as
`rc`, with `active` saying whether ufw is on.

### sshd hardening

"Manage SSH access" option 1 sets `PasswordAuthentication no` and
`KbdInteractiveAuthentication no`; option 2 sets `PermitRootLogin no`. Both write the
drop-in `/etc/ssh/sshd_config.d/00-telcoin-hardening.conf` (root 0644) and leave
`/etc/ssh/sshd_config` alone; the `00-` prefix sorts before cloud-init's drop-in, and
sshd keeps the first value it reads. The new drop-in is checked with `sshd -t`; if the
check fails, the previous drop-in is put back (or the new one removed) and sshd is not
reloaded. After the reload the script reads each value back with `sshd -T` and warns
when one did not take (an earlier drop-in or a `Match` block sets it) or when
`sshd_config` has no `Include` line for `sshd_config.d`.

`sshd -t` fails when `/run/sshd` does not exist, which happens on a host whose sshd is
socket-activated and has not yet taken a connection. If you are logged in over SSH you
already have it; on a console session, create it with `sudo install -d -m 0755 /run/sshd`
and choose the option again.

---

## Caddy edge (dashboard and public RPC)

`install-caddy.sh` puts the Node Manager dashboard and the node's public RPC behind
Caddy with TLS. The README covers setup ("External dashboard access"); these are the
rules that matter next to the add-ons:

- It is not offered on a mainnet validator; the full rule is in
  [Mainnet: every add-on refuses](#mainnet-every-add-on-refuses). It also needs to know
  the network: `NETWORK` in `.node-meta`, else a readable genesis.
- Caddy comes from its apt repository only when the repository key's fingerprint is
  `65760C51EDEA2017CEA2CA15155B6D79CA56EA34`; any other key stops the install before
  `apt-get update`.
- Caddy's admin API listens only on the unix socket `/run/caddy/admin.sock` (mode 0600),
  never on a TCP port. The drop-in `/etc/systemd/system/caddy.service.d/tn-admin.conf`
  gives Caddy its `/run/caddy` directory. The first apply that switches the admin
  address restarts Caddy once; after that every change is a reload.
- `/etc/caddy/Caddyfile` is root:caddy 0640. Each change backs the live file up to
  `/etc/caddy/Caddyfile.bak.<YYYYmmdd_HHMMSS>` (root 0600, five newest kept), and the
  Caddyfile from before install-caddy.sh first touched it is kept once as
  `/etc/caddy/Caddyfile.tn-orig` (root 0600).
- The dashboard password must be at least 16 bytes with no control characters. Give it
  on stdin with `--password-stdin`; `TN_CADDY_PASSWORD` is still read and unset at once,
  and giving both is refused. The interactive menu offers to generate one.
- The dashboard site sends `Strict-Transport-Security "max-age=31536000"`,
  `X-Content-Type-Options "nosniff"`, `X-Frame-Options "DENY"` and
  `Referrer-Policy "no-referrer"`, drops the `Server` header and caps request bodies at
  64KB. A dashboard enabled with an older release gets these headers when you enable it
  again.
- Public RPC needs your consent to an exposure summary (anyone on the internet, every
  RPC namespace the node serves, CORS open, no rate limit at this edge). On a terminal
  it asks; without one it needs `--yes`; a `--json` run sends the summary as a `warn`
  event and treats the UI action as the consent.
- When enabling or disabling public RPC restarts the node, the restart first checks that
  the committee keeps its quorum, then waits for the epoch boundary when the node votes
  in the current committee. If the check refuses or the wait fails, the run puts
  `node-info.yaml` and any `--ws` launch edit back and stops without restarting.
  `TN_ALLOW_QUORUM_RISK=1` and `TN_SKIP_EPOCH_WAIT=1` work as for observability.

---

## Verifying it works

```bash
# Health: returns OK once the node is up; rule restricted to the monitor
curl -s http://127.0.0.1:43174
sudo ufw status | grep 43174          # → 104.155.184.201/32, not Anywhere

# Logging: first reth log line is JSON, Alloy is up and shipping bytes
sudo head -1 /var/log/telcoin/node/telcoin-network-logs/reth.log    # binary/source install
journalctl -u telcoin-alloy -n 20
systemctl show -p User telcoin-alloy                                 # → User=telcoin-alloy (native)
curl -s 127.0.0.1:12345/metrics | grep loki_write_sent_bytes_total

# Metrics: node serves its loopback registry; Alloy is remote-writing samples
curl -s 127.0.0.1:9101/metrics | grep -E '^(tn_|reth_)' | head
curl -s 127.0.0.1:12345/metrics | grep prometheus_remote_storage_samples_total

# VPN: tunnel, keys, drop-in, firewall, self-heal and sudo scope in one report
sudo bash setup-vpn.sh --status
ip route | head -1                    # default route unchanged
```

`bash check-node.sh` reports them under "testnet add-ons" on a testnet node.

---

## Removing the add-ons

Each add-on comes off on its own: the `setup-observability.sh` menu disables logs,
metrics and health monitoring; `sudo bash setup-vpn.sh --disable` tears down the VPN
(see [WGVPN.md](../WGVPN.md#7-turn-it-off)).

`remove-node.sh` clears the observability and VPN add-ons when it removes the node,
including half-removed ones:

- Alloy: stops and removes `telcoin-alloy.service`, the sidecar container and image,
  a tarball-installed `/usr/local/bin/alloy`, shreds the token file and the env file,
  removes `/etc/telcoin/alloy`, `/var/lib/telcoin-alloy` and the `telcoin-alloy` account.
- VPN: removes the self-heal units and `/usr/local/sbin/tn-vpn-selfheal` first (so they
  cannot put the drop-in back), brings `wg0` down, removes its config and key, the
  dormant firewall service and files, `/etc/wgvpn/tnadmin.keys`,
  `/etc/wgvpn/tnadmin.revoked`, `/etc/wgvpn/tnadmin.authorized_keys`,
  `/etc/sudoers.d/90-tnadmin` and the scoped sshd drop-in, deletes the overlay SSH ufw
  rules for both the maintainers' range and the whole overlay, and removes the
  `tnadmin` account. Ask the Association to de-enroll your overlay peer afterwards.

remove-node.sh also removes private alerts (the heartbeat timer and service, the runner,
`/etc/telcoin/alerts` and the runner's state), before it stops the node, so the heartbeat
does not report the stop as a failure. Pause or delete the node's monitor afterwards: a
push monitor alerts on silence.

remove-node.sh does not touch Caddy. Turn the dashboard and public RPC off with
`sudo bash install-caddy.sh`; once no managed site remains it restores the Caddyfile you
had before.

---

## For maintainers (Telcoin Association)

### Issuing an obs ingest token

One token covers **both** telemetry pipelines: the Caddy edge gates the Loki push
(`/loki/api/v1/push`) and the Prometheus remote-write (`/api/v1/write`) on the same exact
`Authorization: Bearer <token>`. To issue a token for an external operator:

1. Generate one: `openssl rand -hex 32`.
2. Register it on the obs VM so Caddy accepts it. The current Adiri obs VM gates on a
   single shared token (`observability/obs-vm/Caddyfile` in deploy-networks-common,
   `OBS_INGEST_TOKEN`) for both the `/loki/api/v1/push` and `/api/v1/write` routes, so
   every operator holds the same token and revoking one operator means rotating it for
   all. Per-node tokens need that gate to check a list of tokens (the rest of #35).
   Coordinate with the obs-stack owner before handing tokens to operators.
3. Give the operator the token over a private channel. They paste it into
   `setup-observability.sh` (it covers logs and metrics; they need not paste it twice),
   or pipe it to `--token-stdin` in a scripted run. A new token reaches a running node
   with `setup-observability.sh --rotate-token`.

Keep these limits in mind on the obs-VM side (they are why this telemetry is
low-risk to accept from outside operators):

- **Fixed, low-cardinality labels only.** The node sets `node`, `region`,
  `validator_address`, `chain`, `image_version` (plus `network` on the metrics path),
  and no operator-defined labels. Don't add high-cardinality labels; they multiply Loki
  streams and Prometheus series across operators.
- **Rate / retention** (from `loki-config.yaml`): ingestion ~16 MB/s (32 MB burst),
  ~14-day retention. The Prometheus `/api/v1/write` route has its own Caddy rate-limit
  zone. Consider per-token stream/rate limits as the operator count grows.
- Treat the token as **telemetry-push only** (logs + metrics). Rotating it is cheap:
  re-issue it, then each operator runs `setup-observability.sh --rotate-token`.

### Enrolling a node on the WireGuard overlay

The operator can't be reached over IAP, so `enroll-node.sh` (which reads the pubkey
over IAP) doesn't apply. Use `add-node.sh` with the operator-supplied values instead. On
your `adiri-genesis` checkout, hand them a free IP first, then register what they send
back (`setup-vpn.sh` prints the exact command, so you can just run that):

```bash
./common/wgvpn/add-node.sh --next-ip        # e.g. 10.100.20.9; give this to the operator first
./common/wgvpn/add-node.sh "<node_name>" "<overlay_ip>" "<wg_pubkey>" "external <vendor>"
git -C common add peers/registry.csv        # commit the registry; bump the parent pointer
```

`add-node.sh` validates the values for you: it rejects the reserved nets (`0` hub, `1`
adiri core, `2` devnet, `9` maintainers; pick from the **external band
`10.100.20.0/24`+**, one `/32` per node) and refuses a duplicate name or IP. It appends
the `node` row (stamping the run-date) and re-renders the hub (`wg syncconf`).
`sync-access.sh` is **not** needed: the node installed the maintainer keys at enrolment
from the `.pub` files that `lib/wgvpn/peers/ssh/KEYS` lists.

Verify the node is reachable once your own tunnel is up:

```bash
source common/wgvpn/lib/wg-ssh-lib.sh && tn_ssh <node_name> hostname
```

To de-enroll: `./common/wgvpn/remove-peer.sh "<node_name>"` (drops the row + re-renders
the hub, severing the overlay route), and tell the operator they can run
`setup-vpn.sh --disable`.

### Maintainer keys

Nodes install a maintainer key only when `lib/wgvpn/peers/ssh/KEYS` lists it as
`<name> SHA256:<fingerprint>` and `<name>.pub` holds exactly that one key. Adding,
revoking and the per-host deny list are in [WGVPN.md](../WGVPN.md#maintainer-keys).
Once an external node runs setup-vpn.sh 2.0.0 (new enrolments, and older nodes after
their first `--sync-keys` or self-heal on the new scripts), `sync-access.sh` no longer
changes its key set: it writes `~tnadmin/.ssh/authorized_keys.tnvpn`, which the node no
longer reads. New keys and revocations reach it through a script release and the
operator's `setup-vpn.sh --sync-keys`.

---

## Sync note (vendored files)

These files are **vendored** from the `deploy-networks-common` repository, which
`adiri-genesis` checks out as its `common/` submodule, and must stay in sync:

| Here (`tn-node-deployment`) | Upstream (`deploy-networks-common`) |
|---|---|
| `observability/config.alloy` (functional blocks) | `observability/node-agent/config.alloy` |
| `lib/wgvpn/wg-node-bootstrap.sh` (below the header) | `wgvpn/node/wg-node-bootstrap.sh` |
| `lib/wgvpn/hub-coordinates.env` | `wgvpn/hub/hub-coordinates.env` |
| `lib/wgvpn/peers/ssh/*.pub` | `wgvpn/peers/ssh/*.pub` |
| `lib/wgvpn/peers/ssh/KEYS` | none yet: one line per `.pub` file (see below) |
| Hub coords / Kuma IP / obs URL in `lib/testnet-addons.env` | `config.sh` (in `adiri-genesis`), `wgvpn/hub/hub-coordinates.env` |

> **`peers/ssh/*.pub` is mirrored for you, `KEYS` is not.** `wgvpn/add-peer.sh` /
> `wgvpn/remove-peer.sh` in `deploy-networks-common` mirror the whole maintainer key set into
> `lib/wgvpn/peers/ssh/` on every (de)registration and print the `tn-node-deployment`
> commit command. Nodes ignore a `.pub` file that `KEYS` does not list, so
> `add-peer.sh` and `sync-access.sh` must also write the key's `KEYS` line. Until that
> tooling does, add the line by hand in the same commit (and move a removed maintainer's
> line under `# revoked:`, as [WGVPN.md](../WGVPN.md#revoke-a-maintainer-key) shows):
>
> ```bash
> printf '%s %s\n' "<name>" "$(ssh-keygen -lf lib/wgvpn/peers/ssh/<name>.pub -E sha256 | awk '{print $2}')"
> ```

**Shipping to operators.** `update-scripts.sh` fetches files by explicit path, so every
vendored file, each maintainer `.pub` and `KEYS` included, must be listed in its
`TESTNET_ADDONS_BUNDLE` array. The release manifest is built from that array, and the
updater installs every changed file the signed `MANIFEST` lists, so a vendored change
reaches operators with the next signed script release. Bump `TESTNET_ADDONS_VERSION`
(or `OBSERVABILITY_VERSION` for `config.alloy`) with it so the updater's version listing
shows the change.

**config.alloy**: BOTH the log-shipping blocks (`local.file_match` through
`loki.write`) AND the metrics blocks (`prometheus.scrape` through
`prometheus.remote_write`) must be byte-identical to upstream so external telemetry lands
in the same Loki/Prometheus schema and dashboards. `lib/observability.sh` slices this file
on the `local.file_match` / `// --- Metrics pipeline` anchors to deploy only the
pipeline(s) the operator opted into; for native Alloy the deployed copy also points
`__path__` at the node log directory. The vendored file itself hashes to the value below
(recompute with `sha256sum observability/config.alloy` and update this line whenever you
re-vendor, so unexpected drift is detectable):

```
sha256(observability/config.alloy) = 3fa5266154aec8b0a2713c30f27cc6c6c4ec6994f9aedd235ad085a5c5200db7
```

The current copy (token file and TLS pin) is vendored from `deploy-networks-common` main
at 18f8485 (PR #8, merged 2026-11-04); the file's header says so. The other upstream
consumers of the file (`docker-compose.yml` beside it, and the `start-*-node.sh` heredocs
in `adiri-genesis`) still pass the token in the environment; that is tracked in
`followup.md`.

Verify the functional blocks against upstream (the file headers differ by design; from
the first River component to EOF must match exactly, so this diff should be empty):

```bash
diff <(sed -n '/^local\.file_match/,$p' <deploy-networks-common>/observability/node-agent/config.alloy) \
     <(sed -n '/^local\.file_match/,$p' observability/config.alloy)
```

`tools/tests/obs_test.sh` runs the same diff when `TN_UPSTREAM_ALLOY_CONFIG` names the
upstream file.

**wg-node-bootstrap.sh**: a verbatim copy with two upstream-pushed changes, the
`WG_NODE_SSHD_HARDEN` and `WG_NODE_SUDOERS` guards (both default `1` = upstream
behavior). `setup-vpn.sh` calls it with `WG_NODE_SSHD_HARDEN=0`, `WG_NODE_SUDOERS=0`,
`WG_NODE_ENFORCE=0` and only the keys that pass `KEYS` and the host's deny list.
`setup-vpn.sh` writes `/etc/sudoers.d/90-tnadmin` itself before the bootstrap runs, and
again afterwards only when the file differs (a vendored copy without the
`WG_NODE_SUDOERS` guard writes full root there). The bootstrap still writes
`~tnadmin/.ssh/authorized_keys.tnvpn`, which `setup-vpn.sh` deletes once the drop-in reads
`/etc/wgvpn/tnadmin.authorized_keys`. `setup-vpn.sh` refuses to run it while `~tnadmin`,
its `.ssh` or that key file is a symlink. The vendored file's header records the upstream
`sha256`. To re-vendor after an upstream change, strip the 14-line provenance header
(lines 2-15: `sed '2,15d' lib/wgvpn/wg-node-bootstrap.sh`) and diff the body against the
new upstream, then update the sha.
