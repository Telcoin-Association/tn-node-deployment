# scripts-v2.3.0 (not released yet)

<!-- release: remove this paragraph when the release is cut, and give the title its month -->
`scripts-v2.3.0` will follow `scripts-v2.2.0`. It is not cut yet. This note collects what has
merged into `main` since `scripts-v2.2.0`; `update-scripts.sh` and the installer keep installing
`scripts-v2.2.0` until the release is tagged. Its serial and dates are set then, and its number
may still change.

So far it holds five fixes for what could cut a mainnet validator off, or stop it, on genesis day,
a way to generate mainnet keys before the mainnet genesis exists, an RPC URL for a mainnet
validator's worker gateway from those keys on, a worker gateway that can run for mainnet before
genesis with checks of its public side, and a Terraform deployment of a validator and its gateway.
Mainnet starts with ten staked validators on a closed subnet that the rest of the network reaches
through trusted observer hubs, and a validator that cannot be reached at genesis cannot be fixed in
time.

1. The kill switch opens the P2P ports. `firewall-setup.sh --p2p-committee off` on a host with a
   static source list put the per-source rules back and cut off every committee peer outside
   that list (see [firewall-setup 2.2.1](#firewall-setup-221)).
2. The allowlist's floor keeps the trusted hubs, and a resync never takes an address out of the
   floor on its own (see [firewall-setup 2.2.1](#firewall-setup-221)).
3. `committee_peers` is written only from a bootstrap peers map the node will start with (see
   [setup-node 2.1.7](#setup-node-217) and [edit-config 2.2.4](#edit-config-224)).
4. Setup and edit-config share one shape check for the trusted hubs, which takes IP addresses
   only, and hand the map to the node's own parser before anything is written (see
   [setup-node 2.1.7](#setup-node-217)).
5. Mainnet validators can generate their keys before genesis, with a binary they supply (see
   [setup-node 2.1.7](#setup-node-217); OPERATOR.md section 2.12).
6. A mainnet node given no RPC URL advertises its default name,
   `https://v<label>.telcoin.network/`, for its worker gateway from key generation on, and on
   mainnet the node-side public RPC site and a worker gateway no longer front one node together
   (see [setup-node 2.1.7](#setup-node-217) and [install-caddy 2.2.2](#install-caddy-222);
   OPERATOR.md sections 2.12 and 4.15).
7. A mainnet worker gateway can be set up, and its name and certificate checked, before genesis:
   the testnet release's gateway image stands in as the mainnet pin while mainnet is not enabled,
   and check-node checks a gateway host's DNS, certificate and firewall (see
   [setup-gateway 2.3.0 and lib/gateway 2.3.0](#setup-gateway-230-and-libgateway-230) and
   [check-node 2.2.2](#check-node-222); OPERATOR.md section 4.15).
8. A Terraform deployment for AWS, Google Cloud and Azure builds a validator host and its
   worker-gateway host; it is not shipped to hosts, and its hosts need this release from the
   installer (see [Terraform deployment](#terraform-deployment); OPERATOR.md section 2.13).

Nothing here enables mainnet: `TN_MAINNET_ENABLED` stays 0, and finalize, the interactive install
and the Node Manager UI stay refused on mainnet. The mainnet gateway pin is a placeholder that the
release enabling mainnet must replace with a mainnet release.

| Component | Version |
|---|---|
| firewall-setup | 2.2.1 |
| setup-node | 2.1.7 |
| edit-config | 2.2.4 |
| check-node | 2.2.2 |
| install-caddy | 2.2.2 |
| setup-gateway | 2.3.0 |
| migrate-node-naming | 2.0.1 |
| lib/common (`COMMON_VERSION`) | 2.2.8 |
| lib/gateway (`GATEWAY_VERSION`) | 2.3.0 |

Every other script, library and UI file keeps its version. setup-node 2.1.7 and edit-config 2.2.4
need lib/common 2.2.8, which the release installs with them.

## What changed

### firewall-setup 2.2.1

- Fix for validators in P2P committee mode with a static source list.
  `--p2p-committee off`, the kill switch, turned `P2P_ALLOW_FROM` back into per-source `ufw` rules and deleted the open rule, so every committee peer outside that list lost the P2P ports (seen on ufw and nftables: 3 of 3 datagrams before `off`, 0 of 3 after).
  `off` now opens the P2P ports to every source behind the new-flow limit, whatever the list holds and whether or not the ports took only that list before committee mode.
  The list stays in `.node-meta` for the next `on`, and the new key `P2P_PER_SOURCE=off` keeps later `--enable` and `--reset` runs from applying it to `ufw` until `--enable --p2p-from <list>` (or `--p2p-anywhere`) removes the key.
  The undo of an unfinished `on` still puts the rules from before it back.
  `off` also runs when `P2P_ALLOW_FROM` is not usable (an invalid entry, or the key set twice), and warns instead of refusing.
  It adds the open rule of every P2P port before it deletes any per-source rule, carries on past a failed `ufw` call and names what is left, and it deletes the table even when another process holds the tool's lock.
  An `off` that did not finish is no longer undone by the next `--enable`, `--reset`, `sync` or `on`, which reinstalled the allowlist without a word: they and `--p2p-committee status` now say that it did not finish, and a rerun of `off` finishes it.
- Fix for validators in P2P committee mode with trusted hubs.
  The allowlist's floor, the addresses it never drops, came from one file: `/etc/telcoin/bootstrap-peers.yaml`, or the genesis `committee.yaml` when there was no peers map.
  `trusted-nodes.yaml` was never part of it, so a hub the node stopped listing left the allowlist on the second sync without it, and a peers map that held only part of the committee replaced `committee.yaml` as the floor.
  The floor is now the union of all three files, each one that exists.
  A floor with no address (a validator with neither map and a `committee.yaml` without addresses) is written with a warning that names the two `edit-config.sh --set` commands that fill it; `on` still goes ahead.
  A resync never takes an address out of the floor on its own: when the files no longer hold an address the floor has (a hub taken out of the trusted nodes map, or a `committee.yaml` gone missing because the data dir's disk is not mounted), it keeps the floor it had, names the addresses and `firewall-setup.sh --p2p-committee sync --accept-floor-shrink`, which drops them on purpose, and finishes the resync with the old floor (`sync` exits 4), so a source list given with `--enable --p2p-from` meanwhile still reaches the table at once.
  The hooks of `setup-node.sh`, `edit-config.sh` and `migrate-node-naming.sh` name that command after such a resync, and the rerun of `--p2p-committee off` after one refused because an `off` did not finish (`sync` exits 5 then); `check-node.sh` reports that unfinished `off` and its command too, instead of `sync`.
  With neither `bootstrap-peers.yaml` nor the genesis `committee.yaml` the capture refuses, as it did before: `trusted-nodes.yaml` never stands in for the committee.
  A symbolic link, directory or FIFO at one of the three refuses the capture too, now with a message that names what is there and the repair (`13) Refresh chain configs` for `committee.yaml`, `edit-config.sh --set` for a map).

### setup-node 2.1.7

- With P2P committee mode on, every re-run that completes runs `firewall-setup.sh --p2p-committee sync` once the node is started and the update lock released, whether or not it changed the bootstrap peers or trusted nodes map (a run that installed one and then failed is caught up by the next); a failed sync is a warning naming that command.
- Fix for validators set up with an admission mode and a bootstrap peers map that does not list the whole genesis committee.
  Setup wrote that map into `network-config` as `committee_peers` without a word, and a node whose `committee_peers` misses a genesis validator exits within a second of every start while its chain is at epoch 0 (`Error: committee_peers: missing validator <key>`, in every admission mode): the first six hours on mainnet, and any time on a new data dir.
  A map of the hubs alone, or of the other validators without this node, did exactly that.
  Setup now checks the map against the validators of the data dir's genesis `committee.yaml` first and writes `committee_peers` only when every one of them, this node included, is a key of the map; keys beside them, such as hubs, are fine, and a complete map is written as before, byte for byte.
  A map that lists fewer is left out of `committee_peers` with a warning naming how many validators are missing and the first three, and setup goes on: the map stays installed, on the start line (the node still dials it) and in the P2P committee allowlist's floor.
  Only the map's first-level keys count, as the node reads them: a validator's block indented under another entry is a field of that entry to the node, which then exits the same way.
  When the map has an entry for this node, that entry must carry the network keys of the node's `node-info.yaml`, because a node whose own entry names others exits at every start, at any epoch (`network key does not match node configuration`), as after keys made again once the map was shared; such a map is left out the same way, with a warning that names the entry.
  A map that lists one key twice at its first level (a validator's block pasted twice) passed both the node's parse check and this check and was written into `committee_peers`, where the node cannot read it and exits at every start (`Error running node: bad yaml data`), although it takes the same map on its start line; such a map is now left out the same way, with a warning that names the key.
- Fix for validators given trusted hubs with `--trusted-nodes`.
  Setup checked only that the file existed, was readable and was small enough, so a hub entry pasted whole from `node-info.yaml` (workers as a list, beside `name` and the other fields), one without a `network_key` and one whose address was a DNS name were installed and written into `network-config` with exit 0.
  The node then exited at start on the first two (`Error: bad yaml data`), and with a `/dns4/...` hub it started but never dialed it, saying so only at debug log level, while the P2P committee allowlist took no address from it.
  Setup now runs edit-config's shape check on the map in its preflight, before key generation or any install step, on a map it reads back from `.node-meta` on a re-run, and again just before the install, and stops with `--trusted-nodes: <reason>.` naming the line and the entry; nothing is written and the node is not started.
  The check holds the worker ids to those of the node's workers (`0` alone for one), and just before the install the release's own parser reads the map, so a bad BLS key, `network_key`, IP literal or peer id, a field given twice or a stray deeper line stops setup with the node's reason before `network-config` is written or a running node restarted.
  The check also refuses an address that is not an IP address with UDP and QUIC v1 (a DNS name, TCP, a value that is no multiaddr): `the network_address of <key>... is a DNS name (...): the node does not resolve names, so it would never dial it. Give the IP address instead; ...`.
  A `--bootstrap-peers` map is held to the same address rule before the release's parser, which accepts such an address.
- Mainnet validators can generate their keys before the mainnet genesis exists (OPERATOR.md section 2.12).
  `--json --phase=keygen --network mainnet` stopped at `Mainnet is not enabled in this script release ...` for every install method, and with only that switch on it still stopped before key generation, at the empty chain-config pins, after it had created the service user, the directories and `.node-meta`.
  It now runs with `--install-method existing --binary-path <binary>`: a binary whose `--version` lists any build feature is refused before anything on the host changes, the chain configs are skipped, the keytool signs the proof of possession for `--address`, the passphrase is stored as an encrypted credential, and the run says to send `node-info.yaml` and never `node-keys/` or the passphrase.
  `release`, `docker` and `source` are refused with a message that names this way.
  Finalize, the interactive install and the Node Manager UI stay refused on mainnet with the message of before.
- An existing binary on mainnet is held to the build-feature rule of mainnet releases and images (none), so a testnet or test build is refused.
  The mainnet keygen ran the `--binary-path` file as root for its `--version` before it checked that the file is root-owned, and with no time limit.
  It now runs it only once it is a root-owned file, not group- or other-writable, in root-owned directories (else `refusing <path>: the node binary must be a root-owned file, ...`, as on testnet), after every other input passed, and gives it 30 seconds (`... its --version did not finish within 30 seconds, ...`).
- Keygen records `NETWORK` in `.node-meta` before it makes the keys, on every network; before, only finalize recorded it, so mainnet keys were finalized as a testnet node without a word.
  On a host recorded for mainnet, a finalize, a keygen or an interactive install for any other network (a `--json` run without `--network` is a testnet run) is refused: `This host is recorded for mainnet (NETWORK=mainnet in <.node-meta>, written before keygen makes mainnet keys), and a mainnet BLS key must never be used on another network, ...`.
  A `--json` finalize or keygen stops right after the root check, before anything on the host changes; an interactive install stops once the network is chosen, before it writes the node's keys, configuration or service.
  A `--json` keygen over an existing `node-keys/` used to rewrite `NETWORK`, `INSTALL_METHOD` and `DATA_DIR` in `.node-meta` before it refused, and then said the keys and `node-info.yaml` were all in place to use without comparing them with the run: an operator correcting a mistyped address was told to send a proof of possession for the old one, and a host with testnet keys was relabelled mainnet.
  It now refuses right after the root check, before anything is written, and compares: keys recorded for another network are not the run's, a `node-info.yaml` for another execution address names both addresses and the way to start over, a `node-info.yaml` with no execution address that can be read (empty, cut short or damaged, or a symbolic link) is not a file to send and gets the same start-over on every network, and only the same address and network get the message of before.
  A host keyed by an older release, with no `NETWORK` before finalize, and every testnet or devnet record keep the behaviour of before.
- A SIGHUP, SIGINT or SIGTERM that reached setup during the keytool call left the keys and a valid `node-info.yaml` with no stored passphrase, which a second keygen (`node-keys already exist ...`) and finalize (`No stored BLS passphrase recorded ...`) both refused without saying the way out.
  New keys now get their stored passphrase before the keytool runs, the three signals are held until the keys are checked, and a keytool that fails or is stopped, or leaves no `node-info.yaml`, has what it wrote and the stored passphrase removed.
  A keygen reports success, and names the file to send, only with the key, `node-info.yaml` and the stored passphrase all in place.
  A second keygen over `node-keys/`, and a finalize without a stored passphrase over keys, say what they found and what to do (OPERATOR.md section 2.12).
- The mainnet keygen also printed the onboarding steps of a testnet validator (governance approval, a ConsensusNFT, the stake it read from the mainnet RPC, `cast send`, `prepare-stake.sh`, re-registering with the Association), none of which applies to a genesis validator.
  It now shows `node-info.yaml` and then only what a genesis validator does next: send `node-info.yaml`, never the keys or the passphrase, and finalize once the mainnet release and genesis are out; it reads no stake.
- A `--json` keygen refuses the zero address before the root check (`--address is the zero address: ...`): the proof of possession is signed over the execution address, which receives the rewards.
- A mainnet node whose keygen is given no RPC URL advertises its default name (OPERATOR.md section 2.12).
  Other nodes forward the transactions they receive to the RPC URL a committee member advertises, and the mainnet keygen left worker 0 with none, so a genesis validator got no forwarded transactions until its operator ran `rpc-advertise`.
  Once the keys exist, keygen runs the keytool's `set-rpc --http https://v<label>.telcoin.network/`, `<label>` being the first five characters of the `bls_public_key` in `node-info.yaml`, lowercased; it passes no WebSocket URL and no passphrase, and keeps the keytool's output off the `--json` stream.
  It reads worker 0 back and records the name as the worker gateway's in `.node-meta`: `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` without the trailing slash and `RPC_ADVERTISED_VIA=gateway`, with no `PUBLIC_WS_URL`.
  The run prints the URL, the handoff that makes it answer (send the name and the static public IP of the worker gateway host to the Telcoin Association (TAO), which creates the A record, then run the gateway with `--domain <name>`) and the encouraged route to a name of one's own, the same on every mainnet node (`rpc-advertise --rpc-domain <name>`, or before key generation `--admission closed --rpc-domain <name>`), as `log` events in `--json` mode, and its `done` event gains `"advertised_rpc":{"http":"https://v<label>.telcoin.network/","via":"gateway","default":true}` before `msg`.
  A BLS key it cannot read, a `set-rpc` that fails (as on a keytool without it), a worker 0 that reads back no https URL, or a WebSocket URL beside it, and a `.node-meta` that cannot be written are warnings naming `install-caddy.sh --phase=rpc-advertise --rpc-domain <name>`: keygen still reports `ok:true`, records no owner, and removes an `RPC_ADVERTISED_VIA` that earlier keys left in `.node-meta`.
  A signal already held when the keys are checked stops setup before `set-rpc` runs.
  Testnet and devnet keygens run no `set-rpc`, and their `done` events are unchanged.
- On a mainnet node that runs admission closed, which is how these scripts tell a validator, `--rpc-domain <d>` and `--rpc-http <url>` name its worker gateway; `setup-node.sh --help` describes both meanings.
  A run that is not given `--admission`, such as a `--json --phase=finalize` or an interactive re-run over an installed node, takes the mode `.node-meta` records, and an interactive run also the recorded network until its network menu sets one, so a validator gets the gateway's texts and the `http://` refusal from the first line; a flag given on the command line wins.
  A `--rpc-http` URL there must be `https://`: an `http://` URL is refused before anything on the host changes (`--rpc-http <url> is refused: a mainnet validator's RPC URL (admission closed) is its worker gateway's, and must be https://. Pass --rpc-http https://<name>/ or --rpc-domain <name>.`).
  The URL is recorded as the keytool stores it, with the scheme and host lowercased, no default port and `/` as the path when it has none, so `--rpc-http https://GW.Example.org:443` and `--rpc-domain GW.Example.org` both record `https://gw.example.org/`.
  When the keytool stores the URL in yet another form (a port written with a leading zero, an IPv6 address not in canonical form, dot segments in a path), the URL worker 0 reads back is recorded, and one line says so: `The keytool stored <given> as <stored>, so that is the URL recorded for your worker gateway.`
  Keygen advertises `https://<d>/` (or the URL) and no WebSocket URL, records it with `RPC_ADVERTISED_VIA=gateway` (`PUBLIC_RPC_DOMAIN` only when the URL is exactly `https://<host>/` with a DNS name, so not for an IP address, a port other than 443 or a path), sets no default, and says to create the name's A record for the gateway host's static public IP (for an IP address, to run the gateway on that host); `done` carries `"default":false`.
  An `--rpc-http` that differs from the `--rpc-domain` URL once both are normalised is advertised as given, with a warning, and `--rpc-public` with no domain says how to name the gateway instead of how to enable a site.
  A `--rpc-ws` given is dropped with a warning (`--rpc-ws <url> is dropped: on a mainnet validator (admission closed) ...`), and when the keytool has no `--rpc-http`, `set-rpc` writes the URL `--rpc-domain` gives once the keys exist, never the default over it.
  On mainnet with another admission mode, or none, `--rpc-domain` or `--rpc-http` sets the node up as one that is not a validator, as before: the name is advertised with a WebSocket URL for a public RPC site on this host, and `rpc-enable` runs at finalize. Key generation then prints a note that a validator must pass `--admission closed`.
- Fix for nodes that advertise a worker gateway (`RPC_ADVERTISED_VIA=gateway`), on every network.
  Writing the service set `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` and `PUBLIC_WS_URL` from the run's own flags, so a `--json` finalize, a new process with none of them, wiped the gateway's record, and so did an interactive re-run.
  Setup now leaves the three keys as they are while the record is the gateway's.
  With `--rpc-domain <d>` over such a record, or on a mainnet validator, setup enables no public RPC site: it says that `https://<d>/` is advertised for the gateway, or warns that the record is kept and names the way to `<d>` (on a validator, and on testnet and devnet, `rpc-advertise --rpc-domain <d>`; on a mainnet node that is not a validator `rpc-unadvertise`, then `rpc-enable --rpc-domain <d>`), and the closing summary shows the gateway's URL in place of the https and wss endpoints, with those two commands for a mainnet node that is not a validator.
- On mainnet the interactive RPC prompt says that Enter accepts the default name, shown after key generation; on a mainnet validator it asks for the worker gateway's name, with no inbound IP question.

### edit-config 2.2.4

- With P2P committee mode on, an edit that changed the trusted nodes map (`--set trusted_nodes=`, or the menu) resyncs the allowlist once the node came back from its restart, as an edit of the bootstrap peers already did, so the floor holds the new hubs at once instead of after the next timer run.
- Fix for the same `committee_peers` gap as in [setup-node 2.1.7](#setup-node-217): `--set admission=`, `--set trusted_nodes=` and `--set bootstrap_peers=` (and the menu items and the Node Manager UI path that reach them) write the bootstrap peers map as `committee_peers` only when it lists every validator of the genesis `committee.yaml`.
  A map that lists fewer is installed and put on the start line as before, the edit goes on with a warning, and `network-config` gets no `committee_peers`, so the node starts instead of exiting at epoch 0.
  As at setup, only the map's first-level keys count, and an entry for this node with other network keys than its `node-info.yaml` leaves the map out too.
- `--set trusted_nodes=` refuses, besides the shapes it refused before, a `network_address` that is a DNS name (`/dns`, `/dns4`, `/dns6`, `/dnsaddr`), uses TCP or is no multiaddr, naming the line and the entry; the node would never dial a hub given by name, and stops at start on a malformed address.
  It also refuses worker ids other than those of the node's workers, and a map the installed release's parser rejects, quoting the node's reason; a map with CRLF line ends or a byte order mark, which it refused before, is taken.
  A quoted field name (`"primary":`) is taken, and UDP port 0, which the node never dials, is refused; so is a DNS name on the line after `network_address:` in a bootstrap peers map.
  `--set bootstrap_peers=` (and the menu and the Node Manager UI path that reach it) refuses the same addresses before the node's parse check, which takes them.
  The shape check now lives in `lib/common.sh`, shared with setup-node.
- On mainnet `--set gateway_upstream=<list>` refuses a host whose `/etc/caddy/Caddyfile` holds the public RPC site's `tn-rpc` block (its `# >>> tn-rpc >>>` line): `this host serves the public RPC site (install-caddy.sh rpc-enable), and on mainnet a node is fronted by that site or by a worker gateway, not both: run sudo bash <dir>/install-caddy.sh --phase=rpc-disable first`.
  Nothing is written; `gateway_upstream=off` is never refused for it, and testnet and devnet keep the behaviour of before.
  On every network a list is also refused while `NETWORK` is set more than once in `.node-meta` (`NETWORK is set more than once in .node-meta; remove the extra lines first`), rather than read as another network.
- The mainnet refusal of `0.0.0.0` in `4) RPC access` names the way a validator's RPC goes public instead: `a mainnet node keeps its RPC on 127.0.0.1. A mainnet validator's public RPC is its worker gateway: run setup-gateway.sh on a separate host, then on this host sudo bash <dir>/firewall-setup.sh --enable --gateway-from <gateway IP> (gateway_upstream is refused until ufw lets the gateway host in) and then sudo bash <dir>/edit-config.sh --set gateway_upstream=<gateway IP>. ...`.

### check-node 2.2.2

- With `P2P_COMMITTEE=on` in `.node-meta` and the allowlist timer's unit file gone, which is an `off` that did not finish, check-node reports one error and checks nothing else of the allowlist: `P2P committee mode is on in .node-meta, but a --p2p-committee off did not finish (the allowlist timer is gone; ...)`.
  The line says whether table `inet tn_p2p_allow` is still loaded, is gone, or could not be checked, and the fix it names is `firewall-setup.sh --p2p-committee off`, which finishes the `off`; a `sync` refuses in that state.
- Fix for nodes that advertise a worker gateway (`RPC_ADVERTISED_VIA=gateway` in `.node-meta`), on every network.
  The public RPC block probed https and wss through a Caddy site such a node does not have, warned that there was no `tn-rpc` vhost, and named `rpc-enable`, which refuses while the advertisement exists.
  It now prints `public RPC: https://<name>/ (the worker gateway's, RPC_ADVERTISED_VIA=gateway; no Caddy site on this host)`, compares worker 0 in `node-info.yaml` with `https://<name>/` and no WebSocket URL (a mismatch names `rpc-advertise --rpc-domain <name>`), and asks `GET https://<name>/health` once, with the options of `rpc-advertise`'s own check.
  A 200 is `public RPC: OK`. A name that does not resolve and is the node's default name (`tn_rpc_default_host`, when the library has it) gets a warning that its A record comes from the TAO, with the handoff and the route to a name of one's own; another such name gets `fix: point the A record of <name> at your worker gateway's static IP`; any other answer names `bash setup-gateway.sh --status` on the gateway host.
  It never probes wss or names `rpc-enable` there, and, like the rest of the block, it only warns: no health issue, no change to the exit code.
- A host where Caddy fronts a worker gateway gets a section `Checking the worker gateway's public edge (Caddy)...` after the gateway section (OPERATOR.md section 4.15).
  `/ready` not 200 while the gateway runs is a warning on a node host, and an issue on a host with no node, whose one job is to take transactions to the validator.
  The name's DNS comes from `install-caddy.sh --json --phase=gateway-check-dns`: a name that does not resolve is an issue, and one that resolves to an address that is neither the host's nor local is a warning.
  `GET https://<name>/health` through Caddy on the host (`curl --resolve <name>:443:127.0.0.1`) must answer 200 over a verified certificate, else an issue with its fix; with `openssl` on the host, a certificate that expires within 14 days is a warning, since Caddy's own renewal is failing.
  `ufw` must be active and allow 80/tcp and 443/tcp from anywhere, else an issue naming `firewall-setup.sh --enable`; reading it needs root.
  One information line says that the cloud's own firewall rules cannot be seen from the host.
- Fix for a mainnet validator behind a worker gateway: with `GATEWAY_UPSTREAM` in `.node-meta`, the `--healthcheck` on the node line is the gateway's readiness port, which `edit-config.sh --set gateway_upstream` sets, and check-node failed it as the testnet health monitor.
  It now reports it as OK (`--healthcheck <value> on the node line serves the worker gateway at <upstream> (GATEWAY_UPSTREAM), not the testnet health monitor`); `ENABLE_HEALTHCHECK_MONITOR=true` stays an error, and so does the flag without `GATEWAY_UPSTREAM`.
  A `GATEWAY_UPSTREAM` set more than once gets a warning, and the check is skipped.
- On a mainnet validator with `GATEWAY_UPSTREAM`, a `node-info.yaml` that advertises anything but an `https` URL with no WebSocket URL is now an error that counts as an issue, because transactions forwarded to the validator fail; elsewhere it stays information.
- On mainnet, a node whose stake status is Staked, Pending Activation, Active or Pending Exit gets a section `Checking admission (mainnet validator)...` after the epoch and committee report (OPERATOR.md section 2.9).
  Its admission mode is `ADMISSION_MODE` in `.node-meta`, else `admission.mode` in `network-config`, else unset, which the node runs as Open.
  Any mode but closed is a warning that names `edit-config.sh --set admission=closed`, and `--set trusted_nodes=<hubs file>` too when no trusted nodes map is recorded; it never counts as an issue.

### install-caddy 2.2.2

- On mainnet `rpc-enable` refuses a node that runs admission closed, as a validator does: `This mainnet node runs admission closed, as a validator does. A mainnet validator's RPC is served by its worker gateway, never by a Caddy site on the validator. Advertise the gateway with --phase=rpc-advertise --rpc-domain <name>. Nothing was changed.`
  When `.node-meta` already records the gateway's URL (`RPC_ADVERTISED_VIA=gateway` and `PUBLIC_RPC_URL`), as after a mainnet keygen, it names it instead of the `Advertise ...` sentence: `node-info.yaml already advertises https://<name>/ for the worker gateway; --phase=rpc-advertise --rpc-domain <name> changes the name.`
  It comes before the refusals over a gateway site or a gateway advertisement, whose advice (`rpc-unadvertise`) would only take the validator's URL away, and before the stake is read.
- On mainnet `rpc-enable` refuses a node fronted by a worker gateway: `GATEWAY_UPSTREAM=<list>: a worker gateway fronts this node, and on mainnet a node is fronted by a gateway or by this host's public RPC site, not both. Run edit-config.sh --set gateway_upstream=off first. Nothing was changed.`
  It too comes before the stake is read; testnet and devnet keep the behaviour of before for both refusals.
- On every network the refusal over a gateway advertisement names the URL and both of its writers: `node-info.yaml advertises https://<name>/ for a worker gateway (RPC_ADVERTISED_VIA=gateway, written by key generation on mainnet or by rpc-advertise). Run --phase=rpc-unadvertise first to serve a public RPC site here. Nothing was changed.`
  Both refusals that quote the recorded URL name a bare host with its `/`, as `node-info.yaml` holds it, and a URL with a path as `.node-meta` records it, with no `/` added.
- On mainnet, `rpc-advertise` on a host with no node service yet, such as one with only the mainnet keys of OPERATOR.md section 2.12, writes the record when `https://<name>/health` does not answer 200 from the host, with a warning instead of the refusal: `https://<name>/ is not verified: GET https://<name>/health from this host got <what> instead of 200, and this mainnet host has no node service yet, so nothing can answer before the node and its gateway run. The record is written anyway; check-node.sh verifies it later.`
  The run lists `https://<name>/ not verified` among its open items. On testnet and devnet, and on a mainnet host with a node service, the check still refuses, and no flag skips it.
- `rpc-unadvertise` on a mainnet node that runs admission closed warns `This validator now advertises no RPC URL, so other nodes cannot forward transactions to it until one is set again (--phase=rpc-advertise --rpc-domain <name>).`, unless the clear failed and `node-info.yaml` still holds the URL.
  It does not put the default name back.

### migrate-node-naming 2.0.1

- A P2P source list the kill switch set aside (`P2P_PER_SOURCE=off`) is not applied when the migration opens the P2P ports: both ports open to every source, as `firewall-setup.sh` leaves them.
- The allowlist resync after the migration names the command that works in each state: `--p2p-committee sync --accept-floor-shrink` when the floor kept addresses the files no longer hold (`sync` exit 4), `--p2p-committee off` when an `off` did not finish (exit 5), else `--p2p-committee sync`.

### lib/common 2.2.8

- New `tn_committee_peers_check DATA_DIR MAP`: rc 0 when every validator under `authorities` in `DATA_DIR/genesis/committee.yaml` is a key of the top-level map of the peers map MAP (YAML in block or flow style, JSON included) and MAP's entry for this node, if it has one, carries the primary and worker network keys of `DATA_DIR/node-info.yaml`; else rc 1 with one line that names the gap (a count and the first three keys), the entry, the line it does not read, or why the check could not run.
  It reads the files as the service user, since they sit in the data dir that user writes.
  setup-node and edit-config call it before every render of `committee_peers` and list it in their library checks.
- New `tn_trusted_nodes_shape_ok FILE`, the trusted nodes map's shape check, moved here from edit-config so setup-node runs the same one, and new `tn_map_addr_check FILE`, which it calls.
  `tn_map_addr_check` refuses a `network_address` that is not `/ip4/<address>/udp/<port>/quic-v1` or the same with `/ip6`, with an optional `/p2p/<peer id>`: a DNS name (`/dns`, `/dns4`, `/dns6`, `/dnsaddr`), which the node keeps and never dials because it does not resolve names, a `/tcp` address, which it does not dial either, and a value the node stops on.
  Each refusal names the line, the entry's BLS key shortened and the address; both scripts list the two functions in their library checks.
- New `tn_trusted_nodes_node_check SPEC FILE`: the release of SPEC parses a trusted nodes map as a `--bootstrap-peers` value, its workers turned into a list; and `tn_local_worker_count DATA_DIR`, the number of workers `node-info.yaml` lists (1 before there is one), which `tn_trusted_nodes_shape_ok FILE [WORKERS]` now takes.
- New `readonly TN_MAINNET_KEYGEN_ENABLED=1` and `tn_mainnet_keygen_enabled`: while `TN_MAINNET_ENABLED` is 0, they open setup-node's mainnet keygen and nothing else; at 0 that keygen is refused as before.
- New `tn_keys_network_ok WANTED [META]`: rc 1 when `.node-meta` records `NETWORK=mainnet` and WANTED is another network (the reason on stderr), rc 2 when `NETWORK` is set more than once, else rc 0; setup-node lists it in its library check.
- New `tn_rpc_default_host KEY`: prints the default advertised RPC name for the base58 BLS public key KEY, `v`, then its first five characters lowercased, then `.telcoin.network` (a key starting `pDmpE` gives `vpdmpe.telcoin.network`), and returns 1 with nothing printed when KEY is not 131 characters long, or 132 starting with `2`, or holds a character outside the base58 alphabet.
  The alphabet is spelled out rather than written as bracket ranges, so the locale cannot widen it.
  setup-node lists it, with `tn_node_info_field` and `tn_node_info_rpc`, in its library check; check-node calls it only when the library has it.

### setup-gateway 2.3.0 and lib/gateway 2.3.0

- `setup-gateway.sh --rate-limit-submissions N` sets the submissions a second the worker gateway keeps for single `eth_sendRawTransaction` calls; the default is 300 (burst 600), and `0` turns the reservation off.
  `gateway.meta` gains `RATE_LIMIT_SUBMISSIONS`, and the flag joins `GW_REQUIRED_FLAGS` (CHANGELOG.md has the entry).
- A mainnet worker gateway can be set up before genesis.
  `lib/gateway.sh` pinned no mainnet image, so `--enable` on mainnet refused (`this scripts release pins no worker-gateway image for mainnet yet`).
  Until telcoin-network publishes a mainnet release, the mainnet pin is now the testnet pin and its release, `v0.18.0-adiri`, as a placeholder: `_gw_pin_ok` takes a final testnet release for mainnet only while `TN_MAINNET_ENABLED` is 0, and never a release candidate.
  `--status` and check-node say `The worker-gateway image is a placeholder: <image> is the image of the testnet release v0.18.0-adiri, pinned for mainnet until telcoin-network publishes a mainnet release. ...` (OPERATOR.md section 4.15).
  A scripts release that enables mainnet refuses the placeholder as a defect of the release.
- `tools/check-gateway-pin.sh`, which CI and the installer's publication run, checks the placeholder against the signed files of the testnet release it names, with a line `mainnet: note: placeholder: ...`.
  At `TN_MAINNET_ENABLED=1` it refuses the placeholder and an empty mainnet pin, with exit 1 and before any download, so the release that enables mainnet pins a signed mainnet release.
  The tool is maintainer tooling and is not shipped to hosts.

### Terraform deployment

- New `terraform/`: root modules for AWS, Google Cloud and Azure that build a validator host and a worker-gateway host in one private network (`terraform/README.md`, OPERATOR.md section 2.13).
  A first apply builds the network, both static IPs, every firewall rule and the validator host; a second apply, once `rpc_domain` is set, creates the gateway host and leaves the validator alone.
- The validator's first boot mounts the data disk and installs the scripts, and stops there: the operator generates the keys from the commands the `next_steps` output prints, so the BLS passphrase never enters Terraform, its state or the hosts' user data.
- The gateway host sets itself up unattended: Docker from Docker's apt repository with its signing key checked against the fingerprint `setup-node.sh` pins, `setup-gateway.sh --enable --mode standalone` behind Caddy, `firewall-setup.sh --enable` and `check-node.sh`.
- Both hosts install the release the installer serves, and stop at their `scripts-release` step on one older than `min_scripts_release`, `scripts-v2.3.0` by default, with the command that runs first boot again once the installer serves it.
- `terraform/` is not shipped to hosts: `update-scripts.sh` does not track it and it has no `.sha256` sidecars.
  `tools/check-terraform.sh` and the CI job `terraform static checks` (pull requests and branch pushes, not a required check) run its static checks, and `terraform/REHEARSAL.md` lists what a rehearsal on each cloud must confirm.

## New keys, flags and exit codes

| Key, flag or exit code | What it is |
|---|---|
| `.node-meta` `P2P_PER_SOURCE` | `off` after `--p2p-committee off` on a host with `P2P_ALLOW_FROM`: the P2P ports stay open to every address and the list only feeds the committee allowlist; `--p2p-from` or `--p2p-anywhere` removes it |
| `firewall-setup.sh --p2p-committee sync --accept-floor-shrink` | Captures a smaller floor on purpose, for a hub taken out of the trusted nodes map; no script passes it for you |
| `firewall-setup.sh --p2p-committee sync` exit 4 | Synced with the floor it had, because a new capture would drop addresses |
| `firewall-setup.sh --p2p-committee sync` exit 5 | Refused because an `off` did not finish; a rerun of `off` finishes it |
| `TN_MAINNET_KEYGEN_ENABLED` in `lib/common.sh` | 1: opens setup-node's mainnet keygen, and nothing else, while `TN_MAINNET_ENABLED` is 0 |
| `.node-meta` `RPC_ADVERTISED_VIA=gateway` from key generation | A mainnet keygen writes it with the default name, or in validator posture with the operator's own gateway name; before, only `rpc-advertise` wrote it. Setup leaves it and the `PUBLIC_RPC_*` and `PUBLIC_WS_URL` keys alone when it writes the service |
| Keygen `done` field `advertised_rpc` | `{"http":"<url>","via":"gateway","default":true\|false}`, on a mainnet keygen that recorded a URL for the worker gateway; `default` is false for the operator's own name |
| `GW_MAINNET_IMAGE_PIN` and `GW_MAINNET_PIN_RELEASE` in `lib/gateway.sh` | The testnet pin and `v0.18.0-adiri`, a placeholder taken only while `TN_MAINNET_ENABLED` is 0 |
| `tools/check-gateway-pin.sh` line `mainnet: note: placeholder: ...` | The mainnet pin is the placeholder; it passed against the testnet release it names |
| `tools/check-gateway-pin.sh` exit 1 at `TN_MAINNET_ENABLED=1` | Also for an empty mainnet pin and for the placeholder |

## Refusals and warnings you may now see

| Message (shortened) | What to do |
|---|---|
| `--install-method <method> cannot install a mainnet node yet: before genesis no mainnet release, image or source tag can be verified. ...` (mainnet keygen) | Generate the keys with `--install-method existing --binary-path <binary>` (OPERATOR.md section 2.12). |
| `Refusing the node binary at <path>: it is not a mainnet build (This build has the features <features>; a mainnet build has none.) ...` | Build `telcoin-network` with no build features (`cargo build -p telcoin-network --bin telcoin-network --release --locked`) and pass that binary. |
| `This host is recorded for mainnet (NETWORK=mainnet in <.node-meta>, written before keygen makes mainnet keys), and a mainnet BLS key must never be used on another network, so a <network> node is refused here. ...` | Finalize this host with `--network mainnet`; set up the testnet or devnet node on another host. |
| `Could not derive the default RPC name from bls_public_key in <node-info.yaml> (...)`, `keytool set-rpc failed (rc <n>: ...)`, `After keytool set-rpc, worker 0 of <node-info.yaml> reads ...` or `Could not record <url> for your worker gateway: ...` (mainnet keygen, warnings) | The keys are fine. Set the URL later with `install-caddy.sh --phase=rpc-advertise --rpc-domain <name>` (OPERATOR.md section 2.12). |
| `--rpc-http <url> is refused: a mainnet validator's RPC URL (admission closed) is its worker gateway's, and must be https://. ...` (keygen, finalize, interactive setup) | Pass `--rpc-http https://<name>/` or `--rpc-domain <name>`. |
| `--rpc-ws <url> is dropped: on a mainnet validator (admission closed) ...` (keygen, warning) | Nothing: the worker gateway serves HTTPS only. |
| `This mainnet node runs admission closed, as a validator does. ...` (`install-caddy.sh rpc-enable`) | Run the worker gateway on its own host and advertise it (OPERATOR.md section 4.15); serve a public RPC site from a node that is not a validator. |
| `GATEWAY_UPSTREAM=<list>: a worker gateway fronts this node, ...` (`install-caddy.sh rpc-enable`) | `edit-config.sh --set gateway_upstream=off` first, if this node is to serve the site. |
| `this host serves the public RPC site (install-caddy.sh rpc-enable), and on mainnet ...` (`edit-config.sh --set gateway_upstream=`) | `install-caddy.sh --phase=rpc-disable` first. |
| `https://<name>/ is not verified: ...` (`install-caddy.sh rpc-advertise` on a mainnet host with no node service, warning) | Run `check-node.sh` once the node and its gateway run. |
| `This validator now advertises no RPC URL, ...` (`install-caddy.sh rpc-unadvertise`, warning) | Advertise a name again with `rpc-advertise --rpc-domain <name>`. |
| `The gateway's /ready is not 200, so it refuses transactions (503): ...` (`check-node.sh` on a gateway host with no node, issue) | Run `check-node.sh` on the validator host; before a mainnet validator runs this is expected. |
| `DNS: <name> does not resolve, so nobody reaches the gateway by its name; ...` (`check-node.sh` on a gateway host, issue) | Point the name's A record at the gateway host's static public IP. |
| `GET https://<name>/health through Caddy on this host got ... instead of 200` (`check-node.sh` on a gateway host, issue) | Follow the line under it: for a TLS or certificate error, the A record and TCP 80 and 443 from anywhere; else `setup-gateway.sh --status` and `journalctl -u caddy`. |
| `The certificate for <name> expires <date>, within 14 days. ...` (`check-node.sh` on a gateway host, warning) | Caddy's renewal is failing: see `journalctl -u caddy`. |
| `ufw is not active, ...` or `ufw does not allow 80/tcp ... from anywhere; ...` (`check-node.sh` on a gateway host, issue) | `sudo bash <dir>/firewall-setup.sh --enable`. |
| `node-info.yaml advertises RPC ..., ws ...; a mainnet validator behind a worker gateway must advertise the gateway's https URL and no ws URL, ...` (`check-node.sh`, issue) | `install-caddy.sh --phase=rpc-advertise --rpc-domain <name>`. |
| `This node is <status> on mainnet, but its admission mode is <mode> (from <source>); ...` or `... no admission mode is set, so it runs Open; ...` (`check-node.sh`, warning) | Move the validator to Closed admission with its trusted hubs, through Grace on a running node (OPERATOR.md section 2.9). |
| `The worker-gateway image is a placeholder: ...` (`setup-gateway.sh --status`, `check-node.sh`) | Nothing until a scripts release pins a mainnet image; then `update-scripts.sh` and `setup-gateway.sh --refresh`. |
| `mainnet: refused: GW_MAINNET_PIN_RELEASE v0.18.0-adiri is a testnet release, the placeholder taken only while TN_MAINNET_ENABLED is 0, ...` or `mainnet: refused: GW_MAINNET_IMAGE_PIN and GW_MAINNET_PIN_RELEASE are empty, ...` (`tools/check-gateway-pin.sh`) | Pin the worker-gateway image of a signed mainnet release in the release that enables mainnet. |
| `The installer put the node scripts <release> on this host; this deployment needs scripts-v2.3.0 or newer. ...` (Terraform first boot) | Once the installer serves `scripts-v2.3.0`, run the command the line names on each host. |

OPERATOR.md section 9 lists the warnings about a bootstrap peers map that is left out of
`committee_peers` and the refusals of a trusted nodes map.

## Left open

- A trusted hub entry whose `/p2p` peer id does not match its `network_key`, or whose network key
  belongs to this node or another hub, passes both checks; the node refuses it only at start.
- A validator's key listed twice in the peers map with one copy written as a YAML escape sequence
  passes the duplicate check.
- `--json --status` reports `tool-missing` for an `off` that did not finish; the text output names
  the state.
- A `setup-node.sh` re-run still restarts the node without a rollback of its config. The checks
  above run before the restart; `edit-config.sh`, which does roll back, is the safer way to
  change hubs or peers on a running validator.
- `check-node.sh` does not flag a `committee_peers` left in `network-config` by an older script
  version.
- A hard kill or power loss during key generation can leave a stored passphrase with no keys; the
  next run says what it found and how to go on.
- The keygen does not warn about an execution address with a wrong EIP-55 checksum (the scripts
  have no keccak-256).
- The default name takes five characters of the BLS key, lowercased, so two keys can give the
  same name; nothing in the scripts detects that.
- `rpc-unadvertise` does not put the default name back. `rpc-advertise` with the default name
  does, once that name answers, or at once on a mainnet host with no node service yet.
- `check-node.sh` does not probe a gateway advertisement whose `.node-meta` has no
  `PUBLIC_RPC_DOMAIN`, as after a `--rpc-http` URL with an IP address, a port other than 443 or a
  path on a mainnet validator; it says so.
- The default name answers only once the TAO has created its A record and a worker gateway runs
  for it; until telcoin-network publishes a mainnet release, that gateway runs the testnet
  release's image as a placeholder.
- `check-node.sh` cannot see a cloud's security groups, firewall rules or network security groups;
  it says so on a gateway host.
- The Terraform deployment's points that need a cloud account or a real host, listed in
  `terraform/REHEARSAL.md`, are not confirmed yet, and its hosts need this release from the
  installer.
- On Azure the testnet validator size, `Standard_D8s_v5`, caps uncached disk IOPS at 12,800, below
  the 15,000 the data disk is provisioned with.
- The partner guide still says that `--p2p-committee off` puts the earlier rules back. It is
  updated with the release, because the published guide describes the released scripts.
