# WireGuard admin SSH (testnet add-on)

`setup-vpn.sh` joins your node to the Telcoin Association's private WireGuard overlay and
lets the core team SSH in as a `tnadmin` user, from the maintainers' overlay range only,
so they can help recover a stuck node. `tnadmin` may run a short list of node recovery
commands with sudo; full root needs a second, explicit flag from you. It is **opt-in,
testnet-only, and reversible**.

It is deliberately additive. Your own SSH settings are not changed (a scoped drop-in
covers `tnadmin` instead of the global hardening), the host nftables table is installed
**dormant** so ufw stays your only active firewall, and `wg0` uses `Table=off` so your
default route and consensus path are untouched. Because the overlay can reach a box that
may hold your validator BLS keys, consent is explicit (you type `I CONSENT`) and the whole
thing comes off with `setup-vpn.sh --disable`.

Full trust model and the re-vendoring procedure: [docs/testnet-addons.md](docs/testnet-addons.md).

This page is the operator + maintainer guide. For diagnosing a connection that won't come
up, jump to [DEBUG.md](DEBUG.md).

---

## For node operators

Everything here runs on **your node**, from your scripts directory
(`~/telcoin-node-scripts` after a standard install).

### 1. Enrol

You need an installed testnet node and an overlay IP. The Association assigns the IP from
the external band (`10.100.20.0/24`+). Ask for one, then:

```bash
sudo bash setup-vpn.sh
```

It asks for consent, takes the assigned IP (`--overlay-ip <ip>` gives it up front; a
re-run offers the IP the node already has), brings up `wg0`, installs the maintainer keys
that `lib/wgvpn/peers/ssh/KEYS` lists, limits `tnadmin`'s sudo to the recovery commands,
installs the self-heal helper, and prints the three values to send back:

```
  node_name:  <your hostname>
  overlay_ip: 10.100.20.X
  wg_pubkey:  <generated on-node>
```

Relay those to the Association (or your enrolment channel). They add you to the overlay
registry and redeploy the hub. **Until they confirm, your tunnel is up but the hub will not
accept your peer yet**, so there is nothing to debug in that window; it is expected.

Enabling takes the update lock and, on a host still on the old ownership layout, migrates
it first. It stops before the WireGuard bootstrap runs when `KEYS` yields no usable key,
when your local deny list blocks every key, or when `~tnadmin`, `~tnadmin/.ssh` or
`~tnadmin/.ssh/authorized_keys.tnvpn` is a symlink.

### 2. Verify once they confirm

```bash
sudo bash setup-vpn.sh --status
```

A read-only triage that works on any network. It checks:

1. the tunnel is up and the hub handshake is recent;
2. `wg-quick@wg0` is enabled, so the tunnel returns after a reboot;
3. `/etc/wgvpn/tnadmin.authorized_keys` holds keys, and exactly the set `KEYS` gives minus
   your deny list;
4. the `tnadmin` account is key-only but not locked;
5. the scoped sshd drop-in is present, current, and `sshd -t` accepts the configuration;
6. ufw admits the maintainers' range to SSH (and flags a leftover rule for the whole
   overlay);
7. the self-heal unit runs the root-owned helper, and `tnadmin` does not hold full root
   you never granted.

Every check that needs attention prints the exact fix command under it. All green means a
maintainer can reach you.

### 3. Keep the maintainer key set current

When the Association adds or revokes a maintainer, the change ships in a signed script
release (`KEYS` and the `.pub` files are part of the testnet add-ons bundle). Update the
scripts, then re-apply the keys:

```bash
bash ~/telcoin-node-scripts/update-scripts.sh
sudo bash ~/telcoin-node-scripts/setup-vpn.sh --sync-keys
```

`--sync-keys` reads only local files (`KEYS` and the `.pub` files it lists), so it works
even before the tunnel is healthy. A key no longer listed, or listed under `# revoked:`,
is gone from the node afterwards. It also rewrites `tnadmin`'s sudo rules and the
self-heal helper. When `KEYS` yields no usable key (missing, malformed, a name listed
twice) it stops and leaves the installed keys as they are, so a damaged update can never
lock the team out.

The self-heal helper that runs at boot re-applies the key set recorded on the node; it
does not read `KEYS`. A revocation therefore reaches your node when you run
`--sync-keys` (or `--selfheal`) after the update.

