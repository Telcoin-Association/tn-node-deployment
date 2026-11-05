status: done

- [x] S1 Policy and dearmor, shared shape (670d361)
- [x] S2 tools/release-scripts.sh (c3f0de4)
- [x] S3 update-scripts.sh (0872054)
- [x] S4 install.sh (20a2fe7)
- [x] S5 tools/cut-release.sh (77b99a0; follow-up bb31565: null-safe gh --jq for a running workflow)
- [x] S6 CI and workflows (e23f4d3)
- [x] S7 Tests (3fa0904)

Fix round V7 (on top of 3fa0904):
- [x] F1 W1 + N1 (f7e1003): install.sh splitter strips CR; release-scripts check_keys refuses CR and,
      where gpg exists, a key file gpg reads no primary key from; fixtures in install_test and
      release_scripts_test (the install case fails against the splitter without the CR strip)
- [x] F2 W2 + W3 + N11 (e2981c4): --check against a newest release signed by another key (rc 2;
      fails with the newest-release verify_manifest removed); a junk .asc beside a good key; a
      MANIFEST listing MANIFEST.asc ("bad path: MANIFEST.asc")
- [x] F3 N6 + N7 + tag key (a73a2be): cut-release key check before the branch (keys of the branch to
      be: origin/main for a new one); step 7 one prompt; tag step 4 and status require a tag signature
      by a lib/release-keys key (git verify-tag --raw, VALIDSIG rule)

## Operator-visible changes

