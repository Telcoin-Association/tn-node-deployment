# Package SIG: GPG-signed script releases (tn-node-deployment)

Read `tasks/spec-r2-shared.md` first. Worktree `~/coding/telcoin/tnd-r2-SIG`, branch `r2/SIG`,
checkpoint `tasks/ckpt-r2-SIG.md`. Size L. Owner of: `update-scripts.sh`, `install.sh`,
`tools/release-scripts.sh`, new `tools/cut-release.sh`, `lib/allowed_signers` (removed),
`lib/release-keys/README` (one paragraph), `.github/CODEOWNERS` path lines, `ci.yml` and
`publish-installer.yml` comments and the manifest grep, `tools/tests/signing.sh`,
`release_scripts_test.sh`, `updater_manifest_test.sh`, `install_test.sh`, new
`cut_release_test.sh`, `vm.d/P0-05.sh`, AGENTS.md "Self-update and integrity contract" facts
only as Docs notes (DOCS-2 writes them).

## Goal

Script releases are signed with OpenPGP by the maintainer release key(s) in
`lib/release-keys/*.asc`, the same key and the same `gpgv` status policy this repository already
uses for node releases, instead of SSH signatures against `lib/allowed_signers`. The signature
file is `MANIFEST.asc`. `scripts-v2.1.0` is the first signed release (serial 1).

## Today (verified 2026-11-04 at 9fd615a)

- SSH constants `release@telcoin.org` / `tn-node-scripts`: release-scripts.sh:61-64,
  update-scripts.sh:46-47, install.sh:28-29. `verify_sig` release-scripts.sh:250-254;
  `verify_manifest` update-scripts.sh:397-411; `verify_release` install.sh:213-288;
  `rewrite_installer` release-scripts.sh:257-279 embeds `lib/allowed_signers` into install.sh
  as the `TN_ALLOWED_SIGNERS` heredoc; `bootstrap_signers` update-scripts.sh:371-392 fetches
  `lib/allowed_signers` + sidecar on a host without one. Other mentions: update-scripts.sh
  6-7,94,136-141,281-289,366-411,471,655-755,824-870,931-932; install.sh 6,17,21,43-72,103,
  171-178,208-226,282-284; release-scripts.sh 9-20,37-49,156,174,196-211,233-254,288-289,
  342-359,445-463; ci.yml 4,152-154,179 (`grep -qxE 'MANIFEST|MANIFEST\.sig|RELEASE'`),225;
  publish-installer.yml 5-6; CODEOWNERS `/lib/allowed_signers`, `/MANIFEST.sig`.
  Grep `allowed_signers|MANIFEST.sig|ssh-keygen|tn-node-scripts|release@telcoin.org` over the
  tree (excluding `tasks/`, `CHANGELOG/`, README/OPERATOR/partner guide, which DOCS-2 handles)
  before you finish: zero hits left in code, workflows and tests.
- `tools/tests/signing.sh`: `REAL_SSH`, `newkey`, `sign_file`; a fake `ssh-keygen` (`FAKESIG`
  lines) where OpenSSH is absent. `vm.d/P0-05.sh:14` asserts ssh-keygen.
- GPG helpers to mirror (do not call the library from the three self-contained scripts; copy
  the policy): `_tn_gpg_status_verdict` common.sh ~7243 (BADSIG/EXPKEYSIG/REVKEYSIG/EXPSIG
  refuse; NO_PUBKEY or ERRSIG code 9 = unknown key, any other ERRSIG refuses; GOODSIG followed
  by VALIDSIG whose last field is a 40-hex primary fingerprint counts). `_tn_release_keyring`
  ~7213 dearmors with `gpg --dearmor` (the library may keep that; setup-node installs gnupg).
  `tools/tests/release_fetch_test.sh:199-241` makes throwaway keys with `--quick-gen-key`
  under a temporary `GNUPGHOME`, including an expired one via `--faked-system-time`, and
  concatenates armored detached signatures into one `.asc`.
- Updater-tracked list: `lib/release-keys/grantkee.asc` and `lib/release-keys/README` are in
  `SCRIPTS` (update-scripts.sh:95-96); `lib/allowed_signers` is there too (line ~94).

## Sections (one commit each; checkpoint after each)

