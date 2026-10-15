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
`docs/partner/mno-node-guide.md` is the partner guide for mobile network operators, the
source of the branded PDF beside it. When a change alters operator-visible behaviour
(flags, prompts, paths, ports), update `OPERATOR.md`, the README and the partner guide
together, then rebuild the PDF (see "Partner guide (MNO PDF)" below).

## The boundary rule

Operator-facing scripts must **not** depend on any `common/` script at runtime. That
covers:

`setup-node.sh`, `edit-config.sh`, `prepare-stake.sh`, `migrate-node-naming.sh`,
`check-node.sh`, `update-node.sh`, `update-scripts.sh`, `firewall-setup.sh`, `setup-vpn.sh`,
`setup-observability.sh`, `install-caddy.sh`, `remove-node.sh`, `install.sh`, `open-ui.sh`
(it runs on the operator's own computer), the deprecated `setup-observer.sh` and
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

## Ownership: root owns the install

On a node host the service account (`telcoin` by default) owns one tree: the data dir
(`/var/lib/telcoin`, 0700). Everything else the scripts install belongs to root: the install
and config dirs (`/opt/telcoin`, `/etc/telcoin`, root 0755), `.node-meta` (root 0600),
`node.env` (0644), the passphrase files, the start scripts under `/usr/local/libexec/telcoin`,
the node binary and every directory above it, the log dir (`/var/log/telcoin`,
root:telcoin-log 0750), `/var/backups/telcoin`, `/var/lib/telcoin-staging` and the update lock
under `/run/telcoin`. `.node-meta` records the layout as `OWNERSHIP_LAYOUT=2`, `check-node.sh`
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
  setup-vpn and setup-observability go through `addon_meta_write_begin`. A teardown or a read
  that must also work on the old layout takes the lock alone (`addon_meta_lock`). On mainnet
  the migration refuses with rc 3: a mainnet host on the old layout is installed fresh.
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
seconds (default 300), it waits for the epoch to close and then `TN_EPOCH_SETTLE` seconds (90),
never longer than `TN_EPOCH_WAIT_MAX` (1800; 0 turns the wait off). `TN_SKIP_EPOCH_WAIT=1`, and
`--no-epoch-wait` where a script offers it, skip the wait. A node whose mode cannot be read
still waits when it is staked (or, on mainnet or an unknown network, when its stake cannot be
read either). When the boundary cannot be read from the node or from the network's public RPC,
it waits `TN_EPOCH_MARGIN` + `TN_EPOCH_SETTLE` seconds, capped by `TN_EPOCH_WAIT_MAX`.

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
the wait. update-node runs both just before it stops the node. edit-config, install-caddy and
the observability add-on write their files first and run both right before the restart. When
the guard refuses, nothing restarts: update-node leaves the running node as it was, and
edit-config and install-caddy put back what they wrote. `--no-epoch-wait` and
`TN_SKIP_EPOCH_WAIT=1` skip the wait, never the guard. Rollback restarts run neither. Any new
code that stops or restarts the node runs the guard, then the wait, right before the stop:
"wait first, then stop" is about the stop, not about every file edit. A script that owns its
EXIT trap sets `TN_EXIT_TRAP_OWNED=1` before `tn_acquire_update_lock` and calls
`tn_release_update_lock` from that trap.

## One-way storage migration (v0.16.0-adiri)

The first start of v0.16.0-adiri migrates the consensus store (`<data dir>/consensus-db/epochs`,
epoch packs v1 to v2), and older releases cannot open the data dir afterwards (`invalid
version`). So update-node (since 1.2.1) never rolls back on its own across the 0.16.0 floor
(`STORAGE_MIGRATION_FLOOR`). `storage_migrating_upgrade` judges the running release from the
image tag on Docker installs (for an image run by digest, the `RELEASE_TAG` recorded with that
`DOCKER_IMAGE_DIGEST`) and from the root-owned `/opt/telcoin/telcoin-network.version` on source
and release installs, never from the checkout's `git describe`; an unreadable running release
counts as older. A failed check does not stop the node or restore the old binary or image,
clears the pending state, keeps the version marker and prints the snapshot-restore steps. In
`--json` mode it ends with a `done` carrying `"rolled_back":false` and
`"storage_migration":true`, and `--check` reports the same boolean. The maintainer fleet driver
(adiri-genesis `adiri-update-all.sh`, maintainer-only) reads both fields and sets
`TN_UPDATE_VERIFY_TIMEOUT`, so keep those names. Do not re-add an automatic binary or image
rollback for that case: only a data dir snapshot taken before the update can undo it.

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

## Partner guide (MNO PDF)

`docs/partner/mno-node-guide.pdf` is the guide the Association hands to prospective mobile
network operators. It is generated, never edited by hand. The source is
`docs/partner/mno-node-guide.md`; the look comes from `docs/partner/template.html`,
`docs/partner/theme.css` and the vendored logos and fonts under `docs/partner/assets/`;
the version, date and subtitle live in `docs/partner/metadata.yaml`.

- Rebuild with `bash tools/build-partner-pdf.sh` after changing the Markdown,
  `metadata.yaml`, `template.html`, `theme.css` or anything under `assets/`. Preview the
  HTML without WeasyPrint using `--html-only --open`. Where WeasyPrint cannot run natively,
  build in the `tn-pdf-tools` container from the repo root. `tn-pdf-tools` is a locally built
  image (Debian 12, pandoc 3.8.3, WeasyPrint 70.0); no Dockerfile for it is committed.

  ```
  docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/w" -w /w tn-pdf-tools bash tools/build-partner-pdf.sh
  ```

- Bump `version` and `date` in `metadata.yaml` with every content change. The build warns
  when the Markdown changed and the metadata did not.
- The document title is the single `#` heading in the Markdown. Do not add a `title:` key
  to `metadata.yaml`, and keep no prose between the `#` heading and the first `##`.
- Partner readers never see legacy installs. The guide carries no `--observer`,
  `migrate-node-naming`, `setup-observer.sh` or `setup-validator.sh` material and no
  "legacy" wording, and its only contact is `support@telcoin.org`. The build script refuses
  the source otherwise.
- Links to other files in this repo are absolute URLs under
  `https://github.com/Telcoin-Association/tn-node-deployment/blob/main/`, because the PDF
  has no repo around it. Cross-references inside the guide are heading links such as
  `[Back up the keys now](#back-up-the-keys-now)`. Headings and prose carry no manual
  numbers; pandoc numbers the chapters at build time.
- Commit the PDF together with the sources that produced it. If only the toolchain changed
  (a pandoc or WeasyPrint upgrade), the script keeps the committed PDF and says so; pass
  `--force` to overwrite it deliberately.
- Reference toolchain: pandoc 3.11 and WeasyPrint 70.0 from Homebrew (`brew install pandoc
  weasyprint`). The script checks for pandoc 3.8+ and WeasyPrint 61+. Same inputs and same
  toolchain give byte-identical output; a second run prints "PDF unchanged".
- Nothing under `docs/partner/` or `tools/` is updater-tracked or carries a `.sha256`
  sidecar. The fonts are Geist and Geist Mono under the SIL Open Font License 1.1; keep
  `OFL.txt` beside them and record provenance in `docs/partner/assets/README.md`.

## Vendored files

Some files are **vendored from `adiri-genesis`** and kept in sync by hand:

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
`scripts-vX.Y.Z` tag on a commit of main. That commit carries `MANIFEST` and `MANIFEST.sig` at
the repository root, and `RELEASE` on main (one line, `<tag> <date>`) names the current tag.

- `MANIFEST` holds `format=1`, `release=<tag>`, `serial=<n>` and `min_updater=<version>`, then
  one `sha256  <hash>  <path>` line per file. `tools/release-scripts.sh` builds it from the
  `SCRIPTS`, `UI_BUNDLE` and `TESTNET_ADDONS_BUNDLE` arrays in `update-scripts.sh`, plus
  `install.sh`, `open-ui.sh` and `lib/allowed_signers`. The three arrays stay the single
  source of truth for what operators receive.
- The release signer signs `MANIFEST` with a hardware-backed SSH key
  (`ssh-keygen -Y sign -f <key> -n tn-node-scripts MANIFEST`), which writes `MANIFEST.sig`.
  Hosts verify it with
  `ssh-keygen -Y verify -f lib/allowed_signers -I release@telcoin.org -n tn-node-scripts`.
  `lib/allowed_signers` lists the keys allowed to sign, and `install.sh` carries an identical
  copy.
- `serial` rises with every release. The updater refuses a serial lower than the installed
  one, and the same serial with a different manifest. `min_updater` is the oldest
  `update-scripts.sh` that can install the release (`--min-updater`; by default the previous
  release's value, and never above the tree's own `SCRIPT_VERSION`). A host whose updater and
  the release's copy of it are both older is told to rerun the installer one-liner.
- `update-scripts.sh` reads `RELEASE`, fetches `MANIFEST` and `MANIFEST.sig` from that tag and
  verifies them, then downloads every changed file from the tag into a staging dir
  (`$SCRIPT_DIR/.tn-update.XXXXXX`) and checks each one against its MANIFEST hash, its
  `.sha256` sidecar when one is published, and `bash -n`. Only when every file passes does it
  install them, all together. It removes files the release no longer lists and writes
  `MANIFEST` and `MANIFEST.sig` last, as the record of the installed release. A refusal or a
  failure leaves the tree as it was. The updater takes no lock, and it no longer redeploys the
  Node Manager UI: it prints `sudo bash ui/install-ui.sh --update` for the operator to run.
- When the release lists a different `update-scripts.sh`, the running updater stages and
  verifies the whole release first, then runs the release's copy from the staging dir with
  `TN_UPDATER_RELAUNCHED=1`. That copy sees that it runs from a `.tn-update.*` dir, adopts the
  staging dir and installs everything, itself included, in one pass. Every future
  `update-scripts.sh` must keep that detection; without it the relaunched copy would treat the
  staging dir as the install. `tools/tests/updater_manifest_test.sh` checks it.
- The one-time bootstrap: hosts on update-scripts 1.1.72 or older know nothing of manifests.
  They fetch each tracked file from main and check it against its `<file>.sha256` sidecar, so
  their next run installs update-scripts 2.0.0 that way (unsigned, hashes from main), and every
  update after that is a signed manifest. The first signed run on a tree with neither
  `lib/allowed_signers` nor an installed `MANIFEST` fetches `lib/allowed_signers` once, through
  its sidecar on the tag, and checks it against its MANIFEST line. From then on a new signer
  list arrives only inside a manifest that verifies against the installed one. That is why the
  sidecars stay: `tools/gen-checksums.sh` still writes them from the three arrays, the
  `checksums` CI job fails on a stale or missing one, and `release-scripts.sh` requires a fresh
  sidecar for every array file and for `lib/allowed_signers`.
- Rotating a signing key: updaters verify a new release against the signer list they already
  have, while `install.sh` and `release-scripts.sh --check` verify it against the list the
  release ships. A release that changes `lib/allowed_signers` must therefore be signed by a key
  that is in both the old and the new list.

To cut a release:

1. On a clean checkout of the release branch, run
   `bash tools/release-scripts.sh [--serial N] [--min-updater X.Y.Z] scripts-vX.Y.Z`
   (`--serial` is required for the first release). It writes `MANIFEST`, `RELEASE` and the tag
   and signer block in `install.sh`, removes the previous `MANIFEST.sig`, and prints the
   signing commands. It never signs.
2. The release signer signs `MANIFEST` on the machine that holds the hardware key and checks
   the result with `bash tools/release-scripts.sh --check --tag scripts-vX.Y.Z`.
3. Commit `MANIFEST`, `MANIFEST.sig`, `RELEASE` and `install.sh` and open the release pull
   request. The `manifest` CI job runs `release-scripts.sh --check --require-sig` on it.
4. Right after it merges, tag the merge commit on main (`git tag -a scripts-vX.Y.Z`) and push
   the tag. `RELEASE` on main names the tag from the merge on, and until the tag exists every
   updater that reads it fails to fetch the release, including the first signed run on a host
   that has just bootstrapped.
5. The tag push runs `publish-installer.yml`, which checks that the tag is on main and that
   `release-scripts.sh --check --tag` passes, then publishes that tag's `install.sh` to GitHub
   Pages as `https://install.telcoin.network`. The `github-pages` environment must allow
   `scripts-v*` tags. `install.sh` is pinned to its tag and carries the signer list; a copy
   without a tag refuses ("names no release").

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
`CHANGELOG.md`, `CHANGELOG/`, `README.md`, `docs/` (the partner guide and its build inputs
included), `tasks/`, `.github/`, `tools/` (the lints, `gen-checksums.sh`, `release-scripts.sh`
and `tools/tests/` included) and the Node Manager UI's tests and dev runner (`ui/tests/`,
`ui/dev/`, `ui/test_*.py`) are documentation or maintainer tooling, are not updater-tracked,
carry no `.sha256` sidecar, and must never be added to the updater arrays. `RELEASE`,
`MANIFEST` and `MANIFEST.sig` are release metadata, not tracked files: the updater reads them
from the tag and keeps the installed `MANIFEST` and `MANIFEST.sig` as its record.
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
`addons_require_lib`), which exit 2 with one message. When a script starts calling a library
helper it did not call before, add the helper to that script's list.

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

