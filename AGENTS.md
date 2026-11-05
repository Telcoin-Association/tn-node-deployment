# AGENTS.md

Orientation for AI agents and human maintainers working in this repository. This
file is documentation only. It is not shipped to nodes and is not tracked by the
updater, so it has no `.sha256` sidecar and must not be added to `update-scripts.sh`.

## What this repo is

`tn-node-deployment` is the **public, standalone operator repo**
(`github.com/Telcoin-Association/tn-node-deployment`). Node operators clone it and
run it **alone**. They do not have the maintainer's `devnet-genesis/` checkout or
its `common/` submodule.

That `common/` submodule — `config-caddy.sh`, `dns.sh`, `ops-agent-install.sh`, the
WireGuard hub, the observability backend, the GCP plumbing — is **maintainer-only**
and is **never shipped to operators**. None of it exists on an operator box. Assume
any path under `common/` or `devnet-genesis/` is absent at runtime for a real operator.

`OPERATOR.md` at the repo root is the operator runbook; `README.md` is the reference.
The partner documents are the guide for mobile network operators
(`docs/partner/mno-node-guide/mno-node-guide.md`) and the Telcoin Network Technical
Specification (`docs/partner/technical-specification/technical-specification.md`), each the
source of the branded PDF beside it. When a change alters operator-visible behaviour (flags,
prompts, paths, ports), update `OPERATOR.md`, the README and the partner guide together, then
rebuild the PDF (see "Partner documents" below).

## The boundary rule

Operator-facing scripts must **not** depend on any `common/` script at runtime. That
covers:

`setup-node.sh`, `edit-config.sh`, `prepare-stake.sh`, `migrate-node-naming.sh`,
`check-node.sh`, `update-node.sh`, `update-scripts.sh`, `firewall-setup.sh`, `setup-vpn.sh`,
`setup-observability.sh`, `setup-alerts.sh`, `install-caddy.sh`, `remove-node.sh`, `install.sh`,
`open-ui.sh` (it runs on the operator's own computer), the deprecated `setup-observer.sh` and
`setup-validator.sh` shims, and everything under `lib/` and `ui/`.

A comment in one of these may *mention* a `common/` script for provenance, but only
if it is clearly marked maintainer-only. A runtime call, a `source`, or a "now run X"
instruction that points at `common/` is a bug: the operator does not have that file.

**Future agents — do NOT "fix" a `config-caddy.sh` comment by adding an operator
dependency on it.** On an operator box the public RPC proxy is repointed with
`install-caddy.sh` (in this repo). The maintainer fleet path
(`devnet-genesis/tasks/migrate-fleet-staggered.sh` → `common/config-caddy.sh`)
already works and is out of scope for this repo. Leave those as provenance comments.

## Node role

The node binary has no `--observer` flag any more. It was removed upstream in
telcoin-network: v0.15.0-adiri accepts it as a hidden no-op, and v0.16.0-adiri rejects it
when it parses its arguments (`unexpected argument '--observer'`, exit status 2).
Role is derived each epoch from committee membership. Scripts decide the validator view
from the on-chain stake status (`getValidator` status Staked / PendingActivation / Active /
PendingExit) via `node_stake_status` / `node_is_staked_validator` in `lib/common.sh`.
Never add `--observer` / `--validator` behaviour back, and never emit `--observer` to the
binary. `update-node.sh` strips a leftover `--observer` from legacy launch files when
updating to v0.15.0-adiri or later.

The Node Manager UI asks the network first: it reads the node's `getValidator` record from the
network's public RPC (only from an endpoint whose `eth_chainId` matches the node's chain), then
from the node itself once it is synced, then from its last saved answer, and shows a full node
when none of them answers. `.node-meta` no longer carries `NODE_TYPE`: setup-node v1.3.0 and
migrate-node-naming v1.2.1 remove the key (a node migrated by 1.2.0 may keep a stale line), and
nothing reads it to choose a view. Do not write it back. `tn_resolve_node_type` in
`lib/fallback.sh` has no callers and stays one more release only as a deprecated stub; do not
add callers.

## The mainnet switch

`readonly TN_MAINNET_ENABLED=0` in `lib/common.sh` keeps mainnet out of every setup path:
option 2 of the interactive network menu (`select_network`), `--network mainnet` in a
setup-node `--json` run, and a Node Manager UI setup on mainnet (the helper asks
`tn_mainnet_enabled`, and an older library without that function refuses too). Each refuses
before anything on the host changes. `ui/server.py` `TN_MAINNET_ENABLED` and
`ui/static/index.html` `const SETUP_MAINNET_ENABLED` mirror it, and `ui/test_mainnet_flag.py`
fails unless the three agree. The launch release flips all three in one change, together with
the mainnet chain-config pins (`tn_chain_config_pin`) and `MIN_SOURCE_VERSION_MAINNET`.

