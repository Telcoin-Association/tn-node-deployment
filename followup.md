# Follow-ups

The work still open after the mainnet hardening round of 2026-10-15 (branch
`mainnet-hardening`, script release `scripts-v2.0.0`). That round rewrote the ownership layout,
passphrase delivery, script updates, release installs, the add-ons and the Node Manager UI, and
closed the backlog items those rewrites touched. What is below is what it could not do from this
repo, chose not to change, or found along the way, re-checked against the code at the end of the
round. Each item says what it is, where it lives and what closes it.

U-numbers name the telcoin-network items of the round. Their issues are drafted but not posted
yet; this file gains the issue numbers when they are.

## Release prep

- `lib/allowed_signers` holds only comments, and there is no `RELEASE`, `MANIFEST` or
  `MANIFEST.sig` yet, so the signed updater has nothing to install. Closes at release prep: the
  release signer adds their SSH signing key, signs `MANIFEST` with the hardware key, and pushes the
  `scripts-v2.0.0` tag right after the release merges (a tag without
  `lib/allowed_signers.sha256` cannot bootstrap hosts still on update-scripts 1.1.72 or older).
  From then on, a release that changes `lib/allowed_signers` must be signed by a key that is in
  both the old and the new list.
- Two repository settings are user steps. The `github-pages` environment's deployment policy must
  allow `scripts-v*` tags, or `publish-installer.yml` cannot publish `install.sh`. And
  `.github/CODEOWNERS` names a single owner on every line, including `/RELEASE` and
  `/MANIFEST*`. Closes when the policy allows the tags and a second owner is added.
- The `.sha256` sidecars stay for the transition. update-scripts 2.0.0 still checks a published
  sidecar against the signed manifest and needs one to fetch `lib/allowed_signers` the first
  time; older updaters use the sidecars as their only check. Closes when no host runs
  update-scripts 1.1.72 or older: then drop the sidecars, `tools/gen-checksums.sh` from the
  release steps, and the sidecar reads in `update-scripts.sh` (`fetch_published_sha`,
  `bootstrap_signers`).

## Mainnet launch

- No mainnet image repository is set: `tn_docker_repo_for mainnet` returns nothing
  (`TN_MAINNET_IMAGE_REPO` is empty in `lib/common.sh`), so Docker installs and updates are
  refused on mainnet. Closes when the repository that publishes mainnet images is named and the
  constant is set.
- `MAINNET_GENESIS_SHA256`, `MAINNET_COMMITTEE_SHA256` and `MAINNET_PARAMETERS_SHA256` in
  `lib/common.sh` are empty, so every mainnet install stops at the chain-config check and a
  mainnet release refuses its chain-config lines in `SHA256SUMS`. Closes after the genesis
  ceremony, when the final files are published (U-13) and the three hashes are set.
- The public RPC for chain 487 is not settled. The UI's `NETWORK_PUBLIC_RPC` has an empty list for
  487, so its comparison cards show "-", while `MAINNET_RPC_URL` in `lib/common.sh` is
  `https://rpc.telcoin.network`, which check-node and the restart-window epoch reads use and which
  answers for chain 2017 until launch. Closes at launch: confirm the endpoint answers chain 487 and
  fill the UI list.

## Upstream and maintainer repos

- U-1 and U-2, the credential passphrase source and `--bootstrap-peers-file`: telcoin-network
  branch `credential-passphrase-source`, attested and pushed; the draft PR is not open yet. Until
  a node release carries it, the start script reads the credential and feeds the node with
  `--bls-passphrase-source stdin`, and expands the peer map from
  `/etc/telcoin/bootstrap-peers.yaml` onto the command line. Closes when it ships in a release and
  the start script switches to `--bls-passphrase-source credential` (gated on `--version`) and
  `--bootstrap-peers-file`.
- U-3 and U-5, the chain 487 guard (faucet opt-in, build features in `--version` and the startup
  line, cleartext BLS key refused on 487): branch `mainnet-chain-guard`, attested and pushed; the
  draft PR is not open yet. The devnet deployment runs a faucet image on a chain-487 genesis and
  must set `TN_ALLOW_FAUCET_ON_CHAIN_487=true` before it takes a release with the guard. Closes
  when it merges and the devnet deployment is updated.
