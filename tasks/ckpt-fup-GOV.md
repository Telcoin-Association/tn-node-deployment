status: done

## Sections
- [x] 1. .github/workflows/ci.yml: drop the two dead fallbacks, add install_ui_test.sh + open_ui_test.sh (UI job bash 5, macOS job 3.2), add "network hits" step to hardening-lint -- commit c6ba9b8
- [x] 2. .github/workflows/publish-installer.yml: drop the .nojekyll touch and its comment -- commit 8d80f88
- [x] 3. .github/CODEOWNERS: line 1 wording, `# second owner: TODO` line -- commit 16b21ba
- [x] 4. tools/tests/ci_pins_test.sh: display names once each, network-hits step, UI shell tests in both jobs, no fallbacks, no .nojekyll -- commit 0647957 (49 checks; 9 fail on the 3b760cc workflows; 9 mutations behave)
- [x] 5. ui/requirements.txt + ui/tests/requirements-dev.txt comment lines: pytest>=9,<10 (install identical before/after) -- commit 87f115b (non-comment lines sha256-identical; pip freeze identical, 18 packages)
- [x] 6. gates (see Tests run)

Commits on fup/GOV (base 3b760cc):
- c6ba9b8 .github: CI runs the network-hits lint and every UI shell test, without dead fallbacks
- 8d80f88 .github: publish-installer no longer writes a .nojekyll file
- 16b21ba .github: CODEOWNERS says the ruleset is not enabled yet and keeps a slot for a second owner
- 0647957 tests: ci_pins_test checks the required job names and what the lint and UI jobs run
- 87f115b ui: the requirements comments name the pytest range the dev file is built from

## Operator-visible changes
None. ui/requirements.txt is updater-tracked (UI_BUNDLE) and changes in one comment line only;
the installed packages are identical. The Pages site is unchanged (the .nojekyll file never
reached it).

## Docs notes
AGENTS.md "CI" (replacement text for the job list and the last paragraph):

- `parse-linux` ("bash -n (Linux)"): `bash -n` on every tracked `*.sh`, then
  `tools/check-bash32.sh` under Ubuntu's bash (with mawk).
- `parse-macos` ("bash -n and bash-3.2 lint (macOS bash 3.2)"): the same two checks under
  macOS `/bin/bash` 3.2 (with BSD awk), then `ui/tests/helper_test.sh`,
  `ui/tests/install_ui_test.sh` and `ui/tests/open_ui_test.sh` under `/bin/bash` 3.2.
- `shellcheck` ("shellcheck"): `shellcheck -x --severity=error` blocks; a second run at
  warning severity is advisory.
- `fixture-tests` ("fixture tests (Linux bash 5)"): `bash tools/tests/run.sh` under bash 5
  (this includes `tools/tests/network_hits_test.sh`, which also runs the lint over the tree).
- `fixture-tests-macos` ("fixture tests (macOS bash 3.2)"): the same suite under macOS
  `/bin/bash` 3.2.
- `hardening-lint` ("hardening lints"): the passphrase-print lint,
  `tools/check-perl-interp.sh` on every tracked `*.sh`, and `tools/check-network-hits.sh`
  (step "network hits"; exit 1 on a testnet name or address without a `network-gated:`
  reason, 2 on a usage error or a missing scanned file).
- `manifest` ("release manifest"): unchanged.
- `ui-tests` ("Node Manager UI tests"): on Python 3.10, installs `ui/requirements.txt` and
  `ui/tests/requirements-dev.txt` with `--require-hashes`, runs `python -m pytest -q ui`
  (no unittest fallback any more), then `ui/tests/helper_test.sh`,
  `ui/tests/install_ui_test.sh` and `ui/tests/open_ui_test.sh` under bash 5. As the runner
  user (not root) `install_ui_test.sh` checks only that the installer refuses a non-root
  run; its ownership and mode cases need root (run them in `bash:3.2`, which runs as root).
- `checksums` ("checksum freshness"): unchanged.

`publish-installer.yml`: the site is `index.html`, `install.sh` and `CNAME` (no
`.nojekyll`: upload-pages-artifact v4+ drops dotfiles and artifact deploys never run Jekyll).

