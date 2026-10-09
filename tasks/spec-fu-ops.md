# Appendix C: Caddy, check-node, firewall, observability, stake tool

Read `tasks/spec-fu-shared.md` first. Helper signatures are those of `tasks/spec-fu-core.md`:
`tn_rpc_call` returns the response body (use `tn_json_field`), failures are any non-zero rc with
`<kind> <detail>`; `tn_keytool` takes an explicit runner spec and data dir with `@DATADIR@`;
`tn_node_info_field` takes the file first; `tn_node_info_worker_ports` prints worker ports only
(the primary port is `tn_node_info_field FILE primary_port`); the progress callback takes
`(kind, message)`.

## C.1 `install-caddy.sh` (1.3.0 → 1.4.0)

Soft guards throughout: nothing dies on a stale library, so rpc-disable can always take an
endpoint down.

- `install_caddy_pkg`: check `caddy version` against a floor of 2.8.0 (`basic_auth` and heredocs);
  below it, die with the repo instructions.
- `caddy_open_ports` / `caddy_close_ports`: no early return when ufw is inactive (ufw keeps staged rules).
- `caddy_swap_in` calls new `caddy_prune_backups`: glob `Caddyfile.bak.[0-9]*_[0-9]*`, name order
  is time order, keep the newest 5, never delete `$CADDY_LAST_BACKUP` or `.tn-orig`.
- `write_rpc_block` emits block v2 (below), stamped `tn-rpc block v2` in its comment.
  `caddy_rpc_block_stale` reports an enabled block without the stamp; `rpc-status` JSON gains
  `"block_stale"`, the human status warns with the refresh command.
- `caddy_edit_node_info` (python fallback): set and clear touch worker 0 only, matching `set-rpc`.
- New `caddy_node_info_write`: prefer `tn_keytool … set-rpc`; on failure restore the backup and
  use the python editor; restore owner and mode from the backup; read back worker 0 and compare.
- `caddy_node_info_advertise`: read the current value first; when it already matches, do not edit
  or restart. The `cmp -s` test goes away because keytool may reformat the file.
- Epoch wait: new `caddy_restart_window` (once per run) calls `tn_wait_restart_window` **before
  the first edit**; `caddy_restart_node_guarded` calls it again as a no-op. The recovery restart
  after a rollback never waits. Progress goes through `caddy_say`, so JSON runs get `log` events.
- `caddy_ws_preflight`: delete the private copy of the inject rule (`caddy_launch_inject_target`,
  `caddy_launch_verify_inject`); call the shared `tn_node_inject_flags`, accept only when the flag
  is on a live line and `bash -n` passes, otherwise restore and warn.
- `.node-meta`: `do_rpc_enable` sets `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL`, `PUBLIC_WS_URL` (empty
  when WebSocket is unavailable); `do_rpc_disable` clears all three.
- JSON mode: a hostname-clash refusal is sent as an `error` event, not only on stderr.
- Intentional addition: the WebSocket matcher becomes case-insensitive (`header_regexp … (?i)`),
  because `Connection: upgrade` as sent by the Google balancer and nginx gets 405 today.

RPC block v2 (validated with `caddy adapt` and `caddy fmt` on Caddy 2.11):

```
<domain> {
	encode zstd gzip
	@preflight method OPTIONS
	handle @preflight { …CORS headers… respond 200 }
	@websocket {
		header_regexp wsconn Connection (?i)upgrade
		header_regexp wsup Upgrade (?i)websocket
	}
	handle @websocket { reverse_proxy 127.0.0.1:<WS_PORT> }
	@browser {
		method GET HEAD
		header !Upgrade
	}
	handle @browser {
		header Allow "POST, OPTIONS"
		header Content-Type "text/html; charset=utf-8"
		respond <<TNPAGE
			…page…
			TNPAGE 405
	}
	handle {
		…CORS headers…
		request_body { max_size 2MB }
		reverse_proxy 127.0.0.1:<RPC_PORT>
	}
}
```

