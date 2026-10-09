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

## Restarts and the epoch boundary

A committee node restarted just before an epoch boundary can miss the epoch transition.
`tn_wait_restart_window` in `lib/common.sh` holds the restart of a node that votes in the
current committee (`tn_nodeMode` `CvvActive`): when the boundary is within `TN_EPOCH_MARGIN`
seconds (default 300), it waits for the epoch to close and then `TN_EPOCH_SETTLE` seconds (90),
never longer than `TN_EPOCH_WAIT_MAX` (1800; 0 turns the wait off). `TN_SKIP_EPOCH_WAIT=1`, and
`--no-epoch-wait` where a script offers it, skip the wait. update-node, edit-config,
install-caddy and `prepare-stake.sh --rotate-address` call it once they hold the update lock,
and the observability add-on calls it too. update-node waits just before it stops the node, and
install-caddy before its first node edit. edit-config and the observability add-on write the
launch file first and wait before the restart. Rollback restarts never wait. Any new code that
stops or restarts the node calls it right before the stop: "wait first, then stop" is about the
stop, not about every file edit. A script that owns its EXIT trap sets `TN_EXIT_TRAP_OWNED=1`
before `tn_acquire_update_lock` and calls `tn_release_update_lock` from that trap.

## One-way storage migration (v0.16.0-adiri)

The first start of v0.16.0-adiri migrates the consensus store (`<data dir>/consensus-db/epochs`,
epoch packs v1 to v2), and older releases cannot open the data dir afterwards (`invalid
version`). So update-node 1.2.1 never rolls back on its own across the 0.16.0 floor
(`STORAGE_MIGRATION_FLOOR`). `storage_migrating_upgrade` judges the running release from the
image tag on Docker installs and from `/opt/telcoin/telcoin-network.version` on source installs,
never from `OLD_REF`, which is `git describe` at prepare time; an unreadable running release
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
that re-signs the proof of possession for `--rotate-address`, through that process's
environment, never a command line. Future agents must keep it that way: do not add a send, a
signing step or a key prompt to it.

## Partner guide (MNO PDF)

`docs/partner/mno-node-guide.pdf` is the guide the Association hands to prospective mobile
network operators. It is generated, never edited by hand. The source is
`docs/partner/mno-node-guide.md`; the look comes from `docs/partner/template.html`,
`docs/partner/theme.css` and the vendored logos and fonts under `docs/partner/assets/`;
the version, date and subtitle live in `docs/partner/metadata.yaml`.

- Rebuild with `bash tools/build-partner-pdf.sh` after changing the Markdown,
  `metadata.yaml`, `template.html`, `theme.css` or anything under `assets/`. Preview the
  HTML without WeasyPrint using `--html-only --open`.
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

## Self-update and integrity contract

Operators stay current with `update-scripts.sh`, which fetches each tracked file from
`raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/main` and verifies it
against a committed `<file>.sha256` sidecar before installing it. The updater fails closed:
it installs nothing whose sidecar is missing, empty or unreadable, installs `lib/common.sh`
and `lib/fallback.sh` together or not at all, and verifies its own replacement against
`update-scripts.sh.sha256` before it relaunches. A tracked file committed without its sidecar
never reaches an operator.

- The set of tracked files is the `SCRIPTS`, `UI_BUNDLE`, and `TESTNET_ADDONS_BUNDLE`
  arrays in `update-scripts.sh`. That is the single source of truth for what operators
  receive.
- `tools/gen-checksums.sh` regenerates every sidecar from those three arrays, so the
  sidecars can never name a different set than the updater downloads.
- `.github/workflows/ci.yml` fails the build on a stale or missing sidecar; on any `*.sh`
  that does not parse with `bash -n` on Linux or under macOS `/bin/bash` (3.2, because
  operators can run on macOS); on a shellcheck error (warnings are advisory); on any finding
  of the bash 3.2 lint described below, which runs on both runners; and on a failing Node
  Manager UI test (`ui/test_*.py`, and `ui/tests/helper_test.sh` under bash 3.2 and 5).

So after you edit any tracked file:

1. Bump its version constant (`SCRIPT_VERSION`, `COMMON_VERSION`, `UI_VERSION`, etc.)
   so `update-scripts.sh` offers the change to operators.
2. Run `bash tools/gen-checksums.sh` and commit the refreshed `*.sha256` sidecars.
3. Keep it bash 3.2 / Ubuntu safe: indexed arrays only — no `declare -A`, no
   `${var,,}`, no `mapfile`/`readarray`, no `&>>`. Run
   `/bin/bash tools/check-bash32.sh <file>` before you commit.

The bash 3.2 lint, `tools/check-bash32.sh`, finds bash 4+ syntax that `bash -n` under 3.2
accepts but 3.2 cannot run, because it fails only when the line executes. CI runs it on every
`*.sh` under `/bin/bash` on the macOS runner and under bash on the Ubuntu runner. It flags
`declare`, `typeset` or `local` with `-A`, `-g`, `-n`, `-l` or `-u`, case modification such as
`${v,,}` and `${v^^}`, `mapfile`, `readarray` and `coproc`, `&>>`, `|&`, `[[ -v` and `wait -n`,
negative subscripts and substring lengths, `exec {fd}>`, `${v@Q}` and the other `@`
transformations, `printf` with `%(...)T`, and the `;;&` and `;&` case terminators, inside
one-line `case` arms too. A line containing `# bash32-ok` is never reported; put the reason
after the marker.

`AGENTS.md` itself is intentionally untracked (docs are not shipped to nodes), so it
has no sidecar and is absent from the updater arrays. Keep it that way.
The same holds for the other docs and the maintainer tooling: `OPERATOR.md`, `followup.md`,
`CHANGELOG.md`, `README.md`, `docs/` (the partner guide and its build inputs included),
`tools/` (`check-bash32.sh` included) and the Node Manager UI's tests and dev runner
(`ui/tests/`, `ui/dev/`, `ui/test_*.py`) are documentation or maintainer tooling, are not
updater-tracked, carry no `.sha256` sidecar, and must never be added to the updater arrays.
`README.md` must stay at the repo root, because `update-scripts.sh` HEAD-probes it as its
connectivity check.
