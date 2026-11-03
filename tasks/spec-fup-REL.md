# REL: manifest freshness and the release report (issue #40)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-REL`, branch
`fup/REL`, checkpoint `tasks/ckpt-fup-REL.md`.

## Goal

A signed script release carries an expiry date; a stale release is reported by the updater,
the installer and `check-node`, and `update-scripts.sh --check` answers "what is installed,
what is current, has it expired" with an exit code a cron job can use.

## Owned files

`tools/release-scripts.sh`, `update-scripts.sh`, `install.sh`, `check-node.sh` (one new
report block only; LIB-B edits `resolve_network` in the same file: add, do not reflow),
tests `tools/tests/updater_manifest_test.sh`, `tools/tests/release_scripts_test.sh`,
`tools/tests/install_test.sh`, `tools/tests/check_node_unit_test.sh` (append a `# REL` block).

## Facts (main 1187ddb)

- MANIFEST today: `format=1`, `release=<tag>`, `serial=<n>`, `min_updater=<ver>`, then
  `sha256  <hash>  <path>` lines sorted by path (tools/release-scripts.sh header). No release
  exists yet; the user cuts `scripts-v2.0.0` (serial 1) with the tool as it is on main
  BEFORE this PR merges, so the first manifest has no `expires=` and 2.0.0 updaters must
  keep accepting manifests with and without it.
- update-scripts.sh: `verify_manifest` :342, `manifest_bad` :358, `parse_manifest` :366
  (counts `format`, `release`, `serial`, `min_updater` lines and refuses a duplicate; sets
  `M_SERIAL`, `M_MIN_UPDATER`; unknown keys fall to the hash-line parser: check what happens
  to an `expires=` line there and make 2.0.0's behaviour explicit in the checkpoint: if
  2.0.0 would refuse an unknown key, say so, because the user must then cut 2.1.0 before any
  manifest carries `expires=`), `refuse_min_updater` :441, `usage` :736. The installed copy
  of MANIFEST lives beside the installed scripts (grep where the updater keeps it after an
  install: `INSTALL_DIR`/`MANIFEST`).
- install.sh: manifest parse :177-215 (`format=*|release=*|serial=*|min_updater=*`).
- tools/release-scripts.sh: `[--serial N] [--min-updater X.Y.Z] [--date YYYY-MM-DD] TAG`;
  `--check [--tag TAG] [--require-sig]`; prepare needs a clean tree; `--check` compares the
  tree with MANIFEST.
- check-node.sh prints a report of `ok|warn|info` lines; LIB-B owns the network block. The
  installed scripts dir and its MANIFEST are readable without sudo (check modes).
- CI "release manifest" job runs `release-scripts.sh --check --require-sig` only when
  MANIFEST/MANIFEST.sig/RELEASE change, and `--check --tag` on tags.

## Required behaviour

1. `tools/release-scripts.sh --expires DAYS` (default 90) writes `expires=YYYY-MM-DD` (UTC,
   date + DAYS) after `min_updater=`; `--check` reports the expiry and warns when it is past
   (rc stays 0 for `--check` unless `--require-fresh` is given: then rc 1 when expired).
2. `parse_manifest` (updater) and the installer's parser accept `expires=` at most once,
   `YYYY-MM-DD` only; a malformed value is `manifest_bad`. A missing key is fine (old
   manifests).
3. Updater: when the newest manifest has expired, every run prints a warning ("Script release
   <tag> expired on <date>; a newer signed release is overdue. Installing it anyway." or, if
   you judge refusal right, say why in the checkpoint; the decision is: WARN, install) and
   continues. `update-scripts.sh --check` (no root needed): prints the installed release
   (tag, serial, date from the installed MANIFEST), the newest release on main (RELEASE +
   fetched MANIFEST, verified signature), whether an update is pending, and the expiry;
   rc 0 fresh and current, rc 1 expired (installed or newest), rc 2 nothing installed or
   the check could not fetch. `--json --check` if the updater has a JSON mode (grep); else
   plain lines.
4. install.sh: the same warning when the release it is about to install has expired.
5. check-node: a "scripts" block: installed release tag, serial, release date, age in days,
   `expires` and "expired N days ago" as `warn`, "no signed release installed" as `warn`.

## Tests

`updater_manifest_test.sh` (uses `tools/tests/signing.sh` for signed fixtures): manifests
with/without `expires=`, malformed, duplicate; expired → warning text + install proceeds;
`--check` rc 0/1/2 with the printed fields; a 2.0.0-shaped manifest (no expires) is still
accepted. `release_scripts_test.sh`: `--expires 30` writes the right date (stub `date` or
compute with the same command); `--check` prints the expiry; `--require-fresh` rc 1 on an
expired one. `install_test.sh`: the warning. `check_node_unit_test.sh`: the block for
installed, expired and absent. Under bash 5.3, `bash:3.2` (busybox `date` has no `-d`:
implement the date arithmetic portably, e.g. with the existing helpers or a pure-bash
day count, and prove it under 3.2), `ubuntu:24.04`.

## Docs notes to hand over

The `expires=` key and default, `--expires` and `--require-fresh`, the warning texts, the
`--check` output and exit codes, the check-node block, and "2-of-N signatures wait until
two signer keys exist".
