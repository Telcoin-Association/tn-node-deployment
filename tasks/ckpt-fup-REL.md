status: done (follow-up round F1-F9 done)

# REL checkpoint (issue #40: manifest freshness and the release report)

Worktree ~/coding/telcoin/tnd-fup-REL, branch fup/REL, base ac9a605.

## Sections
- [x] S0 2.0.0 compatibility fact (what 1187ddb update-scripts.sh does with `expires=`)
  FACT: a 2.0.0 updater (update-scripts.sh at 1187ddb) ACCEPTS a manifest with `expires=` (and any
  other `[a-z]*=*` header line). parse_manifest has the arm `[a-z]*=*) ;;   # a header key a later
  release adds; covered by the signature`, so it ignores the line instead of refusing it.
  install.sh at 1187ddb has the same arm in verify_release. Proved twice: (1) the 1187ddb
  parse_manifest, cut from `git show 1187ddb:update-scripts.sh`, returns rc 0 with serial and
  paths parsed on manifests with no expires, `expires=2027-02-01` and `expires=garbage`, under
  bash 5.3 and bash:3.2; (2) updater_manifest_test.sh runs the whole 1187ddb updater against a
  signed release with date= and expires=: it installs, then hands over to the release copy.
  So `--expires` stays on by default (90 days), and nothing has to be released before 2.1.0.
  Also: the 2.0.0 release-scripts.sh --check drops every `^[a-z_]+=` line before it compares
  the file lines, so it tolerates the new keys too.
- [x] S1 tools/release-scripts.sh: --expires DAYS (default 90), date= + expires=, --check reports, --require-fresh  (da1318f)
- [x] S2 update-scripts.sh: parse_manifest strict date=/expires=; expired warning; --check rc 0/1/2  (8bf54f8)
- [x] S3 install.sh: parser takes date=/expires= at most once, strict; expired warning  (e01a881)
- [x] S4 check-node.sh: "script release" block (section 9.7)  (459f064, wording 316c8fb)
- [x] S5 tests: updater_manifest_test, release_scripts_test, install_test, check_node_unit_test  (7e4f9bd, 5835877)
- [x] S6 gates (all green, see Tests run)

Follow-up round (coordinator, after V4; integration cherry-picks 2c393a6..7924f26):
- [x] F1 macOS: with_headers without awk -v newlines; sweep the four tests + signing.sh for GNU-only constructs  (c0ecc60)
  Reproduced the 33 failures with original-awk (one-true-awk = BSD awk) in a local image tn-rel-awk:local; 0 after the fix. Only other change: sed -n -e per range. Sweep found nothing else.
- [x] F2 release-scripts --check: present-but-empty/malformed date=/expires= dies (rc 1)  (5a886d9)
- [x] F3 update-scripts --check: installed expiry warning before fetching newest; rc 2 wins; --help  (with F4, see git log)
- [x] F4 update-scripts --check: refused newest (lower serial, same serial different manifest) is rc 2; --help lists all cases
  Also rc 2: plan_changes refusal (a listed path is not a regular file here), since the updater refuses that too.
- [x] F5 ymd_days: ASCII-only digits in every locale (four identical copies)  (see git log)
  Reproduced on the host and in ubuntu en_US.UTF-8 ("10#: invalid integer constant", the call aborts); C/C.UTF-8 were already clean.
- [x] F6 release-scripts prepare: warn when expires is on or before today  (see git log)
- [x] F7 header line with whitespace before = (one-line change in each parser arm)  (see git log)
- [x] F8 docs notes corrections (Docs notes rewritten; fixture 9dd3591 for the self-update warning)
- [x] F9 gates (four tests x3 envs, bash -n x2, check-bash32, shellcheck x2, full suite, BSD awk/gawk/mawk)