- U-4, part of U-6 and the release side of U-12, the release pipeline: telcoin-network PR #694,
  draft. Still open there: the `v*` tag ruleset (a repository setting), a build-provenance
  attestation, a separate devnet image repository with CI-built signed images (the rest of U-6),
  and the node refusing fork-epoch overrides on chains 487 and 2017, plus the release check that
  depends on it (the rest of U-12). The telcoin-network README, SECURITY, validator-operations and
  maintainers pages still describe a release as the tarball and `IMAGE_DIGEST`, without the
  chain-config lines. Closes when #694 merges with the ruleset set and those parts land.
- Node releases publish an x86_64 tarball only. On aarch64 a release install or update stops
  with "Release TAG has no aarch64-unknown-linux-gnu tarball". Closes when the release pipeline
  publishes an aarch64 tarball; the scripts already map the architecture.
- U-7: `--healthcheck.addr` (default `127.0.0.1`) and a health server that serves connections
  concurrently. Open.
- U-8: `keytool verify` and `keytool rewrap`, so a passphrase can be checked and changed without
  regenerating keys. Open.
- U-9: a `tn` RPC method that says whether this node signed in recent rounds. Until it exists,
  update-node's post-update check (`verify_consensus_participation`) infers voting from
  `tn_nodeMode` and an advancing `tn_latestConsensusHeader`. Closes when the method ships and the
  check uses it.
- U-10: a non-dumpable node process, with the key pages locked and excluded from core dumps.
  Open.
- U-11: a remote signer with an equivocation guard. Needs a design proposal first.
- U-13: the final mainnet genesis embedded as `MAINNET_GENESIS`, with its hash logged at INFO
  (the chain 487 guard branch adds the startup line). Waits for the genesis ceremony.
- The operator docs backlog merged upstream as telcoin-network #1573, but README and OPERATOR.md
  still warn that the upstream stake and unstake signatures are out of date. Closes when
  docs.telcoin.network is redeployed from it and the warnings are dropped.
- The versioned docs page for v0.15.0 keeps the old staking and port mistakes; #1573 corrected
  the current docs only.
- tn-contracts' `StakeConfig` comment in `IStakeManager.sol` says `epochDuration` is in L2
  blocks; the node and the registry use seconds.
- The telcoin-network CLI README's keytool `generate` table omits `--rpc-http` and `--rpc-ws`,
  and its `--workers` row says "1-4, must be 1" while the real limit is the on-chain worker count.
- telcoin-network's `etc/compose.yaml` uses UDP 49595 for the worker on its private bridge, and
  the CLI README's Docker row mirrors it on purpose. Informational: it differs from the 49594
  convention only inside the compose network.
- The fleet's `common/config-caddy.sh` (maintainer-only) has a case-sensitive WebSocket matcher,
  so `Connection: upgrade` from Google's load balancer or nginx gets 405; it also has a
  30-second backend timeout, dead CSS in its 405 page and a wrong health-check comment. Fix it in
  the maintainer repo.
- devnet-genesis still picks `setup-observer.sh` and `setup-validator.sh` in `devnet-lib.sh`.
  Closes when it calls `setup-node.sh`; then the shims can leave this repo and the updater.

## Host soak

- The integration matrix waits on a signed node release. `integration.yml` runs the six VM
  assertions under `tools/tests/vm.d/` on an Ubuntu 24.04 runner (ownership migration, the
  signed updater, the rendered unit through `systemd-analyze`, logrotate, the perl lint, the
  firewall reset with sshd hardening); all six run on this tree, and only the firewall one skips
  when ufw or sshd is missing. The full matrix (install methods and networks with a real node
  binary) exists only as a comment in `integration.yml`. Closes when a release artifact exists
  and the job is written.
