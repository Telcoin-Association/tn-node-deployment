# Follow-ups — operator nice-to-haves

This is the backlog of improvements deferred from the public-RPC and observer-flag-removal
work (October 2026). Each item says why an operator would care.

## Node Manager UI

- Enable the Public card in the setup wizard (still marked "coming soon") and ask for the
  public RPC hostname, then carry it from `_setup_env` in `ui/server.py` through `cmd_setup`
  in `ui/telcoin-ui-helper.sh` as `--rpc-domain`.
  Why: a UI-only operator cannot make a node public at install time and has to find the RPC
  card afterwards or drop to the shell.
- Stop sending `--rpc-public true` on its own. `cmd_setup` always forwards the wizard's
  `rpc_public` value, and setup-node now keeps the node private with only a notice when no
  `--rpc-domain` comes with it.
  Why: an operator who picks "public" in the UI ends up with a private node and may not notice.
- Add an "advertised" badge to the RPC card from the `rpc-status` keys `advertised_http`,
  `advertised_ws` and `ws_listening`, and replace the `rpc.example.com` placeholder in the
  domain field with the node's own name (`nodeN.<suffix>`).
  Why: operators see at a glance whether wallets can discover the endpoint, and the
  placeholder steers them toward the hostname the network expects.
- Warn on the dashboard card when its hostname equals the public RPC hostname, and suggest
  `dashboard.<node-domain>` instead.
  Why: Caddy cannot serve two sites on one name and install-caddy refuses the combination, so
  today the operator only learns about the clash from an error.
- Pass `--move-dashboard-to` through `cmd_rpc_enable` and `api_rpc_enable`, which accept only
  the domain and inbound IP today.
  Why: install-caddy can move the dashboard and enable RPC in one step, but a UI operator
  whose dashboard already sits on the node name has no way to ask for it.
- Once every installed helper is new enough, drop the `"--${t}"` argument from the helper's
  update-node and edit-config calls, and the `observer|validator` positional argument from the
  helper subcommands and their sudoers lines. edit-config already discards the flag and
  update-node only uses it to skip auto-detection.
  Why: the role split no longer exists, and keeping it doubles the UI's sudoers surface for no
  benefit.
- Refresh the header comment in `ui/install-ui.sh`. It says the UI user gets only six
  `systemctl` commands for `telcoin-{observer,validator}`; the sudoers drop-in now also covers
  the unified `telcoin` unit and the whole `telcoin-ui-helper` command set.
  Why: an operator reading the installer to judge what root access the UI gets is told less
  than it grants.

## Scripts

- `tn_node_inject_flags` in `lib/common.sh` appends to the first line containing `--http`,
  comment lines included. install-caddy guards against this with `caddy_launch_inject_target`;
  the helper should skip comments itself so setup-observability and `lib/observability.sh` are
  safe too.
  Why: a commented-out `--http` line in a hand-edited start script gets the new flags and the
  live line does not, so the change quietly does nothing.
- `confirm()` in `lib/common.sh` lowercases the answer with `${response,,}`, a bad
  substitution under bash 3.2. Use `tr '[:upper:]' '[:lower:]'`.
  Why: every interactive yes/no prompt breaks on macOS `/bin/bash`, and CI's parse check cannot
  catch it because it only fails at runtime.
- `remove-node.sh` still uses `declare -A` for its unit maps. It runs on Linux, so this is
  harmless today, but AGENTS.md asks for indexed arrays.
  Why: with no exceptions left, CI can reject `declare -A` outright instead of relying on review.
- Derive the node type from the chain everywhere and drop the `.node-meta` `NODE_TYPE` hint
  (and `tn_resolve_node_type`) once old UI bundles are gone.
  Why: while the node is unsynced or its RPC is down, the stale hint still picks the dashboard view.
- The hardware preflight counts logical CPUs with `nproc`, but the telcoin-network hardware
  page sizes validators by physical cores.
  Why: on a hyperthreaded VM the preflight sees twice the real cores, so an undersized
  validator passes.
- Support `--bootstrap-peers` in setup-node (the node binary takes a YAML or JSON map keyed by
  BLS key).
  Why: after a network restart or with flaky genesis seeds, operators can point the node at
  known-good peers without hand-editing the launch line.
- Multi-worker support (a worker count, with per-worker addresses, ports and RPC endpoints)
  once governance raises the worker count above one.
  Why: setup-node, the firewall rules and check-node all assume a single worker today.
- An `allow_private_forward_targets` toggle in edit-config, for private networks only.
  Why: single-host and docker-compose testbeds advertise `127.0.0.1`, and the node refuses to
  forward transactions to private addresses unless this parameter is set.
