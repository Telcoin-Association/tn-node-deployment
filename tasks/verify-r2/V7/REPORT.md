# V7 verification report, round 2 on PR #59: SIG (GPG-signed script releases)

Verifier V7, 2026-11-04. Worktree `~/coding/telcoin/tnd-r2-V7`, branch `r2/V7`, measured at
`cff2f63` (SIG + EPOCH). The fast-forward to `c0716f3` (IMG) changes no SIG file: only
`lib/common.sh` changed, and `_tn_gpg_status_verdict` is byte-identical. Checked against
`tasks/spec-r2-shared.md`, `tasks/spec-r2-SIG.md` and `tasks/spec-r2-V7.md`. The harness was
built and run before the implementer's checkpoint was read. The IMG part is a separate report
(`tasks/verify-r2/V7-IMG/`). The verifier could not write this file itself (Write refused); the
orchestrator saved its text unchanged.

Host: bash 5.3.9, gpg/gpgv 2.4.8, git, docker 29, shellcheck 0.11. Containers: `bash:3.2`
(busybox), `ubuntu:24.04` (bash 5.2), `koalaman/shellcheck:v0.9.0`.

Every key is a throwaway made with `gpg --quick-gen-key ... --pinentry-mode loopback
--passphrase ''` in a temporary `GNUPGHOME`. Expired keys and signatures come from
`--faked-system-time`. Revocation comes from the key's own revocation certificate, imported into
a second home. ERRSIG code 4 comes from a real signature whose public-key algorithm byte is set
to 99. No real private key, passphrase, `~/.gnupg` or agent socket was touched.

## Harness (`tasks/verify-r2/V7/`)

| file | what it does |
|---|---|
| `lib.sh` | Shared helpers: temporary GNUPGHOME and keys (valid, second, expired, revoked, old, foreign), signing helpers including EXPSIG and ERRSIG-4 signatures, a `curl` shim that serves a stage over `file://` (22 for a missing file), and a release built by `tools/release-scripts.sh` from the worktree's committed tree with the throwaway keys in `lib/release-keys`. |
| `t_policy.sh` | Items 1 and 2: 18 MANIFEST.asc variants at threshold 1 and 4 at threshold 2, each through `release-scripts.sh --check --require-sig --tag`, `update-scripts.sh` and the prepared `install.sh`. Also a host without gpgv, and `--check` on an installed host. |
| `t_parser.sh` | The three copies of the block are compared. `tn_sig_verdict` and `_tn_gpg_status_verdict` (lib/common.sh) both get the status-line shapes real gpgv 2.4.8 prints, plus a 400-sequence random differential. Dearmor bytes are compared with `gpg --dearmor`, and the `base64 -D` fallback is exercised. Runs in all three environments. |
| `t_dearmor.sh` | Item 3: 13 accepted shapes and 13 refused shapes. Every accepted keyring is checked with real gpgv. |
| `t_bootstrap_install.sh` | Items 4 and 5: bootstrap on a bare host, the installer and its trust root, and key rotation (release 2 adds a key). |
| `t_crlf.sh` | One release whose key file has CRLF line endings, run end to end (W1). |
| `t_cut_release.sh` | Item 6: `cut-release.sh` against a bare origin. Real git and real gpg sit behind logging wrappers; `gh`, `curl` and `gpg --card-status` are stubs; HOME is a temp dir. |
| `t_ci.sh` | Item 7: the CI manifest grep, P0-05, CODEOWNERS and the leftover-word grep. |
| `t_mutants.sh` | Item 8: 39 mutants, each in a shallow clone, scored against the fixtures (real gpg and fakes) and against this harness. |
| `t_check_gaps.sh` | Pins the two mutants nothing else caught (U04, U06), on the tree's updater and on the mutated copies. |

All 10 files have a shebang and pass `shellcheck -x --severity=error` 0.11 and 0.9, `bash -n`
under 5.3 and `bash:3.2`, and `bash tools/check-bash32.sh`.

## Counts per environment

Fixtures (`bash tools/tests/run.sh tools/tests/<name>_test.sh`), passed / failed / skipped:

