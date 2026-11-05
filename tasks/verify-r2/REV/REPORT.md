# REV: whole-range review of 4a2cf6e..HEAD (PR #59 round 2)

Range reviewed: 4a2cf6e..a027e38 on `hardening-followups` (worktree tnd-r2-base), including the late
code commit ccc2b8a "setup-node: finalize --docker-image replaces the image keygen recorded".
Every non-`tasks/` file of the diff was read. The V7, V7-IMG and V8 findings lists were read
first, and nothing they already reported is repeated below.

Scratch evidence is under this directory:
- `head/tools/tests/rev_cut_test.sh` and `rev_cut.out`: cut-release scenarios A and B
- `nonl.sh`: a key file without a final newline
- `dearmor/t.sh`: dearmor edge cases
- `tmo/`: timeout semantics
- `base/` and `head/`: archive copies used for the shellcheck delta

No ERROR (no fail-open path in the node-facing verifiers). Findings are ranked most severe first.

---

## MEDIUM

### M1. `tools/cut-release.sh` `tag_release`: the tag can name a commit the check never saw
- **Scenario.** `tag TAG` checks `origin/main` by name in step 2 (`main_has_release`, three separate
  resolutions of `origin/main`, then `check_in_worktree origin/main`). It resolves `main_sha` after
  step 2 and tags the symbolic `origin/main` in step 3 (`_git tag -s ... "$tag" origin/main`).
  Between the step 2 and step 3 prompts (minutes when run interactively), anything that updates
  `refs/remotes/origin/main` moves the target: an editor's auto-fetch, or `git fetch` in another
  terminal. Step 3 then signs the new commit, step 4 only checks who signed the tag, and step 5
  pushes it.
- **Evidence.** Scenario B in `head/tools/tests/rev_cut_test.sh` (real git and a bare origin, through
  the fixture's fakes). A FIFO feeds the prompts. After `[3/7]` appears, a second clone pushes a
  commit that changes `setup-node.sh` to origin main and the work clone fetches.
  - `B: tag run exits 0` passes.
  - `B: the pushed tag names the commit step 2 checked` fails: expected f564eb6, got 27c2980.
  - `B: the release check on the pushed tag` fails: `release-scripts.sh --check --require-sig --tag`
    fails on the pushed tag.
  - Effect: a signed, pushed `scripts-v*` tag whose tree does not match its signed MANIFEST. CI and
    publish-installer refuse it, and updaters refuse it (hash mismatch). It fails closed, but the
    release number is burnt and a new release has to be cut.
- **Fix.** Resolve `main_sha="$(_git rev-parse origin/main)"` once, right after step 1. Pass that
  sha to `main_has_release`, `check_in_worktree` and `git show/rev-parse "$main_sha:..."`, and tag
  `"$main_sha"`, not `origin/main`.

### M2. `tools/cut-release.sh` `prep`: `--serial N` is ignored once the branch's MANIFEST names the tag
- **Scenario.** `prep TAG --serial 7` is stopped (q) after step 4. The maintainer runs `prep TAG
  --serial 1 --yes` again. Step 4 tests only `manifest_value release == TAG` and reports "already
  done". The serial-7 MANIFEST is then signed, committed and pushed, and the PR body says "serial 7".
  The same happens on any existing `release/TAG` branch (local or origin) that carries another
  serial.
- **Evidence.** Scenario A in `rev_cut_test.sh`:
  - `A: second run --serial 1 exits 0` passes.
  - `A: origin's release branch carries the serial asked for (1)` fails: got `serial=7`.
  - Code: `tools/cut-release.sh:378-381` (`done_step 4 "prepare" "MANIFEST names ${tag}"`).
- **Impact.** The plan pins `scripts-v2.1.0` to serial 1. A wrong, higher serial ships signed, and
  every later release has to pass it (serials cannot go back).
- **Fix.** In step 4, when `--serial` is given and differs from `manifest_value serial`, die with
  "MANIFEST on release/TAG has serial X, not N: remove the prepared files (git checkout --
  MANIFEST RELEASE install.sh; rm -f MANIFEST.asc) and run again". Better still, also compare
  the whole prepared MANIFEST with a fresh `release-scripts.sh` run.

