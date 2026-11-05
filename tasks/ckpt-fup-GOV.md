status: done

## Sections
- [x] 1. .github/workflows/ci.yml: drop the two dead fallbacks, add install_ui_test.sh + open_ui_test.sh (UI job bash 5, macOS job 3.2), add "network hits" step to hardening-lint -- commit c6ba9b8
- [x] 2. .github/workflows/publish-installer.yml: drop the .nojekyll touch and its comment -- commit 8d80f88
- [x] 3. .github/CODEOWNERS: line 1 wording, `# second owner: TODO` line -- commit 16b21ba
- [x] 4. tools/tests/ci_pins_test.sh: display names once each, network-hits step, UI shell tests in both jobs, no fallbacks, no .nojekyll -- commit 0647957 (49 checks; 9 fail on the 3b760cc workflows; 9 mutations behave)
- [x] 5. ui/requirements.txt + ui/tests/requirements-dev.txt comment lines: pytest>=9,<10 (install identical before/after) -- commit 87f115b (non-comment lines sha256-identical; pip freeze --all identical, 18 packages)
- [x] 6. gates (see Tests run)
- [x] 7. (V6 W1) CODEOWNERS line 1 true of the issue #30 ruleset JSON (require_code_owner_review false until a second owner) -- commit f158730
- [x] 8. (V6 N5) ci_pins_test.sh: no continue-on-error (job or step) in the ten required jobs; no if: on required jobs or the checked steps except the pinned release-manifest conditions; no `|| true` / `|| :` on the checked run lines; V6's 4 missed mutations fail, 8 caught stay caught -- commit 26e6cf7 (53 checks; V6 mutations 12 caught 0 missed under bash 5.3, bash:3.2, ubuntu:24.04; 13 extra mutations behave)
- [x] 9. gates again + docs-note corrections (job-level continue-on-error; pip freeze count) -- see Tests run (round 2)

Commits on fup/GOV (base 3b760cc):
- c6ba9b8 .github: CI runs the network-hits lint and every UI shell test, without dead fallbacks
- 8d80f88 .github: publish-installer no longer writes a .nojekyll file
- 16b21ba .github: CODEOWNERS says the ruleset is not enabled yet and keeps a slot for a second owner
- 0647957 tests: ci_pins_test checks the required job names and what the lint and UI jobs run
- 87f115b ui: the requirements comments name the pytest range the dev file is built from
- f158730 .github: CODEOWNERS line 1 matches the ruleset, which needs a review but not yet a code owner's
- 26e6cf7 tests: ci_pins_test fails when a required check can no longer fail

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
  warning severity is advisory (the one `continue-on-error` in the required jobs).
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

Required status checks. The ruleset JSON in issue #30 (what the maintainer applies) lists
eight contexts: "bash -n (Linux)", "bash -n and bash-3.2 lint (macOS bash 3.2)",
"shellcheck", "fixture tests (Linux bash 5)", "hardening lints", "release manifest",
"Node Manager UI tests", "checksum freshness". `tools/tests/ci_pins_test.sh` guards those
and two more, "fixture tests (macOS bash 3.2)" (ci.yml) and "Ubuntu 24.04 VM assertions"
(integration.yml), so either can be made required without a rename: each of the ten must be
the display name (`name:`) of exactly one job, in its workflow. The contexts are the display
names, not the job ids. Do not rename a job without updating the ruleset and
`tools/tests/ci_pins_test.sh` in the same change.