| fixture | host 5.3 real gpg | host `TN_TEST_FAKE_GPG=1` | `bash:3.2` | `ubuntu:24.04` |
|---|---|---|---|---|
| release_scripts_test | 147 / 0 / 0 | 147 / 0 / 0 | 44 / 0 / 2 | 44 / 0 / 2 |
| updater_manifest_test | 215 / 0 / 0 | 214 / 0 / 1 | 211 / 0 / 2 | 211 / 0 / 2 |
| install_test | 109 / 0 / 0 | 108 / 0 / 1 | 108 / 0 / 1 | 108 / 0 / 1 |
| cut_release_test | 68 / 0 / 0 | 68 / 0 / 0 | 0 / 0 / 1 (no git) | 0 / 0 / 1 (no git) |

These match every count in the implementer's checkpoint.

V7 harness, passed / failed:

| script | host 5.3 | `bash:3.2` | `ubuntu:24.04` |
|---|---|---|---|
| t_parser.sh | 48 / 0 | 48 / 0 | 48 / 0 |
| t_policy.sh | 89 / 0 | n/a (needs gpg) | n/a |
| t_dearmor.sh | 42 / 0 | n/a | n/a |
| t_bootstrap_install.sh | 67 / 1 (W1) | n/a | n/a |
| t_crlf.sh | 4 / 1 (W1) | n/a | n/a |
| t_cut_release.sh | 64 / 0 | n/a | n/a |
| t_ci.sh | 22 / 0 | n/a | n/a |
| t_check_gaps.sh | 8 / 0 | n/a | n/a |

## Mutants

Command: `bash tasks/verify-r2/V7/t_mutants.sh`, 6 at a time. Each mutant is applied to a
shallow `file://` clone and committed there, never to the tree; every anchor was asserted to
occur exactly once per file. Block mutants change all three copies alike, except M21, which
changes one copy. The baseline M00 is clean everywhere. Columns: the fixture files that fail
(real gpg | fakes), then the V7 scripts with new failing checks (script:count).

| id | mutant | fixtures, real gpg | fixtures, fakes | V7 harness |
|---|---|---|---|---|
| M01 | block: BADSIG does not refuse | release_scripts updater_manifest install cut_release | same | t_parser:5 t_policy:7 |
| M02 | block: EXPKEYSIG does not refuse | release_scripts updater_manifest install | same | t_parser:3 t_policy:6 |
| M03 | block: REVKEYSIG does not refuse | release_scripts updater_manifest | same | t_parser:3 t_policy:6 |
| M04 | block: EXPSIG does not refuse | release_scripts | same | t_parser:3 t_policy:6 |
| M05 | block: ERRSIG with another code counts as an unknown key | release_scripts | same | t_parser:4 t_policy:7 |
| M06 | block: ERRSIG 9 / NO_PUBKEY refuses (over-strict) | release_scripts updater_manifest | same | t_parser:6 t_dearmor:1 t_policy:9 t_bootstrap_install:4 |
| M07 | block: VALIDSIG counts without GOODSIG | release_scripts | same | t_parser:1 |
| M08 | block: VALIDSIG fingerprint shape not checked | release_scripts | same | t_parser:2 |
| M09 | block: a repeated key counts again (not distinct) | release_scripts updater_manifest | same | t_parser:1 t_policy:3 |
| M10 | block: threshold not enforced | release_scripts updater_manifest | same | t_parser:3 t_policy:9 |
| M11 | block: threshold off by one (-le) | release_scripts updater_manifest install cut_release | same | t_parser:6 t_dearmor:8 t_policy:18 t_bootstrap_install:25 |
| M12 | block: NOSIG branch removed (falls to THRESHOLD) | release_scripts updater_manifest | same | t_parser:10 t_dearmor:1 t_policy:9 t_bootstrap_install:4 |
| M13 | block: a refusing keyword returns 0 | release_scripts updater_manifest install cut_release | same | t_policy:33 |
| M14 | block: tn_verify_manifest ignores the verdict rc | release_scripts updater_manifest install cut_release | same | t_policy:51 t_bootstrap_install:10 |
| M15 | block: dearmor skips a file that is not a key | **-** | **-** | t_dearmor:1 |
| M16 | block: dearmor does not strip CR | release_scripts | same | t_dearmor:3 |
| M17 | block: dearmor reads armor headers as body | release_scripts | same | t_dearmor:3 |
| M18 | block: dearmor keeps the CRC line | release_scripts updater_manifest install cut_release | same | t_parser:3 t_dearmor:19 t_policy:84 t_bootstrap_install:37 |
| M19 | block: dearmor does not check the decode | **-** | release_scripts | t_dearmor:1 |
| M20 | block: dearmor accepts no key file at all | release_scripts install | same | t_dearmor:3 t_bootstrap_install:1 |
| M21 | one copy only: BADSIG does not refuse in install.sh | release_scripts install | same | t_parser:1 t_policy:2 |
| U01 | update-scripts: verify_manifest ignores the verdict | updater_manifest | same | t_policy:19 t_bootstrap_install:8 |
| U02 | update-scripts: bootstrap keys not checked against MANIFEST | updater_manifest | same | t_bootstrap_install:2 |
| U03 | update-scripts: bootstrap key sidecar not compared | updater_manifest | same | t_bootstrap_install:1 |
| U04 | update-scripts: --check does not verify the newest release | **-** | **-** | - (t_check_gaps catches it) |
| U05 | update-scripts: --check does not verify the installed record | updater_manifest | same | t_policy:2 |
| U06 | update-scripts: path_ok lets MANIFEST.asc be a listed file | **-** | **-** | - (t_check_gaps catches it) |
| U07 | update-scripts: bootstraps although a MANIFEST is installed | updater_manifest | same | t_bootstrap_install:3 |
| U08 | update-scripts: bootstrap uses the keys without verifying MANIFEST.asc | updater_manifest | same | t_bootstrap_install:5 |
| I01 | install.sh: verdict ignored | install | same | t_policy:16 t_bootstrap_install:2 |
| I02 | install.sh: also trusts the archive's own keys | install | same | t_bootstrap_install:4 |
| I03 | install.sh: file hashes not compared | install | same | t_bootstrap_install:4 |
| I04 | install.sh: a release without a key file installs | install | same | - |
| R01 | release-scripts: --require-sig without MANIFEST.asc passes | release_scripts | same | t_policy:1 |
| R02 | release-scripts: a signature that does not verify passes | release_scripts cut_release | same | t_policy:17 |
| R03 | release-scripts: embedded keys not compared | release_scripts | same | - |
| R04 | release-scripts: rewrite_installer drops the keys | release_scripts cut_release | same | t_policy:34 t_bootstrap_install:12 |
| R05 | release-scripts: prepare keeps a stale MANIFEST.asc | release_scripts | same | - |
| R06 | release-scripts: a key file outside the updater arrays passes | release_scripts | same | - |