The two lints under `tools/tests/` run with the fixture tests. The CI job `hardening-lint`
runs the passphrase-print lint and the perl lint on every tracked `*.sh`.

## CI

`.github/workflows/ci.yml` runs on pushes to main, on `scripts-v*` tags and on pull requests.
Every action is pinned to a full commit SHA with its tag in a comment, the workflow token gets
no permissions by default (`permissions: {}`) and each job asks for `contents: read`; checkouts set
`persist-credentials: false`. `tools/tests/ci_pins_test.sh` checks these rules. The jobs:

- `parse-linux`: `bash -n` on every tracked `*.sh`, then `tools/check-bash32.sh` under
  Ubuntu's bash (with mawk).
- `parse-macos`: the same two checks under macOS `/bin/bash` 3.2 (with BSD awk), then
  `ui/tests/helper_test.sh` under 3.2.
- `shellcheck`: `shellcheck -x --severity=error` blocks; a second run at warning severity is
  advisory.
- `fixture-tests`: `bash tools/tests/run.sh` under bash 5.
- `fixture-tests-macos`: the same suite under macOS `/bin/bash` 3.2.
- `hardening-lint`: the passphrase-print lint and `tools/check-perl-interp.sh`.
- `manifest`: on a `scripts-v*` tag, `release-scripts.sh --check --tag <tag>`; on a change
  that touches `MANIFEST`, `MANIFEST.sig` or `RELEASE`, `release-scripts.sh --check
  --require-sig`; otherwise nothing is compared.
