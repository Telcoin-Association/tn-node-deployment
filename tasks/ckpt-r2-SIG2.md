status: done

Base: r2/SIG2 at f9e22fb. Seven commits, no trailers, explicit paths, nothing pushed.

- [x] M1 cut-release tag: resolve origin/main once after the fetch; check, tag, push that sha (e69c9f3)
- [x] M2 cut-release prep: compare serial= with --serial N (174e109)
- [x] L6 cut-release: check steps cannot be skipped (1705b01)
- [x] N2 cut-release main_has_release compares with origin/release/TAG first (822ba33)
- [x] N3 cut-release removes its temporary worktree on exit, Ctrl-C and TERM (58e5688)
- [x] L4 release-scripts keys_concat adds a missing final newline; check_keys refuses one (76714d2)
- [x] N5 update-scripts install pass: every move and removal checked (feddc7f)
- [x] Lints + four fixtures in five environments

## Operator-visible changes

- cut-release.sh tag: after step 1 it prints "origin/main is <sha>: steps 2 to 5 check, tag and push
  this commit". Step 2 checks that commit, step 3 shows and runs `git tag -s --local-user=<FPR>! -m TAG
  TAG <sha>` and refuses (exit 1, nothing tagged) when origin/main moved: "origin/main moved from <sha>
  to <sha> since step 1: nothing was tagged. Run again: it checks the new origin/main before it tags
  anything." Step 4 checks the signer against lib/release-keys at that commit ("... on origin/main
  <short>"). Step 5 pushes only a tag that names that commit ("<TAG> does not name <sha>, the commit
  step 2 checked: nothing was pushed"). No origin/main: "there is no origin/main here: run again and let
  step 1 fetch origin".
- cut-release.sh prep --serial N on a release/TAG whose MANIFEST already names TAG with serial X != N:
  exit 1 at step 4, before any signing, with
    cut-release.sh: MANIFEST on release/TAG was prepared with serial X, not N (--serial): this run signed, committed and pushed nothing
      to go on with serial X, run again with --serial X
      to prepare serial N instead, delete the release branch, then run again with --serial N:
        rm -f MANIFEST MANIFEST.asc RELEASE && git checkout -f main && git branch -D release/TAG
        git push origin --delete release/TAG   (origin has it too; close its pull request if one is open)
  (last line only when origin has the branch). Without --serial the prepared serial is kept. "already
  done" now reads "MANIFEST names TAG (serial X)".
- cut-release.sh checks (prep step 6, tag steps 2 and 4) prompt "[Enter] run / q quit"; s is refused with
  "a check cannot be skipped: the steps after it act on what it checks (Enter runs it, q quits)" and the
  question is asked again. Other steps keep "[Enter] run / s skip / q quit".
- cut-release.sh tag step 2 compares MANIFEST and MANIFEST.asc with origin/release/TAG (as fetched), the
  local release/TAG only when origin has none.
- cut-release.sh removes its temporary worktree (git worktree remove --force, git worktree prune) on every
  exit, including Ctrl-C and TERM.
- release-scripts.sh prepare and --check refuse a key file whose last byte is not a newline:
  "release-scripts.sh: <file> does not end with a newline: export the key again with gpg --armor --export
  <fingerprint> > <file> (install.sh embeds the key files one after the other)". keys_concat (the
  TN_RELEASE_KEYS text) ends such a file before the next begins.
- update-scripts.sh: a failed move or removal in the install pass stops the run (exit 1) before the record
  is written: "Could not install MANIFEST.asc. The release record was not updated: run the updater
  again." / "Could not install MANIFEST, so the release record does not match MANIFEST.asc: run the
  updater again." / "Could not remove <path>. The release record was not updated: run the updater
  again." The next run records the release ("Every file already matches <tag>; recorded it as the
  installed release."). The "every file already matches" path uses the same checked moves.

## Docs notes

One sentence per behaviour change, for the AGENTS release steps:
- M1: `cut-release.sh tag` resolves origin/main to a commit once, right after the fetch, prints it
  ("origin/main is <sha>: steps 2 to 5 check, tag and push this commit"), and checks, tags
  (`git tag -s --local-user=<FPR>! -m TAG TAG <sha>`) and pushes that commit; step 3 refuses with exit 1
  and tags nothing when origin/main has moved since step 1 (run again to check the new commit).
- M2: `cut-release.sh prep TAG --serial N` refuses at step 4 when release/TAG already holds a MANIFEST for
  TAG with another serial, naming both; go on with `--serial <prepared>`, or start again with
  `rm -f MANIFEST MANIFEST.asc RELEASE && git checkout -f main && git branch -D release/TAG` (and
  `git push origin --delete release/TAG` when it was pushed).
- L6: the three checks (prep step 6 `--check --require-sig --tag`, tag step 2 origin/main carries the
  release, tag step 4 the tag signature) ask `[Enter] run / q quit` and cannot be skipped; every other
  step still offers `s skip`.
- N2: tag step 2 compares main's MANIFEST and MANIFEST.asc with origin's release/TAG as fetched, and with
  the local release/TAG only when origin has none, so a stale local branch no longer refuses.
- N3: an interrupted cut-release.sh (Ctrl-C, TERM) removes its temporary worktree and its .git/worktrees
  entry.
- L4: key files in lib/release-keys must end with a newline (as `gpg --armor --export` writes them);
  prepare and `--check` refuse one that does not.
- N5: update-scripts.sh records a release only after every file move and removal succeeded; a failed move
  of MANIFEST.asc or MANIFEST stops it with the old record kept, and the next run records the release.
Stale lines (DOCS-2):
- AGENTS.md 484: "Every step prints its command and asks `[Enter] run / s skip / q quit`" -> add that the
  checks (prep 6, tag 2 and 4) ask `[Enter] run / q quit` and refuse s.
- AGENTS.md 490-503 (prep): add the step 4 serial refusal and its redo commands.
- AGENTS.md 525-534 (tag): "checks that `origin/main` carries the release ... the release branch's when
  that branch is still there ... temporary worktree of `origin/main`); makes the signed tag (`git tag -s
  --local-user=<FPR>! -m TAG TAG origin/main`)" -> the commit origin/main names after the fetch (printed),
  compared with origin's release/TAG (the local one only when origin has none), tagged as `... TAG TAG
  <sha>`, refused when origin/main moved; "a key of lib/release-keys/*.asc on origin/main" -> at that
  commit (the message reads "on origin/main <short sha>").
- AGENTS.md 407-412 (key files): add the final-newline rule and message next to the CR rule.
- CHANGELOG/scripts-v2.1.0.md 240-242: "Key files must use LF line endings: release-scripts.sh refuses a
  key file with CR, and one gpg reads no primary key from" -> add "or one without a final newline".
- README/OPERATOR: no line names these behaviours (grep for "s skip", "cut-release.sh tag", "final
  newline" found none outside AGENTS.md and the CHANGELOG).

## Tests run

- Lints on the nine owned files (tools/cut-release.sh, tools/release-scripts.sh, update-scripts.sh,
  install.sh, tools/tests/{cut_release,release_scripts,updater_manifest,install}_test.sh,
  tools/tests/signing.sh): tools/check-bash32.sh clean (9 files); shellcheck 0.11 (host) and
  koalaman/shellcheck:v0.9.0 `-x --severity=error` clean; `bash -n` under 5.3 and bash:3.2 clean;
  tools/check-network-hits.sh clean (147 annotated hits); tools/check-perl-interp.sh clean (181 files).
- Four fixtures (release_scripts / updater_manifest / install / cut_release), checks/failures/skipped:
  - host bash 5.3, real gpg: 167/0/0, 233/0/0, 112/0/0, 119/0/0
  - host bash 5.3, TN_TEST_FAKE_GPG=1: 167/0/0, 232/0/1, 111/0/1, 119/0/0
  - bash:3.2 (worktree mounted at /w by absolute path): 47/0/2, 229/0/2, 111/0/1, 0/0/1 (no git: SKIP)
  - ubuntu:24.04: 47/0/2, 229/0/2, 111/0/1, 0/0/1 (no git: SKIP)
  - bash:3.2 + git (apk; worktree and main .git read-only at their absolute paths; safe.directory via
    GIT_CONFIG_* env only): 166/0/1, 232/0/1, 111/0/1, 119/0/0
  Baseline before the round (host real gpg): 155, 223, 112, 76.
- cut_release_test run 3 more times on the host (FIFO and TERM cases): 119/0 each time.
- Mutants (new fixture against the code before each fix): M1 old cut-release tags and pushes the moved
  commit (22 failures, cascading from the pushed tag); M2 serial 7 signed, committed, pushed (10+
  failures); L6 skip at each check goes on (8); N2 stale local branch refuses (8+); N3 worktree and
  .git/worktrees entry left (2); L4 old release-scripts (4), keys_concat fix without the check_keys
  refusal (3); N5 old updater records R2 MANIFEST with R1 MANIFEST.asc and never repairs it (6).

## Open issues

- update-scripts.sh changed, so update-scripts.sh.sha256 is stale until the orchestrator runs
  tools/gen-checksums.sh at integration (tools/ and install.sh have no sidecars).
- When release-scripts.sh is killed during a verify (seen in the N3 fixture), the RELEASE SIGNATURES block
  leaves its temp files (tn-gpgv.*, tn-release-keys.*) in TMPDIR: the block has no trap, and it must stay
  byte-identical in three scripts. Pre-existing; a trap in release-scripts.sh's main (outside the block)
  would remove them. Not done here.
- L4: the reviewer's stronger option (have --check run the installer's own splitter and dearmor over the
  embedded keys) is not done; check_keys plus keys_concat close the known case.