Caught:

| set of checks | caught / total |
|---|---|
| fixtures, real gpg | 35 / 39 |
| fixtures, fakes | 36 / 39 |
| fixtures, either run | 36 / 39 |
| V7 harness (without t_check_gaps) | 33 / 39 |
| all of the above | 37 / 39 |
| all of the above, plus t_check_gaps.sh | 39 / 39 |

No fixture catches M15, U04 or U06 (W3, W2, N11). M19 is caught only in the fakes run. M07
and M08 matter only for status sequences real gpgv never prints; they are caught by the
canned-line parser checks.

## Findings

### ERROR

None. I found no fail-open path. Every refusal the specs name refuses in all three verifiers,
with real gpgv and with the fakes, and leaves the tree or the install as it was.

### WARN

**W1. A key file with CRLF line endings passes the release gate but breaks the published
installer.**
- Command: `bash tasks/verify-r2/V7/t_crlf.sh` (also the CRLF check in `t_bootstrap_install.sh`).
- Expected: `tn_dearmor_keys` strips CR (`sub(/\r$/, "")`), so a CRLF key file verifies in
  update-scripts and release-scripts. The same file should either be refused by the release
  gate, or work in the installer it is embedded in.
- Actual, step by step:
  - `release-scripts.sh` prepare accepts the file.
  - `rewrite_installer` embeds it with its CRs.
  - `--check --require-sig --tag` passes. That is both the CI tag gate and the
    publish-installer gate.
  - `update-scripts.sh` verifies with the key.
  - The released `install.sh` cannot use it. With other keys embedded it refuses with "The
    release signature does not verify against the Telcoin release keys (no release key in
    lib/release-keys made a good signature). Nothing was installed." With that key alone it
    says "This installer carries no readable release key".
- Where: `install.sh` `verify_release`, the awk splitter that writes one `key-N.asc` per block.
  It compares `$0 == "-----BEGIN PGP PUBLIC KEY BLOCK-----"` exactly, without the CR strip that
  `_tn_armor_body` does. On the other side, `tools/release-scripts.sh` `check_keys` (through
  `tn_dearmor_keys`) accepts CR.
- Fix, either or both:
  - add `{ sub(/\r$/, "") }` as the first rule of the splitter;
  - refuse a key file with CR in `check_keys`, as `check` already does for MANIFEST.