Page rules: authored in this repo, domain baked in, inline `style=""` only, no `<style>` block and
no `{` or `}` anywhere (braces in the curl example are written as entities, which do decode in
normal text), no blank lines. Inline beats a static file: rpc-disable removes it with the block,
`caddy validate` covers it, and it lands in the backups. Existing installs get the new block when
rpc-enable is run again with the same domain (a Caddy reload only); check-node and `rpc-status`
say so.

Limits: the 2 MB body cap applies to the JSON-RPC handler only (largest legitimate request is
about 256 KiB; reth's own cap is 15 MB). No server timeouts (they would cut WebSocket sessions and
long `eth_getLogs` responses) and no per-IP limits (carrier NAT puts many users behind one address).

## C.2 `check-node.sh` (1.1.55 → 1.2.0)

- Network: read `.node-meta` `NETWORK` and map to the expected chain id and comparison RPC
  (testnet, mainnet, devnet); `--network-rpc` still wins; unknown network accepts any known id.
  The default comparison RPC for testnet is `TESTNET_RPC_URL` (`https://rpc.adiri.tel`).
- Authority id: from the local node's `tn_info` (`authority_id`), falling back to `--authority-id`.
  Today's lookup matches nothing on current installs, so the committee header check never runs.
- Committee logic: on-chain membership of the current epoch (from the network RPC) is the main
  test. In the committee and absent from headers: ERROR. Not in it: info ("absence is expected").
  Unknown: ERROR only for status 3 or 4 when the local `tn_nodeMode` is not `Observer`.
- New epoch section: epoch id, time to the next boundary and its UTC time; activation epoch and
  earliest seat (`activationEpoch + 2`); membership of E, E+1, E+2; WARN when the node is in the
  committee but reports `Observer`.
- Worker count: on-chain `numWorkers()` against the local worker list; more required than
  configured is an ERROR and a health issue; a failed read says nothing. Per-worker RPC probes
  only when there is more than one local worker.
- macOS: disk via a `df -Pk` parser, memory only when `/proc/meminfo` is usable.
- wss probe: run curl in the background into a temp file, poll for the status line, kill curl; a
  101 returns in about 0.1 s.
- Public node warnings: a stale RPC block (with the refresh command), and `debug`, `trace`,
  `admin` or `all` named in `--http.api` / `--ws.api`.
- Library contract (from L1): `node_stake_status` now prints `<status> <activation> <retired>
  <exit_epoch>`, `none`, `unknown bad-address` (rc 1) or `unknown <kind> <detail>` (rc 2); call
  `print_validator_onchain_status "$ADDR" "$LINE" "" "$CURRENT_EPOCH"` so an Exited validator gets
  the "is unstake eligible now" answer, and show `${LINE#unknown }` as the reason in the rc-2 branch.
  Use `tn_epoch_info`, `tn_epoch_secs_left`, `tn_node_mode`, `tn_rpc_call` + `tn_json_field` and
  `tn_stake_amount_wei` instead of private curl helpers.

## C.3 `firewall-setup.sh` (1.5.2 → 1.6.0), observability

- New `fw_p2p_ports`: primary and worker 0 from the listener env on live launch-file lines, other
  workers from node-info, constants as the fallback. All status, enable, manage and desired-rule
  code loops over it instead of the 49590/49594 literals.
- `apply_recommended_firewall`: evaluate `caddy_serves_public_edge` on every run and allow 80/443
  before `ufw --force enable`.
- JSON: `ports` keys and the `json_fw_port` allowlist stay as they are; new `"p2p_ports"` list of
  objects, one per port from `fw_p2p_ports`, in order:
  `{"port": 49590, "proto": "udp", "label": "primary", "allowed": true}`, labels `primary`,
  `worker-0`, `worker-1`, …; `allowed` is `true`/`false` from the ufw rule table, or `null` when ufw
  is inactive or not installed. (Decided by the orchestrator; the UI already renders this shape.)
