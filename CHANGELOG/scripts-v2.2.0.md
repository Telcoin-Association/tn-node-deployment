# scripts-v2.2.0 (November 2026)

`scripts-v2.2.0` follows `scripts-v2.1.0`. It adds `setup-gateway.sh`, which runs
telcoin-network's worker gateway: a public JSON-RPC front that sends transaction submissions to
the worker of a node and proxies every other call to a query endpoint the operator names. The
gateway runs next to a testnet or devnet node, or on a host of its own in front of a validator's
private address, so the validator stays off the public internet. Six existing scripts and
`lib/common.sh` change with it. No released worker-gateway image exists yet: devnet takes one by
digest, and testnet and mainnet refuse the enable until a scripts release pins a digest.

One fix reaches every operator, gateway or not: `firewall-setup.sh` now compares the sources of
`--ssh-from` and `--p2p-from` the way `ufw` stores them. Re-entering a source in another spelling
used to delete its rule (see [firewall-setup 2.2.0](#firewall-setup-220)).

| Component | Version |
|---|---|
| setup-gateway | 2.2.0 (new) |
| lib/gateway (`GATEWAY_VERSION`) | 2.2.0 (new) |
| install-caddy, firewall-setup, edit-config, check-node, remove-node | 2.2.0 |
| update-scripts | 2.2.0 |
| lib/common (`COMMON_VERSION`) | 2.2.0 |

Every other script, library and UI file keeps its version. The runbook for the gateway is
[OPERATOR.md section 4.15](../OPERATOR.md#415-worker-gateway).

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
  devnet the repository must be `us-docker.pkg.dev/telcoin-network/tn-public/worker-gateway`. On
  testnet and mainnet only the digest this release pins in `lib/gateway.sh` is taken, and this
  release pins none. Before it writes anything, the enable pulls the digest when Docker does not
  hold it, runs the image's `--help` under a time limit and refuses an image that lacks a flag the
  unit passes.
- The image rule depends on the network, so the network is checked. On a host with a node,
  `--refresh` refuses, and `--status` reports, a gateway whose recorded network differs from the
  node's. On a host with no node, `--enable` and `--refresh` ask the upstream for its chain id and
  refuse the chain of another network; an upstream that does not answer only warns, since the node
  may be down, and `--status` repeats the check.
- After a scripts release changes the pinned image, `--refresh` without `--image` moves the
  gateway to the pin and says so, and `--status` counts an image the release does not allow.
- `--remove` leaves a file it did not write in place and names it.

### install-caddy 2.2.0

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

### edit-config 2.2.0

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

### check-node 2.2.0

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

- Tracks `setup-gateway.sh` and `lib/gateway.sh`. When an update changes either on a host with
  `/etc/systemd/system/telcoin-gateway.service`, it prints `The worker gateway script or its
  library changed. Render the gateway again on the host:` and the `setup-gateway.sh --refresh`
  command. It never runs it: the unit is rendered from `gateway.meta`, and new copies take effect
  only once `--refresh` renders it again.

### lib/common 2.2.0

- The gateway's paths, unit and container names, default ports and Caddyfile fence
  (`TN_GATEWAY_*`).
- The readers the other scripts use: the gateway's meta file (`tn_gateway_meta_path`,
  `tn_gateway_meta_get`), the `GATEWAY_ALLOW_FROM` list (`tn_gateway_from_list`), whether `ufw`
  holds both rules for each listed host (`tn_gateway_from_rules_ok`) and whether nobody else
  reaches the two ports (`tn_gateway_ports_private`).
- Sources `lib/gateway.sh` at its end when the file is present, as it does `lib/alerts.sh`.

## New files, units and keys

| Path or key | What it is |
|---|---|
| `setup-gateway.sh`, `lib/gateway.sh` | The worker gateway's script and library |
| `/etc/systemd/system/telcoin-gateway.service` | The gateway's unit |
| `/etc/telcoin/gateway/gateway.meta` | The gateway's settings (`GATEWAY_META_VERSION=1`) |
| Caddy site `tn-gateway` | The third managed site, beside `tn-dashboard` and `tn-rpc` |
| `.node-meta` `GATEWAY_ALLOW_FROM` | The gateway hosts the firewall admits to the node's RPC and health ports |
| `.node-meta` `GATEWAY_UPSTREAM` | The gateway hosts the node's RPC and health listener are bound for |
| `.node-meta` `GATEWAY_PREV_HEALTHCHECK` | The `--healthcheck` value from before `gateway_upstream`, put back by `off` |
| `firewall-setup.sh --json --status` `gateway_from` | The stored gateway source list |

## Refusals and warnings you may now see

| Message (shortened) | What to do |
|---|---|
| `this scripts release pins no worker-gateway image for <network>` | Testnet and mainnet wait for a release that pins an image. |
| `on mainnet the gateway runs on its own host (use --mode standalone there)` | Run the gateway on a host of its own. |
| `--reset is refused while GATEWAY_UPSTREAM is set` | Set `gateway_upstream=off` first; OPERATOR.md section 4.15 has the order. |
| `GATEWAY_UPSTREAM in .node-meta names <host>: ...` | Keep the host in `--gateway-from`, or set `gateway_upstream=off` first. |
| `<missing rules>, so the gateways cannot reach the RPC and health check; open them first: ...` | Run the `firewall-setup.sh --enable --gateway-from` command it prints. |
| `the node's RPC already listens on every interface` | The RPC is public; a gateway upstream is for a node whose RPC is private. |
| `rpc-advertise was asked to advertise https://<domain>/, and GET https://<domain>/health from this host got <code> instead of 200` | Make the gateway answer at that name first. |
| `A worker gateway is installed here and this script leaves it in place` | Remove it with `setup-gateway.sh --remove`. |

## Left open

- No released worker-gateway image exists. Testnet and mainnet refuse the gateway until a scripts
  release pins a digest in `lib/gateway.sh`; devnet takes one by digest from the repository above.
- The per-client limit (100 requests a second, 32 connections) is keyed on the client IP address,
  so a relay that forwards many users' transactions counts as one client.