- Fixture: `tools/tests/install_test.sh` (a CRLF embedded key verifies), or
  `tools/tests/release_scripts_test.sh` (prepare and `--check` refuse a CR key file).

**W2. No fixture checks `--check` against a forged newest release (mutant U04 survives every
fixture).**
- Command: `bash tasks/verify-r2/V7/t_check_gaps.sh`.
- Setup: an installed host at release 1; RELEASE names `scripts-v2.1.1` (serial 2), whose
  MANIFEST.asc is by a foreign key.
- Expected and actual for the tree: rc 2 and "The release manifest is not signed by a Telcoin
  release key (no release key in lib/release-keys made a good signature); nothing was changed."
  The tree is correct.
- With `verify_manifest ... || return 2` removed from `update-scripts.sh` `check_release`,
  `--check` instead reports "Update pending: every file already matches scripts-v2.1.1, but the
  record names scripts-v2.1.0" with rc 1. No fixture would notice. An update run still refuses,
  but check-node and monitoring read `--check`.
- Fixture: `tools/tests/updater_manifest_test.sh`, add a `--check` case where the newest
  MANIFEST.asc does not verify, expecting rc 2 and the reason.

**W3. No fixture checks that a non-key `.asc` beside a good key is refused (mutant M15 survives
every fixture).**
- Spec S1 says `tn_dearmor_keys` refuses "a file that is not an armored public key block". The
  fixtures test such a file only as the lone file. There, a mutant that skips it still fails on
  "no release key file", so the fixtures cannot tell skipping from refusing.
- `t_dearmor.sh` "a good key file and a junk one: refused whole" catches the mutant.
- Impact if it regressed: a junk `.asc` would be ignored silently. That adds no trust, so this is
  a regression risk, not a hole.
- Fixture: `tools/tests/release_scripts_test.sh`, dearmor section: a dir holding a good key and
  a junk `.asc` expects rc 1 and "is not an ASCII-armored OpenPGP public key".

### NOTE

- **N1. An armored block that decodes to something other than a key passes `check_keys`, and
  then breaks every verification.**
  - Command: `t_dearmor.sh`, "decodes but is not a key".
  - `tn_dearmor_keys` accepts the file, as spec S1 defines it (armor and decode only). gpgv
    then rejects the whole keyring, so a good signature by the valid key next to it comes back
    NOSIG, whichever order the files are in.
  - This fails closed, and `--check --require-sig` catches it before a release, but with a
    misleading reason. Where: `tools/release-scripts.sh` `check_keys`.
  - Suggestion: when gpg is present, also require `key_fpr` (already there for
    `sign_commands`) to read a fingerprint from each file.
- **N2. Bootstrap is trust on first use, by design.** A tag that swaps a key file, its sidecar,
  its MANIFEST line and the signature together is accepted on a host with no key and no
  MANIFEST (`t_bootstrap_install.sh`, "trust limit"). The same swap is refused (NOSIG) on a host
  that already has the release key. That matches spec S3 and the "one time only" warning.
  Existing hosts already carry `lib/release-keys/grantkee.asc` from the node-release trust, so
  they never bootstrap.
- **N3. Hosts keep a leftover `lib/allowed_signers`.** The updater removes only files an
  installed MANIFEST lists. Spec S3 allows this, and SIG's Docs notes say it.
- **N4. gpgv 2.4.8 exits 0 on EXPKEYSIG and REVKEYSIG.** It exits 1 on EXPSIG and BADSIG, and 2
  on ERRSIG and NODATA. Only the status parser refuses expired and revoked keys. All three
  verifiers take their verdict from `tn_sig_verdict` and never from gpgv's exit code, which is
  correct. AGENTS.md should state this as an invariant (DOCS-2).
- **N5. The release key expires 2028-10-16.** That is the primary `4E36D35A...7573`; the
  subkeys only authenticate and encrypt.
  - A host whose installed copy has expired refuses every later release with EXPKEYSIG.
  - Only a release that verifies against that installed copy can renew it.
  - So the extended key must ship in a release before that date, and hosts that miss the window
    re-run the installer. This is operational (DOCS-2 or ops).
- **N6. cut-release.sh refuses a non-release key after step 2.** A `--key` or
  `user.signingkey` outside lib/release-keys is refused, as spec S5 orders it, but only after
  `release/TAG` has been created and checked out, so the clone stays on that branch. Nothing is
  prepared or signed, and a rerun carries on.
