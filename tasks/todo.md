## Review: private alerts, a heartbeat pushed from the node host (issue #60, branch private-alerts, 2026-11-04)

Base `hardening-followups` at 4a2cf6e (rebased onto its head before the PR). Shared spec
`tasks/spec-alerts-shared.md` (section 13 records the decisions taken during the round), package
specs `tasks/spec-alerts-<PKG>.md`, checkpoints `tasks/ckpt-alerts-<PKG>.md`.

### What landed

- `lib/tn-heartbeat.sh` (new, `HEARTBEAT_VERSION` 2.1.0): the runner systemd starts from
  `telcoin-heartbeat.timer` under `DynamicUser`. Five checks in order (service state from
  `systemctl show`, loopback RPC and chain id, the top-level consensus header number advancing,
  node mode with a CvvInactive window plus block and epoch, `/health/network`), first down wins;
  pushes to up to five Kuma, healthchecks or webhook targets with the URL handed to curl through
  `-K`; state in the `StateDirectory` read through a key whitelist; exit 0/1/2. Sources nothing.
- `lib/alerts.sh` (new, `ALERTS_VERSION` 2.1.0): targets file (root 0600 from a process
  substitution), `alerts.env`, runner install, the two units, test heartbeat, enable with a test
  and a rollback that leaves `.node-meta` byte for byte as it was, targets change with restore,
  refresh that replaces only the values given, disable, status with an issue count (quiet one
  line on a host without alerts; `unknown (run with sudo)` without root). Sourced at the end of
  `lib/common.sh` behind the same guard as observability.
- `setup-alerts.sh` (new, 2.1.0): a 7-item menu with hidden URL input and `--json` with exactly
  one of `--status`, `--enable`, `--test`, `--refresh`, `--disable`; targets from
  `--targets-stdin`, `TN_ALERT_TARGETS` or a warned `--target`; `--interval`, `--stall-after`,
  `--inactive-after` (derived defaults max(180, 3 x interval), max(900, stall)), `--label`,
  `--allow-http`; exit 0/1/2/3; the lock and the baseline refresh, never a node restart.
- setup-node offers it on every network (`ENABLE_ALERTS` pending, `step_alerts` runs the child
  once the node is active, the value is read back on a re-run); check-node runs `alerts_status`
  and checks the four alerts paths' owners and modes; remove-node removes the alerts before the
  node stops at every scope and on the leftover path, with fixed paths; update-scripts tracks
  the three files and prints the `--refresh` command.
- Docs: OPERATOR.md 4.14 and short additions, README section and rows and changelog, the
  release note (closes #47 and #60), docs/testnet-addons.md, followup.md (UI card, retiring the
  pull monitor, the maintenance marker, two side findings, a test-flake note), AGENTS.md rules
  and a `## Private alerts` section, the partner guide 1.7 with its PDF (77 pages, second build
  "PDF unchanged").
- Tests: heartbeat_test 187, alerts_test 279 (271 as root), setup_alerts_test 209 (204 without
  python3), setup_node_alerts_test 48, `tools/tests/vm.d/P0-alerts.sh` for the CI VM; updated
  host_baseline, check_node_hardening, remove, remove_addons, updater_manifest, addon_gates,
  addon_oldlib tests.

### Verification

- V1 (code): no E, 3 W (the rollback left an `ENABLE_ALERTS=false` line on a host without the
  key; status without root said "off"; four runner mutants survived), 6 N (a healthchecks
  `#fragment` would ping the success URL; `OnBootSec` fires once at enable; the base branch moved
  on). V1d (docs): 2 E (a `done` field documented on every action that only an enable and a
  test send), 14 W (fixed thresholds documented where the code derives them; a prompt quoted on
  one line; log order; "nothing else is sent" understated), 22 N. 59 runner mutants, 46 killed
  before the fixes; the four survivors that mattered die now (F-B), plus three more.
- Fixes: F-A (undo via `alerts_disable keep-meta` and `meta_unset`; status `unknown (run with
  sudo)` with `systemctl is-enabled`; `alerts_refresh [INTERVAL STALL INACTIVE]` and explicit
  values on an enabled node, two-item `applied`), F-B (fragment refusal, the four scenarios),
  F-C and F-D (every docs finding). V2 re-check: every fix proven end to end with the real
  script and library as root in ubuntu:24.04 (`.node-meta` same bytes, inode and mtime after a
  failed enable), no E, 1 W and 9 N, all applied by the orchestrator (docs wording, `network`
  null in a non-root status, two stray files removed).
- Final tree: fixture suite 65 files in bash 5.3.9, `bash:3.2` and `ubuntu:24.04` (as root);
  `bash -n` under both bashes, `check-bash32`, `shellcheck --severity=error`, the perl,
  passphrase-print, root-write-pipe, network-hits and ci_pins lints clean; `systemd-analyze
  verify` on both units and the data-dir variant, `security` exposure 1.5; sidecars regenerated.
- Not proven locally: `P0-alerts.sh` end to end (Docker cannot supply a `LoadCredential=`
  directory); the "Ubuntu 24.04 VM assertions" job proves DynamicUser, LoadCredential,
  `systemctl show` under the sandbox and the push from inside it.

### CI round (2026-11-05)