- `tn_resolve_node_type` callers removed (status text shows the service name).
- `lib/observability.sh` (1.0.2), `setup-observability.sh` (1.2.1): pre-checks use
  `tn_launch_flag_get`; `tn_wait_restart_window` right before each restart; clearer messages for
  inject return codes.

## C.4 New script `prepare-stake.sh` (1.0.0)

```
sudo bash prepare-stake.sh [--network-rpc <url>]
sudo bash prepare-stake.sh --rotate-address <0xNEW> [--yes] [--no-restart] [--network-rpc <url>]
```

Never reads, accepts or prints a private key. Prepare flow: chain id matches the configured
network; address from node-info `execution_address` (warn when `.node-meta` differs); `balanceOf`
(not whitelisted: exit 3); `node_stake_status` (already staked: skip to activate; later statuses:
report and exit 0); stake amount from `stakeConfig(getCurrentStakeVersion())`; balance check;
calldata from `keytool export-staking-args --calldata` with selector `0x2fb0d025` required;
`eth_estimateGas` simulation from that address (a revert is decoded; `InvalidProofOfPossession`
points to `--rotate-address`, never to regenerating keys); sync lag warning; then the exact
`cast send` lines for `stake` and `activate()` with the network RPC, plus the epoch arithmetic.
256-bit values never go through bash arithmetic: python3 or the library's pure-bash limb helpers
(`tn_hex_to_dec`, `tn_wei_to_tel`), which D verified against python and `cast` on 273 vectors.

Rotation: refuse when the current address has any status 1 to 5 or is retired (a registered BLS
key cannot move), or the new address is retired or has a record; confirm; passphrase from
`TN_BLS_PASSPHRASE`, then the config dir's passphrase file, then a TTY prompt (never argv, unset
by an EXIT trap); back up node-info; `keytool generate pop --address NEW`; verify the address
changed and the BLS key and name did not, else restore and exit 4; restore owner and mode;
`meta_set VALIDATOR_ADDRESS`; restart unless `--no-restart`.

Exit codes: 0 ready or nothing to do; 1 usage or environment; 2 RPC unreachable or state
unreadable; 3 not ready or refused; 4 rotation failed and rolled back.

Wiring (after P3 is committed): a `SCRIPTS` row in `update-scripts.sh` and a `chmod` line in
`install.sh`. Hard guard on `COMMON_VERSION` 1.6.0 (see spec-fu-core B.1).

## C.5 Tests

- install-caddy: render the block and run `caddy validate` and `caddy fmt` locally and in
  `caddy:2.8-alpine` (the floor). Run Caddy on a high port against a JSON-RPC stub and a WebSocket
  stub: GET and HEAD give 405 with `Allow`; POST passes with CORS; OPTIONS gives 200;
  `Connection: upgrade`, `Upgrade`, `keep-alive, Upgrade` and `Upgrade: WebSocket` all give 101;
  a 3 MB POST gives 413 and never reaches the stub; the old block with lowercase `upgrade` gives
  405 (records the bug). Advertise flow in a Linux container with shims: unchanged URLs mean no
  edit, wait or restart; a changed URL waits before editing, edits worker 0 only, keeps owner and
  mode, restarts once. Real `set-rpc` and `--clear` with the v0.15.0 image. Backup pruning.
  `.node-meta` keys. Every JSON line passes `jq`. With today's `lib/common.sh`, rpc-enable
  degrades with warnings and rpc-disable works.
- check-node: curl shim per method and selector for the network, committee, epoch and worker-count
  cases; a real run under macOS `/bin/bash` reaches the summary; the wss probe returns in under
  1.5 s against the stub; live read-only comparison with `cast` against `https://rpc.adiri.tel`.
- firewall: ufw shim log against node-info fixtures (default ports, moved ports, two workers,
  legacy `worker:` map, missing file, listener override); plain enable with and without a Caddy
  site; JSON keys unchanged.
- prepare-stake: shims for every exit code; the 1e24 amount prints exactly; no argv ever holds the
  passphrase; rotation refusals and rollback; real `export-staking-args` and `generate pop` with
  the v0.15.0 image; live read of the stake amount equals `cast call`.