- `ui-tests`: on Python 3.10, installs `ui/requirements.txt` (and
  `ui/tests/requirements-dev.txt`) with `--require-hashes`, runs the UI's Python tests (pytest,
  or unittest when pytest is absent), then `ui/tests/helper_test.sh` under bash 5.
- `checksums`: runs `tools/gen-checksums.sh` and fails on a stale, missing or uncommitted
  sidecar.

`.github/workflows/integration.yml` has one job, `vm-assertions`: on an Ubuntu 24.04 runner
(a full VM with systemd), it installs logrotate, ufw and openssh-server and runs every
assertion file in `tools/tests/vm.d/` as root with `TN_VM_TEST=1`.

`.github/workflows/publish-installer.yml` runs on a `scripts-v*` tag (or by hand on one). Its
`build` job checks that the tag is on main and that `release-scripts.sh --check --tag` passes,
then assembles the Pages site from `install.sh`; `deploy` publishes it to GitHub Pages.

Required status checks in branch protection match the jobs' display names (their `name:`
lines, such as "bash -n (Linux)"), not the job ids.

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
  unless they run as root with `TN_VM_TEST=1`; `integration.yml` runs them. An item whose code
  is not in the tree reports SKIP. Do not run them on a machine you care about.
- `tools/tests/genesis.d/testnet/` holds `genesis.yaml`, `committee.yaml` and
  `parameters.yaml` from telcoin-network at the pinned tag (`TESTNET_CHAIN_CONFIGS_TAG`),
  unchanged. `genesis_hash_test.sh` checks them against the `TESTNET_*_SHA256` pins in
  `lib/common.sh`; refresh the files and the pins together.
- `tools/tests/perl-interp.d/` holds the perl lint's fixtures, and `tools/tests/signing.sh`
  the release-signing helpers of the updater and installer tests (with a stand-in
  `ssh-keygen` where the real one is absent).

Nothing under `tools/tests/` is updater-tracked or carries a sidecar. The UI's own tests live
in `ui/tests/` (`helper_test.sh`, `open_ui_test.sh`, `install_ui_test.sh`) and `ui/test_*.py`.
