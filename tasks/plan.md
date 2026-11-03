# Plan: merge main into docs/technical-specification, refresh the partner documents against telcoin-network main, update PR #58 (2026-11-03)

Branch `docs/technical-specification` (PR #58, draft). Base was 037c810; main at 28a7cc7
(265 commits: the mainnet hardening round, scripts-v2.0.0, the devnet Docker images, a
dependabot bump). Protocol facts refreshed to telcoin-network main at 7167e7800 (2 Nov 2026,
27 commits past `v0.16.0-adiri`, still the newest tag). Facts: `tasks/spec-refresh-2026-11-facts.md`
(preamble) joined from the F1-F3 parts; the change log of the spec is
`tasks/ckpt-spec-refresh-2-log.md`; checkpoints are `tasks/ckpt-merge-A*.md`,
`tasks/ckpt-facts-F*.md`, `tasks/ckpt-refresh-S*.md`, `tasks/ckpt-refresh-V1.md`.

## W0 Setup (orchestrator)
- [x] project-context agent; fetch main and the branch; check the branch out
- [x] pin telcoin-network main (7167e7800) in a detached worktree under the session scratchpad
- [x] `git merge-tree` dry run (9 content conflicts + the old-path PDF, README auto-merged)
- [x] `git merge --no-commit --no-ff origin/main`; resolve the mechanical files myself:
      guide `metadata.yaml` (branch's), old-path PDF (`git rm`), `tasks/lessons.md` (main's
      then the branch's sections), `tasks/plan.md` and `tasks/todo.md` (main's, `---`, the branch's)
- [x] checkpoint stubs and the facts-file preamble

## W1 Merge conflicts (A1-A3, opus, parallel)
- [x] A1 `AGENTS.md`, `CHANGELOG.md`, `followup.md`
- [x] A2 `OPERATOR.md` (2 regions) and `README.md` (auto-merge checked; one paragraph moved back)
- [x] A3 the guide (3 regions), hunk survival both ways, contact sweep, `--html-only` build
- [x] no markers, `git diff --check` (one trailing space in main's own fixture), no script
      differs from main except `tools/build-partner-pdf.sh`; merge committed as 58665ac

## F Facts against telcoin-network main (F1-F3, opus, parallel, read-only worktree)
- [x] F1 storage, sync, restart recovery (#1558, #1767, #1737, #1740, #1648, #1572)
- [x] F2 networking (seven security merges, #1534, #1677, #1679, #1690, #1691, #1692, #1695,
      #1696, #1736, #1739, #1651, #1652, #1553)
- [x] F3 consensus, epoch, execution, CLI, release docs (#1544-#1546, #1556, #1557, #1693,
      #1559, #1715, #694)
- [x] join the parts into `tasks/spec-refresh-2026-11-facts.md`

## W2 Content refresh (S1-S3, opus, parallel; then V1)
- [x] S1 spec writer (log in `tasks/ckpt-spec-refresh-2-log.md`; Introduction edition sentence)
- [x] S2 guide writer (devs@telcoin.org only)
- [x] S3 OPERATOR.md and README.md (support@telcoin.org there; `--all` in the README paragraph)
- [x] V1a/V1b/V1c re-derive every changed statement from the worktree (one per document); X2 and X3
      fix; the orchestrator fixes the spec; V2 re-checks the fixes

## W3 Metadata, build, verify, commit, push, PR
- [x] guide 1.5 / spec 1.2, `date: November 2026`, `protocol: v0.16.0-adiri, main at 7167e7800`
- [x] guide template: `$if(date-meta)$` guard on the two dcterms tags
- [x] CHANGELOG top entry; followup items (credential source, bootstrap-peers file, tndb one-way,
      health listener bind vs the health-monitor add-on, staging 10-27 and the worker gateway)
- [x] container build `--all`: lint clean, WeasyPrint clean, pages in 15-150, `Wrote` both; run
      again: both `PDF unchanged`
- [x] `pdftotext`: "November 2026" on both covers, no "October 2026" cover line,
      `devs@telcoin.org` present, the spec's protocol line carries the sha
- [x] `tasks/todo.md` review section; `tasks/lessons.md` (the tag-check rule, after V1b/V1c corrected decision 2)
- [ ] commit 2 (no trailer), push (fast-forward), PR body via `gh pr edit 58 --body-file`
- [ ] `gh pr view 58`: MERGEABLE; remove the telcoin-network worktree; back to `mainnet-hardening`

---

# Plan: mainnet hardening round (2026-10-15)

Done on branch `mainnet-hardening`, forked from `main` at 037c810: 155 commits up to 417fbe2,
then the docs and release prep. The previous plan (the followup.md backlog round of
2026-10-01) is complete; its review is in `tasks/todo.md`.

## Goal

Make the scripts fit to run a mainnet validator. In practice that means:

- the install tree is root-owned, and root never runs or trusts a file the service account can
  write;
- the BLS passphrase never sits on a command line, in a unit `Environment=` line or in an
  exported variable;
- script updates install only from a signed manifest, node releases only from a signed
  `SHA256SUMS`, and Docker images only by digest;
- every node restart waits for the epoch window and refuses when it would cost the committee
  its quorum;
- the add-ons and the Node Manager UI follow the same rules.

What this round could not finish is in `followup.md`.

## How the round ran

- One integration branch. Each package worked on its own branch in its own worktree, was
  rebased onto the tip and merged fast-forward, so the history stays linear. One person merged.
- Packages did not bump version constants or edit the updater arrays (`SCRIPTS`, `UI_BUNDLE`,
  `TESTNET_ADDONS_BUNDLE`); release prep does both once.
- The shared primitives landed first, so every later package coded against one set of helpers.
- After each package merged, an independent verifier wrote its own harness against the spec,
  and a fix pass on its own branch closed what the verifier found.
- Every package ran the same gates: `bash -n` under bash 5 and bash 3.2,
  `tools/check-bash32.sh`, `shellcheck -x --severity=error`, the fixture suite
  `tools/tests/run.sh` under bash 5, under `bash:3.2` and as root in `ubuntu:24.04`, the UI
  tests, and from the credential package on, `tools/check-perl-interp.sh`. Suite counts below
  are checks passed / failed / skipped.

## Packages

- [x] Test runner and root-write primitives. `tools/tests/` with a runner and shared check
      helpers; `tn_root_dir_ok`, `tn_write_root_file`, `tn_backup_file`, `tn_restore_backup`,
      `tn_install_root_binary`, `tn_as_service_user`, `tn_detect_network`,
      `tn_passphrase_ok`, `tn_release_tag_ok`, `tn_start_script_path`; `meta_get` refuses a
      duplicated key. Gates: bash 5 193/0/5, bash 3.2 233/0/2, Ubuntu as root 248/0/0.
- [x] update-node rollback. The pending update is written root 0600 and parsed as
      `KEY=value` data; backups go through `tn_backup_file` with recorded hashes, and every
      rollback through `tn_restore_backup`, which refuses a hash mismatch; the binary is
      installed with `tn_install_root_binary` and hashed before start; source builds pick
      their cargo features from a known network only. edit-config writes the BLS passphrase
      root-only. Gates: suite green at merge.
- [x] Release signing and updater. `update-scripts.sh` installs only from a `MANIFEST` signed
      with `ssh-keygen -Y` and published under a `scripts-v*` tag: serial check, `min_updater`,
      all-or-nothing staging. `install.sh` is pinned to a release tag. New
      `tools/release-scripts.sh` and `lib/allowed_signers`. CI gained pinned actions,
      per-job permissions, the fixture suites (Linux and macOS), the hardening lints, a
      manifest check, the VM assertions in `integration.yml` and an installer publish from
      `scripts-v*` tags; CODEOWNERS added. Gates: after its fix pass `updater_manifest_test.sh`
      89 checks and `install_test.sh` 47, all green in the three environments.
- [x] Node Manager UI. Per-install token, Host and Origin checks, POST with JSON only, body
      cap, rate limit, security headers, an audit log and redacted streams; every helper
      argument checked against a pattern and secrets passed on stdin; install-ui builds a
      root-owned venv from hashed requirements and checks sudoers with `visudo`. Gates: pytest
      178, `helper_test.sh` 302 under both bashes, `open_ui_test.sh` 8.
- [x] Lock and root-owned layout. The update lock moved to `/run/telcoin/update.lock`;
      `create_directories` stopped using `chown -R`; `/etc/telcoin`, `.node-meta`, the start
      scripts and the binary are root-owned and the data directory belongs to the service
      account; `tn_migrate_ownership` converts an existing host under the lock. setup-node
      takes `--passphrase-stdin` and runs the keytool as the service account; prepare-stake
      and migrate-node-naming take the lock and wait for the epoch window; check-node reports
      a cleartext key, the lock state and the ownership table. Gates at merge: bash 5
      740/0/32, bash 3.2 772/0/25, Ubuntu as root 946/0/5.
- [x] Add-ons. firewall-setup checks its inputs first, saves and restores the ufw rules on any
      failure, takes `--ssh-from` and `--p2p-from` source lists and hardens sshd through a
      drop-in; setup-vpn reads maintainer keys from a `KEYS` file with a revocation list and
      runs a root-owned self-heal; install-caddy moved the Caddy admin API to a unix socket,
      pins the Caddy apt key and takes the dashboard password on stdin; observability runs
      Alloy as its own account, pins the Grafana apt key and pushes only on testnet. Gates at
      merge: bash 5 1139/0/32, bash 3.2 1171/0/25, Ubuntu as root 1345/0/5 (24 test files).
- [x] Unit and start-script generator. `tn_write_node_env`, `tn_write_start_script`,
      `tn_write_node_unit` and `tn_rerender_node_launch` render `node.env`, the start script
      under `/usr/local/libexec/telcoin/` and a sandboxed unit (`systemd-analyze security`
      1.4 for the binary unit); the start script feeds the passphrase on stdin; Docker
      containers run read-only with all capabilities dropped; `tn_committee_down_guard` and
      `--allow-quorum-risk` guard every restart; edit-config keeps the listeners in
      `node.env` and no longer edits values with perl or sed; journald gets a size cap.
      Gates: 31 test files green under bash 5, helper 302/0.
- [x] Credential migration. The passphrase is stored as a `systemd-creds` credential
      (`host+tpm2` when a TPM is present, else `host`); the TPM unseal method is gone;
      `edit-config.sh --migrate-credential` and `--reseal` convert and reseal; the testnet
      genesis, committee and parameters files are pinned by hash; mainnet needs systemd 255;
      remove-node shreds secrets and removes every host file the node left. Gates at merge:
      bash 5 1838/0/33, bash 3.2 1881/0/28, Ubuntu as root 2017/0/8, helper 327/0, perl lint
      clean over 77 files.
- [x] Release installs and Docker digests. `--install-method release` downloads a node
      release and checks `SHA256SUMS.asc` with `gpgv` against the keys in `lib/release-keys/`;
      source builds take release tags only and build as the `tn-build` account with a pinned
      rustup; Docker comes from Docker's apt repository after a fingerprint check, with
      live-restore; images run by digest; downgrades are refused; update-node checks after an
      update that the node is voting again. check-node gained `--audit`. Gates: 51 test files
      green in all three environments, perl lint clean.
- [x] Fix passes, one per package after its verifier. Lock file 0600, symlink-chain check for
      the binary, in-flight temp file cleanup, a required-helper check in every root script,
      signal handling in setup-node and firewall-setup, guard-then-wait ordering in the
      add-ons, a release updater that runs from the verified staging directory, safer
      shredding in remove-node and resumable removal, migration of inline-binary legacy
      units, and the UI fixes. Gates after each merge: 42, 43, 46, then 51 test files green;
      helper 327/0; UI pytest 189, `install_ui_test.sh` 13, `open_ui_test.sh` 9.
- [x] Docs. README, OPERATOR.md, the partner guide and its PDF, AGENTS.md, CHANGELOG.md with
      `CHANGELOG/scripts-v2.0.0.md`, `docs/testnet-addons.md`, WGVPN.md, followup.md and these
      task files, all checked against the code on the branch. Gates: partner PDF build, link
      check, old-term grep with every remaining hit intentional.

## telcoin-network branches

- [x] Credential passphrase source (`credential-passphrase-source`): `--bls-passphrase-source
      credential` with `--bls-passphrase-credential <NAME>`, a zeroized passphrase, the
      environment value scrubbed after reading, and `node --bootstrap-peers-file`. 238 tests,
      fmt and clippy clean, attested and pushed. The draft PR is not open yet.
- [x] Chain 487 guard (`mainnet-chain-guard`): chain id constants, faucet refused on chain 487
      without `--allow-faucet-on-chain-487`, build features in `--version` and in the startup
      line, a cleartext BLS key refused on chain 487 without `--allow-cleartext-bls-key`. 523
      and 122 tests, clippy clean with both feature sets, attested and pushed. The draft PR is
      not open yet.
- [x] Release pipeline (`releases-infra`, PR #694, draft): `SHA256SUMS` lists `IMAGE_DIGEST`,
      the tarball and the three chain-config files; mainnet tags refuse any build feature;
      Dockerfile base images pinned by digest; release docs describe how the scripts verify.
      Attested and pushed.

## Merge order

Primitives, update-node rollback, release signing and updater, Node Manager UI, lock and
root-owned layout, add-ons, unit and start-script generator, UI fix pass, credential
migration, updater fix pass, layout fix pass, generator fix pass, add-ons fix pass, release
installs and Docker digests, credential fix pass (417fbe2), docs, release prep.

## Release prep

- [ ] Set the versions: every changed script 2.0.0, `COMMON_VERSION` 2.0.0, `FALLBACK_VERSION`
      1.1.0, `UI_VERSION` 2.0.0, `HELPER_API` and `HELPER_API_REQUIRED` 3,
      `OBSERVABILITY_VERSION` 2.0.0, `TESTNET_ADDONS_VERSION` 1.1.0.
- [ ] Add the new tracked files to the updater arrays (`lib/allowed_signers`,
      `lib/release-keys/*.asc`, `lib/wgvpn/peers/ssh/KEYS`) and run `tools/gen-checksums.sh`.
- [ ] Dry-run `tools/release-scripts.sh`, sign `MANIFEST`, and push the `scripts-v2.0.0` tag
      right after the release merges.
- [ ] Review the whole range and open the PR.

---


# Plan: refresh the MNO node guide to telcoin-network main 98849a221 and rebuild its PDF

Approved 2026-10-15. Branch `docs/technical-specification` (on top of 706a730). One commit,
no attribution trailer, no push. Facts, rules, decisions and the full edit lists are in
`tasks/spec-guide-refresh-facts.md`; checkpoints are `tasks/ckpt-guide-<unit>.md`.

## W0 Setup (orchestrator)
- [x] line numbers in the guide, OPERATOR.md and README.md match the plan
- [x] upstream citations re-read at 98849a221 (clock drift, recovery log lines, the
      `Cannot check database (epoch)` text, certifier, rejoin, worker RPC, network-config keys)
- [x] `tasks/spec-guide-refresh-facts.md`, `tasks/plan.md`, checkpoint stubs
- [x] baseline `bash tools/build-partner-pdf.sh mno-node-guide --html-only` passes on the
      untouched tree; `git status` clean apart from the known untracked files

## W1 Writers (two opus agents in parallel, disjoint files)
- [x] U1 guide-writer: items 1-11 on `mno-node-guide.md` and `metadata.yaml`, bottom-up;
      `--html-only` lint and anchor check pass; checkpoint `tasks/ckpt-guide-U1.md`
- [x] U2 ops-docs-writer: the OPERATOR.md and README.md list; `git diff --stat` touches only
      those two files; checkpoint `tasks/ckpt-guide-U2.md`

## W2 Verifier (one opus agent after W1)
- [x] U3 verifier: every changed or added sentence re-derived from telcoin-network at
      98849a221 (never from the writers' notes first); figures, log strings, key names, the
      `initiating node shutdown` outcome; no "next release"; lint; anchors; net growth <= 40
      lines; forbidden terms; the three files agree; findings in `tasks/ckpt-guide-U3.md`
- [x] orchestrator applies the fixes or sends them back to U1/U2

## W3 Close (orchestrator)
- [x] CHANGELOG.md "Unreleased": "Partner guide 1.4, October 2026" clause
- [x] followup.md: the triage list and the next-tag re-check
- [x] tasks/todo.md review section
- [x] `bash tools/build-partner-pdf.sh mno-node-guide` writes 46-48 pages, WeasyPrint log
      clean; second run prints "PDF unchanged"
- [x] pdftotext checks (required strings present, forbidden strings absent, cover shows 1.4)
- [x] page renders viewed: cover, Hardware per role, Optional node flags, Restarts and the
      epoch boundary, One-way updates, Watch your status, Sync and node mode, Service and keys
- [x] `pdfinfo`: ModDate 2026-10-15, Author Telcoin Association
- [x] `git status --short`: only the expected files; `gen-checksums.sh` reports no sidecar
      drift; the specification PDF and the telcoin-network checkout unchanged
- [x] commit `docs: guide 1.4 describes telcoin-network main: epoch restart recovery, clock
      drift, opt-in network-config keys` (no trailer)
- [x] memory `technical-specification-branch.md` updated