Follow-up commits on fup/REL (after 5835877):
- c0ecc60 tests: the expiry fixtures run with BSD awk and sed (macOS)
- 5a886d9 tools/release-scripts: --check refuses an empty date= or expires= value
- 653858d tools/release-scripts: prepare warns when the release would expire on or before today
- acf1d3c update-scripts: --check reports the installed expiry first and a refused release as rc 2
- 356cdaa update-scripts, install.sh, check-node, tools/release-scripts: dates take ASCII digits only
- a5cdcdd update-scripts, install.sh: a manifest header key with a blank in it is malformed
- 9dd3591 tests: an expired release that ships a new updater warns once, from the release copy
- 264928a tests: release_scripts_test notes why its locale check single-quotes the program

Commits on fup/REL (on top of ac9a605):
- da1318f tools/release-scripts: a release is dated and expires, and --check reports it
- 8bf54f8 update-scripts: expired releases warn, and --check reports the release state
- e01a881 install.sh: an expired release installs with a warning
- 459f064 check-node: report the installed script release and its expiry
- 7e4f9bd tests: release dates, expiry warnings and update-scripts.sh --check
- 316c8fb check-node: a release record without release= or serial= says which lines it lacks
- 5835877 tests: release_scripts_test starts from a tree with no release and no signer key

## Operator-visible changes
- MANIFEST gets two optional header keys after min_updater=: `date=YYYY-MM-DD` (the release
  date, the same one RELEASE carries) and `expires=YYYY-MM-DD`. A manifest without them (the
  2.0.0 release) is still accepted everywhere.
- update-scripts.sh: when the verified release has expired, every update run warns and goes on
  to install as usual. New `--check` (read-only, no root, no prompt, no banner) with exit 0/1/2.
- install.sh: the same warning just before it installs an expired release.
- check-node.sh: a new "Checking the script release..." block, after the public RPC block and
  before the summary. It only warns and never counts a health issue.
- tools/release-scripts.sh (maintainer): `--expires DAYS`, `--require-fresh`, and --check
  prints the release date and expiry.