### M3. `lib/common.sh` `tn_docker_image_network_ok`: the 60-second limit does not hold when the binary hangs
- **Scenario.** `tmo=(timeout 60)` (common.sh:8206) wraps `docker run --rm ...` (8208) with no `-k`.
  1. When the limit expires, `timeout` sends SIGTERM to the docker CLI.
  2. An attached `docker run` proxies signals to the container (`--sig-proxy` defaults to true) and
     keeps waiting.
  3. The container's PID 1 is `/usr/local/bin/telcoin`, and no `--init` is given. The kernel
     ignores SIGTERM for a PID 1 without a handler.
  4. GNU `timeout` without `-k` never escalates.

  So an image whose `--version` hangs, which is the case the limit exists for, still hangs setup,
  update-node and edit-config while they hold the update lock. If the daemon hangs, the same
  happens.
- **Evidence.**
  - The `tmo/` experiment: a child that catches TERM and keeps running. `timeout 2 child` was still
    running at 8 s, stopped only by an outer limit (rc 124 from the outer timeout). `timeout -k 1
    2 child` ended with rc 137 after 3 s.
  - In-repo precedent: remove-node.sh:1432 already uses `timeout -k 2 5 docker ps`.
  - Docs claim "60 seconds at most": the README setup steps and OPERATOR's Docker table say so.
- **Fix.**
  - Name the container (`--name tn-feature-check-$$`).
  - Use `timeout -k 10 60`, and on rc 124 or 137 run `docker rm -f` on that name.
  - Or add `--init`, so that SIGTERM reaches a process with default handling.

## LOW

### L1. `setup-node.sh` `finalize_docker_override` (ccc2b8a): a digest-alone override skips keygen's release lookup
- **Scenario.** Testnet, finalize `--docker-image ghcr.io/telcoin-association/tn-testnet@sha256:<d>`
  where `<d>` is the image of a release below `MIN_SOURCE_VERSION_TESTNET`.
  - Keygen's preflight for the same flag resolves the release from the registry
    (`tag="$(tn_docker_release_tag_for "$NETWORK" "$DOCKER_IMAGE")"`, setup-node.sh:994 and 1046).
    The floor check then refuses it (rc 1), and the found tag is recorded as `RELEASE_TAG`.
  - The override takes `tag` only from `tn_docker_resolve_ref`. For a new digest that is the
    `.node-meta` record, which names the old digest, so `tag` is empty.
  - `check_release_floor "${tag:-$img}"` (3195) then runs `tn_ref_min_check` on the digest
    string: rc 2, a warning only. The image is pulled, recorded and run, and `RELEASE_TAG` is
    removed. Later updates cannot apply the downgrade, storage or floor checks to it.
- **Evidence.** The code paths above, and `tn_ref_min_check`'s rc table (common.sh:2034-2037: "a
  digest" gives rc 2).
- **Impact.** The commit message's "through keygen's checks" does not hold for this input.
- **Fix.** In the override, when `tag` is empty, set
  `tag="$(tn_docker_release_tag_for "$NETWORK" "$img" 2>/dev/null)" || tag=""` before
  `check_release_floor`, as keygen does.

### L2. `setup-node.sh` `finalize_docker_override`: the `.node-meta` update is several separate rewrites
- **Scenario.** The override writes `.node-meta` in this order:
  1. `write_node_meta "DOCKER_IMAGE=..." "DOCKER_IMAGE_DIGEST=..."` (3208). That is one `meta_set`
     rewrite per key, then `meta_unset NODE_TYPE`.
  2. A separate `write_node_meta "RELEASE_TAG=..."` or `meta_unset RELEASE_TAG` (3210-3213).

  A failure in the second step (`setup_fail "Could not remove RELEASE_TAG ..."`), or a kill
  between the two steps (for example the UI job being cancelled), leaves the new
  `DOCKER_IMAGE_DIGEST` paired with the old `RELEASE_TAG`. From then on, `tn_docker_recorded_tag`
  and update-node's `docker_current_tag` report the old release for the new image. That release
  feeds the downgrade and storage-floor checks, and on mainnet it decides whether a digest given
  alone is accepted.