- **N7. cut-release.sh `tag` trusts any key gpg trusts for an existing tag.** An existing local
  tag that names origin/main counts as done whenever `git verify-tag` passes, which accepts a
  signature by any key in the maintainer's keyring. No consumer checks the tag signature, so this
  is cosmetic. Step 7 also prompts twice (stage, then commit), and both prompts are labelled
  `[7/9]`.
- **N8. Container coverage.**
  - In `bash:3.2` and `ubuntu:24.04` (no git), `cut_release_test.sh` skips whole and
    `release_scripts_test.sh` runs 44 of its 147 checks. The macOS CI job has git and runs them
    all.
  - The fakes never print EXPSIG or an ERRSIG code other than 9. The canned-line parser checks
    cover those branches.
  - The "does not decode" dearmor branch (M19) is pinned only in the fakes run.
- **N9. Where the implementer's checkpoint lives.** It is at
  `~/coding/telcoin/tnd-r2-SIG/tasks/ckpt-r2-SIG.md` (now also committed at `c0716f3`), not in
  this worktree when I verified. Every count it gives matches my runs. It does not mention CRLF
  key files.
- **N10. The SSH signing words survive only in DOCS-2's markdown.** Code, workflows, tests and
  shipped non-markdown files are clean (`t_ci.sh`); the VPN tooling's `ssh-keygen -lf`
  fingerprinting is unrelated. Markdown that still names them, all listed in SIG's Docs notes:
  AGENTS.md 16, README.md 18, OPERATOR.md 11, mno-node-guide.md 3, CHANGELOG.md 1,
  CHANGELOG/scripts-v2.0.0.md 5, followup.md 6.
- **N11. No fixture pins the `path_ok` rule that keeps `MANIFEST.asc` out of the listed files
  (mutant U06).** The tree refuses "bad path: MANIFEST.asc". The mutant still refuses, because a
  listed hash cannot be the signature's own ("does not match the signed manifest"). So it is safe
  either way, but the rule spec S3 names has no fixture. Optional line in
  `tools/tests/updater_manifest_test.sh`.

## What was verified (spec V7 SIG items 1-8)

1. **Harness.** A release prepared by release-scripts from the tree, with five throwaway keys
   shipped and one foreign key, served over `file://`.
   - Prepare prints `gpg --armor --detach-sign --local-user <FPR>! --output MANIFEST.asc
     MANIFEST` with the real fingerprint.
   - It lists every key file in MANIFEST, embeds all five in install.sh and removes
     MANIFEST.asc.
2. **Policy.** All three verifiers agree (`t_policy.sh`).
   - Accepted: one good signature; two keys (both fingerprints printed); the same key twice; good
     plus foreign (with the "is not a release key" warning).
   - Refused at threshold 1, with the matching reason: BADSIG (tampered MANIFEST), EXPKEYSIG,
     REVKEYSIG, EXPSIG, NOSIG (foreign key alone, empty `.asc`, text that is not a signature),
     ERRSIG 4 (the message names "(error 4)"), good+bad, good+expired, good+revoked, good+expired
     signature, good+ERRSIG 4, and a missing `.asc`.
   - Threshold 2: one key, the same key twice, and good+foreign are refused with THRESHOLD; two
     keys are accepted.
   - Without gpgv, all three refuse and name the packages to install.
   - Every refusal leaves the updater host unchanged and leaves no install or staging dir.
   - Parity with the library: verdict keyword and accept/refuse equal `_tn_gpg_status_verdict`'s
     on every canned case and on 400 random sequences, in all three shells. The only differences
     are by design: the threshold, the key id in the refusing line, and unknown ids going to
     stderr.
   - The three copies of the block are byte-identical (sha256 `8d85ac75...`).
3. **Dearmor.**
   - Accepted, each giving the bytes of `gpg --dearmor` and each verified with gpgv:
     Version:/Comment: headers with a CRC line, no CRC line, CRLF, two blocks in one file, one
     block holding two keys, two files, two DIR arguments, and text around the block.
   - Refused: plain text, a PGP SIGNATURE block, a PRIVATE KEY BLOCK, no END line, no blank
     line, a non-base64 character, an empty body, a good block followed by a malformed one,
     padding mid-body, an empty dir, only a symlinked `.asc`, and a good file beside a junk one.
   - busybox base64, coreutils base64, and a base64 that takes only `-D` all produce the same
     keyring.