`ci_pins_test.sh` also checks (add to the sentence "`tools/tests/ci_pins_test.sh` checks
these rules"): the hardening lints job runs the passphrase-print, perl and network-hits
lints; the fixture jobs run `tools/tests/run.sh` (the macOS one under `/bin/bash`); the
checksum job runs `tools/gen-checksums.sh`; the UI job installs the test requirements by
hash and runs pytest; the UI and macOS jobs run the three UI shell tests (the macOS job
under `/bin/bash`); the hardening lints and UI jobs have no `if [ -f` fallback and the UI
job no unittest fallback; no required job, and no step of one, carries an `if:` or a
`continue-on-error` (job level and step level both rejected; `continue-on-error: false` is
allowed), except the advisory shellcheck step "shellcheck (warnings -- advisory)"; no run
line in a required job ends with `|| true`, `|| :` or `|| exit 0`; publish-installer writes
no `.nojekyll`. Reason to state: a skipped required check counts as passed on GitHub, and
`continue-on-error` turns a failure into a pass.

`.github/CODEOWNERS` line 1: "# Code owners. The main-branch ruleset (issue #30) requires a
pull-request review; it will require that review from a code owner once a second owner is
listed here and the ruleset's require_code_owner_review is set to true." It carries a
`# second owner: TODO` line.

"Contributing" note draft (README or AGENTS.md, wherever DOCS keeps it):

> Pull requests to main need the required checks green: "bash -n (Linux)", "bash -n and
> bash-3.2 lint (macOS bash 3.2)", "shellcheck", "fixture tests (Linux bash 5)", "hardening
> lints", "release manifest", "Node Manager UI tests" and "checksum freshness". Once the
> main-branch ruleset (issue #30) is on, a pull request also needs one approving review
> (an approval is dismissed by a later push, and the last push must be approved by someone
> other than its pusher) and signed commits: sign every commit (`git commit -S`, or
> `commit.gpgsign=true` with an SSH or GPG signing key registered on GitHub). It will need
> that review from a code owner (`.github/CODEOWNERS`) once a second owner is listed there
> and the ruleset's `require_code_owner_review` is set to true. Do not rename a CI job: the
> ruleset matches the display names, so a rename leaves a required check that never
> reports. If a rename is needed, change the ruleset and `tools/tests/ci_pins_test.sh` in the
> same pull request. A required job must not be made skippable (`if:`) or non-blocking
> (`continue-on-error`, `|| true`); `ci_pins_test.sh` rejects both.

(If the orchestrator prefers the coordinator's shorter form: "today: one approving review;
a code-owner review and signed commits once the ruleset is on and the second owner is
named". Note that in the issue #30 JSON `required_signatures` is on from the start, not
tied to the second owner.)

ui/requirements.txt recipe comment: requirements-dev is generated from "pytest>=9,<10".

## Tests run
Round 1 (at 87f115b):
- `bash tools/tests/run.sh tools/tests/ci_pins_test.sh` (bash 5.3.9): exit 0; direct run 49 checks, 0 failures
- `docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh tools/tests/ci_pins_test.sh`: exit 0 (bash 3.2.57, busybox awk); direct 49 checks, 0 failures
- ci_pins_test.sh under ubuntu:24.04 (mawk) and with gawk --posix as awk: 49 checks, 0 failures
- negative: ci_pins_test.sh over the 3b760cc workflows: 9 failures, exactly the new items
- mutations on a copy: rename, duplicate name, quoting (passes), cross-workflow reuse, continue-on-error on network hits, commented-out run, open_ui step removed, .nojekyll back: all as expected
- YAML parse (host pyyaml 6.0.3) of the three workflows: ok; actionlint 1.7.7: rc 0
- job display names, every `uses:` pin, permissions/contents: read and persist-credentials lines: identical to 3b760cc
- `bash tools/check-network-hits.sh`: rc 0, "clean, 148 annotated hit(s) in 23 file(s) scanned"; perl lint over git ls-files *.sh: clean, 134 files
- shellcheck 0.11 and v0.9.0 `-x --severity=error`, check-bash32, `bash -n` 5.3/3.2 on ci_pins_test.sh: clean
- requirements: `--require-hashes` install of both files in python:3.10-slim at 3b760cc and at 87f115b: `pip freeze --all` identical, 18 packages (pytest 9.2.0). Count note: stdout of `pip freeze --all` alone is 18 lines; my first capture also held the (empty) install output and was 19 lines, which is the 19 V6 reports. Identical either way. Non-comment lines of both files sha256-identical.
- UI job steps in python:3.10-slim as uid 1000 with a venv (as CI's runner user): pytest 277 passed, 1125 subtests; helper_test.sh 548/0; install_ui_test.sh 1/0; open_ui_test.sh 9/0
- the gate command as root in python:3.10-slim: pytest 277, helper 548/0, install_ui_test.sh 24 checks 5 failed (Open issue 1), chain stops there
- the three UI shell tests under bash:3.2 as root: 548/0, 24/0, 9/0; as uid 1000: 548/0, 1/0, 9/0

Round 2 (at 26e6cf7):
- `bash tools/tests/run.sh tools/tests/ci_pins_test.sh` (bash 5.3.9): exit 0; direct 53 checks, 0 failures
- `docker run --rm -v "$PWD:/w" -w /w bash:3.2 bash tools/tests/run.sh tools/tests/ci_pins_test.sh`: exit 0; direct 53/0; ubuntu:24.04 (mawk) 53/0; gawk --posix 53/0
- V6's tasks/verify-fup/V6/gov_mutation.sh (copied to the scratchpad, archive step replaced by a copy of this worktree): 12 caught, 0 missed under bash 5.3, bash:3.2 and ubuntu:24.04 (the 8 caught before stay caught; the 4 missed now fail: `|| true` on the network hits run, `if: false` on the network hits step, job continue-on-error on fixture-tests, job `if: false` on checksums)
- 13 more mutations, same result under bash 5.3, bash:3.2, ubuntu:24.04 and gawk --posix: fail as wanted on `- if: false` as a step's first key, `pytest || :`, fixture run `|| exit 0`, `||true` inside a run block, job `if:` on vm-assertions (integration.yml), job continue-on-error expression on parse-linux, continue-on-error on the blocking shellcheck step, step `if:` on the macOS open_ui step, job `if: false` on release manifest; pass as wanted on `continue-on-error: false`, an added `timeout-minutes`, the manifest step's `|| ! git cat-file`, a commented-out `# if: false`
- negative: ci_pins_test.sh over the 3b760cc workflows: 53 checks, 9 failures (the same nine new items)
- YAML parse of the three workflows: ok; actionlint 1.7.7: rc 0
- shellcheck 0.11 (error and warning severity) and v0.9.0 `-x --severity=error`: clean; check-bash32: clean; `bash -n` under 5.3 and 3.2: ok
- `bash tools/check-network-hits.sh`: rc 0 (148 annotated hits, 23 files); perl lint: clean, 134 files
- issue #30 body read with `gh issue view 30` (read-only): pull_request rule has required_approving_review_count 1, dismiss_stale_reviews_on_push true, require_code_owner_review false, require_last_push_approval true; required_signatures on; required_status_checks lists eight contexts (no "fixture tests (macOS bash 3.2)", no "Ubuntu 24.04 VM assertions")

## Open issues
1. ui/tests/install_ui_test.sh (not a GOV file): run as root in a Debian or Ubuntu container
   (python:3.10-slim, ubuntu:24.04), its "other administrators and service accounts" block
   runs because `/.dockerenv`, `adduser` and `addgroup` exist, but it calls them with
   busybox flags (`adduser -D -H`), which Debian's adduser rejects ("Option d is
   ambiguous"); the accounts are never created, `chown` fails, and 5 cases fail. CI is not
   affected (runner user is not root) and bash:3.2 (busybox) passes 24/24. Suggested fix:
   `if [[ -f /.dockerenv ]] && adduser --help 2>&1 | grep -q BusyBox && command -v addgroup >/dev/null 2>&1; then`.
2. ui/requirements.txt.sha256 is stale after 87f115b (comment-only change to a UI_BUNDLE
   file); sidecars are regenerated at release prep. "checksum freshness" fails on the branch
   until then (it already did at 3b760cc because of ui/server.py).
3. On the macOS job, install_ui_test.sh and open_ui_test.sh start the script under test
   with `bash` from PATH (as the fixture tests do), so if a newer bash is first on PATH
   there, install-ui.sh and open-ui.sh run under it; their 3.2 coverage then rests on the
   bash:3.2 run. A `"${BASH:-bash}"` launch in both tests would pin it (not GOV files).
4. Issue #30 JSON vs the spec: it requires eight contexts, not ten ("fixture tests (macOS
   bash 3.2)" and "Ubuntu 24.04 VM assertions" are not in it). The test guards all ten; the
   docs notes above say eight are required. Adding the two to the JSON is a user step (issue
   edit), as is any change to require_code_owner_review.
5. Issue #30 JSON with a single maintainer: required_approving_review_count 1 plus
   require_last_push_approval true means the maintainer's own pull requests need an approval
   from another account with write access (GitHub does not count a self-approval). Worth
   stating in the Contributing text or settling before the ruleset is enabled.
6. Spec vs files (round 1): none wrong; "the macOS job" for the UI tests is parse-macos;
   open_ui_test.sh needs no python3; CI keeps two pip commands where the dev file header and
   the gate use one (same result).