Each network has its own image package, and the channel follows the release tag: mainnet
`ghcr.io/telcoin-association/tn-mainnet` (`TN_MAINNET_IMAGE_REPO`, tags `vX.Y.Z`), testnet
`ghcr.io/telcoin-association/tn-testnet` (`TN_TESTNET_IMAGE_REPO`, tags `vX.Y.Z-adiri`), and
every stage derives the package from the network again (`tn_docker_repo_for`). Testnet also
takes the legacy Artifact Registry repository; devnet pulls by digest from that repository or
from `ghcr.io/telcoin-association/tn-dev` (`TN_DEV_IMAGE_REPO`, the node team's dev images).
The old single package `ghcr.io/telcoin-association/telcoin-network`
(`TN_GHCR_LEGACY_IMAGE_REPO`) never held a release: it stays in the testnet and devnet lists
only so a running container is recognised (remove-node, the status screens), and every new
pull refuses it on every network (`tn_docker_pull_repo_ok`, `tn_docker_pull_repos_for`; the UI
twins are `docker_pull_repo_ok` and `pull_image_allowed`). A signed release's `IMAGE_DIGEST`
must name a repository a new pull for the network takes (on mainnet exactly `tn-mainnet`), or
the release is refused. On mainnet an image is still named by its release tag and the digest
comes from the signed release: `tn_docker_resolve_ref` refuses a bare digest on mainnet unless
`.node-meta` records it as the image of a mainnet release (`DOCKER_IMAGE_DIGEST` with a mainnet
`RELEASE_TAG`), and setup-node's `--docker-image` and image prompt apply the same rule. That
rule is defence in depth: only the signed release says which digest of `tn-mainnet` is a
release image. After the pull and the digest check, and before any container starts or any
launch file or `.node-meta` line names the image, `tn_docker_image_network_ok` runs the image's
`/usr/local/bin/telcoin --version` once (no network, no capabilities, read-only, `--init`; under
`timeout -k 5 60` where coreutils `timeout` exists, else with no limit; on rc 124 or 137 it runs
`docker rm -f` on the named container and refuses) and judges its one `Build Features:` line:
none on mainnet, `adiri` on testnet (`faucet` allowed, nothing else); devnet images are not
checked. setup-node (keygen's preflight, and finalize for the recorded image or the one its
`--release-tag` or `--docker-image` override names), update-node's Docker prepare and
edit-config's image change stop on a refusal, in `--json` mode with an error event and then
`done`. A changed image is recorded in `.node-meta` in one order everywhere (finalize's
override, update-node, edit-config): the old `RELEASE_TAG` removed, `DOCKER_IMAGE` and
`DOCKER_IMAGE_DIGEST` written, the new `RELEASE_TAG` last, so a run stopped half way never
pairs a new digest with the old release. The UI's `DOCKER_REPO` and the library's `tn_docker_repo_for` must agree, and
`ui/test_csrf.py` pins that. The release floor
(`tn_ref_min_check`, `MIN_SOURCE_VERSION_<NETWORK>`) applies to setup-node, to every update-node
prepare path and to edit-config's Docker image change; new code that picks a node release
calls it too.

## Ownership: root owns the install

On a node host the service account (`telcoin` by default) owns one tree: the data dir
(`/var/lib/telcoin`, 0700). Everything else the scripts install belongs to root: the install
and config dirs (`/opt/telcoin`, `/etc/telcoin`, root 0755), `.node-meta` (root 0600),
`node.env` (0644), the passphrase files, the start scripts under `/usr/local/libexec/telcoin`,
the node binary and every directory above it, the log dir (`/var/log/telcoin`,
root:telcoin-log 0750), `/var/backups/telcoin`, `/var/lib/telcoin-staging` and the update lock
under `/run/telcoin`. One more tree is not root's: the state dir of the private alerts runner
(`/var/lib/private/telcoin-heartbeat`, 0700), which systemd creates for the heartbeat service's
dynamic user (`DynamicUser=yes`, `StateDirectory=telcoin-heartbeat`). Only the runner writes in
it; the teardown removes it with `systemctl clean --what=state` (see "Private alerts").
`.node-meta` records the layout as `OWNERSHIP_LAYOUT=2`, `check-node.sh`
checks the owners and modes (`check_ownership_layout`), and the README has the full table.
Code that runs as root keeps it that way:

- Write a root-owned file only through the primitives in `lib/common.sh`, or the writers built
  on them (`meta_set`, `tn_write_node_env`, `tn_write_start_script`, `tn_write_node_unit`,
  `tn_store_credential`): `tn_write_root_file` (a temp file in the destination's directory,
  owner and mode set, then one rename), `tn_install_root_binary`, `tn_backup_file` and
  `tn_restore_backup` (copies under `/var/backups/telcoin`, restored only while the hash still
  matches), and `create_directories` for the layout itself. They refuse a destination whose
  directory fails `tn_root_dir_ok` (every directory up to `/` real, root-owned and not writable
  by other accounts). Do not write a root file with your own `>`, `cp`, `sed -i` or `mv`.
- Write inside the data dir as the service user, through `tn_as_service_user` (setpriv or
  runuser, no supplementary groups), never as root.
- Never `chown -R`. `create_directories` sets the owner and mode of each directory it makes
  with `install -d`, and `tn_migrate_ownership` re-owns an older install one entry at a time
  (`chown -h`, parents first). The one recursive chown, in `ui/install-ui.sh`, runs on the temp
  tree that script has just built, before it renames the tree into place.
- Every script that writes `.node-meta` on an existing install takes the update lock and runs
  `tn_migrate_ownership` before its first write, because `meta_set` and `meta_unset` refuse on
  a host still laid out by an older release. setup-node (on a re-run), update-node, edit-config
  and prepare-stake call it right after they take the lock; install-caddy, firewall-setup,
  setup-vpn, setup-observability and setup-alerts go through `addon_meta_write_begin`. A
  teardown or a read that must also work on the old layout takes the lock alone
  (`addon_meta_lock`). On mainnet the migration refuses with rc 3: a mainnet host on the old
  layout is installed fresh.
- Feed a root writer (`tn_write_root_file`, `write_pending_state`, `_tn_meta_write`) from a
  here-string, a here-document or a file, never from a pipe. The right-hand side of a pipe runs
  in a forked subshell that can outlive the script and finish its write after the update lock
  is released. `tools/tests/root_write_pipe_test.sh` fails on a pipe into any of the three.
  The writers of the passphrase file and the credential are the exception to the here-string
  rule: they read from a process substitution run in the main shell
  (`< <(trap - ERR; printf '%s\n' "$TN_CRED_PASS")`), because bash before 5.1 keeps the text of
  a here-string in a temporary file, which would put the passphrase on disk.
- A script that owns its EXIT trap calls `tn_remove_inflight_tmp` from it, so an interrupted
  write leaves no temp file behind (`TN_INFLIGHT_TMP` names it until the rename).
- On a host with `HOST_BASELINE=true` in `.node-meta` (`setup-node.sh --host-baseline`), the
  AIDE database `/var/lib/aide/telcoin-node.db` (config `/etc/aide/telcoin-node.conf`) hashes
  `/opt/telcoin`, `/usr/local/libexec/telcoin`, `/etc/telcoin` and the node unit. A script that
  changes one of them calls `tn_host_baseline_refresh <say-fn>` once its change went through,
  before it releases the update lock, as update-node, edit-config and the five add-ons do
  (guarded with `declare -F` in the add-ons, which run against older libraries). It is a no-op
  without the marker and only ever warns. Files that change on their own schedule stay out of
  the AIDE config: `bls-passphrase`, `bls-passphrase.cred`, `alloy/ingest-token` and the
  writers' `.tn.*` temp files. The Alloy ingest token is root:telcoin-alloy 0640 in
  `/etc/telcoin/alloy/ingest-token`, written with `tn_write_root_file`, and never goes into an
  environment file, a unit or argv.

## The BLS key passphrase

The node reads its BLS key passphrase on standard input (`--bls-passphrase-source stdin`). The
start script feeds it from `$CREDENTIALS_DIRECTORY/bls-passphrase`, which systemd fills from the
encrypted credential `/etc/telcoin/bls-passphrase.cred` (`PASSPHRASE_METHOD=credential`,
`LoadCredentialEncrypted=`) or, in the interim form, from the root 0600 file
`/etc/telcoin/bls-passphrase` (`PASSPHRASE_METHOD=stdin`, `LoadCredential=`). setup-node takes
the passphrase on standard input with `--passphrase-stdin`, or from `TN_BLS_PASSPHRASE`, which
it copies and unsets before anything else runs. On mainnet the credential is sealed with the
TPM (`host+tpm2`) unless the operator passes `--allow-no-tpm`, and the host needs systemd 255
(`TN_MAINNET_MIN_SYSTEMD`). The old TPM-unseal method is gone: `PASSPHRASE_METHOD=tpm` is
refused with a pointer to `edit-config.sh --migrate-credential`. Do not bring it back.

Rules for code that handles the passphrase:

- It never goes on a command line, never into a unit `Environment=` line, and is never
  exported. The units carry `UnsetEnvironment=TN_BLS_PASSPHRASE`, and `tn_as_service_user`
  removes that variable from what it runs.
- The scripts hold it in plain shell variables: `TN_SETUP_PASS` (setup-node),
  `TN_KEYTOOL_PASS` (the input of `tn_keytool`) and `TN_CRED_PASS` (the credential writers).
  Set `TN_KEYTOOL_PASS` with a plain assignment, not as a prefix of the call
  (`TN_KEYTOOL_PASS=x tn_keytool ...` exports it to that call); `tn_keytool` returns 4 when it
  is exported. The value reaches another process only on that process's standard input,
  written by the `printf` builtin: keytool (`--bls-passphrase-source stdin`),
  `systemd-creds encrypt`, or `tn_write_root_file` for the root 0600 file.
- No script prints it. The passphrase-print lint enforces that (see "Lints").

## Restarts and the epoch boundary

A committee node restarted just before an epoch boundary can miss the epoch transition.
`tn_wait_restart_window` in `lib/common.sh` holds the restart of a node that votes in the
current committee (`tn_nodeMode` `CvvActive`): when the boundary is within `TN_EPOCH_MARGIN`
seconds, it waits for the epoch to close and then `TN_EPOCH_SETTLE` seconds, never longer than
`TN_EPOCH_WAIT_MAX` (1800; 0 turns the wait off). `TN_SKIP_EPOCH_WAIT=1`, and
`--no-epoch-wait` where a script offers it, skip the wait.

Margin and settle follow the epoch length (`epochDuration` of `tn_getCurrentEpochInfo`, read
with the boundary): margin is epochDuration / 72 held to 300-900 s, settle epochDuration / 240
held to 90-300 s (`_tn_epoch_timing`, integer division). The 6 h epoch of mainnet and testnet
gives 300 and 90, a 12 h epoch 600 and 180, a 7-day epoch 900 and 300. A whole number of seconds
in `TN_EPOCH_MARGIN` or `TN_EPOCH_SETTLE` is used as given and never clamped. The messages end
with one sentence naming the values and where they came from ("Margin 300s and settle 90s,
derived from a 21600 s epoch."). A `TN_EPOCH_WAIT_MAX` set in the environment is kept as set,
never raised: when it is shorter than margin + settle + two polls (`TN_EPOCH_POLL`, 15, held to
5-20), the script warns that the restart may land before the epoch has settled and suggests a
larger cap or `TN_SKIP_EPOCH_WAIT=1`. The default 1800 covers the largest derived sum, 1240.
Mainnet's epoch is 6 h, equal to telcoin-network's `MAINNET_EPOCH_DURATION_SECS` (#49), so the
shares and clamps stand. Each network's epoch length is a constant at the top of `lib/common.sh`
(`MAINNET_EPOCH_DURATION` and `TESTNET_EPOCH_DURATION`, 21600; `DEVNET_EPOCH_DURATION` empty,
since no devnet genesis is kept here), read through `tn_network_epoch_duration`.

A node whose mode cannot be read still waits when it is staked (or, on mainnet or an unknown
network, when its stake cannot be read either). When the boundary cannot be read from the node
or from the network's public RPC, it waits `TN_EPOCH_MARGIN` + `TN_EPOCH_SETTLE` seconds, capped
by `TN_EPOCH_WAIT_MAX`. Unless set, both derive the same way from the epoch constant of the
network `tn_detect_network` reports (300 + 90 on mainnet and testnet), and are the fixed 300 +
90 when there is none (devnet, or a network that cannot be told), so changing a constant moves
the blind wait with it. Its warning ends with the source of each value ("Margin 300s and settle
90s (network default: epoch 21600 s)."). A `CvvActive` node whose epoch answer cannot be read
continues without a wait.

Stopping a committee member can also cost the committee its quorum. `tn_committee_down_guard`
counts the members that authored no header in the latest consensus commit (a slow member
counts as down) and refuses (rc 1) when stopping this node would leave f + 1 of the n members
down, with f = floor((n - 1) / 3). When it cannot make the count, it refuses (rc 2) on a
mainnet node that is not known to be unstaked and on an unknown network; testnet, devnet and
an unstaked mainnet node only get a warning. `--allow-quorum-risk` (`TN_ALLOW_QUORUM_RISK=1`)
turns both refusals into a warning, for a restart the fleet coordinator has checked.

update-node, edit-config (the credential switch included), setup-node on a re-run over a
running node, migrate-node-naming, install-caddy and the observability add-on run the guard
and then the wait, once they hold the update lock; `prepare-stake.sh --rotate-address` runs
the wait. setup-alerts runs neither, because it never stops or restarts the node. update-node
runs both just before it stops the node. edit-config, install-caddy and the observability
add-on write their files first and run both right before the restart. When the guard refuses,
nothing restarts: update-node leaves the running node as it was, and edit-config and
install-caddy put back what they wrote. `--no-epoch-wait` and
`TN_SKIP_EPOCH_WAIT=1` skip the wait, never the guard. Rollback restarts run neither. Any new
code that stops or restarts the node runs the guard, then the wait, right before the stop:
"wait first, then stop" is about the stop, not about every file edit. A script that owns its
EXIT trap sets `TN_EXIT_TRAP_OWNED=1` before `tn_acquire_update_lock` and calls
`tn_release_update_lock` from that trap.

## One-way storage migration (v0.16.0-adiri)

The first start of v0.16.0-adiri migrates the consensus store (`<data dir>/consensus-db/epochs`,
epoch packs v1 to v2), and older releases cannot open the data dir afterwards (`invalid
version`). So update-node (since 1.2.1) never rolls back on its own across the 0.16.0 floor
(`STORAGE_MIGRATION_FLOOR_TESTNET`, read through `storage_migration_floor`). The floor is per
network: mainnet and devnet have none (`STORAGE_MIGRATION_FLOOR_MAINNET` and `_DEVNET` are
empty), so no update there is one way and no downgrade there is refused for the storage
reason (the `--json` downgrade refusal carries `"storage_downgrade":false`). A node whose
network cannot be told takes the testnet floor. `storage_migrating_upgrade` judges the running
release from the image tag on Docker installs (for an image run by digest, the `RELEASE_TAG`
recorded with that `DOCKER_IMAGE_DIGEST`) and from the root-owned
`/opt/telcoin/telcoin-network.version` on source and release installs, never from the
checkout's `git describe`; an unreadable running release counts as older. A failed check does not stop the node or restore the old binary or image,
clears the pending state, keeps the version marker, prints the snapshot-restore steps and
leaves the launch files as the apply wrote them; a later `--discard` keeps them too
(`STORAGE_MIGRATION_STARTED` in the pending state). In `--json` mode it ends with a `done`
carrying `"rolled_back":false` and `"storage_migration":true`, and `--check` reports the same
boolean. The maintainer fleet driver (adiri-genesis `adiri-update-all.sh`, maintainer-only)
reads both fields and sets `TN_UPDATE_VERIFY_TIMEOUT`, so keep those names. Do not re-add an
automatic binary or image rollback for that case: only a data dir snapshot taken before the
update can undo it.

## Staking helper

`prepare-stake.sh` checks a node before it stakes and prints the `cast send` commands for
`stake()` and `activate()`; the operator signs and sends them with their own wallet. The script
never sends a transaction and never reads, asks for or prints a private key, and its signing note
tells operators not to use `cast --private-key`. The BLS passphrase reaches only the keytool call
that re-signs the proof of possession for `--rotate-address`, on keytool's standard input
(`tn_keytool` with `TN_KEYTOOL_PASS`, a plain unexported variable), never a command line or an
environment; the script removes `TN_BLS_PASSPHRASE` from its own environment before anything
runs. Future agents must keep it that way: do not add a send, a signing step or a key prompt to
it.

## Private alerts

`setup-alerts.sh` installs a push heartbeat. A timer (`telcoin-heartbeat.timer`) runs
`telcoin-heartbeat.service`, a oneshot that checks the node on this host (the service state,
the local RPC, the consensus header, the node mode and `/health/network`) and pushes up or down
with a reason to at most five monitors the operator owns (Uptime Kuma push URLs, healthchecks.io
ping URLs, JSON webhooks). No port opens and the Telcoin Association is not involved. The
library is `lib/alerts.sh`; the runner is `lib/tn-heartbeat.sh`, installed root 0755 as
`/usr/local/libexec/telcoin/tn-heartbeat` with `tn_install_root_binary` after `bash -n`.
`.node-meta` records `ENABLE_ALERTS=true|pending|false` (absent means false). Rules:

- Every network. `setup-alerts.sh`, `lib/alerts.sh` and `lib/tn-heartbeat.sh` call neither
  `require_testnet` nor `is_testnet`/`is_testnet_like`. The alerts are not a testnet add-on:
  `tn_testnet_addons_present` does not report them, and their files never join
  `TESTNET_ADDONS_BUNDLE`. They are three `SCRIPTS` rows with their own version variables
  (`SCRIPT_VERSION`, `ALERTS_VERSION`, `HEARTBEAT_VERSION`); `_file_version` reads the first
  assignment of that name in the file, so keep the real one first.
- The runner sources nothing, `lib/common.sh` included. It holds `hb_*` functions only and runs
  `hb_main` only when it is executed, not when it is sourced; `lib/alerts.sh` sources it for the
  shared parsers (`hb_target_normalize`, `hb_url_host`, `hb_header_number`, `hb_state_get`). It
  reads its settings from `/etc/telcoin/alerts/alerts.env` (validated key by key), finds its
  tools on `PATH` and parses JSON with `[[ =~ ]]`, `grep`, `sed` and POSIX awk only.
- A target URL is a secret: it carries the monitor's token. It lives only in
  `/etc/telcoin/alerts/targets` (root 0600, one `<kind> <url>` line each, written with
  `tn_write_root_file` from a process substitution run in the main shell), which systemd hands to
  the runner as a credential (`LoadCredential=targets:/etc/telcoin/alerts/targets`). curl gets
  each URL through `-K <(printf 'url = "%s"\n' "$url")`, because `/proc/<pid>/cmdline` is
  readable by every account. A URL never goes on a command line (the operator's own `--target`
  is the one exception, and it warns), into the environment of a child, a log line, a JSON
  event, the state file or `.node-meta`; `TN_ALERT_TARGETS` is copied and unset before anything
  else runs. Wherever a target is shown or logged, it is `kind@host` (`kuma@kuma.example.org`).
- The service runs as a dynamic user (`DynamicUser=yes`, never `User=`) with
  `StateDirectory=telcoin-heartbeat` and the sandbox of `alerts_unit_text`
  (`InaccessiblePaths=` covers the data dir and the passphrase files). Its state file
  (`/var/lib/private/telcoin-heartbeat/state`) is written by the runner only, never sourced, and
  checked key by key when read. That state dir is the one exception to root ownership besides
  the data dir (see "Ownership").
- The node service's state comes from root. A dynamic user cannot use the system bus
  (`dbus-daemon` drops a connection from a uid it cannot resolve), so the runner's own
  `systemctl show` fails. The unit's `ExecStartPre=-+/bin/sh -c '...'` line, right after
  `ExecStart=`, runs as root outside the sandbox and rewrites `/run/telcoin/heartbeat-service`
  (root 0644, in the root 0755 update-lock dir) before each run: it removes the old file, writes
  `systemctl show` of `${ALERTS_SERVICE}.service` to a `.tmp` and renames it. The runner reads
  that file when it is a regular file, not a symlink, through the same key whitelist
  (`_hb_svc_field`), and asks `systemctl show` itself only when the file is absent.
  `alerts_disable` and `remove_alerts` remove the file and its `.tmp`, never `/run/telcoin`.
  This is the one root write outside the `lib/common.sh` primitives, and systemd, not a script,
  makes it. Never give the runner bus access (no static `User=`, no D-Bus policy) or any other
  root helper beyond this one line, and keep the line reading the service state and nothing else.
- Enabling, changing the targets, testing, refreshing and disabling never stop or restart the
  node, so they run neither `tn_committee_down_guard` nor `tn_wait_restart_window`. A write takes
  the update lock through `addon_meta_write_begin`, `--test` takes `addon_meta_lock`, `--status`
  takes none, and a change that went through calls `tn_host_baseline_refresh` behind a
  `declare -F` guard. An enable or a target change that no monitor accepts is undone,
  `.node-meta` included: the undo of a failed fresh enable writes back the `ENABLE_ALERTS` value
  it read at the start (setup-node records `pending` before it runs the enable), or removes the
  key when it was absent, and never writes a hard `false`; only an operator's disable does. Exit
  1 from setup-alerts then means nothing on the host changed, so that path needs no baseline
  refresh.
- remove-node.sh removes the alerts (`remove_alerts`) before the node stops, at every scope of
  the menu and of `--json` and on the leftover path, but not in the chain-data-only wipe, which
  keeps the node. It then prints "Pause or delete this node's monitor: a push monitor alerts on
  silence." `remove_alerts` uses fixed paths and calls nothing in `lib/alerts.sh`, so it works
  on a host that has the script without the library; with no alerts file on the host it does
  and says nothing.
- update-scripts.sh never reinstalls the runner. When `lib/tn-heartbeat.sh` or `lib/alerts.sh`
  changed and the timer unit exists, it prints `sudo bash <dir>/setup-alerts.sh --refresh`, and
  the installed copy stays as it was until the operator runs that.
- What a push carries is an operator-visible contract: up or down and the reason (the node mode,
  block and epoch on an up run, the problem on a down run), to every kind. Kuma gets `status`,
  `msg` and `ping` (the local RPC's answer time in ms); healthchecks gets `<url>` or `<url>/fail`
  with a `<status>: <message>` body; the webhook JSON has the keys `status`, `reason`, `node` (the
  host's label), `network`, `mode`, `block`, `epoch`, `ts` and `changed`, in that order. Nothing
  else leaves the host. Adding, renaming or removing a field is an operator-visible
  change: update `OPERATOR.md`, the README and the partner guide with it.

The fixture tests are `tools/tests/heartbeat_test.sh` (the runner), `tools/tests/alerts_test.sh`
(the library) and `tools/tests/setup_alerts_test.sh` (the script); `tools/tests/vm.d/P0-alerts.sh`
runs the whole path on a VM with systemd.

## Partner documents

`docs/partner/` holds one directory per partner document plus a shared `assets/` tree:

- `docs/partner/mno-node-guide/` is the guide the Association hands to prospective mobile
  network operators.
- `docs/partner/technical-specification/` is the Telcoin Network Technical Specification
  handed to partners. It describes the protocol as of the telcoin-network release named by
  `protocol:` in its `metadata.yaml`; refresh it with every protocol release.

Each directory holds `<name>.md` (the source), `<name>.pdf` (generated, never edited by hand,
committed), `metadata.yaml` (version, date, subtitle, contact and `toc-depth`; the
specification also sets `protocol` and `confidentiality`), `template.html` and `theme.css`.
The shared `docs/partner/assets/` is vendored: the fonts (Geist and Geist Mono under
`fonts/geist/` for the guide, Inter under `fonts/inter/` for the specification, all under the
SIL Open Font License 1.1 with their licence files beside them), the logos (the two white
wordmarks `telcoin-network-light.svg` and `telcoin-association-white.svg` for dark
backgrounds, the two `-dark` ones for light backgrounds) and `covers/`. Record the provenance
of every vendored file in `docs/partner/assets/README.md`.

- Rebuild with `bash tools/build-partner-pdf.sh <name>` after changing a document's Markdown,
  `metadata.yaml`, `template.html` or `theme.css`, and with `--all` after a change under
  `assets/`, which can move both PDFs. Preview the HTML without WeasyPrint using
  `--html-only --open`. Scratch output goes to `docs/partner/<name>/build/`, which is
  gitignored. Where WeasyPrint cannot run natively, build in the `tn-pdf-tools` container
  from the repo root (its toolchain is in the reference-toolchain item below):

  ```
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/w" -w /w tn-pdf-tools bash tools/build-partner-pdf.sh --all
  ```

- Bump `version` and `date` in the document's `metadata.yaml` with every content change. The
  build warns when the Markdown changed and the metadata did not.
- The document title is the single `#` heading in the Markdown. Do not add a `title:` key
  to `metadata.yaml`, and keep no prose between the `#` heading and the first `##`.
- The build refuses partner-unsafe text in either document, in the Markdown and (when
  `pdftotext` is present) in the PDF text: `--observer`, `migrate-node-naming`,
  `setup-observer.sh`, `setup-validator.sh`, personal addresses and repo-relative links.
  The guide may not say "legacy" either, because partner readers never see legacy installs;
  the specification may, since EVM legacy transactions are part of the protocol.
- The only contact in either document is `devs@telcoin.org`, the script's `CONTACT`. Each
  `metadata.yaml` must set `contact` to it, the guide's Markdown must mention it, and the
  specification carries it only on its cover. The build fails on any other value.
- Links to repository files are absolute URLs under `https://github.com/Telcoin-Association/`
  (for this repo, `https://github.com/Telcoin-Association/tn-node-deployment/blob/main/`),
  because the PDF has no repo around it. Cross-references inside a document are heading
  links such as `[Back up the keys now](#back-up-the-keys-now)`, and the build fails on one
  that matches no heading. Headings and prose carry no manual numbers; pandoc numbers the
  chapters at build time.
- Commit the PDF together with the sources that produced it. If only the toolchain changed
  (a pandoc or WeasyPrint upgrade), the script keeps the committed PDF and warns "toolchain
  drift"; pass `--force` to overwrite it deliberately. Same inputs and same toolchain give
  byte-identical output; a second run prints "PDF unchanged".
- Reference toolchain: pandoc 3.12.1, WeasyPrint 70.0 and poppler 26.10.0 from Homebrew
  (`brew install pandoc weasyprint poppler`). poppler provides `pdftotext` for the checks on
  the PDF text and is optional. The `tn-pdf-tools` container is a locally built Debian 12
  image with pandoc 3.8.3 and WeasyPrint 70.0; no Dockerfile for it is committed. The script
  checks for pandoc 3.8+ and WeasyPrint 61+.
- Nothing under `docs/partner/` or `tools/` is updater-tracked or carries a `.sha256`
  sidecar.

## Vendored files

Some files are **vendored from `deploy-networks-common`** (the repository `adiri-genesis`
checks out as its `common/` submodule) and kept in sync by hand:

- `lib/wgvpn/*` — the WireGuard node bootstrap and hub coordinates
- `observability/config.alloy`
- the maintainer SSH public keys under `lib/wgvpn/peers/ssh/`

Before editing any of these, read the **"Sync note (vendored files)"** section in
`docs/testnet-addons.md`. It records what each file mirrors upstream, which parts must
stay byte-identical, and how to re-vendor without drifting.

`lib/wgvpn/peers/ssh/KEYS` has no upstream copy yet, so nothing keeps it in sync for you.
setup-vpn installs only the `.pub` files `KEYS` lists, each with a matching fingerprint: when a
maintainer key is mirrored in, add its `KEYS` line by hand in the same commit (the Sync note
shows the command), and keep both files in `TESTNET_ADDONS_BUNDLE`.

## Self-update and integrity contract

Operators install and update the scripts from signed releases only. A release is a
`scripts-vX.Y.Z` tag on a commit of main. That commit carries `MANIFEST` and `MANIFEST.asc` at
the repository root, and `RELEASE` on main (one line, `<tag> <date>`) names the current tag.
`scripts-v2.1.0` is the first signed release (serial 1); `scripts-v2.0.0` was never tagged.

- `MANIFEST` holds `format=1`, `release=<tag>`, `serial=<n>`, `min_updater=<version>`,
  `date=YYYY-MM-DD` and `expires=YYYY-MM-DD`, then one `sha256  <hash>  <path>` line per file.
  `date=` and `expires=` are optional, each at most once, and must be real calendar dates in
  that form with ASCII digits; a repeated, empty or malformed one makes the updater refuse the
  manifest and the installer refuse the release. Updaters and installers of 2.0.0 ignore both
  keys (unknown header keys are ignored), so a manifest with them needs no `min_updater` bump.
  `tools/release-scripts.sh` builds it from the
  `SCRIPTS`, `UI_BUNDLE` and `TESTNET_ADDONS_BUNDLE` arrays in `update-scripts.sh`, plus
  `install.sh` and `open-ui.sh`. The release keys `lib/release-keys/*.asc` are `SCRIPTS` rows
  like any other file. The three arrays stay the single source of truth for what operators
  receive.
- `MANIFEST.asc` holds detached OpenPGP signatures over `MANIFEST`, one armored block per
  signer, by the maintainer release keys in `lib/release-keys/*.asc`: the same keys, and the
  same `gpgv` status policy (`_tn_gpg_status_verdict`), that the scripts trust for
  telcoin-network releases. The first signer runs
  `gpg --armor --detach-sign --local-user <FPR>! --output MANIFEST.asc MANIFEST`; a further
  signer appends with `--output - MANIFEST >> MANIFEST.asc`. Hosts run
  `gpgv --status-fd 1 --keyring <keyring> MANIFEST.asc MANIFEST` with a keyring made from
  `lib/release-keys/*.asc` alone: the keyring is the allowlist, and there is no separate allow
  file. A release is accepted when at least `TN_SIG_THRESHOLD` (1) distinct primary keys made a
  `GOODSIG` followed by a `VALIDSIG` (whose last field is the primary fingerprint). Any
  `BADSIG`, `EXPKEYSIG`, `REVKEYSIG` or `EXPSIG`, or an `ERRSIG` with a code other than 9,
  refuses. `ERRSIG` code 9 or `NO_PUBKEY` (a key that is not in `lib/release-keys`) counts for
  nothing, refuses nothing and is named in a warning. `TN_SIG_THRESHOLD` is the hook for a
  2-of-N signing policy (#40).
- The RELEASE SIGNATURES block (`TN_SIG_FILE`, `TN_SIG_THRESHOLD`, `TN_KEYS_DIR`,
  `tn_dearmor_keys`, `tn_sig_verdict`, `tn_verify_manifest`, `tn_sig_reason`) is the same text
  in `update-scripts.sh`, `install.sh` and `tools/release-scripts.sh`;
  `tools/tests/release_scripts_test.sh` checks that the three copies match. None of them sources
  `lib/common.sh`, because each runs where `lib/` may not exist yet. `tn_dearmor_keys` makes the
  binary keyring in shell (awk and `base64`, with the armor headers, the CRC line and the END
  line dropped), so the updater and the installer need `gpgv` (apt `gpgv`, brew `gnupg`) and
  never `gpg`.
- Invariant: every verifier takes its verdict from the gpg or `gpgv` status lines, never from
  the exit status: `update-scripts.sh`, `install.sh` and `tools/release-scripts.sh` through
  `tn_sig_verdict`, `tools/cut-release.sh` for a tag's signature (`git verify-tag --raw`), and
  `lib/common.sh` for node releases and source tags. `gpgv` 2.4.8 exits 0 on `EXPKEYSIG` and
  `REVKEYSIG`, so a check of the exit status would accept a release signed by an expired or
  revoked key. Keep the `|| true` after the `gpgv` call and the verdict on the parser in every
  copy.
- Key files use LF line endings and end with a newline, as `gpg --armor --export` writes them.
  `release-scripts.sh` (prepare and `--check`) refuses a key file with CR ("<file> has CR line
  endings: write it with LF line endings (as gpg --armor --export does)"), one without a final
  newline ("<file> does not end with a newline: export the key again with gpg --armor --export
  <fingerprint> > <file> (install.sh embeds the key files one after the other)") and, where gpg
  is installed, a key file gpg reads no primary key from ("gpg reads no primary key from
  <file>: export the key again with gpg --armor --export <fingerprint>"), so none of them can
  ship. The updater's dearmor and the
  installer's splitter of its embedded keys read CRLF too.
- `install.sh` carries every key file, sorted by name, in its `TN_RELEASE_KEYS` heredoc, which
  `release-scripts.sh` writes in the release commit. That embedded set is the installer's trust
  root: it verifies `MANIFEST.asc` with it, then installs only files that match the signed
  `MANIFEST`, the release's own `lib/release-keys/*.asc` among them, so a release may add a key.
- `serial` rises with every release. The updater refuses a serial lower than the installed
  one, and the same serial with a different manifest. `min_updater` is the oldest
  `update-scripts.sh` that can install the release (`--min-updater`; by default the previous
  release's value, and never above the tree's own `SCRIPT_VERSION`). A host whose updater and
  the release's copy of it are both older is told to rerun the installer one-liner.
- `update-scripts.sh` reads `RELEASE`, fetches `MANIFEST` and `MANIFEST.asc` from that tag and
  verifies them, then downloads every changed file from the tag into a staging dir
  (`$SCRIPT_DIR/.tn-update.XXXXXX`) and checks each one against its MANIFEST hash, its
  `.sha256` sidecar when one is published, and `bash -n`. Only when every file passes does it
  install them, all together. It removes files the release no longer lists and writes
  `MANIFEST` and `MANIFEST.asc` last, as the record of the installed release, and only after
  every move and removal succeeded: after a failed one the old record stays ("The release record
  was not updated: run the updater again.") and the next run records the new release. A refusal
  or a failure before the install pass leaves the tree as it was. The updater takes no lock, and it no longer redeploys the
  Node Manager UI: it prints `sudo bash ui/install-ui.sh --update` for the operator to run.
- When the release lists a different `update-scripts.sh`, the running updater stages and
  verifies the whole release first, then runs the release's copy from the staging dir with
  `TN_UPDATER_RELAUNCHED=1`. That copy sees that it runs from a `.tn-update.*` dir, adopts the
  staging dir and installs everything, itself included, in one pass. Every future
  `update-scripts.sh` must keep that detection; without it the relaunched copy would treat the
  staging dir as the install. `tools/tests/updater_manifest_test.sh` checks it.
- The one-time bootstrap: hosts on update-scripts 1.1.72 or older know nothing of manifests.
  They fetch each tracked file from main and check it against its `<file>.sha256` sidecar, so
  their next run installs the current `update-scripts.sh` that way (unsigned, hashes from
  main), and every update after that is a signed manifest. The first signed run on a tree with
  neither `lib/release-keys/*.asc` nor an installed `MANIFEST` warns "First signed release on
  this host: fetching the release keys through their published checksums (one time only).",
  takes the key files the not yet verified `MANIFEST` lists, each through its `.sha256`
  sidecar on the tag (which must exist and match), verifies `MANIFEST.asc` with them, and
  requires their hashes to be the lines of the verified `MANIFEST`. That is trust on first use,
  by design; hosts that already carry `lib/release-keys/grantkee.asc` (shipped for node
  releases) never bootstrap. From then on a new key set arrives only inside a manifest that
  verifies against the installed keys. That is why the sidecars stay: `tools/gen-checksums.sh`
  still writes them from the three arrays, the `checksums` CI job fails on a stale or missing
  one, and `release-scripts.sh` requires a fresh sidecar for every array file, the key files
  included.
- Hosts whose updater is the SSH-signature flow of main before `scripts-v2.1.0`
  (update-scripts 2.0.0, never tagged, but on hosts that cloned main) refuse the
  OpenPGP-signed release with "Release scripts-v2.1.0 has no MANIFEST.sig; nothing was
  changed." and need the installer once
  (`curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes`).
  The retired `lib/allowed_signers` stays on such a host, unused: the updater removes only
  files an installed `MANIFEST` lists.
- Expiry: a release has expired from the day `expires=` names (UTC). It is a reminder that a
  newer signed release is due, not a revocation: nothing refuses an expired release. The
  updater warns on every update run ("Script release <tag> expired on <date>; a newer signed
  release is overdue.") and installs as usual; `install.sh` warns the same way before it
  installs; check-node's "Checking the script release..." block reports the installed record
  (tag, serial, release date, expiry) and never counts an issue.
  `bash update-scripts.sh --check` reports the installed and the newest release without
  installing anything, needing root or asking anything: exit 0 when the installed release is
  the newest and neither has expired, 1 when an update is pending or either release has
  expired, 2 when no signed release is installed, the installed record or the newest release
  cannot be verified or fetched, or the updater would refuse the newest one (2 wins over 1).
- Rotating a signing key: updaters verify a new release against the keys they already have
  (`lib/release-keys/*.asc` on the host), `install.sh` against its embedded keys, and
  `release-scripts.sh --check` against the tree's `lib/release-keys`. A release that adds,
  removes or replaces a key must therefore be signed by a key that is in both the old and the
  new set.
- Key expiry: the release key's primary (`4E36D35A4AB61B589861D01AC7173F2377CA7573`) expires
  2028-10-16. From that date `gpgv` reports `EXPKEYSIG` for it on a host whose installed copy
  is the old one, and that host refuses every later release, script or node. Only a release
  that verifies against the installed copy can renew it, so the extended key (re-exported
  with the new expiry) must ship in a script release signed before that date. A host that has
  not installed that release by then re-runs the installer, whose embedded keys are the
  extended ones.

To cut a release, use `tools/cut-release.sh` from a clean clone of the repository: untracked
files count as uncommitted changes, as for `release-scripts.sh` prepare. Every step prints its
command and asks `[Enter] run / s skip / q quit` (`--yes` runs every step without asking). The
three checks (prep step 6, tag steps 2 and 4) ask `[Enter] run / q quit` and cannot be skipped,
because the steps after them push, tag or publish what they check. A step whose result is
already there is reported as "already done" and passed over, so running
the same command again carries on where a run stopped. The tool never sets `commit.gpgsign` or
`user.signingkey`: the commit and the tag name the key with `-S` and `--local-user`.
`TN_CUT_POLL_SECONDS` (default 30) and `TN_CUT_POLL_TRIES` (default 120) pace its waits.

1. `bash tools/cut-release.sh prep scripts-vX.Y.Z [--serial N] [--key FPR] [--sig-from FILE] [--yes]`
   opens the release pull request. It fetches origin; checks the signing key (`--key`, else
   `git config user.signingkey`, else the one key in `lib/release-keys/`) before it creates or
   enters any branch: the key must be the primary key of a `lib/release-keys/*.asc` file of
   the branch to be (`origin/main` for a new one), else it refuses ("... is not a primary key of
   lib/release-keys/*.asc on origin/main") and creates nothing; creates
   `release/scripts-vX.Y.Z` from `origin/main`, or switches to it; checks that the card answers
   (`gpg --card-status`); prepares the release with
   `bash tools/release-scripts.sh [--serial N] scripts-vX.Y.Z` (when `release/TAG` already holds
   a `MANIFEST` for the tag with another serial than `--serial N`, step 4 refuses and names both
   serials: rerun with the prepared serial, or delete the branch with the commands it prints,
   `rm -f MANIFEST MANIFEST.asc RELEASE && git checkout -f main && git branch -D release/TAG`
   and, when origin has the branch too, `git push origin --delete release/TAG`); signs
   `MANIFEST` with
   `gpg --armor --detach-sign --local-user <FPR>! --output MANIFEST.asc MANIFEST`; runs
   `bash tools/release-scripts.sh --check --require-sig --tag scripts-vX.Y.Z`; stages and
   commits `MANIFEST`, `MANIFEST.asc`, `RELEASE` and `install.sh` in one prompt
   (`git add ... && git commit -S<FPR>! -F ...`, message `release: scripts-vX.Y.Z`); pushes the
   branch; and opens the pull request with `gh pr create --base main`.
   - The signing key is the maintainer's YubiKey. When the tool runs on a remote host, the card
     answers through a gpg-agent forwarded from the maintainer's client. When no card answers,
     the sign step prints the gpg command and waits until `MANIFEST.asc` appears: sign
     `MANIFEST` on the machine with the key and copy the file in. `--sig-from FILE` copies a
     signature made elsewhere and skips the card check with a warning; the commit is still
     signed with `-S`, so the key must answer for that step.
   - The prepare step (`release-scripts.sh`, which never signs) takes `--serial N` (required
     for the first release), `--min-updater X.Y.Z`, `--date YYYY-MM-DD` (default today, UTC,
     written to `RELEASE` and to `MANIFEST` `date=`) and `--expires DAYS` (`expires=` is the
     date plus DAYS, default 90, 1 to 3650). It needs at least one `lib/release-keys/*.asc`,
     each an armored public key and a row of an updater array. It writes `MANIFEST`, `RELEASE`
     and the tag and the `TN_RELEASE_KEYS` block in `install.sh`, removes the previous
     `MANIFEST.asc`, prints the release and expiry dates and the signing command for each key,
     and warns when the expiry is on or before today. `--check` prints the release date and
     expiry, fails when `RELEASE` and `MANIFEST` disagree on the date, `expires=` is not after
     `date=`, or the keys embedded in `install.sh` differ from `lib/release-keys/*.asc`, and
     only warns about an expired release unless `--require-fresh` is given (CI does not pass
     it).
2. The "release manifest" CI job runs `release-scripts.sh --check --require-sig` on the release
   pull request. Merge it with a merge commit, so the signed release commit stays on main as
   it was made.
3. Right after the merge, `bash tools/cut-release.sh tag scripts-vX.Y.Z [--key FPR] [--yes]`
   tags it. Right after the fetch it prints the commit `origin/main` names ("origin/main is
   <sha>: steps 2 to 5 check, tag and push this commit"), and works on that commit only. It
   checks that the commit carries the release (its `MANIFEST` names the tag; its `MANIFEST` and
   `MANIFEST.asc` are those of origin's `release/TAG` as fetched, or of the local branch when
   origin has none, and are not compared when neither exists; and `--check --require-sig --tag`
   passes in a clean temporary worktree of it, which an interrupted run removes); makes the
   signed tag (`git tag -s --local-user=<FPR>! -m TAG TAG <sha>`), refusing with nothing tagged
   when `origin/main` has moved since step 1; checks it with `git verify-tag --raw`, whose
   status lines must show a good signature (`GOODSIG` then `VALIDSIG`) by a key of
   `lib/release-keys/*.asc` at that commit and no `BADSIG`, `EXPKEYSIG`, `REVKEYSIG`, `EXPSIG` or
   `ERRSIG` (an existing tag passes only this way too; it refuses with "<TAG> carries no good
   signature by a key of lib/release-keys/*.asc on origin/main <sha>" and reports "<TAG> is
   signed by release key <FPR>" when it passes); pushes it, and the pushed tag must name that
   commit; waits for the tag's `ci.yml` and `publish-installer.yml` runs and prints their
   conclusions; and checks that `https://install.telcoin.network` names the
   tag in its `TN_SCRIPTS_TAG` line. `RELEASE` on main names the tag from the merge on, and
   until the tag exists every updater that reads it fails to fetch the release, including the
   first signed run on a host that has just bootstrapped.
4. The tag push runs `publish-installer.yml`, which checks that the tag is on main and that
   `release-scripts.sh --check --tag` passes, then publishes that tag's `install.sh` to GitHub
   Pages as `https://install.telcoin.network`. The `github-pages` environment must allow
   `scripts-v*` tags. `install.sh` is pinned to its tag and carries the release keys; a copy
   without a tag refuses ("names no release").
5. `bash tools/cut-release.sh status` prints what exists for the newest `release/*` branch and
   `scripts-v*` tag: the branch and its commit, the `MANIFEST` serial, whether `MANIFEST.asc`
   verifies, which release key signed the tag (a key of `lib/release-keys` at the tag) and the
   tag's CI runs.

The first ceremony: after PR #59 merges, run `bash tools/cut-release.sh prep scripts-v2.1.0
--serial 1`, merge the release pull request with a merge commit, then run
`bash tools/cut-release.sh tag scripts-v2.1.0`.

So after you edit any tracked file:

1. Bump its version constant (`SCRIPT_VERSION`, `COMMON_VERSION`, `UI_VERSION`, etc.). The
   updater shows these versions to operators, and the changelog names them.
2. Run `bash tools/gen-checksums.sh` and commit the refreshed `*.sha256` sidecars.
3. Record the change in the Changelog section of `README.md` and in the release note under
   `CHANGELOG/`.
4. Keep it bash 3.2 / Ubuntu safe: indexed arrays only — no `declare -A`, no
   `${var,,}`, no `mapfile`/`readarray`, no `&>>`. Run
   `/bin/bash tools/check-bash32.sh <file>` and the fixture tests before you commit.

`MANIFEST` on main stays the previous release's until the next release is cut; CI compares it
with the tree only on a release change or a release tag.

`AGENTS.md` itself is intentionally untracked (docs are not shipped to nodes), so it
has no sidecar and is absent from the updater arrays. Keep it that way.
The same holds for the other docs and the maintainer tooling: `OPERATOR.md`, `followup.md`,
`CHANGELOG.md`, `CHANGELOG/`, `README.md`, `docs/` (the partner documents and their build
inputs included), `tasks/`, `.github/`, `tools/` (the lints, `gen-checksums.sh`,
`release-scripts.sh` and `tools/tests/` included) and the Node Manager UI's tests and dev
runner (`ui/tests/`, `ui/dev/`, `ui/test_*.py`) are documentation or maintainer tooling, are
not updater-tracked, carry no `.sha256` sidecar, and must never be added to the updater
arrays. `RELEASE`, `MANIFEST` and `MANIFEST.asc` are release metadata, not tracked files: the
updater reads them from the tag and keeps the installed `MANIFEST` and `MANIFEST.asc` as its
record.
`README.md` must stay at the repo root, because `update-scripts.sh` HEAD-probes it as its
connectivity check.

## Scripts and an older library

The scripts and `lib/common.sh` ship together, but a host can still end up with a script newer
than its library (a file copied by hand, or an older updater that installed some files and not
others). The entry scripts refuse to run against a library that lacks a helper they call:
setup-node, update-node, edit-config, prepare-stake and migrate-node-naming check their list
with `declare -F` before anything else and stop with one message naming `update-scripts.sh`
(in a `--json` run, as the `done` event). check-node degrades instead: a check whose helpers
are missing is skipped, and one warning at the end names every skipped check
(`cn_report_skipped`). The add-on scripts do the same as the entry scripts through their own
`*_require_lib` (`caddy_require_lib`, `fw_require_lib`, `vpn_require_lib`,
`addons_require_lib`, `alerts_require_lib`), which exit 2 with one message. When a script
starts calling a library helper it did not call before, add the helper to that script's list.

## Lints

The bash 3.2 lint, `tools/check-bash32.sh`, finds bash 4+ syntax that `bash -n` under 3.2
accepts but 3.2 cannot run, because it fails only when the line executes. CI runs it on every
`*.sh` under `/bin/bash` on the macOS runner and under bash on the Ubuntu runner. It flags
`declare`, `typeset` or `local` with `-A`, `-g`, `-n`, `-l` or `-u`, case modification such as
`${v,,}` and `${v^^}`, `mapfile`, `readarray` and `coproc`, `&>>`, `|&`, `[[ -v` and `wait -n`,
negative subscripts and substring lengths, `exec {fd}>`, `${v@Q}` and the other `@`
transformations, `printf` with `%(...)T`, and the `;;&` and `;&` case terminators, inside
one-line `case` arms too. A line containing `# bash32-ok` is never reported; put the reason
after the marker. Neither the lint nor `bash -n` under 3.2 sees one more 3.2 failure: a `case`
pattern's `)` inside `$( )` is a syntax error when the line runs. Put such a `case` in a
function, or write the pattern as `(pat)`.

The perl interpolation lint, `tools/check-perl-interp.sh FILE...`, flags a perl program that
expands a shell variable, which perl would then parse as code (the `@` of an image pinned by
digest reads as a perl array). It reports a double-quoted `-e` or `-E` program (also inside a
cluster such as `-pe` or `-i.bak -pe`) that holds a `$name`, `${...}`, `$(...)` or backtick;
an unquoted heredoc or here-string program; a `-M`, `-m`, `-d:` or `-I` value taken from a
variable; and a program it cannot see, such as perl reading its program from a pipe, a process
substitution or `/dev/stdin`. Pass values as data instead (`$ENV{NAME}`, `@ARGV`, or `-s`
switches after `--`) and keep the program in single quotes. A perl command with
`# perl-interp-ok REASON` on one of its lines is not reported. Its blind spots, which review
has to cover: perl in a string run by `bash -c`, `sh -c`, `eval` or `ssh`; an argv array built
in a variable; a program passed through `"$@"`; perl reached through a variable
(`"$PERL" -e`); a stdin program behind a wrapper given options (`sudo -u u perl`,
`env -i perl`); and perl written into a generated script. A file whose quoting it cannot
follow to the end is an error (exit 2). No shipped script runs perl today.

The root-write pipe lint, `tools/tests/root_write_pipe_test.sh`, scans the shipped scripts
(the repo root and `lib/`, without the vendored `lib/wgvpn/`) for a pipe into
`tn_write_root_file`, `write_pending_state` or `_tn_meta_write`, on one line or across a line
that ends or starts with `|`. The rule is in "Ownership: root owns the install".

The passphrase-print lint, `tools/tests/passphrase_print_test.sh`, flags any `echo` or
`printf` whose arguments expand `TN_BLS_PASSPHRASE`, `TN_SETUP_PASS`, `TN_KEYTOOL_PASS` or
`TN_CRED_PASS`, in every tracked `*.sh` outside `tools/tests/`. It lets through output piped
straight into a consuming command's standard input (unless that command is `tee`, `cat`,
`logger`, `echo`, `printf` or `xargs`), comment lines, and a line marked
`# passphrase-stdin-ok REASON` (REASON not empty) whose code is a single `printf '%s'` or
`printf '%s\n'` of the bare variable to standard output, with no redirection other than
`2>/dev/null`, no command substitution and no second passphrase expansion. The marker is for
a feed function whose output the caller pipes into the consumer, such as `_tn_feed_pass`.
Redirection to a file or to stderr is always flagged.

The network-hits lint, `tools/check-network-hits.sh [--list] [ROOT]`, reports every line that
names the testnet (`adiri` in any case) or a hub or monitor address of
`lib/testnet-addons.env` (the obs hub host, the WireGuard hub address without its port, the
Kuma monitor address without its prefix; read as text, never sourced) without a reason why it
is safe on mainnet. It scans `lib/*.sh` (not `lib/wgvpn/`), the root `*.sh`, `ui/server.py`,
`ui/telcoin-ui-helper.sh`, `ui/install-ui.sh`, `ui/static/index.html` and
`observability/config.alloy`; docs, tests, `tools/` and `common/` are out of scope. ROOT
defaults to the repository the tool lives in. A hit passes when its line carries the marker,
or when the line right above it is nothing but the marker comment:

```
# network-gated: <reason>          shell, Python
// network-gated: <reason>         JavaScript, Alloy
<!-- network-gated: <reason> -->   HTML outside scripts
```

The reason must hold a letter or a digit. A trailing marker covers its own line only. Some
places cannot hold a marker. Inside a JavaScript template literal an HTML marker becomes part
of the page and `//` is plain text, so move the testnet text into a constant below a `//`
marker line. Inside a heredoc the marker is written into the file the heredoc makes, so
reword the line to name no testnet. Inside a Python docstring the marker is docstring text,
so put the name on the docstring's first line and the marker comment between `def` and the
docstring. In the `--help` header of setup-node, edit-config and update-node a marker line is
fine: their help printers leave `# network-gated:` lines out. Exit status: 0 clean (a summary
on stderr), 1 unannotated hits (one `FILE:LINE: <line>` each on stdout), 2 for a usage error,
a missing or unreadable scanned file, or a `testnet-addons.env` value it cannot read.
`--list` prints every hit with its reason. `tools/tests/network_hits_test.sh` tests the lint
and runs it over the tree.

The two lints under `tools/tests/` run with the fixture tests. The CI job `hardening-lint`
runs the passphrase-print lint, the perl lint on every tracked `*.sh` and the network-hits
lint.

## CI

`.github/workflows/ci.yml` runs on pushes to main, on `scripts-v*` tags and on pull requests.
Every action is pinned to a full commit SHA with its tag in a comment, the workflow token gets
no permissions by default (`permissions: {}`) and each job asks for `contents: read`; checkouts set
`persist-credentials: false`. `tools/tests/ci_pins_test.sh` checks these rules, and also that the hardening lints job
runs the passphrase-print, perl and network-hits lints; the fixture jobs run
`tools/tests/run.sh` (the macOS one under `/bin/bash`); the checksum job runs
`tools/gen-checksums.sh`; the UI job installs the test requirements by hash and runs pytest;
the UI and macOS jobs run the three UI shell tests; the hardening lints and UI jobs have no
`if [ -f` fallback and the UI job no unittest fallback; no required job, and no step of one,
carries an `if:` or a `continue-on-error` (other than `false`), except the advisory
shellcheck step "shellcheck (warnings -- advisory)"; no run line in a required job ends with
`|| true`, `|| :` or `|| exit 0`; and `publish-installer.yml` writes no `.nojekyll`. A
skipped required check counts as passed on GitHub, and `continue-on-error` turns a failure
into a pass. The jobs:

- `parse-linux` ("bash -n (Linux)"): `bash -n` on every tracked `*.sh`, then
  `tools/check-bash32.sh` under Ubuntu's bash (with mawk).
- `parse-macos` ("bash -n and bash-3.2 lint (macOS bash 3.2)"): the same two checks under
  macOS `/bin/bash` 3.2 (with BSD awk), then `ui/tests/helper_test.sh`,
  `ui/tests/install_ui_test.sh` and `ui/tests/open_ui_test.sh` under `/bin/bash` 3.2.
- `shellcheck` ("shellcheck"): `shellcheck -x --severity=error` blocks; a second run at
  warning severity is advisory (the one `continue-on-error` in the required jobs).
- `fixture-tests` ("fixture tests (Linux bash 5)"): `bash tools/tests/run.sh` under bash 5,
  `tools/tests/network_hits_test.sh` included.
- `fixture-tests-macos` ("fixture tests (macOS bash 3.2)"): the same suite under macOS
  `/bin/bash` 3.2.
- `hardening-lint` ("hardening lints"): the passphrase-print lint,
  `tools/check-perl-interp.sh` on every tracked `*.sh`, and `tools/check-network-hits.sh`
  (step "network hits").
- `manifest` ("release manifest"): on a `scripts-v*` tag, `release-scripts.sh --check --tag
  <tag>`; on a change that touches `MANIFEST`, `MANIFEST.asc` or `RELEASE`,
  `release-scripts.sh --check --require-sig`; otherwise nothing is compared.
- `ui-tests` ("Node Manager UI tests"): on Python 3.10, installs `ui/requirements.txt` and
  `ui/tests/requirements-dev.txt` with `--require-hashes`, runs `python -m pytest -q ui` (there
  is no unittest fallback), then the three UI shell tests under bash 5. As the runner user,
  not root, `install_ui_test.sh` checks only that the installer refuses a non-root run; its
  ownership and mode cases need root (run them in `bash:3.2`, which runs as root).
- `checksums` ("checksum freshness"): runs `tools/gen-checksums.sh` and fails on a stale,
  missing or uncommitted sidecar.

`.github/workflows/integration.yml` has one job, `vm-assertions`: on an Ubuntu 24.04 runner
(a full VM with systemd), it installs logrotate, ufw and openssh-server and runs every
`tools/tests/vm.d/P0-*.sh` assertion file as root with `TN_VM_TEST=1`. Only that glob runs: a
new assertion file needs the `P0-` prefix.

`.github/workflows/publish-installer.yml` runs on a `scripts-v*` tag (or by hand on one). Its
`build` job checks that the tag is on main and that `release-scripts.sh --check --tag` passes,
then assembles the Pages site (`index.html`, `install.sh` and `CNAME`; no `.nojekyll`, since
`upload-pages-artifact` v4 and later drop dotfiles and artifact deploys never run Jekyll);
`deploy` publishes it to GitHub Pages.

Required status checks match the jobs' display names (their `name:` lines, such as "bash -n
(Linux)"), not the job ids. The main-branch ruleset in issue #30 lists eight: "bash -n
(Linux)", "bash -n and bash-3.2 lint (macOS bash 3.2)", "shellcheck", "fixture tests (Linux
bash 5)", "hardening lints", "release manifest", "Node Manager UI tests" and "checksum
freshness". `tools/tests/ci_pins_test.sh` guards those and two more, "fixture tests (macOS
bash 3.2)" and "Ubuntu 24.04 VM assertions", so either can be made required without a
rename: each of the ten must be the display name of exactly one job in its workflow. Do not
rename a job without changing the ruleset and `tools/tests/ci_pins_test.sh` in the same
change; a renamed job leaves a required check that never reports.

## Contributing

Pull requests to main need the required checks above green. Once the main-branch ruleset of
issue #30 is on, a pull request also needs one approving review (a later push dismisses an
approval, and the last push must be approved by someone other than its pusher) and signed
commits: sign every commit (`git commit -S`, or `commit.gpgsign=true` with an SSH or GPG
signing key registered on GitHub). `.github/CODEOWNERS` lists three owners on every line,
so the ruleset can require that review from a code owner (`require_code_owner_review`);
`ci_pins_test.sh` requires at least two owners on every owned path. The release path has lines
of its own, among them `/lib/release-keys/`, `/tools/release-scripts.sh`,
`/tools/cut-release.sh`, `/MANIFEST`, `/MANIFEST.asc` and `/RELEASE`. Do not rename a CI job
and do not make a required job skippable (`if:`) or non-blocking (`continue-on-error`,
`|| true`): `ci_pins_test.sh` rejects both.

## Fixture tests (`tools/tests/`)

`tools/tests/*_test.sh` are fixture tests for the scripts and the library. They build fake
installs under a private temp dir (`TN_ROOT_PREFIX` points the path probes at it) and stub
system tools on `PATH`; none of them needs a node. Run them in all three environments before
you hand back a change:

```
bash tools/tests/run.sh                                                  # bash 5
docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh      # bash 3.2, busybox
docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash tools/tests/run.sh  # root, GNU tools
```

`run.sh` runs each file as its own process under the bash that runs it; name files to run only
those. The `bash:3.2` image has busybox tools and no perl, `mv -T` or `setpriv`, so tests that
need them print `SKIP` there and still pass; they run for real under bash 5 and in the Ubuntu
container, which also runs them as root.

To write one, source `tools/tests/lib.sh` at the top level, check with `check`, `check_has`,
`check_lacks`, `check_rc` and `skip`, and end with `finish`. Load the library with
`eval "$(tn_test_source_common)"` at the top level of the test, never inside a function: bash
3.2 keeps a `readonly` array assigned inside a function local to that function. Set
`TN_ROOT_PREFIX` (and `SERVICE_USER` or `SERVICE_GROUP` when the test needs them) before that
line.

- `tools/tests/vm.d/` holds host-level assertions for a disposable VM: they create users,
  write under `/etc`, `/opt` and `/usr/local` and change the firewall. They refuse to run
  unless they run as root with `TN_VM_TEST=1`; `integration.yml` runs the `P0-*.sh` ones. An
  item whose code is not in the tree reports SKIP. Do not run them on a machine you care
  about.
- `tools/tests/genesis.d/testnet/` holds `genesis.yaml`, `committee.yaml` and
  `parameters.yaml` from telcoin-network at the pinned tag (`TESTNET_CHAIN_CONFIGS_TAG`),
  unchanged. `genesis_hash_test.sh` checks them against the `TESTNET_*_SHA256` pins in
  `lib/common.sh`; refresh the files and the pins together.
- `tools/tests/perl-interp.d/` holds the perl lint's fixtures, and `tools/tests/signing.sh`
  the OpenPGP release-signing helpers of `updater_manifest_test.sh`, `install_test.sh`,
  `release_scripts_test.sh` and `cut_release_test.sh`: `newkey NAME [EXPIRY|--expired|--revoked]`,
  `sign_file FILE KEYNAME...` and `sign_file_bad FILE KEYNAME`, with throwaway keys in a
  temporary `GNUPGHOME`. `REAL_GPG` is 1 when the real `gpg` and `gpgv` work there; elsewhere
  (the `bash:3.2` and `ubuntu:24.04` images), or with `TN_TEST_FAKE_GPG=1`, stand-in `gpg` and
  `gpgv` print the real status lines, so the status parser runs in every environment.
  `cut_release_test.sh` drives `cut-release.sh` against a bare repository on disk with
  stand-in `gh`, `gpg` and `curl`.

Nothing under `tools/tests/` is updater-tracked or carries a sidecar. The UI's own tests live
in `ui/tests/` (`helper_test.sh`, `open_ui_test.sh`, `install_ui_test.sh`) and `ui/test_*.py`.
