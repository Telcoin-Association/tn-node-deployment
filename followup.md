# Follow-ups

The work still open for tn-node-deployment and the repos around it. The previous backlog, the
follow-ups from the public-RPC and observer-flag work, was cleared on 2026-10-02 in commits
`7fb7c8d..HEAD`; the "Backlog round" entry in CHANGELOG.md summarises that round. What is below
is what the round could not do from these repos, chose not to change, or found along the way.
Each item says why an operator or the maintainer would care, and the parentheses name the
package or verifier of that round that recorded it.

## Security

- `create_directories` gives `/opt/telcoin` and `/etc/telcoin` to the service user (`chown -R`),
  and fresh installs leave `.node-meta` owned by it, yet root-run scripts write and trust files
  there (`.node-meta`, `bls-passphrase`, `bootstrap-peers.yaml`) and the Docker start wrapper in
  `/opt/telcoin` runs as root. Recommended fix: root-owned 0755 directories, the service user
  owning only the data and log directories, and service-readable files only where the node needs
  them (the passphrase file 0640 `root:<group>`), with a migration step for existing installs and
  a check that nothing the node or the UI writes lives there. Pre-existing. (P4b, plan)
  Why: code running as the service user, such as a compromised node process, could swap a file
  that root later runs or trusts, and so gain root.
- The Node Manager UI's `bootstrap_peers` setting accepts any absolute path, `..` included (the
  helper and server pattern is `^(none|/[A-Za-z0-9._/-]+)$`), so a UI user can still probe
  whether a path exists on the host through the root helper. File contents no longer leak.
  Recommended fix: accept only files in one directory and refuse `..`. (UI-1, P5, V-CORE-1)
  Why: any local user who reaches the UI on 127.0.0.1:8080 can map the host's files as root.
- When remove-node finds no node unit it never offers to remove a leftover Node Manager UI, and
  `--json` stops with "no node installed" first, so the UI service, its root helper and
  `/etc/sudoers.d/telcoin-ui` stay behind. (V-CORE-2-rn)
  Why: an operator who removed the node keeps a sudo-enabled helper they believe is gone.
- The UI helper's ref checks (the update ref in `cmd_update_prepare` and the setup build ref,
  both `^[A-Za-z0-9._/-]+$`) still accept a leading `-`. The server, update-node and setup-node's
  flag parser refuse such a ref, so no live path reaches git today. (UI-2b, P6)
  Why: the helper is the sudo boundary, and a ref such as `--detach` would reach git as an option
  if a caller ever stopped filtering it.
- firewall-setup's "Remove a whitelist entry" deletes one rule number per run and says nothing
  about the `(v6)` twin that ufw creates for `ufw allow <port>/tcp`, so removing the blanket SSH
  rule by hand leaves SSH open to everyone over IPv6. Fix: delete both rules, or offer to.
  (V-DOC)
  Why: an operator who restricts SSH to a whitelist believes it is closed while IPv6 stays open.
- check-node keeps its state between runs in the fixed path `${TMPDIR:-/tmp}/check-node.state`.
  Concurrent runs overwrite each other, and under sudo another local user can create the file
  first; the values are checked to be digits before use, so nothing runs. (B)
  Why: the "advancing +N since last check" line can be wrong or stop updating, and a root-run
  script should not trust a predictable `/tmp` path.

## Multiple workers

- Nothing provisions a second worker. The firewall, check-node and the UI read every worker from
  `node-info.yaml`, and check-node reports a node with fewer workers than
  `WorkerConfigs.numWorkers()` and sends the operator to support, but adding a worker needs a
  release that allows more than one (keytool `generate validator --workers` says workers must be
  1), a listener override per worker and a keytool command that adds a worker. (plan, B)
  Why: once governance raises the worker count, every node needs keys and config that no script
  can make yet.