- Script releases are signed with OpenPGP: MANIFEST.asc (ASCII-armored detached signatures over
  MANIFEST, one block per signer) by the keys in lib/release-keys/*.asc (today grantkee.asc,
  4E36D35A4AB61B589861D01AC7173F2377CA7573), checked with gpgv. TN_SIG_THRESHOLD=1 distinct key.
- update-scripts.sh needs gpgv. Missing: "gpgv (GnuPG) is needed to verify script releases and is
  not installed; nothing was changed." + "Ubuntu/Debian: sudo apt-get install -y gpgv     macOS:
  brew install gnupg". Refusal: "The release manifest is not signed by a Telcoin release key
  (<reason>); nothing was changed." Reasons: "the signature by key <id> does not match MANIFEST:
  one of the two was changed" / "it is signed by release key <id>, which has expired" / "... which
  has been revoked" / "the signature by key <id> has expired" / "gpgv could not check the signature
  by key <id> (error <code>)" / "no release key in lib/release-keys made a good signature" / "good
  signatures by <n> release key(s), <threshold> needed". Success: "[OK] Release manifest signed by
  release key <FPR>[ <FPR>...]". Unknown co-signer (stderr): "a signature by key <id>, which is not
  a release key, was not checked". No MANIFEST.asc: "Release <tag> has no MANIFEST.asc; nothing was
  changed."
- Bootstrap (no lib/release-keys/*.asc and no installed MANIFEST): "[WARN] First signed release on
  this host: fetching the release keys through their published checksums (one time only)." Then per
  key: "<path> of release <tag> does not match its published checksum", "The published checksum for
  <path> in release <tag> is malformed", "No checksum is published for <path> in release <tag>",
  "The release key <path> fetched by checksum is not the one release <tag> lists" (all end
  "; nothing was changed.").
- Record but no key: "lib/release-keys holds no release key (*.asc), so no release can be verified;
  nothing was changed." + reinstall hint. A key file that does not decode: "The release keys in
  <dir> cannot be read, so no release can be verified; nothing was changed." A manifest that lists
  no key: "The release manifest is malformed (no release key (lib/release-keys/*.asc) listed)".
- Installed record: MANIFEST + MANIFEST.asc in ~/telcoin-node-scripts.
- install.sh needs curl or wget, tar, base64, gpgv and sha256sum/shasum (no ssh-keygen): "Need gpgv
  (GnuPG) to verify the release signature. Ubuntu/Debian: sudo apt-get install -y gpgv. macOS: brew
  install gnupg"; OK lines "tar, gpgv, base64 and a SHA-256 tool are available" and "Release
  signature verified (release key <FPR>)". Refusals: "The release <tag> has no MANIFEST.asc.",
  "The release signature does not verify against the Telcoin release keys (<reason>). Nothing was
  installed.", "MANIFEST does not list a release key (lib/release-keys/*.asc).", "This installer
  carries no readable release key, so it cannot verify anything. Use the published installer:
  https://install.telcoin.network". Embedded keys (TN_RELEASE_KEYS heredoc) are its trust root; a
  release may add a key (installed when it matches the signed MANIFEST).
- (V7) release-scripts.sh prepare and --check also refuse a key file with CR line endings
  ("release-scripts.sh: <file> has CR line endings: write it with LF line endings (as gpg --armor
  --export does)") and, where gpg is installed, one gpg reads no primary key from ("release-scripts.sh:
  gpg reads no primary key from <file>: export the key again with gpg --armor --export
  <fingerprint>"). install.sh reads an embedded key with CR line endings.
- (V7) cut-release.sh: the signing-key refusal now comes before release/TAG is made ("the signing key
  <FPR> is not a primary key of lib/release-keys/*.asc on origin/main: ..."); step 7 is one prompt
  (git add ... && git commit -S<FPR>! ...); tag step 4 requires a good tag signature by a key of
  lib/release-keys on origin/main ("<TAG> carries no good signature by a key of lib/release-keys/*.asc
  on origin/main"; "the signature of <TAG> is refused: gpg reports <KW>"; ok: "<TAG> is signed by
  release key <FPR>"); status prints "tag signature: <TAG> is signed by release key <FPR>".
- lib/allowed_signers and its sidecar are deleted from the tree and from SCRIPTS; a host that has
  the file keeps it (the updater only removes files an installed record lists), unused.

## Docs notes

V7 additions (N4, N5):
- Invariant for AGENTS.md: all three verifiers (update-scripts.sh, install.sh, tools/release-scripts.sh,
  and cut-release.sh for tags) take the verdict from the gpgv/gpg status lines (tn_sig_verdict; the
  VALIDSIG rule for tags), never from the exit status: gpgv 2.4.8 exits 0 on EXPKEYSIG and REVKEYSIG.
- Key expiry: the release key's primary (grantkee, 4E36D35A4AB61B589861D01AC7173F2377CA7573) expires
  2028-10-16. The extended key must ship in a script release that verifies against the installed copy
  (signed while the old expiry is still ahead) before that date; after it, gpgv reports EXPKEYSIG for
  every release signed with it, updaters refuse, and hosts re-run the installer.
- Key files must have LF line endings (prepare and --check refuse CR) and, where gpg is installed,
  must hold a primary key gpg reads; cut-release step 7 is one prompt; an existing tag passes `tag`
  only with a good signature by a lib/release-keys key.

Integrity contract (AGENTS.md "Self-update and integrity contract", README "How updates are
verified", OPERATOR):
- A release = the scripts-vX.Y.Z tag on a commit of main carrying MANIFEST and MANIFEST.asc; RELEASE
  on main names the tag. MANIFEST.asc = detached OpenPGP signatures over MANIFEST, made with
  `gpg --armor --detach-sign --local-user <FPR>! --output MANIFEST.asc MANIFEST`; a further signer
  appends with `--output - MANIFEST >> MANIFEST.asc`.
- Keys: lib/release-keys/*.asc, the same keys that sign telcoin-network releases. They are SCRIPTS
  rows (sidecars) and MANIFEST lines like any script, so a release that adds or removes a key must
  be signed by a key the host already has. install.sh embeds every key file (sorted by name) in its
  TN_RELEASE_KEYS heredoc: the installer's trust root.
- Policy (same as _tn_gpg_status_verdict for node releases): `gpgv --status-fd 1 --keyring <keyring
  from lib/release-keys/*.asc> MANIFEST.asc MANIFEST`; accepted when >= TN_SIG_THRESHOLD (1) distinct
  primary keys made GOODSIG+VALIDSIG (VALIDSIG's last field); refused on BADSIG, EXPKEYSIG,
  REVKEYSIG, EXPSIG, any ERRSIG but code 9; ERRSIG 9 / NO_PUBKEY (key not in lib/release-keys) is not
  checked, does not refuse, and is named in a warning. The keyring is built in shell (awk + base64:
  armor headers, CRC and END dropped), so updater and installer need only gpgv; the keyring is the
  allowlist (no separate allow file). The same RELEASE SIGNATURES block (constants TN_SIG_FILE,
  TN_SIG_THRESHOLD, TN_KEYS_DIR; tn_dearmor_keys, tn_sig_verdict, tn_verify_manifest, tn_sig_reason)
  is in update-scripts.sh, install.sh and tools/release-scripts.sh; release_scripts_test.sh checks
  the three copies match.
- Bootstrap: a host with no lib/release-keys/*.asc and no installed MANIFEST fetches the key files
  the (unverified) MANIFEST lists, each through its published .sha256 (must exist and match), verifies
  MANIFEST.asc with them, and requires their hashes to be the MANIFEST lines; then installs.
- `release-scripts.sh --check`: verifies MANIFEST.asc when present ("MANIFEST.asc verifies: signed by
  <FPR> (1 release key(s) needed)."; "FAIL MANIFEST.asc does not verify against lib/release-keys:
  <reason>"; "FAIL no MANIFEST.asc"; "WARN no MANIFEST.asc yet (unsigned release candidate)");
  `--require-sig` and `--tag` require a verifying one. Also fails when install.sh's embedded keys
  differ ("FAIL the release keys embedded in install.sh differ from lib/release-keys/*.asc") or a key
  file is not an armored key or not an updater array row. Prepare: needs >= 1 key file ("lib/
  release-keys holds no release key (*.asc): add the release signer public key first"), each an array
  row ("<f> is not in an updater array: add the row "<f>:<f>:NONE" to SCRIPTS in update-scripts.sh so
  it ships, then run bash tools/gen-checksums.sh"); removes MANIFEST.asc; prints the gpg command per
  key (fingerprint from `gpg --with-colons --import-options show-only --import`, a placeholder when
  gpg is missing), `bash tools/release-scripts.sh --check --require-sig --tag TAG`,
  `git commit -S -m "release: TAG"`, `git tag -s TAG <merge commit> -m TAG`. The file list is the
  three arrays + install.sh + open-ui.sh. Needs gpgv for a check, gpg only for the fingerprints.
- CI: "release manifest" job runs `--check --require-sig` when MANIFEST, MANIFEST.asc or RELEASE
  changed, `--check --tag` on scripts-v* tags; runners install nothing new.
Install dependency: gpgv (Ubuntu/Debian `sudo apt-get install -y gpgv`, preinstalled on Ubuntu as an
apt dependency; macOS `brew install gnupg`) and base64, not ssh-keygen.
OPERATOR §4.10 hand check, replacement block:
    tag=scripts-vX.Y.Z
    base=https://raw.githubusercontent.com/Telcoin-Association/tn-node-deployment/refs/tags/$tag
    curl --proto '=https' --tlsv1.2 -fsSL -O "$base/MANIFEST" -O "$base/MANIFEST.asc"
    for f in ~/telcoin-node-scripts/lib/release-keys/*.asc; do gpg --dearmor < "$f"; done > release-keys.gpg
    gpgv --status-fd 1 --keyring ./release-keys.gpg MANIFEST.asc MANIFEST
  gpgv must print `[GNUPG:] GOODSIG` then `[GNUPG:] VALIDSIG ...` ending in the primary fingerprint
  4E36D35A4AB61B589861D01AC7173F2377CA7573, and no BADSIG/EXPKEYSIG/REVKEYSIG/EXPSIG line (one key
  file per gpg --dearmor call; the keyring path needs a slash). Without an installed copy use the
  tag's lib/release-keys/*.asc and check `gpg --show-keys --with-fingerprint` against the README
  table of lib/release-keys and SECURITY.md of telcoin-network. The per-file sha256 check stays.
Maintainer release steps (AGENTS.md release section, README ~3400):
  `bash tools/cut-release.sh prep scripts-vX.Y.Z [--serial N] [--key FPR] [--sig-from FILE] [--yes]`
  (1 fetch, 2 release/TAG branch from origin/main, 3 key + `gpg --card-status`, 4 prepare, 5 sign,
  6 `--check --require-sig --tag`, 7 `git add MANIFEST MANIFEST.asc RELEASE install.sh` + commit
  `-S<FPR>!` "release: TAG", 8 `git push -u origin release/TAG`, 9 `gh pr create --base main --head
  release/TAG --title "release: TAG"`); after the merge `bash tools/cut-release.sh tag scripts-vX.Y.Z
  [--key FPR] [--yes]` (fetch; origin/main carries the release, checked in a temp worktree; `git tag
  -s --local-user=FPR! -m TAG TAG origin/main`; `git verify-tag`; `git push origin TAG`; waits for
  ci.yml and publish-installer.yml runs; curl install.telcoin.network must name TAG); `bash
  tools/cut-release.sh status`. Signing key: --key, else `git config user.signingkey`, else the one
  key in lib/release-keys; must be a primary key there. The YubiKey answers here or through a
  forwarded gpg-agent; when no card answers, step 5 prints the gpg command and waits for MANIFEST.asc
  to be copied in; `--sig-from FILE` copies a signature made elsewhere (card check skipped with a
  warning; the commit is still -S signed, so it needs the key too). Each step asks "[Enter] run / s
  skip / q quit"; reruns resume (done steps say "already done: ..."). Run it from a clean clone:
  untracked files count as uncommitted changes, as for release-scripts.sh prepare. Never changes git
  config. TN_CUT_POLL_SECONDS (30) and TN_CUT_POLL_TRIES (120) pace the waits.
lib/release-keys/README: new "Script releases" section (written here): the same keys sign script
releases; gpgv policy; threshold; a key change must be signed by a key the host has.
Migration: hosts on main's 2.0.0 updater (SSH flow, 1187ddb) stop with "Release scripts-v2.1.0 has no
MANIFEST.sig; nothing was changed." and must re-run the installer (`curl --proto '=https' --tlsv1.2
-fsSL https://install.telcoin.network | bash -s -- --yes`). Hosts on 1.1.72 or older take
update-scripts.sh 2.1.0 through its sidecar on main and then bootstrap the keys. lib/allowed_signers
left on hosts is unused and can be deleted.
Stale lines (DOCS-2): AGENTS.md 333, 344, 347, 349, 350, 357, 362, 375, 380, 394, 404, 411, 445, 446,
575, 652 (fixture fakes: now gpg/gpgv, signing.sh helpers newkey/sign_file/sign_file_bad, REAL_GPG,
TN_TEST_FAKE_GPG; add cut_release_test.sh). README.md 33 (drop lib/allowed_signers), 145, 330, 1022,
1028, 1065 (MANIFEST.asc: detached OpenPGP signatures by lib/release-keys), 1067, 1071-1072 (hand
check block), 1077, 1901, 1903, 1912, 1920 (bootstrap: key files through sidecars), 3400. OPERATOR.md
225, 226 (dependency), 538, 544, 567, 927 (old-updater path, see Migration), 969-982 (§4.10 hand
check). docs/partner/mno-node-guide/mno-node-guide.md 255 (dependency), 264, 648. CHANGELOG.md 107;
CHANGELOG/scripts-v2.0.0.md 294, 295, 305, 310, 595 (historical: DOCS-2 decides);
CHANGELOG/scripts-v2.1.0.md needs the switch entry. followup.md 22-27, 36, 40 (#40 2-of-N hook is
TN_SIG_THRESHOLD now). Not stale: `ssh-keygen -lf` in WGVPN.md, docs/testnet-addons.md, setup-vpn.sh,
lib/wgvpn/peers/ssh/KEYS, vpn_selfheal_test.sh (VPN key fingerprints, unrelated).

## Tests run

- Gates on every touched .sh: tools/check-bash32.sh, shellcheck 0.11 and 0.9 --severity=error -x,
  bash -n 5.3 and bash:3.2: clean. check-network-hits clean (146 hits annotated), check-perl-interp
  clean. Workflows parse as YAML.
- Per file, host bash 5.3 real gpg / host forced fakes (TN_TEST_FAKE_GPG=1) / bash:3.2 / ubuntu:24.04:
  release_scripts_test 147/0 skip, 147/0, 44+2 skip, 44+2 skip; updater_manifest_test 215/0,
  214+1 skip, 211+2 skip, 211+2 skip; install_test 109/0, 108+1, 108+1, 108+1;
  cut_release_test 68/0 (fakes always), SKIP in bash:3.2/ubuntu (no git).
- bash:3.2 with git added (apk, main .git mounted read-only): cut_release_test 68/0,
  release_scripts_test 146+1 skip, updater_manifest_test 214+1 skip (2.0.0 case runs).
- Full suite (bash tools/tests/run.sh, all 62 files): host bash 5.3 5404 checks 0 failures 54 skipped;
  bash:3.2 5191 checks 0 failures 60 skipped; ubuntu:24.04 5454 checks 0 failures 27 skipped.
- V7 fix round, the four fixtures (release_scripts / updater_manifest / install / cut_release):
  host real gpg 155/223/112/76, 0 failures, 0 skipped; host TN_TEST_FAKE_GPG=1 155/222+1/111+1/76;
  bash:3.2 46+2/219+2/111+1/SKIP; ubuntu:24.04 46+2/219+2/111+1/SKIP; bash:3.2 with git (apk, main
  .git read-only) 154+1/222+1/111+1/76. Mutants killed: install.sh splitter without the CR strip
  (2 failures), check_release without the newest-release verify_manifest (4 failures). Lints clean
  (check-bash32, shellcheck 0.11 and 0.9, bash -n 5.3 and 3.2, check-network-hits, check-perl-interp);
  the RELEASE SIGNATURES block is unchanged and identical in the three scripts; e2e rerun rc 0/0/0.
- End-to-end host run (SIG/e2e.sh in the scratchpad): throwaway ed25519 key in a temp GNUPGHOME ->
  `bash tools/release-scripts.sh --serial 1 --date 2026-11-04 scripts-v2.1.0` -> `gpg --armor
  --detach-sign --local-user <FPR>! --output MANIFEST.asc MANIFEST` -> `bash tools/release-scripts.sh
  --check --require-sig --tag scripts-v2.1.0` (rc 0) -> commit, tag, git archive into a local stage
  -> `HOME=<tmp> bash install.sh --yes` through a curl stand-in serving the stage (rc 0, 41 files,
  "Release signature verified (release key <FPR>)") -> `update-scripts.sh --check` (rc 0, "No
  update pending").

## Open issues

- Hosts running main's 2.0.0 updater (SSH flow) cannot verify an OpenPGP release; they refuse it
  cleanly ("has no MANIFEST.sig") and need the installer once (Docs notes: Migration). Tested in
  updater_manifest_test.
- Stale sidecars until the orchestrator runs tools/gen-checksums.sh at integration:
  update-scripts.sh.sha256 and lib/release-keys/README.sha256 (install.sh and tools/ have none);
  lib/allowed_signers.sha256 is deleted with its file. The "checksum freshness" CI job fails until
  then.