- Expose `--enable-state-export` and `--state-export-keep` in setup-node and edit-config.
  Why: operators who want per-epoch state snapshots must hand-edit the launch line, and without
  a keep limit each epoch's full state copy can fill the data volume.
- Make restarts epoch-boundary aware: update-node and `caddy_restart_node_guarded` in
  install-caddy restart the node without checking how close the next boundary is.
  Why: a committee member restarted seconds before a boundary can miss the epoch transition.
- Raise `MIN_SOURCE_VERSION_TESTNET` in `lib/common.sh` from 0.12.0 to at least 0.13.0 so a
  source build always has keytool `--rpc-http` and `set-rpc`. A local telcoin-network checkout
  already shows both in v0.12.0-adiri, so confirm against the published tags before raising.
  Why: an operator building an old tag should be refused up front, not fail halfway through keygen.
- Print the `OPERATOR.md` runbook URL at the end of `install.sh` and in setup-node's
  `step_final_summary`.
  Why: new operators land on the step-by-step runbook instead of the long README reference.
- check-node's chain-ID check accepts only 2017, so a devnet node (chain 32285) is reported as
  a mismatch and counted as a health issue. Compare against the node's configured network.
  Why: devnet operators see a false error on every run.
- Keep `.node-meta` in step with later Caddy changes. Only setup-node writes
  `PUBLIC_RPC_DOMAIN`, `PUBLIC_RPC_URL` and `PUBLIC_WS_URL`; a later `rpc-enable` or
  `rpc-disable` leaves them untouched, and check-node reads only the domain (falling back to the
  Caddyfile).
  Why: the UI and any tooling reading `.node-meta` can show an endpoint that is gone, or miss one
  that exists.
- setup-node does not validate `--rpc-http`, `--rpc-ws`, `--public-rpc-url` or
  `--public-ws-url`, unlike `--rpc-domain`.
  Why: a malformed value fails late at keygen, and a well-formed wrong one is advertised to wallets.
- The `tn_resolve_node_type` comment in `lib/fallback.sh` says the UI promotes the view from
  `tn_isValidator`. The UI now follows the on-chain stake status (`getValidator`), so the
  comment is stale.
  Why: anyone reading the fallback shim should see the real source of truth for the validator view.
- check-node treats every staked status (Staked, Pending Activation, Active, Pending Exit) as
  "should be in the committee", so a validator that is staked but not yet seated, or Active but
  out of this epoch's committee, gets a health ERROR for missing committee headers. Downgrade it
  to info when `tn_nodeMode` reports `Observer`, so a correctly waiting validator is not told it
  is broken.
- check-node's memory and disk section reads `/proc/meminfo` and `df --output`, which do not
  exist on macOS; a macOS run aborts there. Guard it like the new `check_hardware` does.
- `node_stake_status` decodes the status from the low 16 hex characters of word 3 and ignores
  the rest of the word, so ABI-invalid data (a non-zero upper part) is read as a valid status
  instead of `unknown`. Decode the low byte and require the rest of the word to be zero.
  Why: a corrupt or proxied response should fail closed, not pick a validator status at random.
- `check_validator_onchain_status` prints "node may still be syncing or NFT not yet minted" for
  any non-revert RPC error, including a rate limit; say which error came back.
  Why: an operator hitting a public RPC rate limit is told to wait for sync instead of retrying.
- `setup-node.sh --json --phase=finalize --install-method docker` without `--docker-image` writes
  a wrapper with an empty image, because the image is auto-detected only in `step_preflight`,
  which the finalize phase never runs. Either auto-detect there too or fail early with a clear
  `error` event. The `existing` method has no JSON flag for the binary path and finalize assumes
  `/opt/telcoin/telcoin-network`.
  Why: an automation run that forgets one flag produces a unit that cannot start.
- update-node's argument parser: `--ref` given as the last argument makes `shift 2` loop forever,
  and an unknown argument prints its warning before the JSON file-descriptor swap, so it lands
  on JSON stdout; `check_root` and `detect_node` failures exit without a `done` event.
  Why: the Node Manager UI reads update-node's JSON stream and a stray line breaks its parser.
- The on-chain status report (`print_validator_onchain_status`) tells an Exited validator "you
  can now call unstake()", but `unstake` is only eligible one epoch after the exit; say so.
  Why: an operator who follows the hint straight away gets an `IneligibleUnstake` revert.

## Public RPC / Caddy

- Prefer `keytool set-rpc` for editing the advertised RPC in node-info.yaml, and keep
  `caddy_edit_node_info` as the fallback for binaries that lack it.
  Why: the node's own tool tracks the `p2p_info` format, so a future change there does not
  break rpc-enable.
- `caddy_swap_in` writes a new `Caddyfile.bak.<timestamp>` on every change and never prunes
  them. Keep the last few, or document the cleanup.
  Why: operators who toggle the dashboard or RPC often pile up backups with no hint which matter.
