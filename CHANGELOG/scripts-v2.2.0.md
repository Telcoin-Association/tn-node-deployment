# scripts-v2.2.0 (November 2026)

`scripts-v2.2.0` follows `scripts-v2.1.0`. It adds `setup-gateway.sh`, which runs
telcoin-network's worker gateway: a public JSON-RPC front that sends transaction submissions to
the worker of a node and proxies every other call to a query endpoint the operator names. The
gateway runs next to a testnet or devnet node, or on a host of its own in front of a validator's
private address, so the validator stays off the public internet. Six existing scripts and
`lib/common.sh` change with it. No signed telcoin-network release with a worker-gateway image
exists yet: devnet takes one by digest, and testnet and mainnet refuse the enable until a scripts
release pins the image of a signed release.

One fix reaches every operator, gateway or not: `firewall-setup.sh` now compares the sources of
`--ssh-from` and `--p2p-from` the way `ufw` stores them. Re-entering a source in another spelling
used to delete its rule (see [firewall-setup 2.2.0](#firewall-setup-220)).

A second fix reaches every new testnet node. Setup took the chain configs (`genesis.yaml`,
`committee.yaml` and `parameters.yaml`) from the default branch of the telcoin-network repository,
whose testnet `committee.yaml` stopped matching the pinned sha256 on 2026-11-14, so fresh testnet
Docker, signed-release and existing-binary installs have failed since then, at step 4 of 8, before
any key is made. Setup and edit-config's menu 13
now read the three files from the tag this release pins, `v0.16.0-adiri`, and never from a branch
(see [lib/common 2.2.6](#libcommon-226)). Before a host takes this release, a testnet install on
`scripts-v2.1.0` works with `--genesis-dir <dir>`, where `<dir>` holds the three files of
`chain-configs/testnet` at `v0.16.0-adiri`. The same release also prepares the tag's move to a
telcoin-network release that keeps the testnet bootstrap servers in their own file,
`bootstrap_servers.yaml`, instead of in `committee.yaml`: once a later scripts release pins that
file, a new testnet node given no `--bootstrap-peers` map gets it as its map (see
[setup-node 2.1.5](#setup-node-215)). While the tag is `v0.16.0-adiri` nothing changes.

The hardware check compared every host with the mainnet figures, so it warned "below minimum" on
the machines the testnet validators run on. It now compares the host with the tiers of the
network chosen, and the testnet tiers follow those validators (see
[lib/common 2.2.6](#libcommon-226)); the Node Manager UI's setup preflight does the same for the
wizard's network. The check still only warns. The AWS one-click stack's `Validator` preset moves
to `c7i.2xlarge`, and its data volume defaults to 500 GiB at 15,000 IOPS.

The mainnet chain id is 731 (`0x2db`), as on telcoin-network main since #1716; it was 487, which
upstream devnet genesis files use now (see [lib/common 2.2.6](#libcommon-226)). Mainnet has not
launched and stays switched off, so no running node changes.

The release keys change, for every operator. grantkee's RSA key, the only key of
`scripts-v2.1.0`, is replaced by grantkee's new ed25519 key, and MavenRain's key is added. The keys now come
from the maintainers' key allowlist, the tn-release-signing repository, and `tn-p2p-allow-sync`
moves to v0.1.2, the first release signed with the new key. A host on `scripts-v2.1.0` takes this
release by re-running the installer once (see [The release keys](#the-release-keys)).

Ubuntu 26.04 LTS is the recommended OS; 24.04 stays supported. The systemd messages of
`setup-node.sh` and `lib/common.sh` say so; what they check is unchanged (mainnet still needs
systemd 255).

| Component | Version |
|---|---|
| setup-gateway | 2.2.0 (new) |
| lib/gateway (`GATEWAY_VERSION`) | 2.2.0 (new) |
| firewall-setup, remove-node | 2.2.0 |
| install-caddy, check-node | 2.2.1 |
| edit-config | 2.2.2 |
| update-scripts | 2.2.0 |
| update-node | 2.1.2 |
| setup-node | 2.1.5 |
| lib/common (`COMMON_VERSION`) | 2.2.6 |
| telcoin-ui (`UI_VERSION`) | 2.1.3 |
| Release keys (`lib/release-keys/*.asc`) | grantkee `95A38484E1CBD31D773F6AF928FD56AD2F9FAE47` (replaces `4E36D35A4AB61B589861D01AC7173F2377CA7573`), MavenRain `32F886ADE9C3A88218E4B67CA0A69159FC76DBFD` (new) |
| `tn-p2p-allow-sync` (pinned in lib/common) | v0.1.2 (was v0.1.1) |

Every other script, library and UI file keeps its version. The runbook for the gateway is
[OPERATOR.md section 4.15](../OPERATOR.md#415-worker-gateway). `aws/node.yaml` changed too (see
[AWS one-click stack](#aws-one-click-stack)); it is not an updater entry.

## The release keys

| Key file | Primary key | Expires |
|---|---|---|
| `lib/release-keys/grantkee.asc` | ed25519 `95A38484E1CBD31D773F6AF928FD56AD2F9FAE47` | 2028-11-16 |
| `lib/release-keys/MavenRain.asc` | ed25519 `32F886ADE9C3A88218E4B67CA0A69159FC76DBFD` | 2028-11-10 |

- Either key may sign script releases, node releases and `tn-p2p-allow-sync` releases, under the
  same `gpgv` status rules as before; one good signature is still enough (`TN_SIG_THRESHOLD` 1). The
  RSA-2048 key `4E36D35A4AB61B589861D01AC7173F2377CA7573` is gone from `grantkee.asc` and
  verifies nothing from this release on.
- The files are byte-for-byte copies of `keys/` in
  [tn-release-signing](https://github.com/Telcoin-Association/tn-release-signing) at the commit
  this repository records for its submodule `vendor/tn-release-signing` (`813fcf4`). They still
  ship as ordinary files in `lib/release-keys/`, listed in `MANIFEST` and embedded in
  `install.sh`: the installer downloads GitHub's archive of the release tag, which never holds a
  submodule's files. For maintainers: `tools/check-release-keys.sh` fails when the copies differ
  from the submodule's keys at the recorded commit, the "checksum freshness" CI job checks the
  submodule out and runs it, CODEOWNERS covers the pointer and `.gitmodules`, and
  `lib/release-keys/README` has the steps to move the pointer and copy the keys.
- Hosts on `scripts-v2.1.0` hold only the RSA key, and the updater verifies a release against the
  keys a host already has. The RSA key no longer signs, so `scripts-v2.2.0` carries only the new
  keys' signatures and a 2.1.0 host refuses it with `The release manifest is not signed by a
  Telcoin release key (no release key in lib/release-keys made a good signature); nothing was
  changed.` Re-run the installer once, whose embedded keys are the new ones:
  `curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes`.
  Later releases update with `update-scripts.sh` as usual.
- The Node Manager UI runs its own copy of the scripts and keys: run
  `sudo bash ui/install-ui.sh --update` after the update, as for every script release, or its
  release checks keep the RSA key.

## What changed

### setup-gateway 2.2.0 and lib/gateway 2.2.0 (new)

- The gateway takes JSON-RPC as HTTP `POST`. A transaction submission (`eth_sendRawTransaction`,
  `eth_sendRawTransactionSync`, or a batch made only of those) goes to the worker of the node it
  fronts. Every other call goes to the `--redirect-queries` URL, which the gateway proxies itself;
  the client never gets a redirect. It has no TLS, no WebSocket and no authentication of its own,
  and it limits each client IP address to 100 requests a second and 32 open connections.
- `--enable`, `--status`, `--refresh` and `--remove`, one per run, in the shape of
  `setup-alerts.sh`. With `--json` the events go to fd 3 with one done line. Exit 0 done, 1
  refused or rolled back, 2 older libraries, 3 a step failed after something changed. Unlike the
  other add-ons it runs on a host with no node.
- `--mode same-host` runs on the node's host and reaches the node on `127.0.0.1`; the node needs
  `--healthcheck`. It is refused on mainnet: `on mainnet the gateway runs on its own host (use
  --mode standalone there)`. `--mode standalone` runs on a host with no node, in front of a
  validator's private IPv4 (`--upstream`, with `--network`).
- `--front caddy` (the default) listens on `127.0.0.1:8655`, and this host's Caddy serves
  `https://<domain>/` in front of it; `--domain` must be a DNS name. `--front none` listens on
  `0.0.0.0:8655` over plain HTTP for a load balancer or private network that brings its own TLS.
  No script opens that port.
- Behind Caddy the gateway trusts only `127.0.0.1` and takes the client address from the right end
  of `X-Forwarded-For`. With `--front none` it trusts no proxy unless `--trusted-proxies
  <CIDR>[,<CIDR>]` names one; behind a load balancer every client otherwise counts as the
  balancer.
- Two more listeners, on `127.0.0.1` only: the probe listener on 8656 (`/health`, `/ready`,
  `/ready/any`) and the metrics listener on 9655. `--listen-port`, `--probe-port` and
  `--metrics-port` change the three.
- `--redirect-queries` takes `http(s)://host[:port][/path]` and is refused when it points at the
  worker's RPC or readiness port, or at one of the gateway's own ports on this host.
- `telcoin-gateway.service` runs the image under Docker: host network, uid 1101, read-only, no
  capability, never pulled by the unit. The settings live in `/etc/telcoin/gateway/gateway.meta`.
  An enable or refresh whose inputs equal what is installed changes nothing and restarts nothing.
  A failure after the first write puts the previous unit and meta back. The script never stops,
  starts or restarts the node, and never edits the node's launch file, `.node-meta` or a firewall
  rule.
- Images are taken by digest only, `<repository>@sha256:<64 lowercase hex>`; a tag is refused. On
  devnet the repository must be `ghcr.io/telcoin-association/tn-dev` (telcoin-network's unsigned
  builds), `ghcr.io/telcoin-association/tn-worker-gateway` (the release images) or
  `us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway`. On testnet and mainnet only the
  image this release pins in `lib/gateway.sh` is taken: the image a signed telcoin-network
  release names in its `IMAGE_DIGEST-worker-gateway`, in
  `ghcr.io/telcoin-association/tn-worker-gateway`, with that release's tag on the same line
  (`GW_TESTNET_PIN_RELEASE`, `GW_MAINNET_PIN_RELEASE`). This release pins none. Before it writes
  anything, the enable pulls the digest when Docker does not hold it, runs the image's `--help`
  under a time limit and refuses an image that lacks a flag the unit passes. For maintainers:
  `tools/check-gateway-pin.sh` checks each set pin against its release. The tag must be a release
  tag of that network, `SHA256SUMS-edge.asc` must verify against `lib/release-keys` under the rule
  node releases follow, `SHA256SUMS-edge` must list only that release's edge files, the worker
  gateway's among them, and the `IMAGE_DIGEST-worker-gateway` it lists must hold the pin. The
  "release manifest" CI job runs it, and `publish-installer.yml` publishes the installer only
  when it passes.
- The image rule depends on the network, so the network is checked. On a host with a node,
  `--refresh` refuses, and `--status` reports, a gateway whose recorded network differs from the
  node's. On a host with no node, `--enable` and `--refresh` ask the upstream for its chain id and
  refuse the chain of another network; an upstream that does not answer only warns, since the node
  may be down, and `--status` repeats the check.
- After a scripts release changes the pinned image, `--refresh` without `--image` moves the
  gateway to the pin and says so, naming the telcoin-network release the image comes from, and
  `--status` counts an image the release does not allow.
- `--remove` leaves a file it did not write in place and names it.

### install-caddy 2.2.1

- The mainnet gate refuses a node whose network cannot be told with `tn_detect_network`'s reason.
  For a host with no `NETWORK` in `.node-meta` and a genesis on chain 487 it reads `no NETWORK in
  .node-meta, and the chain id of <datadir>/genesis/genesis.yaml (487) is neither 731 nor 2017`;
  it said "no readable genesis chain id" although the id was read.
- When the local node cannot say whether the address is staked, the gate reads the stake from the
  mainnet public RPC only when that endpoint answers with chain 731; otherwise it refuses and says
  so. Until launch `https://rpc.telcoin.network` answers for testnet, where a mainnet address
  reads as not staked.
- `_tn_rpc_chain_is` joins the library functions it requires.
- A third managed site, `tn-gateway`, serves the gateway's public hostname in front of its
  loopback listener: `POST` is proxied, the probe paths go to the probe listener, and a WebSocket
  upgrade or any other non-`POST` request gets 405.
- New phases `gateway-status`, `gateway-check-dns`, `gateway-enable` and `gateway-disable`.
  `gateway-enable` changes nothing when the site on disk is current, starts a stopped Caddy, and
  runs on a host with a gateway and no node. A public-RPC site and a gateway site are not offered
  on one host.
- The Caddyfile is rebuilt from its managed sites on every write, so every writer now keeps the
  gateway site. The hostname clash check counts three sites, and the teardown runs only when the
  last one goes.
- `rpc-advertise` is for a node whose public endpoint is a gateway: it puts `https://<host>/` and
  no WebSocket URL into `node-info.yaml`, with one guarded node restart and no Caddy change. Other
  nodes use that signed record to forward transactions, so it refuses unless
  `https://<host>/health` answers 200 from the node host. `rpc-unadvertise` clears the URL. Both
  refuse while a public-RPC site exists, and on a host with `HOST_BASELINE=true` both make the
  baseline again, as `rpc-enable` and `rpc-disable` do.
- `rpc-disable` leaves an advertisement made by `rpc-advertise` alone, and `rpc-enable` refuses
  while a gateway site or advertisement is present.

### firewall-setup 2.2.0

- Fix for every operator. The cleanup of stale sources compared the spellings in the stored list
  with the new ones as text, while `ufw` stores `1.2.3.4/32` as `1.2.3.4` and a CIDR by its
  network address. Re-entering a source in another spelling, such as `1.2.3.4` after
  `1.2.3.4/32`, re-allowed its rule and then deleted it as stale. On the SSH list that could lock
  the operator out; it was reproduced on ufw 0.36.2, where entering `1.2.3.4` after `1.2.3.4/32`
  removed the SSH rule. Sources are now compared in the form `ufw` stores them (`fw_src_canon`)
  for `--ssh-from`, `--p2p-from` and `--gateway-from`, and for the health-port keep check.
- `--gateway-from <ipv4[,ipv4|cidr...]>`, with `--enable` or `--reset`, lets the listed hosts
  reach the node's RPC port and health port; `none` removes it. The list is stored as
  `GATEWAY_ALLOW_FROM` in `.node-meta` and applied again by every `--enable` and `--reset`, like
  the SSH and P2P source lists. The rules come after the health-port block on every network. On a
  host without `GATEWAY_ALLOW_FROM` the `ufw` calls are the same as before.
- While `GATEWAY_UPSTREAM` is set, the node's RPC and health listener are bound to every
  interface, so a run that would leave a bound gateway host without its rules is refused before
  any change: `--gateway-from none`, a list that leaves the host out, and `--reset`, which turns
  `ufw` off while it applies the rules again.
- `--json --status` gains `gateway_from`, and the status screen and the expected rules show two
  rows per gateway source.
- A Caddyfile that holds the gateway site counts as a public edge, so 80 and 443 survive a
  `--reset`.
- `--enable` works on a host with a gateway and no node: SSH, 80 and 443, no P2P and no health
  rule. Such a host keeps its SSH source list in the gateway's meta file, so a replaced list has
  its old sources removed and a plain `--enable` applies it again.

### edit-config 2.2.2

- Menu 13, "Refresh chain configs", ran `git pull` in the repository checkout and copied
  `chain-configs/<network>` from it. On a source install, whose checkout is detached at a release
  tag, the pull failed and the menu stopped. On the default-branch clone setup makes for other
  installs, the pull moved the checkout to the branch's tip, and the copy was then refused because
  that branch no longer matches the pins.
  On a network with a pinned tag the menu now installs the pinned files through
  `tn_chain_configs_from_tag` (see [lib/common 2.2.6](#libcommon-226)) and copies them from
  `/etc/telcoin/chain-configs/<network>/`; it runs no pull and no submodule command. The menu
  label reads "(pinned genesis/committee/parameters)".
- When the node's data dir already holds the pinned files (hashed as the service user), the menu
  prints `Nothing to refresh` and returns without a prompt, the update lock or a restart, with a
  pointer to `14) Restart node` for a restart that was put off.
- With no checkout and no pinned files, the menu runs the checks setup runs, then offers to clone
  the repository at the pinned tag, the clone setup makes. Declined or failed, it prints a manual
  `sudo git clone --branch <tag> ...` command and the three raw-file URLs of the tag. It no longer
  tells the operator to re-run setup-node.sh. A git worktree counts as a checkout.
- A network this release pins nothing for (mainnet today) is refused before any prompt. The update
  lock is free at every "Press Enter" prompt. The host baseline is made again whenever the helper
  wrote under the config directory, a reinstall that only corrects owners or modes included.
  Devnet still pulls; the copy, the chain-id guard and the restart path are unchanged.
- `--set gateway_upstream=<ipv4[,ipv4...]>` is for a validator whose gateway runs on another
  host. It binds the RPC and the health listener to every interface and adds none of the
  public-RPC limit flags. `off` puts both binds back; the `--healthcheck` value from before is kept
  as `GATEWAY_PREV_HEALTHCHECK`.
- It refuses unless `ufw` is active, already holds the rules that admit those hosts
  (`firewall-setup.sh --gateway-from`), denies or rejects incoming by default and has no rule that
  admits any source to either port.
- It refuses on a node whose RPC is already public, and while the node is starting, stopping or
  waiting for its automatic restart. Stopped means inactive or failed: a node that was stopped
  when the run began stays stopped, and only its files are edited. On a running node a failed
  restart is rolled back.
- Other keys behave as before.

### check-node 2.2.1

- A comment only: the chain ids it accepts name 731 for mainnet. Its messages take the id from
  the library, so they now say 731, for example `https://rpc.telcoin.network serves chain 2017
  (testnet), not chain 731 (mainnet) -- skipping the network comparison`.
- On a host with a gateway: the unit, the image, the three listeners, `/health`, the Caddy site,
  and in same-host mode the node's health listener. `/ready` is reported and is not an issue
  while the node is down. `[::]:port` counts as a wildcard listener. On a host with a gateway and
  no node, only the gateway is checked.
- On a validator that admits a gateway on another host: the `ufw` rules for each listed host, the
  RPC and health binds against `GATEWAY_UPSTREAM`, that no other source reaches either port, and
  the advertised RPC URL. It reads the RPC port the way edit-config and firewall-setup do.

### remove-node 2.2.0

- A gateway is removed before the node stops (`remove_gateway`, best effort, in the style of the
  alerts removal): its unit, its container and `/etc/telcoin/gateway`. The image stays, and the
  Caddy site is named, not removed.
- It removes a gateway only when the gateway serves a node on the same host or a node is removed
  in the same run. A gateway that runs on its own host was removed as node leftovers, which left
  its Caddy site up; now the leftover cleanup is held and the script says `A worker gateway is
  installed here and this script leaves it in place; remove it with: sudo bash setup-gateway.sh
  --remove`.
- The scan for other installs matched the gateway image's name and would have offered the
  gateway's unit and container as a stray install; it now knows them.

### update-scripts 2.2.0

- Tracks `lib/release-keys/MavenRain.asc`, and ships the ed25519 `lib/release-keys/grantkee.asc`
  (see [The release keys](#the-release-keys)).
- Tracks `setup-gateway.sh` and `lib/gateway.sh`. When an update changes either on a host with
  `/etc/systemd/system/telcoin-gateway.service`, it prints `The worker gateway script or its
  library changed. Render the gateway again on the host:` and the `setup-gateway.sh --refresh`
  command. It never runs it: the unit is rendered from `gateway.meta`, and new copies take effect
  only once `--refresh` renders it again.

### update-node 2.1.2

- Comments only, no change in behaviour: the chain-id comments name 731 for mainnet, and the
  comment on the update lock no longer names a `git pull`, since none runs in update-node.

### setup-node 2.1.5

- A node given no bootstrap peers map gets the network's pinned bootstrap servers. From
  telcoin-network #1848 on, a tag keeps the testnet bootstrap servers in
  `chain-configs/testnet/bootstrap_servers.yaml` and its `committee.yaml` has
  `bootstrap_servers: {}`; the node reads that file only when started with `--chain`, and these
  scripts start it without, so a node set up from such a tag would dial no one. When
  `lib/common.sh` pins the file (`TESTNET_BOOTSTRAP_SERVERS_SHA256`, empty in this release),
  setup checks the copy beside the chain configs it copies (`/etc/telcoin/chain-configs/testnet/`
  or `--genesis-dir`) against the pin, and installs it as `/etc/telcoin/bootstrap-peers.yaml`
  through the `--bootstrap-peers` path: the release's parser checks it, `.node-meta` records it
  as `BOOTSTRAP_PEERS_FILE`, and the start script passes `--bootstrap-peers "$(cat
  /etc/telcoin/bootstrap-peers.yaml)"`. Setup says `Bootstrap peers: the testnet bootstrap
  servers at <tag> (no --bootstrap-peers given)`. A missing or changed file, one other users
  cannot read or one the release rejects stops setup before the chain configs are copied.
  `--bootstrap-peers`, or a map the host recorded, wins: with a pin, an interactive re-run reads
  the recorded map back with or without an admission mode. With an admission mode the default
  map becomes `committee_peers`, as an operator's map does. Mainnet gets no default.
- With the pin empty, as in this release, nothing changes: no default, no new message, and an
  interactive re-run reads a recorded map back only with an admission mode, as before.
- On a network with a pinned chain-config tag, setup searches
  `/etc/telcoin/chain-configs/<network>/` right after `--genesis-dir`, ahead of the repository
  checkout, whose default branch can carry files that no longer match the pins. Each directory is
  searched once.
- A refusal ends with `The <network> chain configs were refused (see above); nothing was copied.`
  and a failed clone, fetch or install with `Could not get the <network> chain configs (see
  above).`. The library's warning above that line names the cause.
- When the files are not found, the hint names the tag, where the three files are at that tag,
  the directory to copy them into and `--genesis-dir`.
- The hardware check runs once the network is chosen, after the internet check, and compares the
  host with that network's tiers. It ran before the choice, with the mainnet tiers on every
  network. It still only warns, and a `--json` run logs its result as before.
- `--help` names Ubuntu 26.04 as the recommended OS for mainnet (systemd 255 or later, so
  Ubuntu 24.04 or later).

### lib/common 2.2.6

- `TESTNET_BOOTSTRAP_SERVERS_SHA256` sits beside the chain-config pins and is empty while
  `TESTNET_CHAIN_CONFIGS_TAG` (`v0.16.0-adiri`) keeps the bootstrap servers in `committee.yaml`.
  It says what the tag carries: with a pin, `tn_chain_configs_from_tag` reads, checks and
  installs `chain-configs/testnet/bootstrap_servers.yaml` with the three other files and refuses
  a tag without it or a changed one; without a pin, it refuses a tag that carries the file
  (`<tag> carries chain-configs/testnet/bootstrap_servers.yaml, but these scripts pin no sha256
  for it; nothing was installed.`). To list the tag for that check, each fetch runs one more
  read-only `git ls-tree`. Mainnet has no such pin and its file, a placeholder set until the
  genesis ceremony, is never read. New helpers: `tn_bootstrap_servers_pin`,
  `tn_bootstrap_servers_check`.
- Fix for every new testnet install: the chain configs come from the telcoin-network tag this
  release pins (`TESTNET_CHAIN_CONFIGS_TAG`, `v0.16.0-adiri`), never from a branch.
  `ensure_chain_configs_available` cloned the default branch, or pulled an existing checkout, and
  since 2026-11-14 that branch's testnet `committee.yaml` no longer matches the pinned sha256.
- `tn_chain_configs_from_tag` fetches the tag from origin into `refs/tn-remote-tags/<tag>`, reads
  `genesis.yaml`, `committee.yaml` and `parameters.yaml` there, checks them against the pins in a
  staging directory and installs them in `/etc/telcoin/chain-configs/<network>/`, directories
  root 0755 and files root 0644. HEAD, the index, the working tree and the submodules of the
  checkout are never touched. When that directory already holds the pinned files with those
  owners and modes, no git runs. When the fetch fails, the files are read from the local copy of
  the tag, and the warning carries git's reason.
- It refuses a checkout that is a symlink, belongs to another account or cannot be read by git; a
  destination that is a symlink; an entry in the way under one of the three names, before anything
  is fetched or written; and files at the tag that do not match the pins, which leaves the
  destination untouched. The right files with other owners or modes are installed again from
  where they are, with no git. A git worktree checkout is read.
- `ensure_chain_configs_available` uses `--genesis-dir` as given, with no git and no prompt. On
  testnet it goes through `tn_chain_configs_from_tag`. With no checkout it refuses a source path
  that exists and is not a checkout, then asks the consent question as before and clones at the
  tag, over https and without submodules. A failed clone returns 2 instead of exiting, and its
  message and the manual clone command reach a `--json` run. Devnet still pulls or clones the
  default branch. Mainnet has no tag yet and runs no git; it refuses while its pins are empty.
- The chain-config helpers run git over https only, with the update lock's descriptor closed and
  without a caller's `GIT_DIR`, and the read-only commands cannot fetch lazily. Staging uses the
  release staging directory, which the existing sweep cleans.
- `check_hardware` takes the network as a third argument. Testnet and devnet use the testnet tiers
  (`HW_TESTNET_*`), which follow the deployed testnet validators. Mainnet, an empty value and an
  unknown one use the mainnet tiers (`HW_MAINNET_*`, the figures every network used before), so a
  caller that passes two arguments gets the verdicts it got before. It still only warns and
  returns 0. The tiers it checks:

  | Role | Testnet (and devnet) | Mainnet |
  |---|---|---|
  | Full node (follower) | 2 cores (4 vCPU), 8 GB RAM, 350 GB | 2 cores (4 vCPU), 8 GB RAM, 2 TB |
  | Public RPC node | 4 cores (8 vCPU), 16 GB RAM, 350 GB | 4 cores (8 vCPU), 16 GB RAM, 2 TB |
  | Validator (minimum) | 3 cores (6 vCPU), 16 GB RAM, 350 GB | 8 cores (16 vCPU), 32 GB RAM, 2 TB |
  | Validator (recommended, printed only) | 4 cores (8 vCPU), 16 GB RAM, 500 GB NVMe | 16 cores (32 vCPU), 64 GB ECC RAM, 4 TB NVMe |

- The report writes CPU as physical cores with the vCPU count in parentheses, says which tiers it
  compares with (`Comparing with the testnet hardware tiers.`), names in a below-minimum line only
  the dimensions that fall short, and ends with `Prioritise single-core performance: EVM execution
  is single-threaded, so a high clock speed matters more than extra cores.` When physical cores
  cannot be counted it compares logical CPUs and says so. ECC, NVMe, IOPS and throughput are not
  checked.
- `MAINNET_CHAIN_ID` is 731 (`0x2db`), as on telcoin-network main since #1716 (2026-11-12); it
  was 487, which upstream devnet genesis files use now. Every use of the constant is an equality
  test or message text. A genesis on chain 487 with no `NETWORK` in `.node-meta` is no longer
  detected as mainnet (`tn_detect_network`).
- The systemd floor messages recommend Ubuntu 26.04 and say "Ubuntu 24.04 or later" for
  mainnet. The floors themselves are unchanged.
- Pins `tn-p2p-allow-sync` v0.1.2 (`TN_P2P_ALLOW_VERSION`, `TN_P2P_ALLOW_TARBALL_SHA256`
  `1177ee11c48a5ff27a2de78fed8de8168360e4810ed23956cd169aa5cc0765d8`). Its code is v0.1.1's, with
  `config-version 1` and `snapshot-versions 1` as before. v0.1.1 is signed only by the retired
  RSA key, so the new keys cannot verify it, and the pin moves with them; v0.1.2 is signed by
  grantkee's ed25519 key. A validator in P2P committee mode keeps running the v0.1.1 binary it
  installed (the timer runs the installed binary) until the next
  `firewall-setup.sh --p2p-committee sync` or `on`, or a resync after a settings change, installs
  the pinned release.
- The gateway's paths, unit and container names, default ports and Caddyfile fence
  (`TN_GATEWAY_*`).
- The readers the other scripts use: the gateway's meta file (`tn_gateway_meta_path`,
  `tn_gateway_meta_get`), the `GATEWAY_ALLOW_FROM` list (`tn_gateway_from_list`), whether `ufw`
  holds both rules for each listed host (`tn_gateway_from_rules_ok`) and whether nobody else
  reaches the two ports (`tn_gateway_ports_private`).
- Sources `lib/gateway.sh` at its end when the file is present, as it does `lib/alerts.sh`.

### Node Manager UI 2.1.3

- The setup wizard's preflight compared the host with the mainnet tiers on every network. The page
  now sends the wizard's network, and the server answers with that network's tiers (`HW_TIERS`,
  which `ui/test_hw_mirror.py` ties to the library's `HW_TESTNET_*` and `HW_MAINNET_*`). Devnet,
  an unknown and a missing network read as testnet.
- The disk floor is decimal GB with the shell's 5 % slack, so a 350 GB disk gets the same verdict
  in the UI as in setup. Cores are compared exactly; RAM keeps its 5 % slack. A measured zero
  (MemTotal 0, a filesystem of 0 kB) counts as not measured, as in the shell.
- The reply's `hardware` object gains `network` and `cpu_kind` (`physical` or `logical`, which
  count `cpu` is), and `validator_recommended` gains `ecc`.
- The rows read like the documentation: cores with the vCPU count in parentheses, "350 GB" and
  "2 TB" disk labels, the detected disk in decimal GB, the tiers compared and the single-core
  note. When only logical CPUs could be counted, the detected line reads `Detected 8 logical CPUs
  / ...` and the shell's sentence about the comparison follows. A missing RAM figure shows `?`.
- The network tables (`NETWORKS`, `NETWORK_PUBLIC_RPC`) key mainnet by 731. Chain 487 is not
  listed, so a node on it is named through `.node-meta`, like a node on any unknown chain.

### AWS one-click stack

`aws/node.yaml` carries no version.

- The presets follow the recommended column of the testnet table for cores and RAM. `FullNode`
  (the default) and `Validator` are `c7i.2xlarge`, 4 cores (8 vCPU), 16 GiB; `PublicRPC` is
  `c7i.4xlarge`, 8 cores (16 vCPU), 32 GiB. `Validator` was `c7i.8xlarge`.
- `DataVolumeSize` defaults to 500 GiB and allows 350, the testnet minimum; 2000 and 4000 stay
  allowed for stacks launched with them, since a volume cannot shrink. The default was 2000. The
  gp3 data volume is provisioned at 15,000 IOPS and 300 MiB/s; it was 10,000 IOPS. It is an EBS
  network volume, not a local NVMe drive.
- The `DataVolumeSize` description in the console says what each preset sustains: a `c7i.2xlarge`
  (`FullNode`, `Validator`) 12,000 IOPS to EBS and 15,000 in bursts, a `c7i.4xlarge`
  (`PublicRPC`) the full 15,000.
- Existing stacks keep running as they are, and nothing in this release needs a change on them. Do
  not update a stack to this template: once Canonical's image has moved, the update fails and its
  rollback waits, possibly for hours, until the volume's IOPS change completes; if the image has
  not moved, a `Validator` stack's update stops and starts the instance outside the epoch-boundary
  wait. Raise the volume's IOPS or change the instance type in the EC2 console instead, as
  [OPERATOR.md section 2.11](../OPERATOR.md#211-aws-one-click) ("Changing the stack later")
  describes.

## New files, units and keys

| Path or key | What it is |
|---|---|
| `setup-gateway.sh`, `lib/gateway.sh` | The worker gateway's script and library |
| `lib/release-keys/MavenRain.asc` | MavenRain's release key (`32F886ADE9C3A88218E4B67CA0A69159FC76DBFD`) |
| `lib/release-keys/grantkee.asc` | Now grantkee's ed25519 key (`95A38484E1CBD31D773F6AF928FD56AD2F9FAE47`); the RSA key is gone |
| `/etc/systemd/system/telcoin-gateway.service` | The gateway's unit |
| `/etc/telcoin/gateway/gateway.meta` | The gateway's settings (`GATEWAY_META_VERSION=1`) |
| Caddy site `tn-gateway` | The third managed site, beside `tn-dashboard` and `tn-rpc` |
| `.node-meta` `GATEWAY_ALLOW_FROM` | The gateway hosts the firewall admits to the node's RPC and health ports |
| `.node-meta` `GATEWAY_UPSTREAM` | The gateway hosts the node's RPC and health listener are bound for |
| `.node-meta` `GATEWAY_PREV_HEALTHCHECK` | The `--healthcheck` value from before `gateway_upstream`, put back by `off` |
| `firewall-setup.sh --json --status` `gateway_from` | The stored gateway source list |
| `/etc/telcoin/chain-configs/<network>/` | The three chain configs at the pinned tag, root-owned, directories 0755 and files 0644; removed with the node |
| `refs/tn-remote-tags/<tag>` in `/opt/telcoin-source` | The pinned tag as fetched from origin, which the chain configs are read from; a local `refs/tags/<tag>` is never moved |

## Refusals and warnings you may now see

| Message (shortened) | What to do |
|---|---|
| `The release manifest is not signed by a Telcoin release key (no release key in lib/release-keys made a good signature)`, on a host on `scripts-v2.1.0` | Re-run the installer once (see [The release keys](#the-release-keys)). |
| `this scripts release pins no worker-gateway image for <network> yet (...)` | Testnet and mainnet wait for a scripts release that pins the image of a signed telcoin-network release; `update-scripts.sh` brings it. |
| `this scripts release's <network> worker-gateway pin cannot be used: ...` | A defect of the scripts release; a corrected one comes through `update-scripts.sh`. |
| `on mainnet the gateway runs on its own host (use --mode standalone there)` | Run the gateway on a host of its own. |
| `--reset is refused while GATEWAY_UPSTREAM is set` | Set `gateway_upstream=off` first; OPERATOR.md section 4.15 has the order. |
| `GATEWAY_UPSTREAM in .node-meta names <host>: ...` | Keep the host in `--gateway-from`, or set `gateway_upstream=off` first. |
| `<missing rules>, so the gateways cannot reach the RPC and health check; open them first: ...` | Run the `firewall-setup.sh --enable --gateway-from` command it prints. |
| `the node's RPC already listens on every interface` | The RPC is public; a gateway upstream is for a node whose RPC is private. |
| `rpc-advertise was asked to advertise https://<domain>/, and GET https://<domain>/health from this host got <code> instead of 200` | Make the gateway answer at that name first. |
| `A worker gateway is installed here and this script leaves it in place` | Remove it with `setup-gateway.sh --remove`. |
| `Could not fetch <tag> from origin (<git's reason>); reading the <network> chain configs from the local copy of <tag>.` | A warning only: the files come from an earlier fetch or the checkout's own tag and are still checked against the pins. |
| `<dir> must be a directory owned by root (not a symlink); nothing was fetched.` | The checkout `/opt/telcoin-source` is a symlink or belongs to another account. Make it a real directory owned by root. |
| `<dir> exists but is not a git checkout; move it aside first.` | Something without a `.git` sits where setup or menu 13 would clone. Move it aside and run again. |
| `<dir>/<file> is a symlink or not a regular file; nothing was installed. Remove it and run again.` | An entry is in the way in `/etc/telcoin/chain-configs/<network>/`. Remove it. |
| `<dir> must be a directory, not a symlink or a file; nothing was installed. Remove it and run again.` | `/etc/telcoin/chain-configs` or its `<network>` directory is a symlink or a file. Remove it. |
| `Reinstalled the <network> chain configs in <dir> root-owned, directories 0755 and files 0644: their owner or modes were not the ones the install sets.` | Nothing: the right files were installed again with the owner and modes the install sets. |
| `The <network> chain configs were refused (see above); nothing was copied.` (setup) | The warning above names the cause. |
| `Could not get the <network> chain configs (see above).` (setup) | The clone, the fetch or the install failed; the warning above says why. Without network access, pass `--genesis-dir` with the three files of the tag. |
| `Nothing to refresh: the node's data dir already holds the <network> chain configs this script release pins (<tag>), ...` (menu 13) | Nothing; use `14) Restart node` if the node was not restarted after those files were copied. |
| `Clone the repository at <tag> into <dir> now?` (menu 13) | No checkout and no pinned files. Answer yes, or follow the manual clone command and the raw-file URLs it prints. |
| `This script release pins no <network> chain configs yet, so there is nothing to install. Chain configs unchanged.` (menu 13) | Mainnet today: its chain configs come with a signed scripts release. |

## Left open

- telcoin-network main still lists the RSA key (`.github/maintainer-gpg-keys/grantkee.asc`). From
  this release on the scripts accept a node release only when a tn-release-signing key signed it,
  so the first telcoin-network release must be signed with one.
- tn-release-signing refuses a `SHA256SUMS.asc` that carries any signature not good by one of its
  keys, and counts signatures per holder; these scripts only warn on a signature by a key they do
  not ship, and count distinct primary keys. The two policies are not reconciled yet.
- No signed telcoin-network release with a worker-gateway image exists yet. Testnet and mainnet
  refuse the gateway until a scripts release pins the image of a signed release in
  `lib/gateway.sh` and `tools/check-gateway-pin.sh` passes on it; devnet takes one by digest from
  the three repositories above.
- The per-client limit (100 requests a second, 32 connections) is keyed on the client IP address,
  so a relay that forwards many users' transactions counts as one client.