- The first CI run on PR #61 found three things the local gates could not: the "Ubuntu 24.04 VM
  assertions" job showed the runner never saw the node's service state (a `DynamicUser` cannot
  use the system bus: dbus-daemon drops a connection from a uid it cannot resolve, reproduced on
  systemd 255 and fixed with a root `ExecStartPre=-+` that writes `systemctl show` to
  `/run/telcoin/heartbeat-service`, proven in a privileged systemd container); the macOS bash 3.2
  fixture job failed two new tests on BSD tools (`grep -o` with `\|` alternation, an awk `-v` value
  holding a newline); and the base branch had moved on (rebased twice, three conflicts resolved:
  update-scripts' `local` line, the release note's #49 bullet, the sidecars).
- The base moved a third time while the fix landed (eight round-2 docs commits, among them a
  partner-guide bump to 1.7 for OpenPGP signing and image packages), so the guide with private
  alerts is 1.8 (the guide commit's title still says 1.7; its metadata and PDF say 1.8). GitHub
  runs no `pull_request` workflow while a PR conflicts, which is why the push before that rebase
  had no CI run.
- Every other check was green on the first run: bash -n on both bashes, shellcheck, the Linux
  fixture suite, the hardening lints, the release manifest, checksum freshness, the UI tests.

### Merge of the base (2026-11-04)

The base moved a fourth time (41 round-2 commits: the finalize image override, the
build-feature run under `timeout -k`, the record-order fix, the checked install pass, the
cut-release fixes, the review records) and the operator asked for a merge, not a rebase, with
both sides kept. `origin/hardening-followups` (4a24629) was merged into `private-alerts` as
01c4eb7. The sources all merged on their own with no contradiction: the base's edits sit in
the Docker, finalize, release and cut-release areas, mine in the alerts areas; `write_node_meta`
takes key=value arguments on both sides. The only conflicts were generated files, rebuilt from
the merged sources: the three sidecars (`tools/gen-checksums.sh`) and the guide PDF (77 pages,
byte-identical on a second build). The guide stays at 1.8: the base changed the guide text
twice under 1.7 without a bump, and no PDF with either side's text has shipped. Gates on the
merge: `bash -n`, the bash 3.2 lint, shellcheck, the perl lint and `git diff --check` clean;
the fixture suite 66 files, 0 failed in bash 5.3.9, bash 3.2.57 and Ubuntu 24.04.

### Process notes

- Agent budgets: A1b (342k), V1 (336k), V1d (312k), F-A (308k), A2 (299k) and V2 (265k) ran past
  the 250k guideline. The library package carried the library, the common.sh block, the fixture
  test and the VM assertion; the verifiers carried every gate plus a mutant run. Next round:
  split a library package from its tests, and a verifier's gates from its mutants.
- The docs agents wrote before the code existed and the verifier found 38 docs-versus-code
  items; a second docs pass after the code fixers landed caught the rest. Writing docs from the
  spec in parallel saved wall-clock time but cost one extra docs pass.

### Left to the maintainer

- Merge this PR into `hardening-followups` before `scripts-v2.1.0` is cut (the three new files
  must be in that release); then PR #59 into main; then the cut.
- After the first real install: enable with a Kuma push URL, stop the node once, see the `down`
  reach the monitor; confirm the VM job passed on this PR.
- Follow-ups in followup.md: the UI card, retiring the pull monitor, the maintenance marker.

## Review: main merged into docs/technical-specification; guide 1.5 and specification 1.2 against telcoin-network main 7167e7800 (2026-11-03)

Branch `docs/technical-specification` (PR #58, draft). Two commits on top of 619f80f: the merge of
`origin/main` 28a7cc7 (58665ac) and the refresh commit. Plan in `tasks/plan.md`; facts in
`tasks/spec-refresh-2026-11-facts.md` (preamble, orchestrator decisions, the F1-F3 parts, the
gpgv test); the specification's change log in `tasks/ckpt-spec-refresh-2-log.md`; the guide's
and the operator docs' logs in `tasks/ckpt-refresh-S2.md` and `tasks/ckpt-refresh-S3.md`; the
verifiers' reports in `tasks/ckpt-refresh-V1{a,b,c}.md`.

### Merge

- 265 commits from main (the mainnet hardening round and scripts-v2.0.0, the devnet Docker
  images, a dependabot bump). `git merge-tree` predicted nine content conflicts plus the old-path
  guide PDF; README.md auto-merged. The mechanical files (guide `metadata.yaml`, the old-path
  PDF, `tasks/lessons.md`, `tasks/plan.md`, `tasks/todo.md`) were resolved by the orchestrator;
  A1 (`AGENTS.md`, `CHANGELOG.md`, `followup.md`), A2 (`OPERATOR.md`, `README.md`) and A3 (the
  guide) kept both sides with main's text as the base. A2 found the one auto-merge mistake: the
  branch's epoch-change paragraph had landed at the end of main's new "Backups and the update
  lock" section and went back beside the epoch-wait paragraph. A3: only two `support@telcoin.org`
  were left to sweep (git carried the branch's earlier sweep); all 20 branch hunks and all 306
  lines main added survive; the guide's 12 README anchors resolve against main's README.
- No script, library, UI file, sidecar, `MANIFEST`, `RELEASE` or `install.sh` differs from main;
  `tools/build-partner-pdf.sh` is the branch's. `git diff --check` reports one trailing space in
  main's own `tools/tests/passphrase_print_test.sh:112` (a fixture line; left alone).

### Facts and writers

- F1 (storage, sync, restart), F2 (networking) and F3 (consensus, epoch, execution, CLI, release)
  read a detached worktree of telcoin-network at 7167e7800, read-only, and wrote their parts with
  `path:line` citations; the orchestrator joined them under a decisions section (release wording,
  nothing off main, numbers copied, optional additions, contacts, logs, open points). F1: 3
  corrections, 8 additions; F2: 3 corrections, 17 additions (10 optional); F3: 5 corrections, 6
  additions, 3 follow-ups. The fork table, the hardware figures, the clock-drift rule, the rejoin
  window, the chain-config pins and the stdin passphrase delivery are unchanged.
- S1 (specification): 23 statements (6 corrections, 6 additions, 8 optional additions applied, the
  edition sentence). S2 (guide): 31 logged changes and checks. S3 (OPERATOR.md, README.md): 29
  changed statements (20 and 9). All three built or checked clean before handing back.
- Two writer judgment calls the orchestrator reversed: both had replaced main's `v0.17.0-adiri`
  (the planned first signed release) with "the next release"; the name is restored as "planned as
  `v0.17.0-adiri`", which keeps main's information and says it is a plan. One the orchestrator
  kept: the durability-barrier row names both releases (on `v0.16.0-adiri` the node keeps running
  after `; initiating node shutdown`; from the next release it exits with status 1 and systemd
  restarts it), per decision 2.
- The orchestrator settled one open point locally: with gpg and gpgv 2.4.8, plain `gpgv` prints
  `Good signature from` and exits 0 on an expired key; `--status-fd 1` prints `EXPKEYSIG` and
  `VALIDSIG` and no `GOODSIG`. The hand-check rule in all three documents follows that.

### Verification

- V1a (specification): 37 statements checked, all match the code; 3 defects (two imprecise, one
  convention), fixed by the orchestrator: "by default at most 128" with the `process_budget`
  override, "fixed" dropped from the Peer scoring ceilings, the `CvvInactive` exception limited to a
  record that still names the key (the observer check runs first), the commit hash in a code span.
  Open points settled from the code: the refusal is `-32603` (jsonrpsee-types 0.26.0
  `INTERNAL_ERROR_CODE`; `crates/tn-reth/src/rpc_fee_cap.rs:68-77`), a demoted node keeps the
  transactions it already holds (no pool clearing on a mode change), and every printed figure has
  its computing line (45 s = 5 s slack + 4 × 10 s; 24,579 = max(12,000 + 512, 16,384 + 3) + 8,192;
  21,600 s from the mainnet genesis storage word).
- V1b (guide): 51 statements, 12 defective in 9 defects, 2 of them wrong. The decisive one:
  `v0.16.0-adiri` has no `Cannot check database (epoch)` check (`epoch_db_recovery.rs` came with
  #1572, after the tag; a damaged epoch row panics `Invalid bytes!`), so decision 2's "on
  `v0.16.0-adiri` move `consensus-db/epoch` aside" was wrong; also "count as unset when `null` or
  `{}`" was false (a configuration error). The six opt-in `network-config` keys, the two `-32000`
  worker messages and the 62 GiB reservation are main-only and now say "from the next release";
  `epochs/` also holds the pack of the epoch in progress; the gpgv rule adds `ERRSIG`; the tag's
  vote lines end `; initiating node shutdown: <e>`; "on bare metal".
- V1c (OPERATOR.md, README.md): 52 statements, 7 defects (1 wrong, the same epoch-check premise; 6
  imprecise), plus the safety point that a `--json` apply (the Node Manager UI) rolls back without
  asking after a failed check, so a committee node takes the tndb update from a terminal. The
  `--version` lines, the annotated signed tags (`^{commit}`), the UI's one-way warning (fires only
  across the 0.16.0 floor) and the scripts' `ERRSIG` handling (any code other than 9 refuses) were
  confirmed from the scripts and the release pipeline.
- X2 (guide, D1-D10) and X3 (OPERATOR.md, README.md, D1-D7 plus the shared V1b items) applied the
  fixes; the orchestrator fixed the spec, two guide bullets (the rollback exception and the UI
  one-way bullet) and two operator-docs sentences. V2 re-checked all 29 fixes against the code at
  7167e7800, the tag and the scripts: 29 resolved, none still wrong, none new. Its two remaining
  items (the guide's "email first" lead on the move-aside case; "failed health check" narrower than
  the code) were applied by the orchestrator. The facts file carries the correction to decision 2
  and `tasks/lessons.md` the rule (check each "today's behaviour" fact at the tag).

### Build

- Built in the `tn-pdf-tools` container (pandoc 3.8.3, WeasyPrint 70.0) from the repo root with
  `--all`: lint clean, WeasyPrint log empty, guide 61 pages, specification 37 pages. A second run
  printed `PDF unchanged` for both. `pdftotext` in the container: both covers read "November 2026"
  (guide `Version 1.5 · November 2026`; spec `Version 1.2 · November 2026` and
  `Protocol v0.16.0-adiri, main at 7167e7800`), no "October 2026" anywhere, `devs@telcoin.org` on
  every guide page and on the spec cover, no `support@telcoin.org` in either PDF, no CreationDate
  in either file (the guide template's dcterms tags are now behind `$if(date-meta)$`, as the spec's
  were; a month-only date leaves `date-meta` unset).

### Agent budgets

- Merge units: A1 122k, A2 105k, A3 96k tokens. Facts units: F1 293k, F2 387k, F3 368k, each past
  the 250k guideline; they finished, but a facts unit that reads many crates for many PRs needs a
  narrower scope (by PR group, five or six PRs per unit, not by topic). Writers: S1 222k, S2 245k,
  S3 261k. Verifiers: V1a 286k, V1b 259k, V1c 269k, V2 206k. Fixers: X2 127k, X3 148k.

### Follow-ups recorded in followup.md

The `STORAGE_MIGRATION_FLOOR` second floor (tndb), the health listener bind change against the
health-monitor add-on, `--bls-passphrase-source credential` and `--bootstrap-peers-file` once a
release carries them, the liveness metric for check-node, update-node's printed hand check
without `--status-fd 1`, the re-check at the next tag (staging 10-27 and the worker gateway are
not described), the upstream issue for the tndb remedy, and the list of upstream changes the guide
leaves out on purpose.

---

## Review: the five defects of the 2026-10-28 review of PR #11 (2026-10-30)

Branch `mainnet-hardening`, d8c138f + 18 fix commits (ff5a34b..963f0f8) + the release-prep commit
3fb57d1 (sidecars, partner guide 1.3.3) + this note. Each item has a fixture that fails on d8c138f
and passes on the tip.

### What landed

- [x] Quorum stop guard (`lib/common.sh`, ff5a34b): a node whose own `tn_nodeMode` cannot be read
      is counted as still voting; it is counted among the down only when `tn_info` on its own RPC
      returns an authority id that authored nothing in the counted commit (`_tn_commit_has_author`,
      `tn_node_authority_id`; the public RPC is never asked). The refusal stays under the UI
      helper's 300-character cut. `quorum_guard_test.sh` 85 checks (28 fail on d8c138f).
- [x] One-way update failure (`update-node.sh`, 69b866b..e86ee71): a started one-way apply records
      `STORAGE_MIGRATION_STARTED=true` in the pending state; a failed health check clears the state
      without restoring the unit, start script or `node.env` (`clear_pending_after_start`) and says
      so; a later `--discard` keeps them too and prints the manual way back (`pending_undo_hint`;
      `--json` done carries `"storage_migration":true`). New `storage_migration_test.sh` (96 checks,
      126 as root; 40+ fail on d8c138f).
- [x] VPN enable sudoers (`setup-vpn.sh`, 9774caf; vendored bootstrap eed4faa): the consent-matching
      `/etc/sudoers.d/90-tnadmin` is written before the vendored bootstrap runs, which now honours
      `WG_NODE_SUDOERS=0` (default 1 keeps upstream behaviour); after the bootstrap the rule is
      rewritten only when it differs (`vpn_sudoers_current`). The enable order and every
      SSH-related step are unchanged. The guard is mirrored in the upstream checkout
      (deploy-networks-common, branch `wgvpn-sudoers-guard`, commit 9b2c8f2, unpushed) and the
      vendored header records its sha. New `vpn_enable_test.sh` (45 checks; 12 fail on d8c138f).
- [x] Alloy partial disable (`lib/observability.sh`, 69c3afd; `setup-observability.sh`, 294e980):
      one `obs_render_config_alloy` derives owner, group and the node log path from the installation
      for the enable and both partial disables; `obs_restart_alloy` restarts and watches `is-active`
      for 5 s; a disable records its choice, restarts through the helper, and exits non-zero when
      Alloy does not stay up (menu says so; `--json` ends `done ok:false` without the marker).
      `obs_test.sh` 103 -> 170 checks (39 fail on d8c138f).
- [x] Update lock after a removal (`remove-node.sh`, 3b48813): `/run/telcoin` and the lock file stay
      (the deferred unlink in the EXIT trap is gone), so no second operation can lock an unlinked
      inode. `remove_test.sh`: same inode before and after, a fresh acquire succeeds (9 fail on
      d8c138f).
- [x] Docs: OPERATOR.md, README.md, CHANGELOG/scripts-v2.0.0.md, WGVPN.md, docs/testnet-addons.md
      (the provenance header is 14 lines, `sed '2,15d'`), AGENTS.md, partner guide 1.3.3 (PDF
      57 pages).

### Gates on the tip

- `tools/tests/run.sh`: 59 files, 0 failed under bash 5.3, bash 3.2.57 and as root in Ubuntu 24.04.
- `ui/tests/helper_test.sh`: 494 checks under bash 5 and bash 3.2; `install_ui_test.sh` 1/1;
  pytest 258 passed (python:3.10-slim).
- `bash -n` (bash 5 and 3.2), `tools/check-bash32.sh`, shellcheck 0.9 and 0.11 `--severity=error`:
  clean on the 13 touched files; `tools/check-perl-interp.sh` clean (100 files).
- Sidecars fresh; no version constant changed; no `Co-Authored-By` or "Generated with" in any
  commit; the vendored bootstrap body is byte-identical to the mirror
  (f6e22378569c5f79bb24127dacaa14794f392aa1cececa037641f1e5f07f80d5).

### Left to the user

- Done 2026-10-30: `wgvpn-sudoers-guard` merged in `deploy-networks-common` (PR #6, `main` 4a2925c);
  the vendored header records it and its sha equals the merged file. The superproject branch of
  the same name (df30349) only moves the `common` pin; fold it into the next pin bump.
- Re-request the review if the token could not; sign `MANIFEST` and commit `lib/allowed_signers`
  plus `MANIFEST*`/`RELEASE` on the final tip before merging #11.
- The follow-ups added to `followup.md` (UI display of the one-way discard note, the quorum-check
  timeout in `server.py`, a re-apply after a started one-way update, the `--json` done after a
  failed add-on action).

### Assumptions

- 2.0.0 is unreleased, so a pending-state key unknown to an older dev build needs no shim.
- `obs_enable` now takes about 4 s longer and fails when Alloy exits within 5 s of the restart.
- The partner guide version is a document version, not a script version.

## Review: close-out of the hardening round (2026-10-21)

Branch `mainnet-hardening`, b02735a + 24 commits (last code commit c960f96; this note on top): the four red CI jobs fixed, the
maintainer release key shipped, and the scripts aligned with the signed-release pipeline of
telcoin-network PR #694. Issues for every item are open in both repositories (tn-node-deployment
#12-#51, telcoin-network #1723-#1735).

### What landed

- [x] CI: shellcheck 0.9 directives where a stub replaces a sourced function; the UI helper's
      locked stop or restart runs in a subshell so the lock is released under bash 3.2; BSD
      stand-ins in the fixture harness (`stat -c`, `mv -T`, `chmod MODE --`, `timeout`, `TMPDIR`)
      and reasoned skips for `/proc`, `getent`, `PATH` and a 0700 `TMPDIR`; the VM job restores
      stock modes on `/opt` and `/usr/local` that the runner image leaves world-writable.
- [x] `lib/release-keys/grantkee.asc` ships (SCRIPTS row, sidecar, README with the refresh rule).
- [x] Signature policy: one good signature by a shipped key accepts; `BADSIG`, `EXPKEYSIG`,
      `REVKEYSIG`, `EXPSIG` refuse; an unshipped co-signer beside a good signature warns.
- [x] Release candidates on testnet when named; every "newest" pick takes finals only; tags are
      ordered by release (rc1 < rc2 < final) in the downgrade check and the pickers.
- [x] Images from `ghcr.io/telcoin-association/telcoin-network` for both networks; "newest" from
      the GitHub Releases API with the digest from the signed `IMAGE_DIGEST`; ghcr's anonymous
      token for lookups; the Artifact Registry tag listing only as the testnet fallback while no
      release exists; mainnet Docker refused up front until its pins exist.
- [x] UI: the default image comes from the library; both testnet repositories and the mainnet one
      are accepted by digest; no registry hardcode left in `server.py` or the helper.
- [x] Docs: README, `OPERATOR.md`, changelog and release note, partner guide (PDF 1.3.2).

### Gates on the tip

- `tools/tests/run.sh`: 57 files, 0 failed under bash 5, bash 3.2 and as root in Ubuntu 24.04.
- `ui/tests/helper_test.sh`: 494 checks, 0 failed under bash 5 and bash 3.2; `install_ui_test` 1/0;
  pytest 258 passed (python 3.10).
- shellcheck 0.9.0 and 0.11 error-clean; `check-bash32`, `check-perl-interp` (98 files) and the
  passphrase-print lint clean; sidecars fresh; no attribution trailers.
- GitHub: every CI and Integration job green (https://github.com/Telcoin-Association/tn-node-deployment/actions/runs/39637763432 and the Integration run https://github.com/Telcoin-Association/tn-node-deployment/actions/runs/39637763301).
- Independent verifier over b02735a..c960f96: all seven sections pass with no error; the three warnings it raised (an rc-unaware update check, an unsigned registry fallback for a release the GitHub API lists, an unshipped tag signer refusing instead of warning on testnet) are closed in the follow-up commits ending at c960f96.

### Left as-is (deliberate)

- `DEFAULT_DOCKER_IMAGE` and `DEFAULT_DOCKER_TAG` stay at `v0.16.0-adiri` on Artifact Registry
  until the first signed release (`v0.17.0-adiri`) exists; `TN_TESTNET_IMAGE_REPOS` keeps both.
- Product code keeps the GNU forms (`chmod MODE --`, `stat -c`, `mv -T`, `timeout`); only the test
  harness carries BSD stand-ins.
- `ui/dev/serve.py` still fakes a registry tag for the dev server (predates the round).

## Review: mainnet hardening round (2026-10-15)

Branch `mainnet-hardening`, forked from `main` at 037c810: 208 commits (code packages, one
independent verification per package with its fix pass, docs, the scripts-v2.0.0 release prep,
and a whole-range review with its fix pass). The packages, merge order and per-package gates are in `tasks/plan.md`;
what remains is in `followup.md`.

### What landed

- [x] Root-owned install tree: `/etc/telcoin`, `.node-meta`, the start scripts and the binary
      belong to root, the data directory is the only tree the service account owns, and
      `tn_migrate_ownership` converts an existing host under the lock (`OWNERSHIP_LAYOUT=2`).
- [x] One update lock at `/run/telcoin/update.lock` for every root script that writes the
      install. Every restart waits for the epoch window, and one that would cost the committee
      its quorum is refused unless `--allow-quorum-risk` is given.
- [x] The BLS passphrase is a `systemd-creds` credential (`host+tpm2` or `host`) or, in the
      interim, a root-only file; the root-owned start script feeds it to the node on stdin. It
      is never on a command line or in a unit `Environment=` line. The TPM unseal method is
      gone; `edit-config.sh --migrate-credential` and `--reseal` convert and reseal.
- [x] Generated `node.env`, start script under `/usr/local/libexec/telcoin/` and a sandboxed
      unit; the listeners moved out of the launch line.
- [x] Script updates install only from a signed `MANIFEST` under a `scripts-v*` tag;
      `install.sh` is pinned to a release tag; `tools/release-scripts.sh` and the CI jobs that
      check them.
- [x] Node releases are checked with `gpgv` against `lib/release-keys/`; release tags only;
      source builds run as `tn-build` with a pinned rustup; Docker comes from Docker's apt
      repository and images run by digest; downgrades are refused; update-node checks after an
      update that the node votes again.
- [x] Testnet genesis, committee and parameters files pinned by hash; mainnet needs systemd 255.
- [x] Add-ons: a fail-safe firewall with SSH and P2P source lists and an sshd drop-in, a `KEYS`
      file and self-heal for the testnet VPN, the Caddy admin API on a unix socket, Alloy under
      its own account.
- [x] Node Manager UI: per-install token, Host and Origin checks, a JSON-only API, checked helper
      arguments, a hashed venv, and `http://127.0.0.1:8080` as the address.
- [x] remove-node takes the lock, shreds secrets and can finish an interrupted removal.
- [x] telcoin-network: the credential passphrase source, the chain 487 guard and the release
      pipeline, each attested and pushed.

### Gates at the final merge (417fbe2)

- [x] `tools/tests/run.sh`: 51 test files green under bash 5 (2800 checks, 0 failures, 40
      skipped because they need root), under `bash:3.2`, and as root in `ubuntu:24.04`.
- [x] `ui/tests/helper_test.sh` 327 checks, 0 failures. UI pytest 189, `install_ui_test.sh` 13
      and `open_ui_test.sh` 9 at the UI fix pass.
- [x] `tools/check-perl-interp.sh`, the passphrase-print lint, `tools/check-bash32.sh` and
      `shellcheck -x --severity=error` clean.
- [x] VM assertions in an `ubuntu:24.04` container as root, at the updater fix pass: five
      passed; the perl-lint one skipped because the lint had not merged yet. Its skip guard is
      satisfied on 417fbe2, but it has not run since.
- [x] No co-author trailer in `037c810..417fbe2`.
- [x] telcoin-network: 238 tests on the credential branch; 523 and 122 on the chain 487 guard,
      clippy clean with both feature sets; all three branches attested.

### What remains

- [ ] Release prep: versions, the new tracked files in the updater arrays,
      `tools/gen-checksums.sh`, the signed `MANIFEST` and the `scripts-v2.0.0` tag.
- [ ] User steps: a GPG key in `lib/release-keys/`, an SSH signing key in `lib/allowed_signers`,
      the `github-pages` environment allowing `scripts-v*` tags, a second CODEOWNERS owner, the
      rulesets.
- [ ] Post the drafted issues; open this repo's PR and the two telcoin-network draft PRs; update
      PR #694.
- [ ] Merge the pending UI follow-up pass and the release-install fix pass.
- [ ] Review the whole range.
- [ ] Mainnet constants, the host soak, the upstream items and the rest: `followup.md`.

---


# Review — Technical Specification as a partner document (2026-10-15, branch docs/technical-specification)

Nothing is pushed. Branch `docs/technical-specification` off `main` (037c810), six commits:
1331145 (guide moved to `docs/partner/mno-node-guide/`, fonts to `assets/fonts/geist/`, build
script by document name, PDF carried over at R100), 9a0f5d3 (Inter v4.1, two light-background
logos, cover art, assets README), 6010ed3 (partner contact devs@telcoin.org, guide 1.3 dated
15 October 2026 and rebuilt, AGENTS.md "Partner documents", README pointer), 924fa0c (the
specification: Markdown, metadata 1.1 / 15 October 2026 / protocol v0.16.0-adiri, template,
theme, 34-page PDF), 10b666e (the build stages each theme beside the HTML with raster images
inlined, so the PDF bytes do not depend on the checkout path), and the commit carrying this
file, the CHANGELOG clause and the task files. No attribution trailers. The original Google
Docs PDF stays untracked at `docs/Telcoin Network Technical Specification.pdf` for the user to
delete after sign-off; `.claude/project-context.md` stays untracked.

## What landed

- `docs/partner/technical-specification/technical-specification.md`: 738 lines, the ten
  chapters of the April 2026 document in their order, 59 headings, 12 tables, three added
  subsections (Gas over-reservation penalty, Fork gates with the six armed Adiri epochs,
  Transaction forwarding), one renamed section ("Keccak-256 hashing" to "Hashing": consensus
  digests are BLAKE3). Every change from the faithful transcription is logged with a code
  citation at the tag in `tasks/ckpt-spec-refresh-log.md` (parts A, B and C).
- The refresh corrected, among 108 stale statements: the committee drawn at the close of epoch
  N serves epoch N+3 and the node, not the contract, does the draw from the seed chain; the
  leader commit rule is f+1; four epoch-boundary system calls, 100M gas each; `mix_hash` carries
  the seed-chain PREVRANDAO; four gossip topics with committee publishers and no transaction
  topic; role-specific request-response ids `/tn-primary-{chain_id}/0.0.2`; three reputation
  levels with a ban at -50; node modes derived from committee membership, `CvvInactive`
  carrying over; `final_state` only pins a pack's start state; the fixed-stake membership model,
  rewards weighted by leader rounds, exit over three committees; every node holds a BLS key with
  derived Ed25519 network keys. The intent-scope table gains `EpochCloseSeed`.
- The toolchain on this Mac is pandoc 3.12.1, WeasyPrint 70.0, poppler 26.10.0 (installed this
  session). The guide PDF was rebuilt once for the contact change; a word-level diff against the
  pandoc 3.12 baseline showed only the address, version and date tokens.

## Verification

- `bash tools/build-partner-pdf.sh --all` in a worktree at another path: "PDF unchanged" for
  both documents, `git status --porcelain` empty; the same in the main tree. Before 10b666e the
  specification reported "toolchain drift" from any other path, because WeasyPrint names image
  objects after the md5 of the image URL.
- Script: `/bin/bash -n`, `bash -n`, `tools/check-bash32.sh`, `shellcheck --severity=warning`
  all clean; usage errors exit 2 (no argument, `bogus`, two names, `--all` with a name or with
  `PARTNER_MD`, an unknown flag); anti-churn in a scratch clone: a perturbed PDF gives
  "toolchain drift" and exit 0, `--force` writes, a Markdown edit writes and warns to bump the
  metadata.
- Specification PDF: 34 pages, empty WeasyPrint log, cover with no header or footer, header and
  footer on pages 2 to 34, "Page | 2 / 34" and "Page | 34 / 34", the confidentiality line with
  the date on every page, `mailto:devs@telcoin.org` on the cover, three-level contents with only
  chapters numbered, all 59 entries matching their pages; text contains v0.16.0-adiri and the
  `/tn-primary-` ids and none of `/telcoin-network/0.0.1`, `--observer`, `tn-txn`, personal
  addresses or "mainnet".
- `.gitignore` `docs/partner/*/build/` and `.gitattributes` `docs/partner/*/*.pdf` verified with
  `git check-ignore` and `git check-attr`; `git log --follow` on the guide PDF reaches 7fb7c8d;
  `git diff -M --stat` shows the move commit's PDF as a pure rename; no `.sha256` changed; the
  only references to the old partner paths are historical CHANGELOG lines.
- Reviews: fidelity (Q1) found no transcription defect and a complete log, and classified 68
  additions beyond the corrections (5 partner-needed kept, 18 out of scope dropped, 7 duplicate
  pairs resolved); technical disproof (Q2a/b/c, fresh agents against the code) found 5 wrong and
  36 imprecise statements among 151 checked, all applied; render review (Q3, Q3r) found no
  must-fix item, the one remaining runt page was removed by tightening one sentence.

## Out of scope, for the user

- `support@telcoin.org` remains in README.md (6), OPERATOR.md (12), `setup-node.sh`,
  `check-node.sh` and `update-scripts.sh` (1 each; those three are updater-tracked and need
  version bumps, sidecars and a changelog entry if changed), and in three historical CHANGELOG
  lines.
- Two telcoin-network docs disagree with the code at the tag and could be fixed upstream:
  `docs/src/network/discovery.md` (a record holds up to 4 addresses, not 1) and `SYNC.md:51`
  ("headers include certificates"; the sub-DAG stores headers without signatures).
- The cover counts as page 1 (the original numbered the contents page as 1); the cover card is
  about 4.6 mm narrower than the original's; the first column of the three-chains table is
  regular weight where the original is bold.

# Review — followup.md backlog round (2026-10-01 19:20 → 2026-10-02, three repos)

Nothing is pushed. `main` is 42 commits ahead of `origin/main` (`7fb7c8d..6622d1e`; the release
commit is e5e7f4f, followed by the fixes from the whole-range review); tn-5 has the
branch `docs/operator-docs-backlog` (13 commits on `origin/main` f47a2603); devnet-genesis `main`
is one commit ahead (`e732765`). Docker was unavailable for the whole session; the real-binary
tests ran against a v0.15.0-adiri build made from `git archive` of the tag and against the
pre-v0.15.0 debug build in `tn-4`, and the Caddy floor against a downloaded 2.8.4 binary.

## What landed (tn-node-deployment)

- lib/common 1.6.0, lib/fallback 1.0.3: URL and release checks, JSON-RPC and epoch helpers,
  `tn_wait_restart_window`, strict stake decode on the real struct layout, launch-file editing
  with a shell-aware tokenizer, keytool and node-info helpers, physical cores, flock release
  that survives orphans, CRLF-tolerant `.node-meta`, `tn_node_parse_check` that never echoes
  the value (commits 1e2d2f1, d1593ae, 2c423dc, 8185d00, ea86e22, aa65fc3, 20ad47a).
- setup-node 1.3.0 (9df76cb, 16123b8, 8c69378, babb69d, 509bedb), edit-config 1.3.0 (9ff00af,
  59d10a0, 48a4c42), update-node 1.2.0 (e28e8e5, f9c47df, 12e58f4), install-caddy 1.4.0
  (7acc653, a051680), check-node 1.2.0 (c7a9690, 823e149), firewall-setup 1.6.0 +
  observability (5eb98b4, 1540751), prepare-stake 1.0.0 (f918d4f, 77e043b), remove-node 1.2.9,
  migrate 1.2.1, the lint and updater (78d9f46, eb73857, 3c78a6d, 13f6309), UI 1.9.0 (2025ea3,
  0c8aacf, 8feb576), CI (0b54c64), docs (d48270b), release update-scripts 1.1.70 (e5e7f4f).
- Security fixes found by the verifiers, not in the original backlog: unquoted shell
  metacharacters accepted into a root-run wrapper; a peers-file path that echoed a root-only
  file's first line through the UI (and the probe exposing the map in `ps`); check-node's
  header parser `eval`ing strings from the RPC answer; the updater installing files whose
  sidecar was missing and relaunching an unverified copy of itself; a passphrase inherited by
  every child of prepare-stake; the flock kept by orphaned children after SIGTERM; a config
  save interrupted during the epoch wait left on disk unapplied; prompt answers such as
  `9101;id` written into the start wrapper.

## Verification

- 9 independent Opus verifiers with their own harnesses (V-L, V-UP ×2, V-CORE-1, V-CORE-2,
  V-UI, V-OPS-1, V-OPS-2, V-DOC); every error-level finding fixed and re-tested, warns fixed
  unless recorded in followup.md.
- Final sweep against HEAD, both bashes: library 794 + 427; update-node 683 + 35; setup-node
  726; edit-config 858; install-caddy 176 + 245 JSON + 60 live Caddy (2.8.4 and 2.11);
  check-node 614 + 7; firewall 178; observability 229; prepare-stake 266 + 264 + 123; migrate
  45; lint 86 fixtures under BSD awk and mawk; UI 135 Python tests + 205 helper checks. Live
  read-only checks against rpc.adiri.tel matched `cast` throughout. (Sweep output:
  `<scratchpad>/final-sweep-2.txt`.)
- Tree gates: parse under both bashes, shellcheck error level, lint under both awks, zero sidecar
  drift, every changed tracked file bumped, zero trailers in three repos.
- Code review: see below.

## Deferred

`followup.md` (84 items, each with why and source). The largest: multi-worker provisioning,
the ownership of `/opt/telcoin` and `/etc/telcoin` by the service user (security, with the
recommended fix), the UI's fixed firewall toggles and missing inputs for the new edit-config
fields, `--help` gaps, the fleet Caddy items in the maintainer repo, the upstream PR.

## To push (user)

```
cd ~/coding/telcoin/tn-node-deployment && git push origin main
cd ~/coding/telcoin/tn-5 && git push -u origin docs/operator-docs-backlog   # then open the PR and run make attest on its head SHA
cd ~/coding/telcoin/devnet-genesis && git push origin main
```

The partner PDF's links to `blob/main/prepare-stake.sh` and the new README anchors resolve once
tn-node-deployment is pushed.

## Code review (/code-review high over origin/main..HEAD, 2026-10-02)

Eight findings, all real; seven fixed, one recorded.

| # | Finding | Outcome |
|---|---|---|
| 1 | `tn_wait_restart_window` slept in the foreground, deferring every caller's signal trap by a poll interval; the UI's kill then orphaned a root script holding the update lock | fixed, dd898c3 (sleeps run in the background with `wait`) |
| 2 | `prepare-stake --rotate-address` held the update lock at the interactive passphrase prompt | fixed, 23eb06c (passphrase first, lock after) |
| 3 | `network_stake_status` blocked the UI's request thread for 3–6 s per cache expiry when the public RPC was slow or down | fixed, 504aad4 (chain-id cache, endpoint back-off, refresh on one background thread; 135 tests) |
| 4 | the updater worded a checksum download error as "no checksum available" | fixed, 3682e5a |
| 5 | stale `lib/fallback.sh` comment naming a caller that no longer exists | fixed, dd898c3 |
| 6 | the updater left `lib/*.sh.tmp` behind on Ctrl-C | fixed, 3682e5a (EXIT trap removes only what the run created) |
| 7 | edit-config duplicated the library's lock bookkeeping and closed fd 9 twice | fixed, d752211 |
| 8 | five near-identical wait printers across scripts | recorded in followup.md (Library) as a shared `tn_wait_printer` |

The first review run died on the previous account's weekly limit before reading the diff; the
second run completed.

# Review — public-RPC consolidation, observer-flag removal, OPERATOR.md (2026-10-01)

Final HEAD = origin/main = 413ed71. 16 commits since the session started (A_HEAD b5d912b
closed Track A; add9ece is the release re-cut operators pull; 413ed71 the last docs commit).

## What landed
- Track A: public-RPC set committed (install-caddy 1.3.0, setup-node 1.1.0, check-node 1.1.54,
  firewall-setup 1.5.2, lib/fallback 1.0.2), #9 merged (arg-parser conflict resolved), lib/common
  1.3.9 + UI 1.8.7 changelog.
- lib/common 1.4.0: node_stake_status / node_is_staked_validator / print_validator_onchain_status;
  tn_node_has_observer_flag / tn_node_strip_observer_flag / tn_target_drops_observer; HW_* tiers,
  warn-only check_hardware with TN_HW_SUMMARY/TN_HW_GAPS; DEFAULT_DOCKER_IMAGE v0.15.0-adiri.
- setup-node 1.2.0: --rpc-domain derives advertised + .node-meta URLs; keytool --help probe;
  rpc_args built once, bash-3.2-safe expansion; hardware gaps as WARNING log events.
- update-node 1.1.62: role flags ignored; strips --observer on apply to >= 0.15.0 with backup/rollback.
- check-node 1.1.55: stake status decides validator checks; Consensus role from tn_nodeMode;
  legacy --observer warning; no role flags.
- edit-config 1.2.6 / remove-node 1.2.8: role flags ignored / slot-name only.
- UI 1.8.8: onchain_is_validator from getValidator; warn-only hardware preflight with tiers.
- update-scripts 1.1.67 re-cut; README changelog entries for all of the above.
- Docs: OPERATOR.md (856 lines), README technical edits, followup.md, CHANGELOG/AGENTS/testnet-addons.

## Verification
- Independent harnesses (not the implementers') under bash 3.2 and 5: V-B1 (lib/common) PASS,
  V-B(a) (setup-node, check-node, edit-config, remove-node, UI) PASS, V-B(b) (update-node) PASS;
  fleet keytool argv byte-identical to b5d912b; UI unittest 7/7.
- Docs: D2 read-through (8 findings fixed), V-C links/flags/line-numbers/headings PASS.
- D1: bash -n (3.2 + 5) on all 22 scripts, shellcheck error-level, py_compile, sidecars fresh,
  versions bumped on every changed tracked file, no co-author trailers, no line numbers.

## Left as-is (deliberate)
- tasks/lessons.md is TRACKED (plan assumed untracked); my harness-gotchas append is uncommitted.
- Pre-existing bash-4 uses not fixed: confirm() ${response,,}; remove-node declare -A (followup.md).
- check-node still flags a staked-but-unseated validator's missing committee headers (followup.md).
- .claude/project-context.md and tasks/ckpt-*.md untracked, not deleted.

# Review — one support address + MNO partner guide PDF (2026-10-01)

HEAD = 7fb7c8d (not pushed). Two commits on main: e20500c (support address, setup-node
1.2.1, update-scripts 1.1.69) and 7fb7c8d (partner guide, build script, docs).

## What landed
- Every operator-facing contact is support@telcoin.org: OPERATOR.md (5 places, §10 now one
  sentence, appendix Contact row), README (2 lines + changelog entries), setup-node.sh banner.
  Sidecars regenerated; only setup-node.sh.sha256 and update-scripts.sh.sha256 changed.
- docs/partner/mno-node-guide.md (911 lines, 10 chapters, 58 headings, 28 internal heading
  links, 14 absolute GitHub links, 5 GitHub alerts). No legacy material, no manual numbers.
- docs/partner/{metadata.yaml,template.html,theme.css}, assets/ (2 logos from
  tel3.telcoin.network, 7 Geist/Geist Mono woff2 from vercel/geist-font v1.7.2 + OFL.txt +
  LICENSE.txt, 400 KB, provenance in assets/README.md), mno-node-guide.pdf (31 pages, 220 KB).
- tools/build-partner-pdf.sh: tool checks, source lint (forbidden terms fail anywhere, H1
  count is fence-aware), pandoc, dangling-anchor check, WeasyPrint with log gate, PDF sanity
  via stdlib python (page count, mailto), anti-churn gate, PARTNER_MD override for tests.
- AGENTS.md "Partner guide (MNO PDF)" section + sync rule; README call-out and "Docs move
  with the code" paragraph; CHANGELOG Unreleased entries; .gitignore docs/partner/build/;
  .gitattributes marks the PDF binary + linguist-generated; .claude/project-context.md line.

## Toolchain (only system change: `brew install pandoc weasyprint`)
- pandoc 3.11, WeasyPrint 70.0 (Homebrew, bundled Python 3.14.8). woff2 loads natively.
- Poppler not installed; page renders for review used throwaway CoreGraphics Swift tools in
  the session scratchpad.

## Verification
- `grep -rn 'grant@telcoin' --exclude-dir=.git --exclude-dir=tasks .` → empty.
- /bin/bash 3.2 + bash 5 `-n` on setup-node.sh, update-scripts.sh, tools/build-partner-pdf.sh
  → ok; shellcheck -x --severity=warning on the build script → clean.
- gen-checksums.sh after commit → no sidecar drift; no .sha256 under docs/ or tools/;
  `grep partner update-scripts.sh` → empty.
- Build: working tree → "Wrote … (31 pages)"; second run → "PDF unchanged"; clean
  `git clone --local` of 7fb7c8d → "PDF unchanged" and `cmp` byte-identical to the committed PDF.
- Negative tests: `--observer` inside a fenced block → exit 1; grant@ in prose → exit 1;
  `--bogus` → exit 2; dangling #link, second `# `, "legacy", missing support@ → exit 1 (C).
- Forbidden-term grep on md + built HTML → empty; non-http hrefs in the HTML → only ../theme.css.
- PDF metadata: Producer WeasyPrint 70.0, CreationDate/ModDate D:20261001, Author Telcoin
  Association, Lang en-GB, 60 outline entries, 6 mailto links.
- Visual review of all 31 pages (Read tool on 80 dpi renders): full-bleed gradient cover with
  both logos and no header/footer; Contents with dotted leaders and correct page numbers;
  every chapter on a new page with running header "<title> | <chapter>" and "Page X of 31";
  internal links show "(page N)"; code wraps inside A4; callouts amber/cyan; table header rows
  repeat (Status values); troubleshooting as five 3-column tables, nothing overflows.

## Orchestrator changes on top of the agents' work
- metadata.yaml `date: 1 October 2026` (pandoc normalises to 2026-10-01 for dcterms).
- theme.css `th code { white-space: nowrap }` so `--install-method` / `--rpc-domain <d>` headers
  stop breaking mid-word.
- Build lint: forbidden terms fail inside code fences too (C had made them warn-only).

## Known cosmetic points (accepted)
- Chapter-per-page leaves short end-of-chapter pages (6, 9, 15, 25 are mostly blank).
- "Menu choice" column of the Install methods table wraps `1) Build from source` to three lines.
- Two em dashes remain, both inside code quoting check-node.sh's literal output.

# Review: MNO guide 1.4 refresh to telcoin-network main (2026-10-15)

## What changed
- `docs/partner/mno-node-guide/mno-node-guide.md` 1.3 -> 1.4 (+16 lines net, 1313 lines) and
  its PDF (48 pages, was 46), describing telcoin-network `main` 98849a221 (three merges past
  `v0.16.0-adiri`: #1622, #1647, #1572) as current behaviour, no release qualifier.
  Correction: the clock-drift sentence (a validator holds its vote up to 1 s on adiri; rejects
  beyond its drift tolerance plus the 5 s vote timeout, "five to six seconds"). Additions:
  bootstrap peers are discovery hints; the opt-in `network-config` keys (four lines);
  the boundary-window repair note; the `Cannot check database (epoch)` pointer and remedy row
  (`consensus-db/epoch` only, never `consensus-db/epochs`); the `initiating node shutdown`
  row; the rejoin wording (20 rounds, `attempting to rejoin consensus`); the
  `worker is inactive` row.
- `OPERATOR.md` and `README.md` carry the same facts in their own style (`support@`,
  "section N.N", "data dir"). `CHANGELOG.md` Unreleased clause, `followup.md` triage.
- Nothing updater-tracked changed: no version bumps, `gen-checksums.sh` reports no drift.

## Verifier catches applied (U3, all re-derived at 98849a221)
- BLOCK: the reject threshold adds `vote_timeout` to the RAW tolerance (handler.rs:787), so
  5.25 s on a current `network-config` and 6 s only where the old bare `1` remains; the facts
  file's "1 s + 5 s" was wrong. Guide says "five to six seconds"; OPERATOR gives both figures.
- `worker is inactive` happens only for a worker the network dropped while the node ran
  (`deactivate_workers_above`); a worker above the count at start is never initialised.
- `; initiating node shutdown` does not exit the process: the consensus notifier is per-epoch,
  the task error is non-critical, `run_epochs` loops; the durability latch is sticky
  (layered_db.rs:233-238), so the node cannot vote until restarted. Row says so and tells the
  operator to restart at once (the wait protects nothing while it cannot vote).
- `network-config` keys are "unset" (absent, `null` or `{}`), not "absent"; every key is
  optional; the Node Manager UI writes `hostname` too.
- A restarted seated node starts `CvvActive` (optimistic) and drops to `CvvInactive` only when
  40+ rounds or an epoch behind; "falls behind, for example during a long restart".
- OPERATOR/README recovery sentence: "stopped while the epoch changes", not "close to the
  boundary". README's discovery-hints sentence moved after "It needs v0.15.0-adiri or later".

## Verification
- `bash tools/build-partner-pdf.sh mno-node-guide --html-only`: exit 0, no FAIL/WARN.
- Full build: "Wrote ... (48 pages)", WeasyPrint log clean; second run "PDF unchanged".
- `pdftotext | tr '\n' ' '` counts: every required string >= 1 (`Cannot check database
  (epoch)`, `consensus-db/epoch`, `consensus-db/epochs`, `attempting to rejoin consensus`,
  `discovery hints`, `five to six seconds`, `initiating node shutdown`, `previous epoch record
  missing`, `source admission is enabled`, `worker is inactive`, `devs@telcoin.org`); every
  forbidden string 0 (`legacy`, `--observer`, `migrate-node-naming`, `setup-observer.sh`,
  `setup-validator.sh`, `grant@`, `support@`, `more than a second ahead`, `next release`,
  `Invalid bytes`, `about six seconds`). Cover: "Version 1.4 · 15 October 2026".
- `pdfinfo`: 48 pages, ModDate 2026-10-15, Author Telcoin Association.
- Page renders viewed (80 dpi): cover, Hardware per role (7), Optional node flags (15), One-way
  updates (19), Restarts and the epoch boundary (20), Watch your status (33), Sync and node
  mode (41), Service and keys (45-46): long rows wrap cleanly, header row repeats across the
  page break, running header and "Page X of 48" intact.
- All 38 `(#slug)` links match heading ids; README's `OPERATOR.md#9-troubleshooting` resolves.
- `git status --short`: M only for the guide .md, metadata.yaml, the PDF, OPERATOR.md,
  README.md, CHANGELOG.md, followup.md, tasks/plan.md, tasks/todo.md; new task files
  untracked until the commit; the specification PDF and the telcoin-network checkout unchanged.

## Accepted as is (verifier NOTEs)
- Row 10a: the message can print `header epoch unknown`; the row already says email first.
- Row 10c leaves out the ERROR-level sibling line at close_epoch.rs:653-662 (also no action).
- "which waits for the epoch boundary" for edit-config menu item 12 is the guide's existing
  shorthand (waits only for a `CvvActive` node inside `TN_EPOCH_MARGIN`).

## Review: follow-ups round, scripts-v2.1.0 (2026-11-03 to 2026-11-04)

Plan of 2026-11-02 executed on branch `hardening-followups` (draft PR #59, 166 commits over main
1187ddb). Specs in `tasks/spec-fup-*.md`; checkpoints `tasks/ckpt-fup-*.md` and
`tasks/ckpt-verify-*.md`; verifier harnesses `tasks/verify-fup/V1..V6/`; the orchestrator's
own notes in `tasks/ckpt-fup-ORCH.md`.

- Wave 0: Dependabot #53 to #57 merged (two over SSH, since both tokens refuse workflow-file
  merges); 16 issue status comments; #34 closed; specs; draft PR.
- Wave 1 and 2: nine packages (LIB-A, LIB-B, KEYS, AUDIT, OBS, REL, FW, UI-S, NET-2, GOV),
  AUDIT-2 for the add-on refresh hooks, and nine follow-up rounds from the verifiers and the
  whole-range review; six independent verifiers (harness first), 170 mutants, 169 caught.
- The review (`/code-review high`, eight angles) found seven seam issues, all fixed: the
  interactive key removal and the host baseline on multi-node hosts, the push-URL override
  intent, the explicit epoch-wait cap, a held firewall lock, an unconditional table rewrite,
  a failed baseline install leaving rules loaded.
- Release prep: 14 version constants at 2.1.0, sidecars regenerated twice (after the fixes).
- Final gates on f0a47c8: fixture suite 61 files, 0 failed under bash 5.3, bash:3.2 (with and
  without flock) and ubuntu:24.04; helper 548/548 under bash 5 and 3.2; pytest 281 on Python
  3.10 and 3.12; shellcheck 0.9 and 0.11, check-bash32, bash -n under 3.2, perl, passphrase,
  root-write-pipe and network-hits lints clean; actionlint clean; the vendored Alloy config
  identical to upstream from the first River component; sync-note sha matching; no attribution
  trailers; no private-path mention.
- CI: all nine jobs and Integration green on dbec6cb; the final tip's run is linked from the
  PR body.
- Docs: README, OPERATOR.md (key lifecycle 4.12, host baseline 4.13), AGENTS.md (mainnet switch,
  contributing, CI, lints), docs/testnet-addons.md, followup.md, CHANGELOG/scripts-v2.1.0.md,
  partner guide 1.6 with a byte-identical PDF.
- Upstream: deploy-networks-common PR #8 (config.alloy token file and TLS 1.3), merged 2026-11-04
  as 18f8485; the vendored header and sync note name it.
- Lessons recorded in `tasks/lessons.md` (BSD userland on the macOS runner, the lock fallback,
  linted verifier records, tree-wide lints on orchestrator commits, commit messages through a
  file, verifier rounds back to the owning implementer).

Left to the maintainer (commands in the closing report): the github-pages tag policy,
`scripts-v2.0.0` cut and signed from main before this merges, the #30 rulesets and settings
(JSON with the two missing contexts and a second approver), telcoin-network PR #1716, the
deploy-networks-common PR #8 merge, the values for the second code owner, mainnet epoch
timing and the nft rate, and `scripts-v2.1.0` with `--serial 2` after the merge.

## Review: round 2 on PR #59 (2026-11-04/05)

Plan of 2026-11-04 (`tasks/plan.md`), specs `tasks/spec-r2-*.md`, checkpoints `tasks/ckpt-r2-*.md`,
verifier records `tasks/verify-r2/{V7,V7-IMG,V8}/`. Last code commit ee641df (90 commits over 4a2cf6e, plus the records); CI and Integration green on
the final tip; the whole-range review (`tasks/verify-r2/REV/REPORT.md`): no ERROR, three MEDIUM
(the tag step could sign a moved origin/main, a rerun ignored `--serial`, the feature-check
timeout could not stop a container ignoring SIGTERM), six LOW and six NOTEs; every MEDIUM and
LOW fixed in the SIG-2 and IMG-3 rounds, the NOTEs recorded.

What landed:
- SIG: OpenPGP-signed script releases (`MANIFEST.asc`, `lib/release-keys/*.asc` as the allowlist,
  one RELEASE SIGNATURES block in update-scripts, install.sh and release-scripts, shell dearmor,
  gpgv status policy, `TN_SIG_THRESHOLD` 1, installer-embedded keys, bootstrap through sidecars,
  CR and non-key refusals), `tools/cut-release.sh prep|tag|status`, CI and VM gates, fixtures with
  real gpg and fakes. First signed release: scripts-v2.1.0, serial 1; scripts-v2.0.0 never tagged.
- IMG: `tn-mainnet` and `tn-testnet` packages, old package recognition-only, `tn-dev` for devnet,
  pull rule beside the recognition rule, IMAGE_DIGEST package rule, storage floor by network,
  build-feature check before any container start (setup, update, edit, finalize), UI twins,
  docker-detect counts devnet repositories, the image prompt stops at end of input.
- EPOCH: `MAINNET_EPOCH_DURATION`/`TESTNET_EPOCH_DURATION` 21600 s; the blind wait derives from
  the network's constant.
- Owners: three code owners; Alloy header at deploy-networks-common main 18f8485.
- Upstream: telcoin-network draft PR #1784 (packages per channel in etc/release.sh, Makefile
  tn-dev, docs), V8-verified (484 assertions at the final tip).
- Docs: README, OPERATOR, AGENTS, lib/release-keys/README, both changelogs, followup, partner
  guide 1.7 (PDF byte-identical twice). Comments on #41 (manifest proposal) and #46 (scheme).
- Test library: `check_has`/`check_lacks` read a here-string (a pipefail flake).

Verification: V7 SIG (0 ERROR, 3 WARN fixed, 39 mutants: 36 caught by the fixtures, 39 with the
harness), V7-IMG (0 ERROR, five fixture gaps and the docker-detect gap fixed, 48 counting mutants
all caught by the fixtures after the fix round), V8 on the upstream branch (0 ERROR, 3 WARN
fixed, 484/484 at the final tip); full suite 62 files x 4 environments (bash 5.3, bash 3.2 with
and without flock, Ubuntu 24.04), helper 557 x 2 shells, pytest 283 x 2 interpreters, every
lint, a sentinel-docker run of the whole suite (no fixture reaches the host docker), CI on every
push, the review.

Left to the maintainer: rulesets (#30) with `require_code_owner_review`; the signing environment
(forwarded gpg-agent) and a test signature; after the merge the ceremony (`cut-release.sh prep
scripts-v2.1.0 --serial 1`, merge, `tag`); PR #1784 review and the package access lists after the
first pushes; a one-time check that `DEFAULT_DOCKER_IMAGE` prints `Build Features: adiri`;
closing #49 if wanted.
