# Verifier V7: SIG + IMG (round 2)

Read `tasks/spec-r2-shared.md`, `tasks/spec-r2-SIG.md` and `tasks/spec-r2-IMG.md` first. You
verify against the SPECS, not the implementers' claims: write your harness before reading
`tasks/ckpt-r2-SIG.md` and `tasks/ckpt-r2-IMG.md`, then compare. Worktree
`~/coding/telcoin/tnd-r2-V7` on the integration tip; records in `tasks/verify-r2/V7/`
(committed by the orchestrator: every `*.sh` there has a shebang, passes shellcheck 0.9 and
0.11 `--severity=error`, `bash -n` under 5.3 and 3.2 and `tools/check-bash32.sh`); checkpoint
`tasks/ckpt-r2-V7.md`. Report `tasks/verify-r2/V7/REPORT.md`: ERROR (wrong or unsafe
behaviour, a fail-open path, a spec promise not kept), WARN (gap or regression risk), NOTE.
Each finding: the exact command that shows it, expected, actual, the file and function.

## SIG

1. Harness: a temporary GNUPGHOME, throwaway keys (valid, expired via `--faked-system-time`,
   revoked, a second valid key), a stage directory with MANIFEST/RELEASE/install.sh built by
   `tools/release-scripts.sh`, served over `file://` for `install.sh` and `update-scripts.sh`.
2. Policy mutants (each must be refused by all three verifiers, release-scripts `--check
   --require-sig`, update-scripts, install.sh): BADSIG (tampered MANIFEST), EXPKEYSIG, REVKEYSIG,
   a signature by a key not in `lib/release-keys/` alone (NOSIG), ERRSIG with a code other than
   9 (unsupported algorithm: craft via a fake gpgv or skip with a note), an empty `.asc`, a
   `.asc` holding one good and one bad signature, threshold 2 with one good signature.
3. Dearmor: a key file with `Version:`/`Comment:` headers and a CRC line; a file with two keys
   concatenated; a file that is not a key (refused); CRLF line endings; base64 without the
   CRC line. The resulting keyring verifies with real gpgv.
4. Bootstrap (update-scripts on a host without keys and without a MANIFEST): happy path; a key
   file whose sidecar mismatches (refused, nothing installed); a key file whose hash is not the
   MANIFEST line (refused); a MANIFEST.asc signed by a key that is not in the fetched set.
5. Installer: the embedded key set verifies; a tree whose `lib/release-keys/*.asc` differ from
   the MANIFEST lines is refused after download, before install; the installed tree has no
   `lib/allowed_signers`.
6. `cut-release.sh`: with stubbed `gh`, `gpg`, `curl` and a local bare origin: step order
   (prepare → sign → check → commit → push → pr), refusals (dirty tree, fingerprint not in
   `lib/release-keys/`, `tag` when origin/main lacks the release commit), resumability (kill
   after sign; rerun continues at check), `--sig-from`, and that it never sets `commit.gpgsign`
   or `user.signingkey` (inspect `git config` after a run).
7. CI: the manifest grep in ci.yml matches `MANIFEST.asc`; `vm.d/P0-05.sh` asserts gpgv; no
   `ssh-keygen`/`allowed_signers`/`MANIFEST.sig`/`tn-node-scripts` left in code, workflows,
   tests (list any).
8. Run the three fixture files and `cut_release_test.sh` in bash 5.3, `bash:3.2`, `ubuntu:24.04`;
   mutation count: for each policy branch, break it in a scratch copy and show which check fails.

## IMG

1. `tn_docker_repo_for`/`repos_for`/`repo_ok` per network; resolve_ref refusals across
   networks (`tn-testnet:vX.Y.Z-adiri` on mainnet; `tn-mainnet:vX.Y.Z` on testnet; the old
   ghcr name and the GAR name for a new pull; `-adiri` tag on mainnet; plain tag on testnet;
   `latest`; raw digest on mainnet without a recorded mainnet tag).
2. The release's `IMAGE_DIGEST` naming another package is refused on mainnet (fixture with a
   signed SHA256SUMS whose IMAGE_DIGEST says tn-testnet for a mainnet tag).
3. Storage floor: mainnet `v0.1.3 → v0.2.0` is not a migration and not a storage downgrade
   refusal; testnet `v0.15.x → v0.16.0` still is; devnet per the spec.
4. Feature check: stub docker printing canned `--version` outputs; mainnet image with `adiri`
   refused; without features accepted; testnet without `adiri` refused; `faucet` alone on
   testnet refused; two `Build Features:` lines refused; missing line refused; docker run
   failure refused (fail closed); order in setup-node and update-node (resolve → pull → check →
   start; no `.node-meta` write before the check): prove with a stub that records call order
   and a mutation that removes the check call (the fixture must fail).
5. `--json` paths: the refusal emits an error event then `done`, nothing else on stdout.
6. UI twins: `DOCKER_REPO` equals the library per network (the existing agreement test), the
   wizard offers the network's package, pytest green under 3.10 and 3.12.
7. remove-node's container scan recognises containers from all three testnet repositories and
   tn-mainnet.

Hand back: the report path, counts (checks run per environment, mutants caught/total), the
findings by severity, and the exact fixture files that need to change if any.
