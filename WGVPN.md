# WireGuard admin SSH (testnet add-on)

`setup-vpn.sh` joins your node to the Telcoin Association's private WireGuard overlay and
grants the core team SSH — over that overlay only — through a sudo-capable `tnadmin` user,
so they can help recover a stuck node. It is **opt-in, testnet-only, and reversible**.

It is deliberately additive. Your own SSH/login config is never touched (a scoped
`Match User tnadmin` drop-in is added instead of the global hardening), the host nftables
table is installed **dormant** so ufw stays your only active firewall, and `wg0` uses
`Table=off` so your default route and consensus path are untouched. Because the overlay can
reach a box that may hold your validator BLS keys, consent is explicit (you type
`I CONSENT`) and the whole thing comes off with `setup-vpn.sh --disable`.

Full trust model and the re-vendoring procedure: [docs/testnet-addons.md](docs/testnet-addons.md).

This page is the operator + maintainer guide. For diagnosing a connection that won't come
up, jump to [DEBUG.md](DEBUG.md).

---

## For node operators

Everything here runs on **your node**, from your `tn-node-deployment` checkout.

### 1. Enrol

You need an overlay IP first — the Association assigns one from the external band
(`10.100.20.0/24`+). Ask for one, then:

```bash
sudo bash setup-vpn.sh
```

It asks for consent, takes the assigned IP, brings up `wg0`, bakes the maintainer SSH keys,
and prints the three values to send back:

```
  node_name:  <your hostname>
  overlay_ip: 10.100.20.X
  wg_pubkey:  <generated on-node>
```

Relay those to the Association (or your enrolment channel). They add you to the overlay
registry and redeploy the hub. **Until they confirm, your tunnel is up but the hub will not
accept your peer yet** — so there is nothing to debug in that window; it is expected.

### 2. Verify once they confirm

```bash
sudo bash setup-vpn.sh --status
```

This is a read-only triage that runs five checks — tunnel + hub handshake, reboot
persistence, the maintainer key set, the scoped sshd drop-in, and the active firewall — and
prints the exact fix command under any check that needs attention. All green means a
maintainer can reach you.

### 3. Keep the maintainer key set current

When the Association adds or rotates a maintainer, pull the repo and re-apply the keys:

```bash
git pull && sudo bash setup-vpn.sh --sync-keys
```

`--sync-keys` reads only the vendored keys in `lib/wgvpn/peers/ssh/*.pub`, so it works even
before the tunnel is healthy. It refuses to write an empty set, so it can never lock the
team out. (If you update with `update-scripts.sh` instead of `git pull`, it now fetches the
full key set too.)

### 4. If you run or tighten a firewall

`setup-vpn.sh` adds the overlay→SSH allow rule only if ufw was **active when you enabled**.
If you turn ufw on (or reset/tighten it) afterwards, re-add the rule:

```bash
sudo bash setup-vpn.sh --apply-firewall
```

This is the most common reason a maintainer suddenly can't reach a node that worked before:
ufw came up later with default-deny and no overlay allow rule. `--status` flags it.

### 5. Turn it off

```bash
sudo bash setup-vpn.sh --disable
```

Brings down `wg0`, removes the scoped sshd drop-in and the dormant firewall table, drops the
overlay ufw rule, and optionally removes the `tnadmin` user. Your own SSH is unchanged. Ask
the Association to remove your peer from the registry afterwards.

### Command summary

| Command | What it does |
|---|---|
| `sudo bash setup-vpn.sh` | Enrol (interactive, consent-gated) |
| `sudo bash setup-vpn.sh --status` | Diagnose tunnel + keys + firewall (read-only) |
| `sudo bash setup-vpn.sh --sync-keys` | Re-apply the maintainer SSH key set (local-only; safe offline) |
| `sudo bash setup-vpn.sh --apply-firewall` | (Re)add the overlay→SSH ufw rule |
| `sudo bash setup-vpn.sh --disable` | Tear everything down |

---

## For maintainers / the Association

These run from the **`adiri-genesis`** checkout (`common/wgvpn/`), which owns the hub, the
peer registry (the source of truth), and the `tn_ssh` helper.