S1 **Policy and dearmor, shared shape.** In each of `tools/release-scripts.sh`,
`update-scripts.sh`, `install.sh` (self-contained, no sourcing of lib/common.sh in the updater
and installer paths that run before the tree exists): constants `TN_SIG_FILE="MANIFEST.asc"`,
`TN_SIG_THRESHOLD=1` (the hook for #40's 2-of-N: distinct signing keys needed), key directory
`lib/release-keys` with the glob `*.asc`. Functions: `tn_dearmor_keys DIR... > keyring` (for each
`.asc`: drop everything up to and including the first blank line after `-----BEGIN PGP PUBLIC
KEY BLOCK-----`, drop the `=CRC` line and the `-----END` line, base64-decode the body with
`base64 -d`, falling back to `base64 -D` when `-d` fails on an empty probe, and append the
binary packets; refuse a file that is not an armored public key block, or whose body does not
decode); `tn_verify_manifest KEYRING MANIFEST.asc MANIFEST` runs `gpgv --status-fd 1 --keyring
KR SIG FILE` (stderr to a log you print on failure), parses the status lines with the policy
above, counts DISTINCT primary fingerprints that made a GOODSIG+VALIDSIG pair, refuses on any
BADSIG/EXPKEYSIG/REVKEYSIG/EXPSIG/ERRSIG≠9, requires count ≥ `TN_SIG_THRESHOLD`, and prints the
fingerprints it accepted. `gpgv` is the only OpenPGP tool the updater and installer need
(apt package `gpgv`, brew `gnupg`); dependency checks name it. The keyring is the allowlist: a
GOODSIG by a key not in it cannot happen, so no separate allow file.

S2 **`tools/release-scripts.sh`.** `prepare` requires at least one `lib/release-keys/*.asc`
(each must dearmor), removes `MANIFEST.asc`, lists the key files in MANIFEST like any tracked
file, and prints the signing command:
`gpg --armor --detach-sign --local-user <FPR>! --output MANIFEST.asc MANIFEST` (FPR = the
fingerprint of each key file, from `gpg --with-colons --import-options show-only --import` when
gpg exists, else "the key's fingerprint"). `--check` verifies `MANIFEST.asc` with the threshold
when present; `--require-sig` makes a missing or failing signature an error (CI and the tag
path). `rewrite_installer` embeds the concatenation of the key files (sorted by name) as the
`TN_RELEASE_KEYS` heredoc in install.sh (replacing `TN_ALLOWED_SIGNERS`); the installer's own
`lib/release-keys/*.asc` must hash to the MANIFEST lines after install. Keep the serial /
expires / min_updater logic as is. Help text updated.

S3 **`update-scripts.sh`.** `verify_manifest` → keyring from the installed
`lib/release-keys/*.asc`, verify `MANIFEST.asc`. Bootstrap when the host has no
`lib/release-keys/*.asc` and no installed MANIFEST (today's `bootstrap_signers` structure):
fetch MANIFEST (unverified) → read its `lib/release-keys/*.asc` lines → fetch each key file and
its `.sha256` sidecar from the tag → sidecar must match → build the keyring → fetch and verify
`MANIFEST.asc` → the fetched key files must hash to the MANIFEST lines → only then install.
`path_ok` excludes `MANIFEST.asc` (as it excludes `MANIFEST.sig` today). `--check` keeps its
shape and exit codes. The `SCRIPTS` array loses `lib/allowed_signers` (and the file and its
sidecar are deleted from the tree). An installed host that still has `lib/allowed_signers`
gets it removed by the updater's sweep if such a sweep exists; otherwise leave it and note it.
Dependency check: `gpgv` present (message names `apt install gpgv` / `brew install gnupg`).

S4 **`install.sh`.** `verify_release` uses the embedded `TN_RELEASE_KEYS` heredoc (written to
a temp dir as `*.asc` files, one per `-----BEGIN` block), builds the keyring, verifies
`MANIFEST.asc`, then installs and checks that the installed `lib/release-keys/*.asc` hash to the
MANIFEST lines (a release may add a key: the embedded set is the trust root, the tree's set is
checked against the signed MANIFEST). Dependency check `gpgv`. Header comment and the
`TN_SCRIPTS_TAG` flow unchanged.

S5 **`tools/cut-release.sh`** (new; maintainer tool, not updater-tracked, no sidecar; bash
3.2 clean; shellcheck clean; `set -euo pipefail`). Interactive, resumable from the state on
disk, every step prints the exact command, then asks `[Enter] run / s skip / q quit`
(`--yes` runs without asking, for the test). Subcommands:
- `prep TAG [--serial N] [--sig-from FILE] [--yes]`: `git fetch origin`; create or reuse
  `release/TAG` from `origin/main` (refuse a dirty tree); key check: `gpg --card-status`
  through the agent (skip with a warning when `--sig-from` is given) and the signing
  fingerprint (`git config user.signingkey`, else the one key in `lib/release-keys/`) must be
  the primary fingerprint of a file in `lib/release-keys/`; `bash tools/release-scripts.sh
  --serial N TAG` (prepare); sign: `gpg --armor --detach-sign --local-user <FPR>! --output
  MANIFEST.asc MANIFEST` through the forwarded agent, or copy `--sig-from FILE`, or (when gpg
  cannot reach a card) wait until `MANIFEST.asc` appears (the maintainer signs on another
  machine and copies it in); `bash tools/release-scripts.sh --check --require-sig`;
  `git add MANIFEST MANIFEST.asc RELEASE install.sh` and `git commit -S -F <msg>` (message
  "release: TAG"); `git push -u origin release/TAG`; `gh pr create --base main --head
  release/TAG --title "release: TAG" --body-file <generated body naming the serial, the
  key fingerprint and the tag>`.
- `tag TAG`: `git fetch origin`; `origin/main` must carry the release commit (MANIFEST and
  MANIFEST.asc identical to the release branch; `bash tools/release-scripts.sh --check
  --require-sig --tag TAG` against a clean checkout of `origin/main`, e.g. a temporary
  worktree); `git tag -s TAG origin/main -m TAG`; `git verify-tag TAG`; `git push origin TAG`;
  poll `gh run list --workflow ci.yml --branch TAG` and `--workflow publish-installer.yml`
  until they finish (print the conclusions); `curl -fsSL https://install.telcoin.network |
  grep -m1 TN_SCRIPTS_TAG` must name TAG.
- `status`: what exists for the newest `release/*` branch and tag (branch, commit, MANIFEST
  serial, signature verification, tag signature, CI runs).
- Never sets `commit.gpgsign` or `user.signingkey`; uses `-S` and `--local-user` explicitly.
  Every git/gh/gpg/curl call is through a small wrapper so the test can stub them on `PATH`.

S6 **CI and workflows.** ci.yml: the manifest grep becomes `MANIFEST|MANIFEST\.asc|RELEASE`;
comments at 4, 152-154, 225 say MANIFEST.asc and lib/release-keys; the runner installs nothing
new (ubuntu has gpgv; macOS job has gnupg); publish-installer.yml comment 5-6. `vm.d/P0-05.sh`
asserts `gpgv` instead of ssh-keygen. CODEOWNERS: `/lib/allowed_signers` → `/lib/release-keys/`,
`/MANIFEST.sig` → `/MANIFEST.asc` (keep the three owners). `tools/tests/ci_pins_test.sh` if it
names either path.

S7 **Tests.** `tools/tests/signing.sh` → GPG: `REAL_GPG=1` when `gpg` and `gpgv` can make and
verify an ed25519 key under a temporary `GNUPGHOME` (`--quick-gen-key`, `--pinentry-mode
loopback --passphrase ''`); helpers `newkey NAME [expiry|--expired|--revoked]` (prints the
fingerprint; writes `$TN_TEST_TMP/NAME.asc`), `sign_file FILE KEYNAME...` (appends one armored
detached signature per key to `FILE.asc`), `sign_file_bad` (a signature over other content).
Where gpg is absent: fake `gpg` and `gpgv` on `BIN` with the interfaces the scripts use
(`--armor --detach-sign`, `--with-colons --import-options show-only --import`, `--dearmor`
if the library path is exercised, `gpgv --status-fd 1 --keyring`), where a fake key file is an
armored-looking block whose body base64-encodes `FAKEKEY <fpr>` and a fake signature names
the fingerprint and the SHA-256 of the data; the fake gpgv prints real-shaped status lines
(`[GNUPG:] GOODSIG`, `VALIDSIG … <fpr>`, `BADSIG`, `EXPKEYSIG`, `REVKEYSIG`, `ERRSIG … 9`)
so the policy parser is tested in every environment. Port `release_scripts_test.sh`,
`updater_manifest_test.sh`, `install_test.sh`; cases: foreign key (ERRSIG 9 → refused as
NOSIG), missing `.asc`, tampered MANIFEST (BADSIG), expired key (EXPKEYSIG), revoked key
(REVKEYSIG), two signatures (count 2), threshold 2 with one signature refused, dearmor of a key
with armor headers (`Version:`, `Comment:`) and a CRC line, a key file that is not a key,
bootstrap on a bare host (key files fetched, sidecar mismatch refused, hash mismatch refused),
installer with the embedded keys, `--require-sig` without a signature. New
`cut_release_test.sh` drives `cut-release.sh prep --yes` and `tag` with stubbed `gh`, `gpg`,
`curl` and a bare "origin" repository on disk (real git, `git push` to the local bare remote;
`-S` replaced by a stubbed gpg that writes a fake signature via `gpg.program`), asserting the
step order (prepare before sign before check before commit before push before pr), the refusal
on a dirty tree, on a fingerprint not in `lib/release-keys/`, and the `tag` refusal when
`origin/main` lacks the release commit. All fixtures green under bash 5.3 (real gpg) and
`bash:3.2` + `ubuntu:24.04` (fakes). End-to-end on the host once, in a temp dir: throwaway key
→ `release-scripts.sh` prepare → sign → `--check --require-sig` → `install.sh` from a
`file://` stage → `update-scripts.sh --check`; record the commands in the checkpoint.

## Docs notes to produce (for DOCS-2; do not edit those files)

The integrity contract (MANIFEST + MANIFEST.asc + lib/release-keys; threshold; policy; what
`--check` and `--require-sig` do), the install dependency (`gpgv`), the OPERATOR §4.10 hand
check (the `gpgv --status-fd 1 --keyring` block), the maintainer release steps
(`cut-release.sh prep`/`tag`, the forwarded agent, the `--sig-from` fallback), the
`lib/release-keys/README` sentence (keys also sign script releases), and every README/OPERATOR/
AGENTS/CHANGELOG/partner-guide line that names `allowed_signers`, `MANIFEST.sig`, `ssh-keygen`,
`tn-node-scripts` or `release@telcoin.org` (grep and list them with the replacement wording).