Required status checks (the ruleset's required contexts, the jobs' display names, not the
job ids): "bash -n (Linux)", "bash -n and bash-3.2 lint (macOS bash 3.2)", "shellcheck",
"fixture tests (Linux bash 5)", "fixture tests (macOS bash 3.2)", "hardening lints",
"release manifest", "Node Manager UI tests", "checksum freshness" (ci.yml) and
"Ubuntu 24.04 VM assertions" (integration.yml). `tools/tests/ci_pins_test.sh` fails when any
of them is not the name of exactly one job, in that workflow. Do not rename a job without
updating the ruleset and `tools/tests/ci_pins_test.sh` in the same change.

`ci_pins_test.sh` also checks (add to the sentence "`tools/tests/ci_pins_test.sh` checks
these rules"): the hardening lints job runs the network-hits and perl lints, the UI job
installs the test requirements by hash and runs pytest, the UI and macOS jobs run the three
UI shell tests (the macOS job under `/bin/bash`), those three jobs have no `if [ -f`
fallback (lint and UI jobs) and no `continue-on-error` step, and publish-installer writes
no `.nojekyll`.

The `.github/CODEOWNERS` header now says the code-owner review is required once the
main-branch ruleset (issue #30) is enabled, and carries a `# second owner: TODO` line.

"Contributing" note draft (README or AGENTS.md, wherever DOCS keeps it):

> Pull requests to main need every required check green: "bash -n (Linux)", "bash -n and
> bash-3.2 lint (macOS bash 3.2)", "shellcheck", "fixture tests (Linux bash 5)", "fixture
> tests (macOS bash 3.2)", "hardening lints", "release manifest", "Node Manager UI tests",
> "checksum freshness" and "Ubuntu 24.04 VM assertions". Once the main-branch ruleset
> (issue #30) is on, it also requires a code-owner review (`.github/CODEOWNERS`) and signed
> commits: sign every commit (`git commit -S`, or `commit.gpgsign=true` with an SSH or GPG
> signing key registered on GitHub). Do not rename a CI job: the ruleset matches the display
> names, so a rename leaves a required check that never reports. If a rename is needed,
> change the ruleset and `tools/tests/ci_pins_test.sh` in the same pull request.

ui/requirements.txt recipe comment: requirements-dev is generated from "pytest>=9,<10".

## Tests run
All at fup/GOV tip 87f115b unless noted.
- `bash tools/tests/run.sh tools/tests/ci_pins_test.sh` (bash 5.3.9): exit 0; direct run 49 checks, 0 failures
- `docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh tools/tests/ci_pins_test.sh`: exit 0 (bash 3.2.57, busybox awk); direct 49 checks, 0 failures
- ci_pins_test.sh under ubuntu:24.04 (mawk) and with gawk --posix as awk: 49 checks, 0 failures
- negative: new ci_pins_test.sh over the 3b760cc workflows: 49 checks, 9 failures, exactly the new items (network hits, both fallbacks, unittest, install_ui + open_ui in both jobs, .nojekyll)
- mutations on a copy (each fails only its check, quoting passes): rename "hardening lints" (1 fail), duplicate a name in ci.yml (2), quote a name with " (0) and ' (0), reuse a ci.yml name in integration.yml (2), continue-on-error on network hits (1), network-hits run commented out (1), open_ui step removed from parse-macos (1), .nojekyll back (1)
- YAML parse (host pyyaml 6.0.3, no venv needed) of ci.yml, publish-installer.yml, integration.yml: ok
- actionlint 1.7.7 on the three workflows: rc 0
- job display names, every `uses:` pin, every permissions/contents: read and persist-credentials line: identical to 3b760cc in all three workflows
- `bash tools/check-network-hits.sh`: rc 0, "clean, 148 annotated hit(s) in 23 file(s) scanned"
- `git ls-files -z '*.sh' | xargs -0 bash tools/check-perl-interp.sh`: clean, 134 files
- shellcheck 0.11 and koalaman/shellcheck:v0.9.0 `-x --severity=error` on tools/tests/ci_pins_test.sh: clean (0.11 also clean at warning severity); `bash tools/check-bash32.sh tools/tests/ci_pins_test.sh`: clean; `bash -n` under 5.3 and 3.2: ok
- requirements: `pip install --require-hashes -r ui/requirements.txt -r ui/tests/requirements-dev.txt` in python:3.10-slim before (3b760cc files) and after: rc 0 both, `pip freeze --all` identical (18 packages, pytest 9.2.0); non-comment lines of both files sha256-identical before/after
- UI job steps in python:3.10-slim as root (the gate command): pip ok; pytest 277 passed, 1125 subtests; helper_test.sh 548 checks 0 failed; install_ui_test.sh 24 checks 5 FAILED (container artifact, see Open issues 1); open_ui_test.sh not reached in that chain
- UI job steps in python:3.10-slim as uid 1000 with a venv (as CI's runner user; separate pip installs as ci.yml does): pytest 277 passed, 1125 subtests; helper_test.sh 548/0; install_ui_test.sh 1/0 (root cases skipped); open_ui_test.sh 9/0; rc 0
- the three UI shell tests under bash:3.2 as root: helper 548/0, install_ui 24/0, open_ui 9/0; as uid 1000: helper 548/0, install_ui 1/0, open_ui 9/0
- host bash 5.3 as user: install_ui_test 1/0, open_ui_test 9/0
- worktree left clean (root-owned ui/__pycache__ from the root pytest run removed; reruns used PYTHONDONTWRITEBYTECODE=1 -p no:cacheprovider)

## Open issues
1. ui/tests/install_ui_test.sh (not a GOV file): run as root in a Debian or Ubuntu container
   (python:3.10-slim, ubuntu:24.04), its "other administrators and service accounts" block
   runs because `/.dockerenv`, `adduser` and `addgroup` exist, but it calls them with
   busybox flags (`adduser -D -H`), which Debian's adduser rejects ("Option d is
   ambiguous"); the accounts are never created, `chown` fails, and 5 cases fail ("a checkout
   owned by telcoin/tn-build/telcoin-alloy/telcoin-ui (even in sudo): refused", "one file
   owned by telcoin in a root checkout: refused"). CI is not affected (runner user is not
   root, so the block never runs) and bash:3.2 (busybox) passes 24/24. Suggested fix by the
   file's owner: also require busybox in the guard, e.g.
   `if [[ -f /.dockerenv ]] && adduser --help 2>&1 | grep -q BusyBox && command -v addgroup >/dev/null 2>&1; then`.
   The gate command in this round's brief (UI steps chained with && in python:3.10-slim as
   root) therefore stops at install_ui_test.sh; run it as a non-root user (as above) or run
   install_ui_test.sh's root cases in bash:3.2 only.
2. ui/requirements.txt.sha256 is stale after 87f115b (comment-only change to a UI_BUNDLE
   file); the orchestrator regenerates sidecars at release prep. The integration tip 3b760cc
   already had stale sidecars (ui/server.py), so "checksum freshness" fails on the branch
   until then either way.
3. On the macOS job, install_ui_test.sh and open_ui_test.sh run under /bin/bash 3.2, but they
   start the script under test with `bash` from PATH (as the fixture tests do). If the
   runner image puts a newer bash first on PATH, install-ui.sh and open-ui.sh themselves run
   under that bash there; their 3.2 coverage then rests on the bash:3.2 container run. Not
   changed here (tests are not GOV files; a `"${BASH:-bash}"` launch in both tests would pin
   it).
4. Spec vs files: none wrong. Notes: the dead fallbacks were at ci.yml 128-134 and 197-207 as
   stated; "the macOS job" for the UI shell tests is parse-macos (the job that runs
   helper_test.sh), not fixture-tests-macos; open_ui_test.sh needs no python3 (only sh,
   uname, mktemp, tr, grep and its own fake ssh/open/xdg-open); CI installs the two
   requirement files with two pip commands (kept as is) while the file header and the gate
   use one combined command (same result).
