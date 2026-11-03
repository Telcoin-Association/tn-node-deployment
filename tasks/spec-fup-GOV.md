# GOV: workflows and governance files (issues #30, #31, #47; Dependabot notes)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-GOV`, branch
`fup/GOV` from the integration branch AFTER NET-2 is in, checkpoint `tasks/ckpt-fup-GOV.md`.

## Owned files

`.github/workflows/ci.yml`, `.github/workflows/publish-installer.yml`, `.github/CODEOWNERS`,
`tools/tests/ci_pins_test.sh`, `ui/requirements.txt` (comment lines only),
`ui/tests/requirements-dev.txt` (comment line only; hashes untouched).

## Facts (main 1187ddb, Dependabot merged)

- ci.yml :128-134: `perl interpolation lint` step has an `if [ -f tools/check-perl-interp.sh ]`
  fallback with a notice; the tool exists. :197-207: the UI job installs
  `ui/tests/requirements-dev.txt` behind `if [ -f … ]` and runs pytest behind
  `if python -c 'import pytest'` else unittest; both files exist and pytest 9.2.0 is pinned.
  The UI job runs `ui/tests/helper_test.sh` under bash 5; the macOS job runs it under 3.2;
  `ui/tests/install_ui_test.sh` and `ui/tests/open_ui_test.sh` run nowhere in CI.
- publish-installer.yml :49: `touch _site/.nojekyll`; upload-pages-artifact v5 drops dotfiles
  and Pages artifact deploys never run Jekyll, so the line is dead.
- `.github/CODEOWNERS`: single owner on every line; line 1 says the ruleset requires a code
  owner review (no ruleset exists yet; the user adds one with the JSON in issue #30).
- `tools/tests/ci_pins_test.sh` checks pins, `permissions: {}`, per-job `contents: read`,
  `persist-credentials: false`.
- CI display names (the ruleset's required contexts): "bash -n (Linux)", "bash -n and
  bash-3.2 lint (macOS bash 3.2)", "shellcheck", "fixture tests (Linux bash 5)", "fixture
  tests (macOS bash 3.2)", "hardening lints", "release manifest", "Node Manager UI tests",
  "checksum freshness", "Ubuntu 24.04 VM assertions".
- `ui/requirements.txt:12` says requirements-dev is generated from "pytest>=8,<9";
  `ui/tests/requirements-dev.txt:29` carries `# via pytest>=8,<9`.
- NET-2 adds `tools/check-network-hits.sh` (exit 1 on an unannotated hit).

## Required behaviour

1. ci.yml: remove both dead fallbacks (run the tool and pytest directly); add
   `bash ui/tests/install_ui_test.sh` and `bash ui/tests/open_ui_test.sh` to the UI job (bash
   5) and to the macOS job (3.2) after `helper_test.sh` (check what they need: `open_ui_test`
   may need `python3`; macOS runners have it); add a `network hits` step to `hardening-lint`
   that runs `bash tools/check-network-hits.sh`. Keep every pin, permission and
   `persist-credentials` line; the display names do not change.
2. publish-installer.yml: drop the `.nojekyll` touch and its comment.
3. CODEOWNERS: line 1 reads "The main-branch ruleset (issue #30) requires a review from a
   code owner once it is enabled."; add a commented `# second owner: TODO` line under the
   header (no login given yet).
4. `ci_pins_test.sh`: assert the ten display names above exist exactly once across the two
   workflows (so a rename shows up as a failed test before the ruleset breaks), assert the
   network-hits step exists, and keep today's checks.
5. `ui/requirements.txt:12` and `ui/tests/requirements-dev.txt:29`: "pytest>=9,<10".

## Tests

`bash tools/tests/run.sh ci_pins_test.sh` under bash 5.3 and `bash:3.2`; `actionlint` if
present on the host (else `python3 -c 'import yaml; …'` parse of both workflows); run the
UI job's steps locally in `python:3.10-slim` (`--require-hashes` install, pytest, helper,
install_ui, open_ui) and the three UI shell tests under `bash:3.2`.

## Docs notes to hand over

The AGENTS.md "CI" and "Contributing" text (the jobs now run the three UI shell tests and
the network-hits lint; required contexts list; "do not rename a job without updating the
ruleset and ci_pins_test.sh").