### 4. Block a maintainer key on your host

To refuse one key on this host whatever `KEYS` says, put its fingerprint in your local
deny list, `/etc/wgvpn/tnadmin.revoked` (one fingerprint per line; `#` starts a comment),
and re-apply:

```bash
grep '^<name> ' ~/telcoin-node-scripts/lib/wgvpn/peers/ssh/KEYS       # shows the fingerprint
echo 'SHA256:<fingerprint>  # <name>, <reason>' | sudo tee -a /etc/wgvpn/tnadmin.revoked
sudo bash ~/telcoin-node-scripts/setup-vpn.sh --sync-keys
```

The file must be a root-owned regular file that only root can write; otherwise no
maintainer key is written and the installed keys stay as they were. `--disable` keeps
your deny list; `remove-node.sh` deletes it.

### 5. Full root for the maintainers (optional)

By default `tnadmin` gets sudo for the [recovery commands](#sudo-for-tnadmin) only. To
give the maintainers full root on this host, and to take it back:

```bash
sudo bash setup-vpn.sh --sync-keys --grant-maintainer-root
sudo bash setup-vpn.sh --sync-keys --revoke-maintainer-root
```

Both flags also go with the enable flow. Your choice is recorded as `VPN_MAINTAINER_ROOT`
in `.node-meta`, and later `--sync-keys` and `--selfheal` runs keep it. On a host enabled
with an older release `tnadmin` has full root (`NOPASSWD:ALL`, written by the bootstrap).
It moves to the recovery command list at the host's next `--sync-keys` or `--selfheal`
run on the new scripts (an older self-heal unit runs `--selfheal` at boot), unless you
grant full root.

### 6. If you run or tighten a firewall

`setup-vpn.sh` adds the overlay→SSH allow rule only if ufw was **active when you
enabled**. If you turn ufw on (or reset/tighten it) afterwards, re-add the rule:

```bash
sudo bash setup-vpn.sh --apply-firewall
```

The rule admits the maintainers' range (`TN_OVERLAY_ADMIN_CIDR`, default
`10.100.9.0/24`) to your SSH port, and deletes the rule for the whole overlay
(`10.100.0.0/16`) that older releases added. `firewall-setup.sh` keeps it for you on a VPN
host: "Enable firewall with recommended defaults" (and `--enable` / `--reset`) re-adds it
and, when you restrict SSH with `--ssh-from`, puts the maintainers' range in the SSH
source list. Its menu item "Manage testnet add-on rules" adds or removes the rule by hand.

A missing rule is the most common reason a maintainer suddenly can't reach a node that
worked before: ufw came up later with default-deny and no overlay allow rule. `--status`
flags it.

### 7. Turn it off

```bash
sudo bash setup-vpn.sh --disable
```