- `keytool set-rpc` and install-caddy's python fallback edit worker 0 only. A node advertised by
  install-caddy 1.3.0 carries the URL on every worker, so rpc-disable leaves workers 1 and up
  advertising the old URL; it warns and names the entry to clear by hand. This lasts until a
  keytool release ships `--worker-id`, which exists only on telcoin-network `main`, and the
  upstream docs should describe the flag then. (A, V-OPS-1, UP)
  Why: wallets can keep finding an endpoint the operator withdrew.

## Setup and configuration

- Keygen records the install method, the image or binary, bootstrap peers and state export in
  `.node-meta` for finalize to read back, but not the two listener addresses, so a `--json`
  finalize without `--listener-primary` and `--listener-worker` writes empty listener values into
  the start wrapper. Record them at keygen and read them back the same way. (P4a)
  Why: a two-phase automated install that leaves those flags out at finalize gets a broken start
  wrapper.
- Answering Yes to setup-node's "Overwrite existing keys?" always ends "Key generation failed.",
  because the v0.15.0-adiri keytool refuses a non-empty `node-keys/` and setup-node passes no
  `--force`. Candidate fix: move `node-keys/` and `node-info.yaml` aside into a timestamped
  backup first, and never pass `--force`. (V-DOC)
  Why: the overwrite the prompt offers can never succeed, and the operator has to move the files
  by hand.
- A `--json` finalize cannot undo the bootstrap-peers or state-export choices recorded at keygen:
  there is no `--bootstrap-peers none` and no `--no-state-export`. (P4b)
  Why: automation that changes its mind between the phases has to re-run keygen or fix the node
  afterwards with edit-config.
- edit-config's `bootstrap_peers` and `state_export` edits rewrite the launch line but leave
  `BOOTSTRAP_PEERS_FILE` and `STATE_EXPORT` in `.node-meta` as setup-node wrote them. (P4b)
  Why: anything that reads `.node-meta` after such an edit sees the old choice.
- edit-config's "Refresh chain configs" runs `git pull` in the source directory, which fails on
  the detached checkout of a release tag, the default for a source install. It stops with "git
  pull failed ... Chain configs unchanged." and nothing tells the operator what to do instead. It
  also refuses when `.node-meta` has no `NETWORK`, although it could take the network from the
  genesis chain ID, which it checks anyway. (P5, DOC-3)
  Why: most source-build operators cannot refresh chain configs from the menu.
- edit-config rolls an edit back when the run ends before its restart, but bash runs the trap
  only when the foreground command returns: a signal during the epoch wait is handled at the next
  poll (`TN_EPOCH_POLL`, 15 seconds by default), and one during a Docker pull or the parse check
  when that returns. (P5)
  Why: the rollback is not instant, so a restart inside that window would still apply the edit.
- edit-config's "Refresh chain configs" copies the new genesis, committee and parameters files
  without recording backups, so a run stopped during its epoch wait keeps the new files for the
  next restart. This is by design, since they are the files a network restart needs. (P5)
  Why: an operator who cancels a refresh still gets the new chain configs at the next restart.
- edit-config's BLS passphrase edit waits for the epoch boundary, then stops the node, writes the
  new passphrase file and starts the node; a signal in the few seconds between the stop and the
  start leaves the node stopped with the new file. (P5)
  Why: a cancelled passphrase change can leave the node down until someone starts it.
- In the edit-config menu a refused edit can end the script: under errexit,
  `edit_bls_passphrase` returning 1 (for example "Passphrase file not found") exits the menu, and
  several prompts exit at end of input. Pre-existing. (P5)
  Why: a refused edit drops the operator out of the menu instead of back into it.
- The edit-config menu's Docker image edit pulls the image before the check that refuses a launch
  file with more than one node command; `--set` checks first. (P5)
  Why: a large download is wasted on an edit that is then refused.
- `set_env_var` (listener edits on binary installs) and `edit_rpc` in edit-config use GNU-only
  `sed -i`. (P5)
  Why: portability only; it works on Ubuntu but would break with a BSD sed.
- setup-node's warning that `--binary-path` is used only with `--install-method existing` is
  printed before the welcome screen clears the terminal. (P4a)
  Why: the interactive operator never sees it.

## Updates, removal and migration