- `apply_recommended_firewall` in firewall-setup re-adds 80/443 only on `--reset`. If Caddy was
  set up while ufw was off, `caddy_open_ports` skipped them, so a later plain enable leaves
  80/443 closed under a live site.
  Why: the dashboard and public RPC go dark right after the operator turns the firewall on.
- The wss probe in check-node's `report_public_rpc` waits the full `--max-time 8` on a healthy
  node, because a successful upgrade keeps the connection open. Stop reading after the status
  line, or use a short timeout for the 101 case.
  Why: every check-node run on a public node pays eight extra seconds for a check that passed.
- A browser landing page on the RPC hostname, matching the fleet's 405 HTML page but built
  inside install-caddy (never by calling `common/`, which operators do not have).
  Why: someone opening the RPC URL in a browser gets a short explanation instead of a raw error.
- Review rate limiting and `--http.api` exposure for public endpoints.
  Why: a public node serves anyone, and one heavy client can degrade it, validator duties included.
- Guidance for reth's `--rpc-cache.*` flags (`--rpc-cache.max-blocks`,
  `--rpc-cache.max-receipts` and friends) on public nodes.
  Why: the defaults suit a private node, and operators of busy endpoints have no starting numbers.
- Devnet `NETWORK_PUBLIC_WS` in `ui/server.py` lists the five node endpoints but no
  `wss://rpc.devnet.telcoin.network` load-balancer entry, while the HTTP list leads with the
  load balancer. Confirm whether the load balancer terminates WebSocket, then add it or say why not.
  Why: devnet users copying a WebSocket URL from the dashboard get one node, not the balanced one.

## Validator tooling

- A stake helper script that exports the stake calldata, checks the address is whitelisted and
  prints the exact `cast send` line.
  Why: staking is the riskiest manual step for a new validator and today means copying hex by hand.
- Show the activation epoch, the earliest committee seat and the time to the next epoch boundary
  in check-node and the UI.
  Why: after staking, operators cannot tell whether "not in the committee yet" is expected.
- Execution-address rotation using `keytool generate pop` to re-sign the proof of possession.
  Why: an operator moving to a new staking address has no guided path, and a stale PoP makes the
  stake call revert.

## Docs upstream (telcoin-network, devnet-genesis — not fixable here)

These live in other repos. They are listed so operators who hit them know they are known.

- `how-to-stake.md` still shows `stake(bytes,(bytes,bytes))`-style signatures and `--force`
  advice; the live contract takes `stake(bytes,(bytes))` and `unstake(address,bool)`.
  Why: operators copying those `cast` commands get a revert.
- Old function selectors in telcoin-network's `chain-configs/testnet/genesis.yaml` (this repo
  does not vendor that file).
  Why: anyone decoding registry calls against it gets the wrong functions.
- The tn-3 docs point at `rpc.adiri.tel` and their own explorer, while this repo and the UI use
  `rpc.telcoin.network`.
  Why: operators cannot tell which endpoint is canonical.
- The upstream docs give two contact addresses: a personal maintainer address in one place and
  `support@telcoin.org` elsewhere.
  Why: operators should have one place to ask for help.
- The tn-3 docs give the worker UDP port as 49595; this repo and the firewall use 49594.
  Why: an operator following the upstream page opens the wrong port and the worker is unreachable.
- The `p2p_info.worker` example in the upstream docs predates the current `p2p_info.workers` list.
  Why: operators comparing their node-info.yaml to the docs think their file is wrong.
- The validator-operations page says validators should not expose RPC, while transaction
  forwarding has observers send to the RPC endpoint each validator advertises.
  Why: a validator operator cannot tell whether to advertise an endpoint.
- A devnet-genesis `config.sh` comment still describes `node --observer`.
  Why: the flag is gone from operator setups, and the comment implies otherwise.

## Superseded

This file supersedes the untracked `tasks/followups-public-rpc.md` from the public-RPC sessions.
Every item in that file is already covered above, so none needed a new entry: the wizard Public
card, `--rpc-public` without a domain, the advertised badge and placeholder, the dashboard and
RPC hostname warning, `--move-dashboard-to`, comment matching in `tn_node_inject_flags`,
`confirm()` under bash 3.2, `caddy_swap_in` backups, `apply_recommended_firewall` versus
`caddy_open_ports`, the wss probe timeout in check-node, and the epoch-boundary check in
`caddy_restart_node_guarded`. Details carried over from it: the `ws_listening` key, the
`dashboard.<node-domain>` suggestion, the `caddy_launch_inject_target` guard, the `tr` fix for
`confirm()`, and the note that the wss probe stalls on success, not failure.