- **Fix.** Remove `RELEASE_TAG` first, then write the image keys, then write `RELEASE_TAG` last. An
  interrupted run then leaves "release unknown", never a wrong release. Alternatively, write all
  keys in one `_tn_meta_write`.

### L3. `setup-node.sh` finalize (ccc2b8a): on mainnet the advice in the new refusal messages always fails
- **Scenario.** A recorded mainnet image fails the pull rule or the feature check. The new message
  (3158, 3161) says "to replace it, run finalize again with --docker-image <repo>@sha256:<digest>
  (a mainnet image)". That run is refused every time:
  - `json_check_install_flags` accepts only a digest for `--docker-image`.
  - `tn_docker_resolve_ref` refuses a digest given alone on mainnet unless `.node-meta` records a
    mainnet tag for that digest. Only the old digest is recorded, and giving the old digest again
    is no override.
  - `--release-tag` at finalize is not used by the docker path.
- **Fix.** Either take `--release-tag` at finalize as the override for docker (resolve it through
  the signed release, and refuse giving both), or keep "run --phase=keygen again" in the message
  on mainnet.

### L4. `tools/release-scripts.sh` `keys_concat` / `check_keys`: a key file without a final newline breaks the installer, and the release gate passes it
- **Scenario.** `lib/release-keys` holds two keys, and the first by name has no trailing LF (an
  editor, or `printf '%s'`). `keys_concat` runs `cat` on each file, so install.sh's heredoc gets
  the line `-----END PGP PUBLIC KEY BLOCK----------BEGIN PGP PUBLIC KEY BLOCK-----`.
  - `--check` compares `embedded_keys` with `keys_concat` (equal) and dearmors each file on its
    own (fine), so it passes. The same holds for `--require-sig --tag` and so for CI and
    publish-installer.
  - The published install.sh splits the heredoc into one file with a broken block, refuses it,
    and stops with "This installer carries no readable release key" for every new install.
  - This is the same class as V7 W1, which was fixed only for CR. It bites with the second key
    of the 2-of-N hook (#40).
- **Evidence.** `nonl.sh`. Output: "release-scripts --check: embedded keys == key files ->
  passes", install.sh line 254 with the merged END/BEGIN, "per-file dearmor ...: ok", "installer
  dearmor: REFUSED: .../key-1.asc: public key block 1 is malformed", `bash -n install.sh` ok.
- **Fix.**
  - In `keys_concat`, add a newline after a file whose last byte is not LF:
    `cat "$f"; [ -z "$(tail -c 1 "$f")" ] || echo`.
  - Or have `check_keys` refuse such a file.
  - Best: have `--check` run the installer's own splitter and `tn_dearmor_keys` over
    `embedded_keys`, so any shape the installer cannot read fails the gate.

### L5. `setup-node.sh` `json_phase_finalize` (ccc2b8a): the override's side effects come before the remaining input checks
- **Scenario.** `finalize_install_inputs` runs the override first: it pulls the image and rewrites
  `.node-meta`. After that, `json_phase_finalize` checks the listener multiaddrs and runs
  `finalize_node_extra_flags`. A CLI finalize with a bad `--listener-primary` or a node flag the
  release does not know is refused after `.node-meta` has already changed. The helper refuses
  missing listeners first, so the UI path is not affected.
- **Impact.** The goal "a refusal leaves .node-meta byte-identical" holds only for the override's
  own refusals.
- **Fix.** Validate the listeners and extra flags before `finalize_install_inputs`, or run the
  override after them.

### L6. `tools/cut-release.sh`: the checks can be skipped and the side effects still run
- **Scenario.** The checks are ordinary steps with "s skip", wrapped in `|| true`: prep step 6
  (`--check --require-sig --tag`), and tag steps 2 (`main_has_release`) and 4 (the tag's signer).
  Skipping step 2 tags whatever `origin/main` is. Skipping step 6 commits and pushes an unchecked
  release. CI still gates afterwards, but the tag or branch is already pushed.
- **Fix.** For check steps, offer only run or quit (or treat s as q). Or keep skip, and make a
  skipped check stop before the next step that changes something.

## NOTE

- **N1. Docs.** The README/OPERATOR row for `--json --phase=keygen|finalize` says "finalize refuses
  flags that differ from what keygen recorded". That is no longer true for `--docker-image`
  (ccc2b8a removed `finalize_same_as_keygen docker-image`). The "60 seconds at most" claim is
  covered under M3. The OPERATOR hand check ("no ... ERRSIG line") is stricter than the scripts,
  which accept ERRSIG 9 with a warning. That is harmless, but worth one clause.
- **N2. `cut-release.sh` `main_has_release` prefers a stale local `release/TAG` over origin's.**
  When the branch was re-prepared elsewhere and merged, the local copy's MANIFEST/MANIFEST.asc blobs
  differ, and `tag` refuses although main is right. Check `refs/remotes/origin/release/TAG` first,
  or compare against the merged PR head.
- **N3. `cut-release.sh`: Ctrl-C leaves a stale worktree entry.** An INT or TERM during
  `check_in_worktree` runs `cleanup` (`rm -rf "$TMP"`), which leaves `.git/worktrees/worktree*`
  until `git worktree prune`. Harmless (git picks a new name), but `cleanup` could run
  `git worktree prune`.
- **N4. `setup-node.sh` `_preflight_docker`: typed text without a final newline is not used.** The
  new EOF stop also fires when the last input line has no newline (`printf 'v0.17.0-adiri' |
  setup-node.sh`): read returns 1 although it read the value, so setup stops instead of using it.
  Interactive only. `if ! read ... && [[ -z "$input" ]]` keeps the fix and takes the value.
- **N5. `update-scripts.sh` `install_pass` runs with errexit off.** It is called as
  `install_pass || exit 1`, so a failed `mv -f "${STAGE}/MANIFEST.asc" "$INSTALLED_SIG"` does not
  stop the following `mv` of MANIFEST. The record then has no matching signature, and the next
  `--check` says it does not verify. The shape predates this range (it was MANIFEST.sig). Guard
  both moves: `mv ... || { print_error ...; return 1; }`.
- **N6. shellcheck `--severity=warning` delta, base to head (gcc format, same file set).** Four new
  SC2034 warnings, all `read` placeholders:
  - `x` in the RELEASE SIGNATURES block, in install.sh, release-scripts.sh and update-scripts.sh;
  - `h` in update-scripts.sh `bootstrap_keys`.

  Everything else predates the range (SC2034, SC2206, SC2115, SC1083, SC2155, SC2258 in
  tests and helpers).

---

## Checked and found correct

- **RELEASE SIGNATURES block.**
  - The three copies are byte-identical (sha256 aafc9268...).
  - `tn_sig_verdict` counts distinct primary fingerprints. The last VALIDSIG field, so a signature
    by a subkey of the same primary counts once.
  - A NO_PUBKEY/ERRSIG 9 pair dedupes by key id.
  - The gpgv exit code is ignored, and stdout carries only status lines (stderr goes to a log).
  - Status keywords are not localized. The `[A-F]` ranges cannot admit anything gpgv prints.
- **Dearmor edge cases (`dearmor/t.sh`, gawk, mawk and busybox awk agree).**
  - Accepted: no final newline, armor headers, a header line of only whitespace as the separator,
    two blocks back to back without a blank line, no CRC line, CRLF, junk before BEGIN or after END.
  - Refused (fail closed, and the same in the release gate): BEGIN with trailing spaces, a CRC line
    with a trailing space, a body line with a trailing space.
  - `exit` inside the main rules still runs END with the right status. The `-d`/`-D` probe is sound.
- **Shell options.** All three scripts and cut-release set `set -euo pipefail`. No `printf big |
  grep -q` under pipefail in a production path: the ones that remain write small strings into the
  pipe buffer. The CI manifest step runs `bash -e` without pipefail, so its `git diff | grep -qxE`
  cannot SIGPIPE-fail.
- **update-scripts.**
  - Bootstrap order: unverified MANIFEST, keys by sidecar, verify, keys equal the verified lines,
    then install.
  - `path_ok` excludes MANIFEST.asc.
  - `--check` returns 2 on a forged newest release.
  - Old 2.0.0 updater message quoted in README ("Release scripts-v2.1.0 has no MANIFEST.sig;
    nothing was changed.") matches 4a2cf6e's code.
- **install.sh.** The splitter strips CR (V7 W1 fixed). The embedded keys are the trust root, and
  the tree's keys are checked against the signed MANIFEST.
- **cut-release.sh.**
  - It never prints key material or passphrases, and it never changes git config.
  - `--sig-from` is made absolute before the `cd`. EXIT/INT/TERM traps are set after TMP exists.
  - `gh pr create` failing after the push resumes cleanly (step 8 is reported done, step 9 is
    retried).
  - `served_tag` survives SIGPIPE under pipefail.
- **IMG.**
  - Every new-pull site adds `tn_docker_pull_repo_ok`: setup interactive and `--json`,
    `json_check_install_flags`, finalize, resolve_ref and fetch_release_image. The helper's
    `docker_image_ok` and the server's `docker_pull_repo_ok`/`pull_image_allowed` match.
  - The devnet lists agree in all three places: library, server `DOCKER_REPO`/`IMAGE_REPO`, and the
    helper docker-detect together with the remove-node scan, tn-dev included.
  - `tn_docker_resolve_ref` refuses the old package before any lookup.
  - The feature check runs after pull and digest check and before any pending, `.node-meta`,
    start-script or unit write, in setup, update (both paths pass `$net`), edit `--set`, the edit
    menu, finalize and the override.
  - JSON goes to fd 3 in all three scripts, so `_tn_c4_say ... >&2` cannot corrupt the stream.
  - The `9>&-` on docker run and docker pull keeps the lock fd out of the client.
- **Storage floor.** `storage_migration_floor` follows `_tn_guard_network`. Empty floors short-
  circuit both `storage_migrating_upgrade` and `update_downgrade_check`.
- **EPOCH.**
  - `tn_wait_restart_window` no longer reads margin/settle before the blind branch. No other use
    precedes it.
  - `_tn_epoch_timing ""` gives 300/90 "default". `tn_detect_network` failures, devnet among them,
    give "default".
  - The seventh argument appends with `${timing:+ ${timing}}`.
  - keytool_test and restart_window_test are green in a scratch copy.
- **Lints.**
  - `tools/check-bash32.sh $(git ls-files '*.sh')`: clean, 181 files.
  - `check-network-hits.sh`: clean, 147 annotated hits.
  - `check-perl-interp.sh`: clean.
  - `actionlint .github/workflows/*.yml`: clean.
  - setup_release_test and finalize_inputs_test: green at a027e38.
- **Docs spot-checks (10).**
  - Match the code:
    - the expired-key refusal text;
    - "Could not run <image> to read its build features (docker run exited <rc>) ...";
    - both "Image refused: ... Build Features" messages;
    - the old-package refusal;
    - the IMAGE_DIGEST refusal;
    - the blind-wait example sentence;
    - the 420 s cap figure;
    - update-scripts exit codes (0, 1, and 2 for an unknown argument);
    - the first-update bootstrap warning text;
    - the old 2.0.0 updater message.
  - Stale: the finalize "refuses flags that differ" row (N1) and "60 seconds at most" (M3).