- update-node's interactive prepare prints "Run this script again when you are ready to apply."
  and exits 0 even when the prepare failed, a refused ref included. (P6)
  Why: the operator is told to apply a prepare that never happened.
- On a host with both a legacy unit and the unified layout, remove-node reads the unified
  `.node-meta` for the legacy unit (`config_dir_for_unit` ignores the unit), so that unit's
  container and service account are left behind. The menu also has no entry for removing one of
  several nodes. (P3, V-CORE-2-rn)
  Why: a partial teardown leaves a container and an account the operator thinks are gone.
- migrate-node-naming opens 49590 and 49594 instead of the node's own P2P ports; OPERATOR.md
  documents it as is. (DOC-2)
  Why: a legacy node on other ports gets rules for ports it does not use and none for the ones it
  does.
- Nodes migrated by migrate-node-naming 1.2.0 keep `NODE_TYPE=observer` in `.node-meta`. Running
  1.2.1 again does not remove it and nothing else does; nothing reads the key either. (P3)
  Why: optional cleanup of a stale line that can mislead someone reading the file.

## Library

- Delete the deprecated `tn_resolve_node_type` stub in `lib/fallback.sh`, and its comment saying
  firewall-setup still calls it, in the release after firewall-setup 1.6.0 reaches operators.
  (L1, L2)
  Why: dead code that suggests `.node-meta` still decides a node's role.
- `check_ports` in `lib/common.sh` pipes `ss` into `grep -qE` under pipefail. Capture the output
  first and grep the variable, as `ufw_active` and `ufw_has_allow` now do. (L2)
  Why: when grep exits early, `ss` can die of SIGPIPE and a busy port reads as free.
- `validate_port` in `lib/common.sh` accepts leading zeros: `0101` passes because its arithmetic
  test reads it as octal 65, while `09101` fails. `^[1-9][0-9]{0,4}$` would be stricter; nothing
  can be injected either way. (P4b)
  Why: a port typed with a leading zero passes a check that read it as a different number.
- Five scripts each carry their own progress printer for `tn_wait_restart_window`
  (`update_wait_say`, `edit_wait_say`, `caddy_wait_say`, `addons_say`, `obs_wait_say`), all
  mapping `step`, `warn` and `log` to a JSON event or a `print_*` line with the same JSON-mode
  branching. One shared `tn_wait_printer` in `lib/common.sh`, taking the JSON flag and the
  script's event function, would replace them. (code review)
  Why: a change to the wait's event vocabulary has to be copied into five files today.
- `prompt_testnet_addons` in `lib/common.sh` takes the region label without checking it.
  setup-node cuts the answer to letters, digits, `_` and `-` (32 at most) afterwards, with a
  warning; the prompt itself could ask again. (P4b)
  Why: the operator learns of a bad label only from a warning after the prompt has moved on.
- `tn_node_parse_check` accepts `--state-export-keep 3` without `--enable-state-export`, because
  the probe does not apply clap's "requires" rules; callers pair the two flags themselves. (V-L)
  Why: a flag combination that passes the check can still stop the node at start.
- `tn_rpc_call` reports `rpc-error <code> <message>` and drops the error's `data`, so
  prepare-stake keeps a private RPC call to decode registry reverts. A `data=<hex>` suffix or a
  revert-data helper would let it go. (D)
  Why: every later script that wants to name a contract revert has to repeat that code.
- `tn_keytool`'s `-q` hides keytool's WARN lines along with the INFO line (errors still reach
  stderr); the launch-file parser does not read a heredoc inside a start wrapper; flag edits leave
  a double space on a one-line wrapper. (L2)
  Why: keytool warnings never reach the operator, and a hand-edited wrapper with a heredoc can be
  misread.
- `print_validator_onchain_status` still tells an address with no record to call `stake()` with
  its BLS key by hand instead of naming `prepare-stake.sh`. (D)
  Why: the hint sends operators down the manual path the helper now covers.
- `tn_sync_submodules` still hands the update-lock descriptor to `git submodule`. The lock is
  released anyway, so closing the descriptor there (`9>&-`) is for consistency. (P6)
  Why: an orphaned git process keeps the lock descriptor open.