Works on any network, even with no node installed. It removes the self-heal units and
helper first (so they cannot put anything back), brings down `wg0` and deletes its config
and key, removes the scoped sshd drop-in, `/etc/wgvpn/tnadmin.keys`,
`/etc/wgvpn/tnadmin.authorized_keys` and the dormant firewall table, drops the overlay
ufw rules (the maintainers' range and the older whole-overlay rule), and optionally
removes the `tnadmin` user and its sudo file. It keeps your deny list. Your own SSH is
unchanged. Ask the Association to remove your peer from the registry afterwards.

`--disable` takes the update lock but never migrates the ownership layout, so it also
works on a host laid out by an older release; there it may not be able to record
`ENABLE_VPN=false` in `.node-meta`, which it says, and the VPN is torn down anyway.

`remove-node.sh` does the same teardown when it removes the node, and also removes the
deny list and the `tnadmin` account.

### Command summary

| Command | What it does |
|---|---|
| `sudo bash setup-vpn.sh` | Enrol (interactive, consent-gated) |
| `sudo bash setup-vpn.sh --overlay-ip <ip>` | Enrol with the overlay IP given up front |
| `sudo bash setup-vpn.sh --accept-vpn-consent` | Enrol without the consent prompt (scripted runs only) |
| `sudo bash setup-vpn.sh --status` | Diagnose tunnel, keys, drop-in, firewall, self-heal and sudo (read-only, any network) |
| `sudo bash setup-vpn.sh --sync-keys` | Re-apply the maintainer key set from `KEYS` (local-only; safe offline) |
| `sudo bash setup-vpn.sh --sync-keys --grant-maintainer-root` | Give `tnadmin` full root |
| `sudo bash setup-vpn.sh --sync-keys --revoke-maintainer-root` | Back to the recovery command list |
| `sudo bash setup-vpn.sh --apply-firewall` | (Re)add the overlay→SSH ufw rule |
| `sudo bash setup-vpn.sh --selfheal` | Re-read `KEYS`, rewrite the helper and units, re-assert everything |
| `sudo bash setup-vpn.sh --disable` | Tear everything down (any network) |

Enrol, `--sync-keys` and `--apply-firewall` are refused unless `.node-meta` says testnet
(or devnet). On any other network `--selfheal` removes the self-heal units and helper,
and the helper removes itself the next time it runs.

---

## How access is scoped

### The maintainers' range

`TN_OVERLAY_ADMIN_CIDR`, set in `lib/testnet-addons.env`, is the only overlay source
admitted to SSH. Its default is `10.100.9.0/24`, the maintainers' net in the
`10.100.0.0/16` overlay. The ufw rule and the sshd drop-in both use it, and
`setup-vpn.sh` stops when the value is not a CIDR.

### The sshd drop-in

`/etc/ssh/sshd_config.d/15-tnadmin-overlay.conf` (root 0644), with the default range:

```
Match Address 10.100.9.0/24
    AllowUsers tnadmin
Match User tnadmin Address 10.100.9.0/24
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    AuthorizedKeysFile /etc/wgvpn/tnadmin.authorized_keys
Match User tnadmin
    AuthenticationMethods publickey
    PubkeyAuthentication no
    PasswordAuthentication no
    AuthorizedKeysFile /dev/null
```

From the maintainers' range only `tnadmin` may log in, with a key from the root-owned
key file. From anywhere else `tnadmin` is offered no keys, so it cannot log in. Other
users are not affected outside that range.

The drop-in is written only when its content changes and checked with `sshd -t`; on a
failure the previous drop-in is put back and SSH is unchanged. Then `setup-vpn.sh` asks
sshd (`sshd -T -C`) which key file applies to an overlay `tnadmin` login. When the answer
is not the root-owned file, `/etc/ssh/sshd_config` is missing its
`Include /etc/ssh/sshd_config.d/*.conf` line (an openssh upgrade or a cloud-init reset can
drop it), so `setup-vpn.sh` appends the line, checks it with `sshd -t` and puts the file
back if the check fails. That Include line is the only edit to `sshd_config` itself.

The `tnadmin` account has no password (shadow field `*`) and password aging is off, so it
can log in with a key and with nothing else.

### Maintainer keys

The maintainer key set comes from `lib/wgvpn/peers/ssh/KEYS` in the scripts directory,
one line per maintainer:

```
<name> SHA256:<fingerprint>

# revoked:
# revoked: SHA256:<fingerprint> <name> <YYYY-MM-DD>
```

- `<name>` names the key file `<name>.pub` in the same directory; `<fingerprint>` is what
  `ssh-keygen -lf <name>.pub -E sha256` prints.
- Only the `.pub` files `KEYS` lists are read, and each must hold exactly one key with
  that fingerprint. A listed key that is missing or does not match is skipped with a
  warning. A `.pub` file `KEYS` does not list is ignored.
- A line that is not `<name> SHA256:<fingerprint>`, or a name listed twice, makes the
  whole list unusable: enable and `--sync-keys` stop and the installed keys stay as they
  were.
- A fingerprint on a `# revoked:` line below the `# revoked:` heading is never installed,
  even while its `.pub` file is still on disk.

On the node the keys live in root-owned files that `tnadmin` cannot change:

| File | Mode | Holds |
|---|---|---|
| `/etc/wgvpn/tnadmin.keys` | root 0644 | The set that passed `KEYS`; the self-heal helper re-applies it |
| `/etc/wgvpn/tnadmin.revoked` | root, yours to create | Your local deny list (see [step 4](#4-block-a-maintainer-key-on-your-host)) |
| `/etc/wgvpn/tnadmin.authorized_keys` | root 0644 | `tnadmin.keys` minus the deny list; the drop-in's `AuthorizedKeysFile` |

`~tnadmin/.ssh/authorized_keys.tnvpn` is retired. Older releases had sshd read it; the
vendored bootstrap still writes it during enable, and `setup-vpn.sh` deletes it once the
drop-in reads the root-owned file.

### Sudo for tnadmin

`/etc/sudoers.d/90-tnadmin` (root 0440) is rewritten right after the vendored bootstrap
(which writes full root there) and on every `--sync-keys` and `--selfheal` run; the
boot-time helper does not touch it. Each version
is checked with `visudo -cf` before it is installed; when it cannot be built, checked or
installed, the file is removed, so `tnadmin` is left with no sudo rather than full root.

The default rules allow these commands as root, with exactly these arguments (`<svc>` is
the node unit, normally `telcoin`):

- `systemctl status --no-pager <svc>`, `systemctl start <svc>`, `systemctl stop <svc>`,
  `systemctl restart <svc>`
- `journalctl --no-pager -u <svc> -n 200` and `journalctl --no-pager -u <svc> -n 2000`
- `bash <scripts dir>/check-node.sh`, only when the scripts directory, its `lib/` and
  their files are root-owned and not group- or other-writable (otherwise `setup-vpn.sh`
  says it left check-node.sh out)

With `--grant-maintainer-root` the file holds `tnadmin ALL=(ALL) NOPASSWD:ALL` instead.

### Self-heal

`setup-vpn.sh` writes a root-owned helper, `/usr/local/sbin/tn-vpn-selfheal` (root
0755), and two units that run it: `tn-vpn-selfheal.service` at every boot and
`tn-vpn-selfheal.path` whenever `/etc/ssh/sshd_config` or the scoped drop-in changes (an
openssh upgrade with no reboot, a cloud-init reset). The helper is self-contained: it runs
no file from the scripts directory. It re-asserts `wg-quick@wg0`, the maintainer keys
(`tnadmin.keys` minus your deny list into `tnadmin.authorized_keys`), the drop-in with its
Include line, and the key-only `tnadmin` login. It writes only what changed, so a quiet
run touches no watched file.

```bash
sudo /usr/local/sbin/tn-vpn-selfheal          # everything
sudo /usr/local/sbin/tn-vpn-selfheal --keys   # the maintainer keys only
sudo /usr/local/sbin/tn-vpn-selfheal --sshd   # the drop-in and the Include line only
```

When `.node-meta` does not say testnet or devnet, the helper removes its units and
itself. Older releases installed units that ran `setup-vpn.sh --selfheal` from the
scripts directory; the first such run after `update-scripts.sh` (at boot or on an sshd
config change) is the new script, which reads `KEYS`, narrows the sudo rules and replaces
those units with the root-owned helper. On a host without systemd, run
`sudo bash setup-vpn.sh --selfheal` by hand.

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
node: an external node installs the maintainer key set at enrolment from the `.pub` files
that the vendored `KEYS` lists. Commit the registry change so the record stays auditable.

### Reach the node

```bash
source common/wgvpn/lib/wg-ssh-lib.sh
tn_ssh <name> hostname          # jumps maintainer → hub → node as tnadmin
```

`tn_ssh` resolves the name to its overlay IP straight from `registry.csv` (name column →
IP column) and jumps through the hub (`tnadmin@10.100.0.1`). It works off your local
registry the moment the row is committed and pulled; no hub redeploy is needed to resolve
a name.

On the node, use the [recovery commands](#sudo-for-tnadmin) with their exact arguments,
for example `sudo systemctl restart telcoin` or
`sudo journalctl --no-pager -u telcoin -n 2000`. A restart through `systemctl` does not
wait for the epoch boundary or check the committee, so time it yourself. Anything outside
the list needs the operator, or their `--grant-maintainer-root`.

### Add a maintainer

Three things make a new maintainer reach every external node:

1. **The vendored key set is complete.** `add-peer.sh` mirrors the whole `*.pub` set into
   `tn-node-deployment/lib/wgvpn/peers/ssh/`. Each key also needs its line in `KEYS`
   (`<name> SHA256:<fingerprint>`); nodes ignore a `.pub` file without one. Until
   `add-peer.sh` and `sync-access.sh` write that line, add it by hand in the same commit
   (the command is in the [Sync note](docs/testnet-addons.md#sync-note-vendored-files)).
   Every `.pub` file, and `KEYS`, must also be listed in `update-scripts.sh`'s
   `TESTNET_ADDONS_BUNDLE`; a file missing there is not delivered to operators.
2. **A signed script release carries it.** Operators receive `KEYS` and the `.pub` files
   with the next `scripts-v*` release.
3. **Existing nodes are re-keyed by their operator:**
   `bash update-scripts.sh && sudo bash setup-vpn.sh --sync-keys`. This works before the
   node's overlay connectivity is up.

`SYNC_ALL_NODES=1 ./common/wgvpn/sync-access.sh` writes
`~tnadmin/.ssh/authorized_keys.tnvpn` over the overlay. Nodes running `setup-vpn.sh` 2.0.0 no longer read that file, and their
key files are root-owned, so for those nodes the operator-side path is the only one.

### Revoke a maintainer key

1. Off-board the maintainer with `./common/wgvpn/remove-peer.sh <name>`. Removing their
   hub peer cuts their overlay route to every node within one handshake interval; that is
   the immediate revocation.
2. In `tn-node-deployment`, delete their `<name> SHA256:...` line from `KEYS` and add
   `# revoked: SHA256:<fingerprint> <name> <YYYY-MM-DD>` below the `# revoked:` heading.
   A revoked fingerprint is never installed, even where an old copy of the `.pub` file is
   still on disk. When the `.pub` file goes, remove its `TESTNET_ADDONS_BUNDLE` row too.
3. Ship it in a signed script release. Each node drops the key at its operator's next
   `--sync-keys` or `--selfheal` run after `update-scripts.sh`. A node still on the older
   self-heal units picks it up at its next self-heal run.

An operator who wants a key gone before the release can block it locally in
`/etc/wgvpn/tnadmin.revoked` (see [step 4](#4-block-a-maintainer-key-on-your-host)).

### Rename a node

The node name is a free label: `tn_ssh` matches it against `registry.csv` only, never
against the host's hostname, and the IP band is independent of the name. So renaming is a
direct registry edit: change the name column (and the note), keep the IP, pubkey, and
`added` date, and commit:

```
node,validator-6-adiri,10.100.20.7,<pubkey>,2026-06-18,external Mobicom VPS (was telcoin-mobicom-testnet)
```

Use a plain edit, **not** `remove-peer.sh`: it's a relabel of the same key/IP, and
`remove-peer.sh` would needlessly tear down access and fan out a removal. A hub redeploy is
optional and purely cosmetic (it only refreshes the peer's comment line); `tn_ssh` picks up
the new name from the local registry immediately.

---

## Firewall: why no per-maintainer change is ever needed

Every maintainer IP is in `10.100.9.0/24`, the node's `TN_OVERLAY_ADMIN_CIDR`, and every
rule that admits maintainers matches that whole range:

- **Hub** (`hub/nftables.conf`): `ip_forward=1`; the FORWARD chain admits the entire
  maintainer band (`ip saddr 10.100.9.0/24 accept` + `ip daddr 10.100.9.0/24 accept`); INPUT
  allows overlay→:22 to the hub itself.
- **Node**: the enforced path is the operator's ufw rule
  `from 10.100.9.0/24 to any port <ssh> proto tcp` (added and verified by
  `setup-vpn.sh --apply-firewall` / `--status`, and kept by `firewall-setup.sh` on a VPN
  host) together with the sshd drop-in's `Match Address 10.100.9.0/24`. The dormant
  `tn_filter` table the bootstrap installs admits SSH from the whole overlay, but it is
  not enforced.

Because these rules cover the full maintainer `/24`, maintainer #7…#N needs only a
registry row, their `.pub` and its `KEYS` line, with **no firewall change anywhere**. A
maintainer address outside `10.100.9.0/24` would be refused by both the node's ufw rule
and its sshd drop-in.

## Names vs. bands (don't be fooled by the suffix)

`validator-6-adiri` lives in the `10.100.20.x` **external** band, not `10.100.1.x`. The
`-adiri` suffix means "validates the adiri testnet"; it does not imply the core `10.100.1.x`
band. External nodes stay in the external band regardless of what they're named.