- The unit sandbox needs a soak on a real host. The binary unit emits `MemoryDenyWriteExecute=yes`
  and the `SystemCallFilter=` lines behind `TN_UNIT_STRICT_SANDBOX` (default `1`; `audit` drops
  `SystemCallErrorNumber=`, `0` drops all of them) and always `ProtectProc=invisible`, which
  needs systemd 247 or later. Closes after a validator has run through epoch changes, an update
  and restarts with the strict set, or the set is turned down in that one place.
- Add-on behaviour to confirm on the same host: the Caddy admin API on its unix socket with
  `systemctl reload caddy`; Alloy's `StateDirectory=` re-owning an older state directory to
  `telcoin-alloy`; and `ufw delete` of a rule that is not there returning 0, which
  `apply_kuma_rule`, `fw_p2p_allow`, `fw_apply_rules` and `json_fw_port` assume (off testnet a
  failed delete is a failed step). Closes when each is confirmed or fixed.
- UI-started updates and setup run under `systemd-run --scope` (the helper's `exec_job`) so a
  source build escapes the UI unit's memory and task caps. Confirm on a real host by watching
  `systemd-cgls` during a source build started from the UI.
- `edit-config.sh --migrate-credential` converts a legacy unit with an inline `docker run` or
  binary command and an embedded passphrase into the current unit and start script. It is
  fixture-tested only; run it once on a real legacy Docker node.
- Before any mainnet host: a testnet rehearsal of the migration path on an existing host, and a
  fresh install on Ubuntu 24.04 from a verified `scripts-v*` tag and a verified node release.

## Add-ons

- firewall-setup writes no `DOCKER-USER` block to `/etc/ufw/after.rules`, so ports Docker
  publishes are not filtered by the ufw rules. Closes when firewall-setup adds the block and the
  fixture tests cover it.
- Without a `--p2p-from` list, `fw_p2p_allow` opens the P2P ports to everyone with plain
  `ufw allow`, with no per-source rate limit. ufw's `limit` keeps one list for all sources, so a
  per-source limit needs nftables beside ufw. Closes with a decision on that and its
  implementation.
- The native Alloy install checks the tarball against the `SHA256SUMS` downloaded from the same
  release (`_obs_install_alloy_tarball`); there are no pinned per-architecture hashes for
  `TN_ALLOY_NATIVE_VERSION`. Closes when the hashes are constants in `lib/observability.sh`.
- `TN_ALLOY_IMAGE` defaults to the tag `grafana/alloy:v1.5.1`, repeated in
  `lib/observability.sh`, `lib/common.sh`, `lib/testnet-addons.env` and `remove-node.sh`.
  Closes when it is pinned by digest in one place.
- The vendored `wg-node-bootstrap.sh` still writes and chowns `~tnadmin/.ssh/authorized_keys.tnvpn`
  as root, a file setup-vpn has retired in favour of `/etc/wgvpn/tnadmin.authorized_keys`.
  setup-vpn refuses to run it while that path or a parent is a symlink
  (`vpn_tnadmin_home_safe`), but the check and the write are separate steps. The bootstrap should
  stop writing the file. The maintainers' `sync-access.sh` and `add-peer.sh` do not add lines to
  `lib/wgvpn/peers/ssh/KEYS`, so a new maintainer key is ignored until someone adds the line by
  hand. Closes in the maintainer repo, then a vendored copy refresh (see "Sync note" in
  `docs/testnet-addons.md`).
- firewall-setup's "Remove a whitelist entry" (`manage_whitelist`) deletes one rule number per
  run and says nothing of the `(v6)` twin ufw creates for `ufw allow <port>/tcp`, so removing the
  blanket SSH rule by hand leaves SSH open over IPv6. Closes when it deletes or offers to delete
  the twin.
- install-caddy and the keytool's `set-rpc` edit worker 0 only (`caddy_edit_node_info`). On a
  node with more workers, rpc-disable leaves workers 1 and up advertising the old URL, and
  nothing warns. Closes when every worker is cleared or warned about, or `set-rpc --worker-id`
  ships in a release.
- Per-IP rate limiting for the public RPC is deliberately not automated: the RPC block caps
  request bodies at 2 MB with stock Caddy, and per-IP limits need a custom Caddy build or a proxy
  in front.
- The 2 MB `request_body` cap in `write_rpc_block` cuts an oversized POST only after reth has
  received the headers and the first 2 MB. A Content-Length matcher answering 413 before
  `reverse_proxy` would stop requests that declare their length.
- The RPC block's `Access-Control-Allow-Methods` lists GET, which always gets the 405 page.
  Cosmetic; drop GET from both headers.
- `do_rpc_enable` always re-renders the RPC block, so a hand edit inside a block stamped
  `# tn-rpc block v2` is replaced on the next rpc-enable, and only the newest five
  `Caddyfile.bak.<ts>` backups keep it. Closes when the live block is compared with a fresh
  render and a difference warns or refuses.
- The 405 landing page is written from the plan before `caddy_ws_inject` runs, so when the `--ws`
  launch edit fails the page still mentions `wss://` until the next rpc-enable. Closes when the
  page is re-rendered after a failed edit.
- `_obs_has_metrics` in `lib/observability.sh` checks only that `--metrics` is present, not that
  its address matches `obs_metrics_addr`, so Alloy can scrape a port the node does not serve.
- `obs_enable` re-renders and restarts Alloy before the real launch-flag write; if that write
  fails after a passing dry run, Alloy runs a pipeline the node does not feed and `.node-meta`
  keeps the old `ENABLE_*` values. Accepted for now; closes when Alloy is rolled back on that
  failure.

## UI

- The Jaeger image is `jaegertracing/all-in-one:latest` (`JAEGER_IMAGE` in
  `ui/telcoin-ui-helper.sh`). Closes when it is pinned by digest.
- The log download for an external node (`api_logs_download` in `ui/server.py`) collects the
  whole output in memory before sending it, bounded only by the 200000-line cap and the unit's
  `MemoryMax`. Closes when it streams.
- install-ui's one-time move of `node-role.json` checks the old copy under `/opt/telcoin-ui`, then
  root installs it, and that old path may belong to the UI account. Closes when the copy is read as
  the UI account.
- The read-only public path is not bound to the dashboard's host name: `is_public_request` only
  checks that the `X-TN-Dashboard-Public` header is present, so any local process can read the
  eight public routes (none reaches sudo). Closes when the path is tied to the dashboard Host.
- `ui/server.py`'s refusal to bind off loopback still says "This UI has no auth of its own",
  although the UI now has a per-install token. Closes when the message is reworded.
- The Config tab's credential migration and re-seal cannot pass `--allow-no-tpm`, so on a mainnet
  host without a TPM2 they are refused and the operator runs `edit-config.sh` on the server.
  Closes when the Config tab offers the flag the way the setup wizard does.
- The System tab's firewall form takes an SSH source list only; it has no field for
  `--p2p-from`, `--ssh-anywhere` or `--p2p-anywhere`. Closes when the form offers them.
- `ui/server.py` keeps its own front-line copies of rules the library and helper also enforce
  (`passphrase_ok`, `image_allowed`, `release_tag_ok`). They have to change together
  with the library. Closes when the server asks the helper instead, or a test compares the
  copies.
- A wizard keygen that fails after `.node-meta` is written cannot be retried: the helper refuses
  with "a node install already started", finalize is offered only after a successful keygen, and
  the way out is `remove-node.sh` over SSH. The wizard's Back button also stays live after keygen
  and offers Generate Keys again. Closes when the wizard offers resume or removal.
- Restarts from the UI skip the epoch wait and the quorum guard: `api_service` runs
  `systemctl start|stop|restart` directly, and the tracing toggles and hostname change restart
  with `--no-block`. The quorum badge on the update panel is display only. Updates and config
  saves do run both checks through update-node and edit-config. Closes when UI restarts go through
  the same wait and guard.
- The Config tab offers `docker_image` as an editable field for Docker installs, which the
  server's `CONFIG_FIELDS` and the helper both refuse. Closes when the field is read-only there.
- An action stops when the operator closes the browser or leaves the Update or Config tab: the
  server terminates the script two seconds after the stream ends, and an update, config save,
  setup, rpc-enable or rpc-disable can sit in the epoch wait for up to 30 minutes. The Update tab
  still promises "brief downtime" with no notice to keep the tab open. Closes when the child is
  handed to a reaper that drains its output, the notice is added, and update-node is shown to be
  consistent when terminated mid-wait.
- The Update tab's status card ignores `storage_migration` from `update-node.sh --json --check`,
  and Apply asks no snapshot question; the one-way warning appears in the apply log only after
  Apply is pressed. After a one-way restart the health check (up to 600 s) and the vote check (up
  to `TN_UPDATE_VOTE_TIMEOUT`, 600 s) widen the window in which leaving the tab cuts the apply
  off. Closes when the card shows it, Apply asks for a snapshot confirmation, and a terminated
  one-way apply has been checked.
- The UI cannot skip the epoch wait for an update or a config save: the helper's arguments are
  fixed and sudo resets the environment, so neither `--no-epoch-wait` nor `TN_SKIP_EPOCH_WAIT`
  gets through. Closes with a validated helper flag and a checkbox.
- The firewall card's three toggles act on 49590, 49594 and 43174 even when the node listens
  elsewhere. The Config tab has no inputs for `bootstrap_peers`, `state_export`,
  `allow_private_forward_targets` or `metrics=off`, the config API does not report them, and the
  wizard sends none of the three node flags, although the helper and server accept the fields.
- The wizard's completion card ignores finalize's `operator_guide` field, so it links no runbook.
- The helper never passes `--binary-path`, so a wizard `existing` install depends on keygen
  finding the binary on PATH or under `/usr/local/bin`, `/opt` or `/home`.
- When the wizard's public RPC hostname already serves the dashboard, setup only warns, because
  setup-node has no `--move-dashboard-to`; public RPC stays pending until the System tab moves the
  dashboard.
- install-ui reads "Start the UI now?" and "Enable the UI on boot?" only from a terminal and
  otherwise answers yes, so piped answers are ignored.
- When a script that sends its own JSON `error` fails, the server adds its stderr tail as a second
  `error` (install-caddy's `die` triggers it). Closes when the tail is skipped after a child error.
- After a successful RPC enable, disable or withdraw, the card re-renders and the stream log, with
  any warnings in it, disappears.
- The Network tab links `https://status.adiri.telcoin.network/`, while the server's
  `STATUS_PAGE_BASE` and the page's other link use `https://status.telscan.xyz`. One is wrong.
- The live log tail sends bare `data:` lines and keepalives with no end event, and the page leaves
  the LIVE badge on when the stream drops. Closes with an end event the page reacts to.
- `/api/addons/status` still returns 400 without `?node_type=`, which the helper no longer uses.
- The "Refresh Caddy block" button re-runs rpc-enable without an inbound IP, and install-caddy
  does not record a `--public-ip` override, so on a 1:1-NAT host the refresh's DNS check can fail.
- The UI's `bootstrap_peers` setting accepts any absolute path, `..` included (pattern
  `^(none|/[A-Za-z0-9._/-]+)$` in the helper and server), and edit-config's `set_bootstrap_peers`
  gives different messages for missing and unreadable files, so a UI user can probe which paths
  exist on the host. Closes when only files in one directory are accepted and `..` is refused.

## Scripts

### setup-node

- The deprecated shims `setup-validator.sh` and `setup-observer.sh` still run `dirname` with the
  inherited environment, `TN_BLS_PASSPHRASE` included, before they forward to `setup-node.sh`.
  Closes when the shims are removed (after devnet-genesis moves off them) or unset the variable
  first.
- `json_refuse_installed` checks only `telcoin.service`, not the legacy `telcoin-validator` or
  `telcoin-observer` units. Closes when it checks every node unit name.
- `finalize_install_inputs` compares `--data-dir` with the keygen value only when it is not the
  default, so a finalize that leaves the flag out on a non-default keygen is not caught there.
- A `--json` keygen does not record `NETWORK` or the two listener addresses in `.node-meta`; only
  finalize writes them, and finalize stops with "finalize needs --listener-primary and
  --listener-worker" when the flags are missing. Closes when keygen records them and finalize reads
  them back, as it already does for bootstrap peers and state export.
- Answering Yes to "Overwrite existing keys?" always ends "Key generation failed", because the
  keytool refuses a non-empty `node-keys/` and setup-node passes no `--force`. Closes when the old
  `node-keys/` and `node-info.yaml` are moved aside as the service account first.
- A `--json` finalize cannot undo the bootstrap-peers or state-export choices made at keygen:
  there is no `--bootstrap-peers none` and no `--no-state-export`.
- The warning that `--binary-path` is used only with `--install-method existing` is printed before
  the welcome screen clears the terminal. Closes when it goes through `NODE_FLAG_WARNINGS`.
- Source builds now build in `/var/lib/tn-build/target`; a host that built from source before keeps
  the old root-owned `/opt/telcoin-source/target`, which nothing removes short of remove-node.
  Closes when update-node or a changelog step removes it.
- A source build's `--version` check looks at the "Build Features" line only; tags made with the
  pre-release tooling report version 0.1.0, so the version is not compared. Closes when release
  builds report their tag.

### edit-config

- edit-config's `bootstrap_peers` and `state_export` edits change the launch line but leave
  `BOOTSTRAP_PEERS_FILE` and `STATE_EXPORT` in `.node-meta` as setup-node wrote them.
- "Refresh chain configs" (`refresh_chain_configs`) still runs `git pull` in `/opt/telcoin-source`
  on testnet and devnet, which fails on the detached checkout of a release tag, and refuses when
  `.node-meta` has no `NETWORK` although the genesis chain id would tell it. Mainnet never pulls.
  Closes when it checks out only the chain-config path at the pinned tag and takes the network
  from the genesis.
- "Refresh chain configs" copies the new genesis, committee and parameters files without backups,
  so a run stopped during its epoch wait keeps them for the next restart. By design: they are the
  files the network restart needs.
- A signal during the epoch wait now ends the wait at once, but one during an epoch RPC read, a
  Docker pull or the parse check takes effect only when that command returns, and the comment near
  the end of `edit-config.sh` still says one poll interval. Closes when those commands run in the
  background the way the wait does.
- A signal after `--migrate-credential` has restarted the node keeps the previous passphrase files
  (root only, under `/var/backups/telcoin`) until the command runs again; the exit message says so.
  Closes if the next root script run shreds them.
- Menu prompts such as the P2P port and Docker image edits use bare `read` under `set -e`, so end
  of input ends the script instead of returning to the menu.
- The menu's Docker image edit (`edit_docker_image`) pulls the image before any launch-file check;
  the refusal comes after the download. `--set docker_image=` checks first.

### update-node

- The image swap backs up the unit and `node.env` (`swap_backup_extras`) in shell variables only,
  not in the pending state, so a run killed during a swap leaves a later `--discard` with nothing to
  restore for them. Closes when they become pending-state keys.
- An interactive prepare prints "Run this script again when you are ready to apply." and exits 0
  even when the prepare failed, a refused tag included.
- A one-way apply killed after its restart leaves the pending state and the old version marker. A
  second apply backs up the binary installed now, already the new release, and overwrites
  `BIN_BACKUP`, so the undo a later failure prints restores the new binary; the old one is only in
  the earlier copy under `/var/backups/telcoin`. Closes when a backup whose hash differs from the
  built binary is kept, or the message says so.
- An interactive "Prepare only" says nothing about a one-way update; the warning comes at apply.
  `--json --prepare` already warns.
- No script runs `telcoin-network db migrate` (v0.16.0-adiri) between the stop and the first start,
  so a slow migration has to fit the 600-second health window of a one-way apply. Not tried.

### remove-node and migrate-node-naming

- When remove-node finds no node unit, the leftovers path never offers to remove the Node Manager
  UI, and `--json` stops with "no node installed" before honouring `--remove-ui` when nothing else
  is left, so the UI service, its root helper and its sudoers file stay behind.
- On a host with both a legacy unit and the unified layout, `config_dir_for_unit` ignores the unit
  and returns the unified config dir, so the legacy unit's container and account are left behind;
  the menu has no entry for removing one of several nodes.
- migrate-node-naming does not call `tn_migrate_ownership`; the entries it moves keep their owners
  until the next update-node or edit-config run converts them.
- migrate-node-naming opens 49590 and 49594 (`open_consensus_ports`) instead of the node's own
  P2P ports.
- Nodes migrated by migrate-node-naming 1.2.0 keep `NODE_TYPE=observer` in `.node-meta`; nothing
  reads it and nothing but setup-node removes it.

### check-node

- check-node keeps its state between runs in `${TMPDIR:-/tmp}/check-node.state`, so concurrent runs
  overwrite each other and, under sudo, another local account can create the file first (the values
  are checked to be digits). Closes with a root-owned or per-user state path written atomically.
- `check_update_lock` reads `/proc/locks`; inside a container that file hides a lock whose holder
  has exited, so the check can miss it there. The test keeps a live holder for that reason.
- check-node shows the bootstrap-peers map only as information. It should fail when the start
  script reads the map from `/etc/telcoin/bootstrap-peers.yaml` and that file is missing or empty,
  since the node then refuses to start.
- An explicit `--http.api` or `--ws.api` list without `tn` drops the `tn_*` methods that
  update-node, check-node and the UI read; `risky_api_modules` warns about `debug`, `trace` and
  `admin` but not a missing `tn`.
- Nothing provisions a second worker. check-node reports a node with fewer workers than the
  on-chain count, and `node.env` holds one primary and one worker listener. Closes with a node
  release that allows more workers, a listener per worker and a keytool command that adds one.
- The wss probe's limit for a silent server is 15 polls of `sleep 0.1`; `read -t 0.1` would be
  tighter but needs bash 4. Accepted.

### prepare-stake

- `--rotate-address` cannot read the passphrase from `/etc/telcoin/bls-passphrase.cred`:
  `ps_get_passphrase` takes only `TN_BLS_PASSPHRASE`, a plaintext file or the prompt, and credential
  installs keep no plaintext file. Closes when it decrypts the credential with `systemd-creds`, as
  `edit-config.sh --reseal` does.
- A short balance in the `stake()` simulation is recognised by reth's "insufficient funds" text only;
  other simulation errors warn. The separate balance check covers it unless that read fails.

### update-scripts

- `update-scripts.sh` sources `lib/fallback.sh` at top level, so under bash 3.2 with `set -e` a copy
  that is present but broken stops the updater before it can repair it. Only the restart hint needs
  it.
- update-scripts needs curl and reports a missing curl as a connection failure, while `install.sh`
  accepts wget.

### Library

- The update lock falls back to a `mkdir` lock at `${TMPDIR:-/tmp}/telcoin-update.lock.d` when
  `/run` is missing (stock macOS), which any account can create. Dev hosts only; check-node does not
  look there.
- `_tn_release_sig_ok` refuses a release when any signature on `SHA256SUMS.asc` reports
  `NO_PUBKEY` or `ERRSIG`, even with a good signature from an allowed key, while tag checks accept an
  unknown second signer. Decide whether a second, unknown signer should refuse a release.
- `tn_as_service_user` ends with a bare `return` after `setpriv` and `runuser`; it returns the
  command's status anyway, but `return $?` would say so.
- Delete the deprecated `tn_resolve_node_type` stub in `lib/fallback.sh` (no callers remain) once the
  release carrying firewall-setup 1.6.0 has reached operators.
- `check_ports` pipes `ss` into `grep -qE` under pipefail, so a busy port can read as free when `ss`
  dies of SIGPIPE. Capture the output first, as `ufw_active` does.
- `validate_port` accepts leading zeros (`0101` passes as octal 65). `^[1-9][0-9]{0,4}$` is stricter.
- Five progress printers for `tn_wait_restart_window` (`update_wait_say`, `edit_wait_say`,
  `caddy_wait_say`, `addons_say` and `obs_wait_say` in `lib/observability.sh`) repeat the same JSON
  branching; the library's default `_tn_wait_say` has no JSON mode. One shared printer would do.
- `prompt_testnet_addons` takes the region label without checking it; setup-node trims it afterwards
  with a warning.
- `tn_node_parse_check` probes with `--help`, so clap's "requires" rules never run and
  `--state-export-keep` passes without `--enable-state-export`; callers pair the flags themselves.
- `tn_rpc_call` drops a JSON-RPC error's `data`, so prepare-stake keeps its own `ps_rpc_raw` to
  decode registry reverts.
- `tn_keytool` passes `-q`, which hides keytool's WARN lines, and the launch-line parser
  `_tn_launch_awk` reads a heredoc inside a start script as flags.
- `print_validator_onchain_status` tells an address with no record to call `stake()` by hand instead
  of naming `prepare-stake.sh`.
- `tn_sync_submodules` hands the update-lock descriptor to `git submodule`; add `9>&-`.
- `lib/common.sh` and `ui/server.py` decode `getValidator` words 5 and 6 as `stakeVersion` and
  `region` (tn-contracts 10cc12b7). Live testnet replies have zero in both, so the deployed layout is
  unconfirmed until a validator with a non-zero value is checked.

## Tooling and docs

- `tools/tests/root_write_pipe_test.sh` keeps an allow-list of credential writers that no longer
  pipe into a root writer, and its header still names `step_generate_keys`. Drop the list so the
  test is strict.
- `check_has` and `check_lacks` in `tools/tests/lib.sh` pipe into `grep -q` with pipefail on, so on a
  large text under bash 3.2 `check_has` can fail and `check_lacks` can pass by mistake. Use
  `grep -qxF -- "$2" <<<"$3"`.
- `tools/check-bash32.sh` misses `read -N`, `shopt -s globstar`, `{1..10..2}`, `local -`,
  `declare -I`, `unset 'a[-1]'`, `$'\u...'` and a redirection before `declare`, and a `# bash32-ok`
  inside a string also hides its line.
- The same lint trips on valid code: an array literal containing the word `mapfile`, a case arm such
  as `a)#it's`, and a heredoc opened on a line whose quote spans lines.
- CI has no test of the page's JavaScript or a browser walk-through, and runs neither
  `ui/tests/install_ui_test.sh` nor `ui/tests/open_ui_test.sh`.
- `shellcheck -x --severity=warning` reports 175 warnings in 46 files, 136 of them in
  `tools/tests/`. Outside the tests: 29 SC2034, 4 SC2206, 3 SC2178/SC2128 in firewall-setup, one
  SC2155, and 2 SC2115 in remove-node (`rm -rf "/home/${user}"` without `${var:?}`). The CI step is
  advisory. Closes when they are cleared or annotated and the step blocks.
- `tools/build-partner-pdf.sh` skips its forbidden-text check on the PDF when `pdftotext` is
  missing. Install poppler on the build machine or make the skip loud.
- In `docs/partner/theme.css`, `td code { overflow-wrap: break-word }` lets inline code in a table
  break after a leading `--`. Cosmetic.
- `--help` gaps. `setup-node.sh --help` omits `--network`, `--binary-path`, `--docker-image`,
  `--address`, the `--external-*` and `--listener-*` flags, `--data-dir`, `--advertised-name`,
  `--service-user`, `--service-group`, `--genesis-dir` and `--enable-healthcheck-monitor`;
  `update-node.sh --help` omits `--json`, `--check`, `--prepare`, `--ref`, `--apply` and `--yes`.
  install-caddy, firewall-setup, setup-observability and remove-node answer `--help` with "must be
  run as root".
- The `format-output` layout rules (one sentence per line among them) have not been applied to
  README.md or OPERATOR.md.
- The "Public node tuning" values in README are labelled unmeasured; measure them on a busy public
  RPC node.
- OPERATOR.md says the largest legitimate JSON-RPC request is about 256 KiB, which nobody has
  verified. Verify it or soften the sentence.
- OPERATOR.md keeps the hidden anchor `64-export-the-stake-calldata-on-the-node`; README's link to
  "Stake by hand" has shipped and nothing else links to it, so it can go.