- `lib/common.sh` and the UI server decode `getValidator` words 5 and 6 as `stakeVersion` and
  `region`, the tn-contracts layout at v0.15.0-adiri. Live testnet replies have zero in both
  words, so the layout of the deployed registry is unconfirmed; check it against a validator
  with a non-zero value. (UI-2b)
  Why: if testnet runs the older layout, the UI shows the wrong stake version.

## Public RPC

- Per-IP rate limiting is deliberately not automated. Block v2 caps request bodies at 2 MB with
  stock Caddy; per-IP limits need a custom Caddy build or a proxy in front. (plan, A)
  Why: one heavy client can still slow a public node, validator duties included, and operators
  who need limits must add them.
- Caddy's 2 MB `request_body` cap cuts an oversized POST only after reth has received the headers
  and the first 2,000,000 bytes. A Content-Length matcher that answers 413 before `reverse_proxy`
  would stop requests that declare their length; chunked bodies would still stream. (A, V-OPS-1)
  Why: reth still reads up to 2 MB of every oversized request.
- The RPC block's `Access-Control-Allow-Methods` lists GET, which always gets the 405 page. (A)
  Why: the header names a method the endpoint refuses (cosmetic).
- install-caddy treats a hand-edited block that still carries the `# tn-rpc block v2` stamp as
  current, and a later rpc-enable for the same hostname rewrites it; only the timestamped backup
  keeps the edit. (A, V-OPS-1)
  Why: an operator's own changes to the RPC block are replaced without warning.
- The 405 landing page is written from the plan, so when the planned `--ws` launch edit then
  fails, the page mentions `wss://` until the next rpc-enable. (A)
  Why: the page advertises a WebSocket endpoint the node does not serve.
- The UI's "Refresh Caddy block" re-runs rpc-enable without an inbound IP, and install-caddy
  neither records nor reports a `--public-ip` override. (UI-3a)
  Why: on a 1:1-NAT host first enabled with `--public-ip`, the refresh's DNS check can fail.

## Health check

- check-node shows the bootstrap-peers file only as information. It should fail when the launch
  line reads the map from a file that is missing or empty, since v0.15.0-adiri then refuses to
  start, and, once edit-config keeps `.node-meta` current, flag a `STATE_EXPORT` that disagrees
  with the launch line. (P4b)
  Why: the node will not come back after its next restart, and check-node says nothing.
- The wss probe's limit for a silent server is 15 polls of `sleep 0.1`, about 1.7 seconds;
  `read -t 0.1` would be tighter but needs bash 4. (B)
  Why: a slightly longer run, accepted to stay bash 3.2 safe.

## Firewall and observability

- `_obs_has_metrics` in `lib/observability.sh` checks only that `--metrics` is present, not that
  its address matches `obs_metrics_addr`; `tn_launch_flag_get` already returns the value. (C)
  Why: Alloy can scrape a port the node does not serve, so the metrics pipeline reports itself on
  while it ships nothing.
- `obs_enable` dry-runs the flag edit before it touches Alloy, but a launch-file write that fails
  after a passing dry run still leaves Alloy re-rendered and restarted while `.node-meta` keeps
  the old `ENABLE_*` values. Accepted for now. (C, V-OPS-2-obs)
  Why: Alloy runs a pipeline the node does not feed until the operator enables again.

## Staking helper

- `prepare-stake.sh --rotate-address` cannot unseal a TPM-sealed passphrase. TPM installs delete
  the plaintext passphrase file after sealing, so rotation needs `TN_BLS_PASSPHRASE` or the
  prompt. (D)
  Why: TPM operators must type or export the passphrase to rotate.
- prepare-stake recognises a short balance in the `stake()` simulation by reth's message
  ("insufficient funds", code -32003); by design, any other simulation error is only a warning.
  (D)
  Why: if reth rewords that error, a short balance shows as a warning instead of a refusal.

## Node Manager UI

