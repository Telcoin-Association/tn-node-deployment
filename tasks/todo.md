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