## Docs notes
(exact facts for DOCS: README, OPERATOR.md "4.10 Verifying a release by hand", AGENTS.md
"Self-update and integrity contract", partner guide, CHANGELOG/scripts-v2.1.0.md)
- MANIFEST header (AGENTS.md says "format=1, release=, serial=, min_updater="; it is now):
  `format=1`, `release=<tag>`, `serial=<n>`, `min_updater=<version>`, `date=YYYY-MM-DD`,
  `expires=YYYY-MM-DD`, then the `sha256  <hash>  <path>` lines. date= and expires= are
  optional, may each appear at most once, and must be real calendar dates in exactly
  YYYY-MM-DD form with the ASCII digits 0-9 (in every locale). A present-but-empty value is
  malformed. A header key with a blank in it ("expires =...") makes the manifest malformed
  in the updater ("bad line: ...") and the installer ("MANIFEST line is malformed: ..."). Otherwise the updater refuses the whole manifest ("The release manifest is
  malformed (expires 2027-02-30); nothing was changed." / "(date and expires may each appear
  once at most)"), and the installer refuses the release ("MANIFEST expires=2027-02-30 is not a
  calendar date YYYY-MM-DD." / "MANIFEST repeats expires=."). Updaters and installers of
  2.0.0 ignore both keys (unknown header keys are ignored), so no release ordering is needed.
- Meaning of the expiry: a release has expired from the day expires= names onwards (UTC). On
  that day it reports "expired ... today". Expiry is a reminder that a newer signed release is
  due, not a revocation: nothing refuses an expired release.
- tools/release-scripts.sh:
  `bash tools/release-scripts.sh [--serial N] [--min-updater X.Y.Z] [--date YYYY-MM-DD] [--expires DAYS] TAG`
  `bash tools/release-scripts.sh --check [--tag TAG] [--require-sig] [--require-fresh]`
  - `--date` (default today, UTC) is now written to MANIFEST as date= as well as to RELEASE.
    It must be a real calendar date ("date must be a calendar date like 2026-10-15, got: X").
  - `--expires DAYS`: default 90, accepted 1 to 3650 ("--expires takes a number of days from
    1 to 3650, got: X"). expires = date + DAYS.
  - Prepare prints "Release date <date>; the release expires <expires> (<DAYS> days later)."
  - --check prints "Release date <date>." and either "Release <tag> expires <expires> (in N
    days)." / "(in 1 day)", or "MANIFEST has no expires= line: <tag> does not expire.", or
    on stderr "WARN release <tag> expired on <expires> (N days ago|today): a newer signed
    release is overdue". It exits 0 in that case.
  - `--require-fresh`: an expired release fails the check, rc 1, with "FAIL release <tag>
    expired on <expires> (...): cut a newer release". Without MANIFEST it fails like --tag
    ("release-scripts.sh: no MANIFEST in the tree"). CI does not pass it.
  - --check also fails on "FAIL RELEASE is dated X, MANIFEST date=Y", on "FAIL MANIFEST
    expires=X is not after date=Y", and on a repeated, malformed or present-but-empty
    date=/expires= (die, rc 1: "release-scripts.sh: MANIFEST: expires= is not a calendar
    date YYYY-MM-DD"), the same lines the updater and installer refuse. A header key with
    a blank before = ("expires =...") is not a header to --check, so the file-line diff
    fails.
  - The check that expires= is after date= exists only in release-scripts --check. The
    updater and the installer accept a signed manifest whose expires= is on or before its
    date=: it is simply expired from the start.
  - Prepare warns, on stderr, with rc still 0, when the computed expiry is on or before
    today (UTC), for example with --date 2020-01-01: "release-scripts.sh: WARN <tag> expires
    <date>, on or before today (<today>): every updater, installer and check-node will
    report it as expired. Prepare it again with a later --date or a longer --expires before
    signing."
  - Unchanged: without MANIFEST, plain --check prints "No MANIFEST in the tree: nothing to
    check." and exits 0.
- update-scripts.sh, update run, expired release (printed after the plan is made, before the
  file downloads and the prompt):
  `[WARN] Script release <tag> expired on <date>; a newer signed release is overdue. Installing it anyway.`
  (without " Installing it anyway." when every file is already current), followed by
  `-> The release still verifies. If no newer one appears soon, tell support@telcoin.org.`
  The run continues and installs. When the release ships a new update-scripts.sh, the
  running updater first downloads and verifies every changed file, then runs the release's
  copy. That copy prints the warning once, after the files are verified and before its
  prompt; the running copy prints nothing about the expiry.
- `bash ~/telcoin-node-scripts/update-scripts.sh --check` (no root, installs nothing, asks
  nothing, no screen clear or banner; downloads into a temp dir under $TMPDIR, removed on
  exit). The updater has no JSON mode, so the report is plain lines. Lines:
  - `-> Installed:  <tag>, serial <n>, released <date>, expires <date> (signature verified)`.
    Without date=: "release date not recorded". Without expires=: "no expiry date". The
    installed record (MANIFEST + MANIFEST.sig beside the scripts) is verified against
    lib/allowed_signers.
  - `[WARN] No signed release is installed in <dir> (no MANIFEST record).` (then rc 2, after the
    Newest line and `-> To install it: bash <dir>/update-scripts.sh`)
  - `-> Newest:     <tag>, serial <n>, released <date>, expires <date> (signature verified)`
    (RELEASE on main, the tag's MANIFEST and MANIFEST.sig, verified against lib/allowed_signers)
  - `[WARN] Update pending: N file(s) to update, M to remove. Run: bash <dir>/update-scripts.sh`
    or `[OK] No update pending: every file matches <tag>.` Another rc 1 case is "Update
    pending: every file already matches <tag>, but the record names <old tag>. Run: ...".
  - A newest release the updater would refuse is rc 2 (ERROR):
    "RELEASE names <tag> (serial a), older than the installed release (serial b): the
    updater refuses it." + "A release pointer that goes back can mean tampering: tell
    support@telcoin.org."; "Release <tag> reuses the installed serial n with a different
    manifest: the updater refuses it." + "Two manifests with one serial can mean tampering:
    tell support@telcoin.org."; "<path> is not a regular file; nothing was changed." (a
    listed file that is a directory or similar in the tree).
  - `[WARN] Installed release <tag> expired on <date> (N days ago|1 day ago|today); a newer signed release is overdue.`
    It is printed right after the Installed line, before anything is downloaded, so it
    also appears when the newest release cannot be fetched.
  - `[WARN] Newest release <tag> expired on <date> (...); a newer signed release is overdue.`
    (only when the newest is not the installed one)
  - On success: `[OK] Up to date with <tag>; it expires <date> (in N days).` or `...; it
    carries no expiry date.`
  - Exit status with --check (as `--help` lists it):
    0 = the installed release is the newest and neither has expired.
    1 = an update is pending, or the installed or the newest release has expired.
    2 = no signed release is installed; the installed release record does not verify
    (missing lib/allowed_signers or MANIFEST.sig, a bad signature, a malformed record);
    the newest release cannot be fetched or verified (no RELEASE, a network error, a
    manifest for another tag than RELEASE names, a bad signature, a malformed manifest);
    or the updater would refuse it (a lower serial than the installed one, the installed
    serial with a different manifest, a listed file that is not a regular file here).
    When a 2 case and a 1 case both hold, the exit status is 2; the installed expiry
    warning is printed in every case. An unknown argument is 2 as before.
- install.sh: just before "Installing to ...", for an expired release:
  `[WARN] Script release <tag> expired on <date>; a newer signed release is overdue. Installing it anyway.`
  plus `-> The release still verifies. If no newer one appears soon, tell support@telcoin.org.`
- check-node.sh, new block (section 9.7, after "public RPC", before the summary):
  `>>> Checking the script release...`
  - `-> Scripts release: <tag> (serial <n>), released <date>, <N days ago|1 day ago|today>`
    (for a 2.0.0 record: `..., release date not recorded`)
  - `[OK] Scripts release expires <date> (in N days)`, or `->   The release carries no
    expiry date.`
  - expired: `[WARN] Scripts release <tag> expired N days ago (on <date>): a newer signed
    release is overdue.` (or "expired today") + `->   Check for it: bash <dir>/update-scripts.sh --check`
  - no record: `[WARN] No signed release installed: <dir> has no MANIFEST record.` +
    `->   Bring the scripts to the latest signed release: bash <dir>/update-scripts.sh`
  - other: `[WARN] The release record <dir>/MANIFEST lacks a valid release= or serial= line.`,
    `[WARN] The release record has an unreadable expiry date: expires=<value>`
  It reads the record only (no signature check, no network) and never adds to the issue
  count.
- 2-of-N signatures (#40) are deferred until two signer keys exist.

## Tests run
All at the branch tip (5835877; check-node wording 316c8fb included):
- bash 5.3.9 (host): updater_manifest_test 159 checks 0 fail 0 skip; release_scripts_test 78/0/0;
  install_test 79/0/0; check_node_unit_test 58/0/0; check_node_hardening_test 22/0/2.
- bash:3.2 (busybox, fake ssh-keygen, no git): updater_manifest 155/0/2 skip (real ssh-keygen; the
  2.0.0-updater case needs git); release_scripts 6/0/1 (the date arithmetic checks run; the
  rest SKIP without git, as before); install 78/0/1; check_node_unit 58/0/0.
- ubuntu:24.04 (root, GNU tools, no git/ssh-keygen): same counts as bash:3.2 (155/2, 6/1, 78/1, 58/0).
- Baseline at ac9a605 (bash 5.3): 89 / 38 / 47 / 37 checks.
- `bash -n` under bash 5.3 and `bash:3.2` on all 8 touched files: clean.
- `bash tools/check-bash32.sh` on the 8 files: clean.
- `shellcheck -x --severity=error` host 0.11.0 and koalaman/shellcheck:v0.9.0 on the 8 files: clean.
  Advisory-level warning counts unchanged against ac9a605 (one SC2034 in the new unit block was
  silenced with a reason).
- `bash tools/tests/run.sh tools/tests/root_write_pipe_test.sh tools/tests/passphrase_print_test.sh`: 2 files, 0 failed.
- `git ls-files -z '*.sh' | xargs -0 bash tools/check-perl-interp.sh`: rc 0.
- `bash tools/release-scripts.sh --check` on a tree without MANIFEST: "No MANIFEST in the tree:
  nothing to check." rc 0. That is byte-identical to the 1187ddb tool. `--require-sig`: rc 1,
  same message as main.
- Full suite `bash tools/tests/run.sh` (bash 5.3): 60 test file(s), 0 failed (run twice, the
  second at the tip).
- Date helpers: ymd_days and days_ymd agree with GNU date on 12 reference dates (1970 to
  9999), refuse impossible and malformed dates, and round-trip over 1970-2298 (in the test).
  They matched Python datetime on 2942 sampled days up to 9999-12-31 (by hand, scratchpad).
- Simulated main after scripts-v2.0.0 (an independent clone with a signer key, MANIFEST,
  MANIFEST.sig and RELEASE, and a tagged install.sh): the new release_scripts_test passes
  78/0. The ac9a605 version fails ("no key yet", first release, prepare).

### Follow-up round (tip 264928a)
- bash 5.3 (host): updater_manifest 178/0/0, release_scripts 92/0/0, install 83/0/0,
  check_node_unit 58/0/0.
- bash:3.2 (busybox awk/sed/date): 174/0/2, 10/0/1, 82/0/1, 58/0/0.
- ubuntu:24.04 (root, mawk): 174/0/2, 10/0/1, 82/0/1, 58/0/0.
- Local image tn-rel-awk:local (ubuntu:24.04 + original-awk, gawk, git, openssh-client,
  en_US.UTF-8). The worktree and the main .git are mounted, the .git read-only. awk is
  switched by PATH. With BSD awk (original-awk, the one-true-awk that macOS ships), gawk
  and mawk alike: 178/0/0, 92/0/0, 83/0/0, 58/0/0, with no SKIP (real ssh-keygen and the
  2.0.0-updater case run). Before the with_headers fix, BSD awk gave updater_manifest
  155 checks, 33 failures: the macOS CI count exactly.
- `bash -n` (5.3 and bash:3.2), check-bash32, and shellcheck --severity=error (0.11, v0.9.0)
  are clean on the 8 files. Advisory counts equal ac9a605 on all 8.
- root_write_pipe + passphrase_print: 0 failed. perl lint: rc 0. `release-scripts.sh
  --check` without MANIFEST: unchanged (rc 0).
- Full suite bash 5.3 at 264928a: 60 test file(s), 0 failed.

## Open issues
- None blocking.
- Found in passing (pre-existing, not changed): parse_manifest and check_serial in
  update-scripts.sh check `serial` with `[1-9][0-9]{0,8}`, then do `10#` arithmetic. In a
  UTF-8 locale, a serial written in full-width digits would stop the updater with an
  arithmetic error rather than a "malformed" message. It only applies to a signed manifest
  or a hand-edited installed record, and it fails closed (nothing is installed). The same
  holds for `--expires DAYS` in release-scripts (maintainer input). Left alone because the
  item named only ymd_days.
- Spec vs code: (a) MANIFEST had no release date, so the spec's "date from the installed
  MANIFEST" / check-node "release date, age in days" could not be met. Added `date=` (written
  by release-scripts from --date, the same date as RELEASE). (b) unknown header keys do not
  fall to the hash-line parser: the explicit `[a-z]*=*) ;;` arm ignores them (updater and
  installer). (c) The updater has no JSON mode, so --check prints plain lines. (d) rc 1 also
  covers "update pending" (not only "expired"): the spec's rc 0 means "fresh and current".
- DOCS: AGENTS.md "Self-update and integrity contract" lists the MANIFEST keys and the
  release-scripts flags. It needs date=/expires=, --expires, --require-fresh and
  update-scripts.sh --check (text above).
- Orchestrator: update-scripts.sh, install.sh and check-node.sh are updater-tracked and changed,
  so release prep bumps their versions and sidecars (not done here, by the rules).