4. **Bootstrap.**
   - Happy path: all five keys installed, each hashing to its MANIFEST line, and `--check` passes
     afterwards. It also works through self-update from an older updater.
   - Refused with nothing installed: a sidecar that does not match, a missing sidecar, a
     malformed sidecar, a swapped key with a matching sidecar, a swapped key that also signs, a
     MANIFEST.asc by a key outside the fetched set, a key path below a subdirectory, a MANIFEST
     with no key, and a host with a MANIFEST but no keys.
5. **Installer.**
   - The embedded keys verify. The installed keys hash to the MANIFEST lines and equal the
     embedded block, and there is no `lib/allowed_signers`.
   - A key file that differs from its MANIFEST line is refused before install, and the old
     install stays as it was. An unlisted extra key file in the archive is not installed.
   - The embedded set is the trust root: a signature by a key that the archive ships but the
     installer does not embed is refused (NOSIG). An empty key block is refused.
   - Rotation: release 2 signed only by a new key is refused on a release-1 host. Signed by the
     installed key, it is accepted and the new key is installed.
6. **cut-release.sh.**
   - Order: prepare (log line 14) < sign (56) < check (57) < commit (60) < push (64) < pr (66).
     Every step header is followed by its `$` command.
   - The commit is signed by the release key (`verify-commit` VALIDSIG) and holds exactly
     MANIFEST, MANIFEST.asc, RELEASE and install.sh. The PR body names the serial, the
     fingerprint and the tag.
   - Refusals: a dirty tree (no branch made); `--key` or `user.signingkey` outside
     lib/release-keys; `tag` before the merge (no tag made); `tag` when origin/main's
     MANIFEST.asc is not the branch's.
   - Resume: killed right after sign, the rerun reports steps 4 and 5 already done, runs check,
     commit, push and pr, and does not sign again. `q` at step 6 stops with rc 0. A full rerun is
     all "already done".
   - `--sig-from` copies the file, skips the card check with a warning and does not sign; a
     signature that does not verify stops at step 6 with nothing committed.
   - With no card, it prints the command, waits for MANIFEST.asc and then carries on.
   - `tag` makes a signed annotated tag on origin/main, checks in a temporary worktree and removes
     it, polls a running CI run until it completes, and checks the served installer. A failed CI
     run, or an installer that does not serve the tag, gives rc 1. `status` works.
   - Git config: no repo config holds commit.gpgsign, tag.gpgsign, user.signingkey or gpg.*; no
     global config was written; the tool ran `git config` only with `--get`.
7. **CI and workflows.**
   - The grep is `MANIFEST|MANIFEST\.asc|RELEASE`. It matches those three and none of
     `MANIFEST.sig`, `MANIFESTxasc`, `lib/MANIFEST` and `install.sh`.
   - The tag path runs `--check --tag`, a release change runs `--check --require-sig`, and
     publish-installer runs `--check --tag` before publishing.
   - P0-05 asserts gpgv and runs the four fixtures.
   - CODEOWNERS has `/lib/release-keys/` and `/MANIFEST.asc` with three owners each, and no old
     lines. `lib/allowed_signers` and its sidecar are gone.
8. **Fixtures and mutants:** see the tables above.

## Verdict for SIG

SIG does what its spec asks, and I found nothing unsafe. One RELEASE SIGNATURES block,
byte-identical in all three scripts, applies the node-release gpgv policy, and on 400 random
status sequences it reaches the same verdicts as `_tn_gpg_status_verdict`. The keyring built
from `lib/release-keys` is the allowlist, and the threshold counts distinct primary keys. Each
of the three verifiers refuses every bad, expired, revoked, expired-signature, unknown-algorithm,
foreign, empty, mixed and below-threshold case, with real gpgv and with the fakes. Each refusal
leaves the host or the install untouched.

Bootstrap binds the fetched keys to the signed MANIFEST, and the installer's embedded keys are
its only trust root. Key rotation works in both directions. cut-release.sh runs its steps in
order, resumes from the state on disk, refuses dirty trees, foreign keys and unmerged tags, and
never writes git config. Every fixture count the implementer claims reproduces in all four
environments.

What remains before merge: W1, a fail-closed defect where a CRLF key file would pass CI and ship
an installer that cannot install, fixed with one awk rule or a CR refusal in `check_keys`. And
two fixture gaps, W2 (`--check` against a forged newest release) and W3 (a junk `.asc` beside a
good key). With those three addressed, I would approve SIG.