- An action stops when the operator closes the browser or leaves the Update or Config tab: the
  stream ends and the server terminates the script two seconds later. An update, a config save,
  setup, rpc-enable and rpc-disable can each sit in the epoch wait for up to 30 minutes, so the
  window is long. The abort comes before the node is stopped, but the action has to be run again,
  and the Update tab promises "brief downtime" with no notice to keep the tab open. Fix: hand the
  child to a background reaper that keeps draining its output (or keep the stream alive in the
  page), add the notice, and confirm that update-node leaves the node and its staging consistent
  when it is terminated mid-wait. (plan, UI-2a, UI-2b, UI-3a, P6, A, DOC-2)
  Why: operators abort long actions without meaning to.
- The UI cannot skip the epoch wait for an update or a config save: the helper's arguments are
  fixed and sudo resets the environment, so neither `--no-epoch-wait` nor `TN_SKIP_EPOCH_WAIT`
  gets through. (P6, P5)
  Why: a UI operator who needs a restart now has no override and waits up to 30 minutes.
- The firewall card's three toggles still act on 49590 and 49594 when the node listens elsewhere
  (its other ports are listed read-only from `p2p_ports`); the page could grey the toggles out
  when `p2p_ports` lists none of them. The Config tab has no inputs for `bootstrap_peers`,
  `state_export`, `allow_private_forward_targets` or `metrics=off` (its metrics check rejects
  `off`), the config API does not report their values, and the setup wizard sends none of the
  three node flags; the helper and the server already accept the config fields.
  (C, UI-1, P4b, DOC-1, DOC-2)
  Why: a UI-only operator on non-default ports cannot open the right ports, and cannot use the
  new settings without a shell.
- The wizard's completion card does not use finalize's `operator_guide` field, so it shows no
  link to the operator runbook. (P4a)
  Why: a new operator who finishes in the UI is not pointed at the runbook.
- The helper never passes `--binary-path` (there is no `TN_SETUP_BINARY_PATH`), so a wizard
  `existing` install depends on keygen finding the binary on PATH or under `/usr/local/bin`,
  `/opt` or `/home`. (P4a)
  Why: a binary anywhere else cannot be used from the wizard.
- When the wizard's public RPC hostname already serves the dashboard, setup only warns, because
  setup-node has no `--move-dashboard-to`; public RPC stays pending until the System tab's RPC
  card moves the dashboard. (UI-3b)
  Why: setup cannot finish this case in one step.
- install-ui reads its "Start the UI now?" and "Enable the UI on boot?" answers only from a
  terminal and otherwise answers yes, so piped answers are ignored. (UI-1, V-UI)
  Why: an unattended install that pipes "n" still starts the UI and enables it at boot.
- When a script that sends its own JSON `error` fails, the server adds its stderr tail as a second
  `error`; install-caddy's `die` triggers this. Skip the tail when the child already sent an
  `error`. (A)
  Why: the same error shows twice in the UI log.
- `ui/server.py` has no mainnet entry (chain 487) in `NETWORKS` and `NETWORK_PUBLIC_RPC`. Add it
  when mainnet launches; `https://rpc.telcoin.network` serves chain 2017 today. (UI-2b, UP)
  Why: a mainnet node would get no network answer for its view and no comparison cards.
- After a successful RPC enable, disable or withdraw, the card re-renders and the stream log
  disappears. (UI-3a)
  Why: warnings printed during the run are lost.
- The Network tab links `https://status.adiri.telcoin.network/`, while the server's
  `STATUS_PAGE_BASE` and its error text use `https://status.telscan.xyz`. (UI-3a)
  Why: there are two status-page addresses, so one is probably wrong.
- The live log tail (`/api/logs/<t>/stream`) sends raw EventSource lines with no `done` or
  `closed` event, unlike the action streams. (UI-2a, V-UI)
  Why: the page cannot tell a finished tail from a dropped one.
- `/api/addons/status` still requires `?node_type=`, which the helper no longer uses. (UI-2a)
  Why: a request without it gets a 400 for nothing.
