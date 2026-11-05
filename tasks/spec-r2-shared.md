# Shared spec for round 2 on PR #59 (read first)

Round of 2026-11-04: the second round on the follow-up PR `scripts-v2.1.0` (branch
`hardening-followups`, PR #59, ready for review). It switches script-release signing to GPG with
the maintainer's existing release key, splits the node image into per-network ghcr packages,
gives mainnet an epoch constant, and adds the release ceremony tool. Every implementation and
verification agent reads this file, then its own package spec `tasks/spec-r2-<pkg>.md`. The
orchestrator is the only committer on the integration branch; implementers commit on their own
`r2/<pkg>` branch in their worktree `~/coding/telcoin/tnd-r2-<pkg>` (UPS: the telcoin-network
worktree `~/coding/telcoin/tn-r2-packages`, branch `release-packages-per-network`).

## Ground rules

- Commits (implementers, on your branch in your worktree): one commit per section, conventional
  prefix (`lib/common: …`, `update-scripts: …`, `tests: …`, `tools: …`), plain prose that says what
  the behaviour is now, no `Co-Authored-By`, no "Generated with", no trailer of any kind. Write
  the message to a file and `git commit -F <file>` (never `-F -` with a chained heredoc: the
  subject gets swallowed). Check `git log --format=%s` before handing back. Explicit paths only:
  never `git add -A`, never `tasks/`, `.claude/`, `*.sha256`.
- No version bumps (every tracked script already reads 2.1.0 from the release prep), no
  `tools/gen-checksums.sh`, no `README.md`/`OPERATOR.md`/`CHANGELOG/`/partner-guide edits (DOCS-2
  owns them; write your facts under **Docs notes**). AGENTS.md and `docs/testnet-addons.md` only
  where your spec says so. The orchestrator regenerates sidecars at integration.
- The maintainer's private ops checkout and the maintainer's workspace `.env` files (outside this
  repository) are never read into a public file, commit, comment or test. Do not reference them
  anywhere. Never print, copy or read any private key or passphrase; tests make throwaway keys.
- bash 3.2 safe (CI runs every fixture under macOS `/bin/bash` 3.2 and `bash:3.2`): no
  `declare -A`, `declare -g`, `local -n`, `${var,,}`, `${var^^}`, `mapfile`, `readarray`,
  `&>>`, `|&`, `[[ -v`, `wait -n`, negative subscripts, `${v@X}`, `%(…)T`, `;;&`. Empty arrays
  expand as `${a[@]+"${a[@]}"}` under `set -u`. No apostrophe inside a `${var:-default}`
  word. Declare locals on the `local` line, assign on their own lines. `readonly arr=(…)`
  sourced inside a function is invisible under 3.2: source at top level. Inside `$( )` never
  write a `case` with bare `pat)` patterns (3.2 counts parentheses): move it into a function
  or write `(pat)`. `source missing || true` still exits under 3.2 with `set -e`: guard with
  `[ -r f ] && source f`. `tools/check-bash32.sh FILE` must stay clean on every touched file.
- The macOS runner is BSD userland (the `bash:3.2` image is busybox and does not catch it):
  no `stat -c`, `date -d`, `sed -i` without a suffix, `readlink -f`, `sha256sum` without a
  `shasum -a 256` fallback, `awk -v` with a multi-line value, `base64 -w`, `grep -P`. The test
  library `tools/tests/lib.sh` has a BSD shim table; use its helpers.
- Tree-wide lints run on every commit, comment lines included: `tools/check-network-hits.sh`
  (a network name or host in a line needs the lint's `network-gated:` annotation; read the
  script's header), `tools/check-perl-interp.sh`, `tools/check-bash32.sh`, shellcheck 0.9 and
  0.11 `--severity=error` with `-x` on every `*.sh` (verifier harness files and `tools/`
  scripts too: shebang, `# shellcheck shell=bash` where sourced), `bash -n` under 5.3 and 3.2.
- Boundary rule (AGENTS.md): nothing operator-facing may call, source or point at `common/`
  or `devnet-genesis/`. Root owns the install: root-owned files go through
  `tn_write_root_file`, never a pipe; the passphrase variables are never echoed; no perl program
  expands a shell variable.
- `--json` runs print only JSON events on stdout and always end with a `done` event.
- Agents edit, test and commit on their own branch only. Never `git checkout`/`switch`
  another branch, never `git stash`, `git reset`, `git rebase`, `git push`, never set
  `commit.gpgsign` or `user.signingkey`, never touch the gpg-agent sockets or
  `~/.gnupg`; tests use a temporary `GNUPGHOME`. Read-only git is fine. If a change seems to
  need a file another package owns, write it under "Open issues" in your checkpoint with the
  exact text and hand back.
- Prose in comments, help text and messages: plain, specific, no filler, no line-number
  references, no em-dashes. Messages tell the operator what happened and what to do.
- Temporary files go in `/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/a63179cc-f715-4653-8076-ca7024820f15/scratchpad/<pkg>/`
  (implementers) or your worktree's `tasks/verify-r2/<name>/` (verifiers, committed as
  records), never elsewhere in the repo.

## Checkpoint protocol

- Checkpoint file: `tasks/ckpt-r2-<pkg>.md` in your worktree (do not commit it; the
  orchestrator collects it). First line `status: <in-progress|blocked|done>`. Then the
  sections with `[x]`/`[ ]`, rewritten after EACH section, not once at the end.
- On start, read your own checkpoint and continue from the first unfinished section.
- The checkpoint ends with four headings: **Operator-visible changes**, **Docs notes** (the
  exact facts DOCS-2 must write: flags, env names, file paths, messages, defaults, and the
  README/OPERATOR/AGENTS/CHANGELOG/partner-guide lines you know are now stale), **Tests
  run** (commands and results, bash 5 and bash 3.2), **Open issues**.
- Budget well under 250k tokens. If you are ballooning, checkpoint and hand back; the
  orchestrator respawns for the remainder.
- If Write is refused, do not work around it: return the complete text in the final answer.
- Return a summary (not file dumps) in the final answer: commits on your branch (sha +
  subject), tests run with counts, docs notes, open issues.

## Test environments (2026-11-04)

Host: bash 5.3, gpg 2.4.8 with `gpgv`, ssh-keygen, docker 29, shellcheck 0.11, python 3.12.
Containers (`docker run --rm -v "$PWD:/w" -w /w IMAGE …`): `bash:3.2` (busybox userland),
`ubuntu:24.04` (bash 5.2), `koalaman/shellcheck:v0.9.0`, `python:3.10-slim`, `python:3.12-slim`.
`bash:3.2` and `ubuntu:24.04` have NEITHER `gpg`, `gpgv` nor `ssh-keygen`: tests that need a
real signature SKIP there or use a fake on `PATH`. CI runners: `ubuntu-latest` (gpg + gpgv)
and `macos-latest` (gnupg installed; `base64 -d` works on current macOS, older ones took
`-D`). Run fixtures with `bash tools/tests/run.sh tools/tests/<name>_test.sh` (the runner
sets `TN_TEST_TMP`, `BIN`, the `check` helpers).

## Verified facts (checked on hardening-followups 9fd615a, 2026-11-04)

- Versions: every tracked script, `COMMON_VERSION` and `UI_VERSION` read 2.1.0 (release prep
  dc5a023 of the previous round); `CHANGELOG/scripts-v2.1.0.md` exists. There is no
  `scripts-v*` tag, no `RELEASE`/`MANIFEST`/`MANIFEST.sig` on any branch, no GitHub release of
  the scripts, and `lib/allowed_signers` holds only comments. Decision: `scripts-v2.1.0` is the
  FIRST signed script release (serial 1); `scripts-v2.0.0` is never tagged.
- Updater-tracked files: the three arrays `SCRIPTS`, `UI_BUNDLE`, `TESTNET_ADDONS_BUNDLE` in
  `update-scripts.sh` (around lines 73-130), each with a `.sha256` sidecar.
  `lib/release-keys/grantkee.asc` and `lib/release-keys/README` are tracked (lines 95-96).
  `tools/`, `tasks/`, `AGENTS.md`, tests are not tracked.
- Release key: `lib/release-keys/grantkee.asc`, primary fingerprint
  `4E36D35A4AB61B589861D01AC7173F2377CA7573`, a YubiKey-held key; it already signs upstream node
  releases and this repository trusts it for them (`_tn_release_keyring` common.sh ~7213,
  `_tn_gpg_status_verdict` ~7243, `_tn_release_sig_ok` ~7289, `_tn_tag_sig_check` ~8067).
  Decision: the same key signs script releases.
- CI (`.github/workflows/ci.yml`) job display names: "bash -n (Linux)", "bash -n and bash-3.2
  lint (macOS bash 3.2)", "shellcheck", "fixture tests (Linux bash 5)", "fixture tests (macOS
  bash 3.2)", "hardening lints", "release manifest", "Node Manager UI tests", "checksum
  freshness"; `integration.yml`: "Ubuntu 24.04 VM assertions". Never rename a job.
- CODEOWNERS now lists `@grantkee @sstanfield @MavenRain` on every line (8db70e0);
  `ci_pins_test.sh` requires at least two owners on every owned path. The path lines
  `/lib/allowed_signers` and `/MANIFEST.sig` exist today and SIG renames them.
- Upstream node release process (telcoin-network `etc/release.sh`, origin/main a0d6e6e26):
  `TAG_RE` accepts `vX.Y.Z[-adiri][-rcN]`; `parse_tag` (line ~256) sets CHANNEL `adiri` for
  `-adiri` tags (FEATURES `adiri`, ALIAS `adiri`) and mainnet otherwise (no features, alias
  `latest`); `IMAGE=ghcr.io/$(lower "$REPO")` (~2107) with `REPO` from `RELEASE_REPO` (~2092,
  dry runs); `check_version_output` (~1236) refuses Build Features on a mainnet tag and requires
  `adiri` (faucet allowed) on an adiri tag; `SHA256SUMS` lists `IMAGE_DIGEST` whose one line is
  `<image>@sha256:<hex>` (~1179-1193); dry runs: `RELEASE_DRY_RUN=1`, `RELEASE_IMAGE`
  (localhost registry), `RELEASE_DIR`; `parse TAG` needs neither git nor network; sourcing the
  file defines the functions without running. `Makefile:13` `GHCR_IMAGE :=
  ghcr.io/telcoin-association/telcoin-network` for `docker-adiri`/`docker-devnet`
  (`dev-<flavor>-<TAG>`). `make release-lint` = actionlint on release.yaml/docs.yaml +
  shellcheck `-S style` on etc/release.sh, etc/yubikey-setup.sh, verify_commit_hash.sh.
- Images today in this repository: `TN_GHCR_IMAGE_REPO="ghcr.io/telcoin-association/telcoin-network"`
  (common.sh ~1522), `TN_TESTNET_LEGACY_IMAGE_REPO` (GAR adiri, ~1524), `TN_MAINNET_IMAGE_REPO=
  "$TN_GHCR_IMAGE_REPO"` (~6926), `TN_TESTNET_IMAGE_REPOS` (~6934), `tn_docker_repo_for`
  (~6957), `tn_docker_repos_for`, `tn_docker_repo_ok` (~7016), `tn_docker_resolve_ref` (~7940:
  its comment says testnet and mainnet share the ghcr repository), tag grammar
  `tn_release_tag_ok` (~1701: mainnet `^vX.Y.Z$`, testnet `-adiri`), `STORAGE_MIGRATION_FLOOR=
  "0.16.0"` (update-node.sh:137, used by `storage_migrating_upgrade` ~966 and
  `update_downgrade_check` ~1806). UI twins: `ui/server.py` `RELEASE_TAG_RE` (~296),
  `GHCR_IMAGE_REPO`/`DOCKER_REPO` (~376-388); `ui/static/index.html` ~2404;
  `ui/test_server_contract.py` ~1377, ~1952-1962.
- Epoch: `_tn_epoch_timing DUR` (common.sh ~4538) derives margin DUR/72 clamped 300-900 and
  settle DUR/240 clamped 90-300, env overrides win; `_tn_wait_blind` (~4511) takes fixed
  margin/settle from its caller when the epoch length is unreadable; no per-network epoch
  constant exists. Decision: mainnet epoch 21600 s (upstream `MAINNET_EPOCH_DURATION_SECS`),
  adiri today 21600 s. Firewall P2P limit 20/min burst 40 stays on every network.
- Alloy: vendored header now names deploy-networks-common main 18f8485 (a2162b6); not in scope.