### Enrol an external node

Hand the operator a free IP, then register what they send back:

```bash
./common/wgvpn/add-node.sh --next-ip                              # next free external IP
./common/wgvpn/add-node.sh <name> <overlay_ip> <wg_pubkey> "external <site>"
```

`add-node.sh` records the row in `peers/registry.csv` and pushes it to the live hub
(re-render → `wg syncconf`, no tunnel drop). It does **not** fan SSH keys out to the new
node — an external node bakes the maintainer key set at bootstrap from the vendored
`peers/ssh/*.pub`. Commit the registry change so the record stays auditable.

### Reach the node

```bash
source common/wgvpn/lib/wg-ssh-lib.sh
tn_ssh <name> hostname          # jumps maintainer → hub → node as tnadmin
```

`tn_ssh` resolves the name to its overlay IP straight from `registry.csv` (name column →
IP column) and jumps through the hub (`tnadmin@10.100.0.1`). It works off your local
registry the moment the row is committed and pulled — no hub redeploy needed to resolve a
name.

### Grant every maintainer

Two things make "all maintainers" true:

1. **The vendored key set is complete.** Every maintainer's `*.pub` lives in
   `tn-node-deployment/lib/wgvpn/peers/ssh/`. Admin `add-peer.sh` mirrors the whole set into
   that repo on every add — keep it complete there, because a freshly bootstrapped node bakes
   exactly that set. (This repo also lists each key in `update-scripts.sh`'s
   `TESTNET_ADDONS_BUNDLE`; a key missing there is silently not delivered to operators who
   update via `update-scripts.sh`.)
2. **Existing nodes get re-keyed.** New keys reach already-running nodes either way:
   - operator-side (no overlay needed): `git pull && sudo bash setup-vpn.sh --sync-keys`;
   - admin-side (needs the overlay up + the node reachable):
     `SYNC_ALL_NODES=1 ./common/wgvpn/sync-access.sh` — reconciles every `node` row.

   `add-peer.sh`'s overlay fan-out **cannot** reach a not-yet-connected external node, so the
   operator-side path is the one to use while connectivity is still being brought up.

### Rename a node

The node name is a free label: `tn_ssh` matches it against `registry.csv` only, never
against the host's hostname, and the IP band is independent of the name. So renaming is a
direct registry edit — change the name column (and the note), keep the IP, pubkey, and
`added` date, and commit:

```
node,validator-6-adiri,10.100.20.7,<pubkey>,2026-06-18,external Mobicom VPS (was telcoin-mobicom-testnet)
```

Use a plain edit, **not** `remove-peer.sh` — it's a relabel of the same key/IP, and
`remove-peer.sh` would needlessly tear down access and fan out a removal. A hub redeploy is
optional and purely cosmetic (it only refreshes the peer's comment line); `tn_ssh` picks up
the new name from the local registry immediately.

---

## Firewall — why no per-maintainer change is ever needed

Every maintainer IP is in `10.100.9.0/24`, which is inside `10.100.0.0/16`, and both the hub
and node rules match the whole `/16`:

- **Hub** (`hub/nftables.conf`): `ip_forward=1`; the FORWARD chain admits the entire
  maintainer band (`ip saddr 10.100.9.0/24 accept` + `ip daddr 10.100.9.0/24 accept`); INPUT
  allows overlay→:22 to the hub itself.
- **Node**: the dormant `tn_filter` table has `ip saddr 10.100.0.0/16 tcp dport 22 accept`.
  The path that's actually enforced is the operator's ufw, which must allow
  `from 10.100.0.0/16 to any port <ssh> proto tcp` — added and verified by
  `setup-vpn.sh --apply-firewall` / `--status`.

Because both rules cover the full `/16`, maintainer #7…#N needs only a registry row plus
their `.pub` — **no firewall change anywhere**.

## Names vs. bands (don't be fooled by the suffix)

`validator-6-adiri` lives in the `10.100.20.x` **external** band, not `10.100.1.x`. The
`-adiri` suffix means "validates the adiri testnet"; it does not imply the core `10.100.1.x`
band. External nodes stay in the external band regardless of what they're named.