- The wizard's Back button on step 5 stays usable after keygen and offers Generate Keys again,
  which setup-node refuses; a refused finalize offers only a retry. Pre-existing. (UI-3b)
  Why: the operator reaches a dead end after keygen.

## Updater

- `update-scripts.sh` sources `lib/fallback.sh` at top level, so under bash 3.2 with `set -e` a
  copy that is present but broken stops the updater, with no output, before it can repair the
  file. Only the restart hint needs the library; resolve it after the downloads, in a child
  shell. (V-CORE-2-us)
  Why: on macOS a broken library blocks the only repair path.
- `update-scripts.sh` needs curl and reports a missing curl as "Cannot reach ... check
  internet/DNS", while `install.sh` accepts a box that has only wget. (V-CORE-2-us)
  Why: a wget-only operator installs fine, then cannot update and gets a misleading message.
- Smaller output problems in `update-scripts.sh`: end of input at the Y/n prompt exits 1 without
  a word; Ctrl-C leaves `<file>.tmp` behind; `version_gt` prints arithmetic errors when the local
  version is "unknown"; "unavailable" overflows its column; the counts say "script(s)" for data
  files and include the forced re-download of the library pair; the restart hint appears only
  after a fully successful run. (V-CORE-2-us)
  Why: the output confuses, although nothing wrong gets installed.
- `download_updates` expands `"${FILES_TO_UPDATE[@]}"` under `set -u` with no empty-array guard;
  it is safe only because `check_versions` exits when nothing is due. (P3)
  Why: a later change to that flow would stop the updater with "unbound variable" under bash 3.2.

## Maintainer tooling and CI

- `tools/check-bash32.sh` misses `read -N`, `shopt -s globstar`, `{1..10..2}`, `local -`,
  `declare -I`, `unset 'a[-1]'`, `$'\u…'` and a redirection placed before `declare`, and a
  `# bash32-ok` inside a string also hides its line. (V-CORE-2-lint)
  Why: bash 4 code can still reach macOS operators past CI.
- The lint also trips on valid code: an array literal containing the word `mapfile` is reported,
  and a case arm such as `a)#it's`, or a heredoc opened on a line that also opens a quote, makes
  it exit 2. (V-CORE-2-lint)
  Why: CI can fail on correct code, and the only workaround is `# bash32-ok`.
- The page's JavaScript tests and browser walk-throughs used during the UI work stayed outside
  the repo; CI runs only the Python tests and `ui/tests/helper_test.sh`. (UI-3a, UI-3b)
  Why: page regressions, such as the firewall-card error found in review, are not caught by CI.
- `shellcheck -x --severity=warning` reports 32 warnings in 12 files, 13 of them in
  `lib/common.sh` and 5 in remove-node. 24 are SC2034 (unused variables); the rest are SC2206
  (unquoted splitting into an array: 2 in update-scripts, 1 each in `lib/common.sh` and
  firewall-setup), SC1090 (2 in update-node) and SC2115 (2 in remove-node, an `rm -rf` path not
  guarded with `${var:?}`). CI's warning step is advisory. (V-OPS-2, V-DOC)
  Why: noise in the advisory step hides new warnings, and remove-node's two SC2115 deserve a
  look of their own.
- `tools/build-partner-pdf.sh` skips its check for forbidden text in the PDF when `pdftotext` is
  missing; `brew install poppler` on the maintainer's machine enables it. (DOC-3)
  Why: today the partner-guide rules are checked on the HTML only.
- In `docs/partner/theme.css`, `td code { overflow-wrap: break-word }` lets inline code in a
  table cell break after a leading `--`, as in `--network-rpc <URL>`. (DOC-3)
  Why: a cosmetic defect in the partner PDF.

## Docs in this repo

- `--help` gaps. `setup-node.sh --help` lists none of the flags `--json` runs use (`--network`,
  `--install-method`, `--binary-path`, `--build-ref`, `--docker-image`, `--address`,
  `--external-*`, `--listener-*`, `--data-dir`, `--passphrase-method`, `--advertised-name`,
  `--service-user`, `--service-group`, `--genesis-dir`, `--enable-healthcheck-monitor`).
  `update-node.sh --help` lists none of `--json`, `--check`, `--prepare`, `--ref`, `--apply` and
  `--yes`. install-caddy, firewall-setup, setup-observability and remove-node answer `--help`
  with "must be run as root". (DOC-1, DOC-2)
  Why: operators and integrators must read the README to find a flag, and need sudo to read the
  usage.
- The `format-output` pass, the layout rules for README files (one sentence per line among them),
  was not applied to README.md or OPERATOR.md. (DOC-1, DOC-2)
  Why: both files keep a mixed layout, which makes later diffs harder to review.
- README's procedure for converting a unit-started Docker node to a start wrapper mirrors
  setup-node 1.3.0's wrapper but has never been run on a real legacy node. (DOC-1)
  Why: operators need it before they can use bootstrap peers on such a node, and it is untested.
- The "Public node tuning" values in README are labelled unmeasured; measure them on a busy
  public RPC node. (DOC-1)
  Why: operators tune by numbers nobody has measured.
- OPERATOR.md says the largest legitimate JSON-RPC request is about 256 KiB, which nobody has
  verified independently. Verify it or soften the sentence. (DOC-2)
  Why: it is the stated reason the 2 MB cap is safe.
- OPERATOR.md keeps a hidden anchor, `64-export-the-stake-calldata-on-the-node`, for an old
  README link; remove it once README's link to "Stake by hand" has shipped. (DOC-2)
  Why: a leftover anchor that nothing links to.

## Maintainer repos (devnet-genesis and the fleet)

- The fleet's `common/config-caddy.sh` (maintainer-only, never shipped to operators) still has a
  case-sensitive WebSocket matcher, so `Connection: upgrade` as Google's load balancer and nginx
  send it gets 405; it also has a 30-second backend timeout, dead CSS in its 405 page and a wrong
  health-check comment. The balanced hostnames answer 405 to every WebSocket upgrade. Fix these
  in the maintainer repo, never from this one. (plan)
  Why: WebSocket clients that come through a proxy cannot connect to fleet nodes, and long
  requests are cut at 30 seconds.
- devnet-genesis still calls the deprecated `setup-observer.sh` and `setup-validator.sh` shims;
  move it to `setup-node.sh` so the shims can be retired. Its commit e732765 (the node 5
  `config.sh` comment) is committed locally and not pushed yet. (plan, UP)
  Why: the shims stay in this repo and in the updater while maintainer tooling still calls them.

## Upstream (telcoin-network and tn-contracts)

- The telcoin-network branch `docs/operator-docs-backlog` (13 commits) is prepared locally. Push
  it and open the PR, which needs `make attest` on the head commit. Once it is merged and
  deployed, drop README's note that the upstream how-to-stake guide shows outdated signatures.
  (UP, V-UP, DOC-1)
  Why: until it merges, the published docs keep the staking ABI, worker port and endpoint
  mistakes this repo works around.
- The versioned docs page for v0.15.0 stays wrong; the branch corrects the current docs only.
  (plan, UP)
  Why: an operator reading the docs for the release they run still sees the old mistakes.
- tn-contracts' `StakeConfig` comment in `IStakeManager` says `epochDuration` is in L2 blocks;
  the node and the registry use seconds. (UP)
  Why: anyone timing epochs from the contract docs is off by a large factor.
- The telcoin-network CLI README has drift outside the sections the branch touched: its keytool
  `generate` flags table omits `--rpc-http` and `--rpc-ws`, and the `--workers` row says "1-4,
  must be 1" while clap accepts 1 to 65536 and the real limit is the on-chain worker count, 1
  today. (UP)
  Why: operators reading the CLI reference miss the RPC flags and get a wrong worker range.
- telcoin-network's `etc/compose.yaml` uses UDP 49595 for the worker on its private bridge, and
  the CLI README's Docker environment row mirrors it on purpose. (UP)
  Why: it differs from the 49594 convention, so an operator comparing the two may think one is
  wrong; it matters only inside the compose network.
