# Lessons

## Bash: no apostrophes / single quotes inside `${var:-default}` defaults

**Symptom:** `bash -n install-caddy.sh` reported `syntax error near unexpected
token '('` on a line whose `(` was harmlessly inside a double-quoted string — and
the *real* offending code was ~14 lines earlier.

**Cause:** a default value contained an apostrophe:
`note="... (-> ${pub:-this host's inbound public IP}) ..."`. Even inside double
quotes and inside `${...:-...}`, bash treats that `'` as a quote delimiter and pairs
it with the *next* single quote in the file (here, the opening `'` of a later
`printf '{...}'` format string). Everything between is mis-quoted, desyncing all the
double-quote accounting, so the parser blows up on a much later line.

**Rule:** never put `'` (including apostrophes in prose) inside a `${var:-word}` /
`:+` / `:=` default. Rephrase to avoid the apostrophe. The codebase already follows
this — e.g. `${pub:-this servers public IP}` (no apostrophe in "servers"). Match it.

**Bonus:** when `bash -n` points at a line that looks obviously fine, suspect an
unbalanced quote *earlier* in the file, not the reported line.

## Bash: `local a; a="$(cmd)" b` runs `b` as a command and drops `a`

**Symptom:** shellcheck SC2154 ("b is referenced but not assigned") on a resolver I
wrote as `local etc; etc="$(_tn_etc)" var; ...; printf '%s' "$var"` — and at runtime
`$var`/`$etc` would have been **empty**. `bash -n` passed (valid syntax) so it nearly
slipped through; only shellcheck + a fixture unit test caught it.

**Cause:** `etc="$(_tn_etc)" var` is parsed as *run the command `var` with the env var
`etc` set for that one command*. Prefix assignments are temporary — `etc` is NOT
retained in the shell afterward — and `var` (or `t`, `n`, …) is executed as a bogus
command. Six resolver functions had this shape; every one was silently broken.

**Rule:** declare all locals on the `local` line, then assign on their own lines:
`local etc var; etc="$(_tn_etc)"; var="$(_tn_var)"`. Never trail a bare word after a
`VAR="$(...)"` assignment expecting it to be another local. Always shellcheck +
fixture-test library resolvers before building consumers on top of them.

## Verifying bash scripts that gate on `check_root` / do real side effects

To unit-test functions in a script that ends with `main "$@"` and whose interactive
path calls `check_root` + real installers: strip the trailing `main "$@"` into a temp
copy (`grep -v '^main "\$@"$'`), symlink `lib/` next to it so `source lib/common.sh`
resolves, `source` it, then override the side-effecting/network functions with stubs
and call the target function directly. Drive `read` prompts via piped stdin. Note:
`read -p` shows its prompt **only when stdin is a TTY**, so a piped harness won't see
prompt text — assert on resulting behavior/state instead. For network-dependent
helpers (curl/dig/hostname), prefer PATH shims that echo env-var-controlled values so
every branch is deterministic.

## Release hygiene: editing a tracked file is not done until versions + .sha256 are refreshed

**Symptom:** I edited `setup-vpn.sh` and bumped only its own `SCRIPT_VERSION`, then
declared the task complete. The user had to remind me to bump `update-scripts.sh` and
regenerate the `.sha256` sidecars.

**Cause:** `update-scripts.sh` fetches every tracked file from GitHub and verifies it
against a committed `<file>.sha256` sidecar; CI fails if any sidecar is stale. So a
content change to a tracked file leaves its sidecar (and the operator-facing verification)
out of sync until regenerated. The repo's release convention also bumps the updater itself
and adds a README changelog entry on each release (see commit 03bfc07,
`chore(release): refresh checksums...`).

**Rule:** after editing ANY updater-tracked file (anything in the `SCRIPTS`,
`UI_BUNDLE`, or `TESTNET_ADDONS_BUNDLE` arrays of `update-scripts.sh`), do ALL of:
1. bump that file's own version var (`SCRIPT_VERSION` / `COMMON_VERSION` / `UI_VERSION` / …);
2. bump `update-scripts.sh`'s `SCRIPT_VERSION` (release marker so updaters re-bootstrap);
3. run `bash tools/gen-checksums.sh` and commit the changed sidecars (it regenerates all 34;
   only the touched files' sidecars actually change — verify with `git status -- '*.sha256'`);
4. add a `### <script> vX.Y.Z` entry to the README Changelog.

**Rule of thumb:** "I changed a `.sh`/`.py`/`.env` that operators fetch" ⇒ versions +
`gen-checksums.sh` + changelog, every time. Don't call it done before that.

## Harness gotchas collected while verifying on macOS (bash 3.2 + 5)

- **`readonly arr=(…)` sourced inside a function is invisible on bash 3.2.** Source the script
  copy at the harness top level, never from inside a helper function, or array globals come
  back "unbound variable" under 3.2 only.
- **macOS `/usr/bin/mktemp` ignores a nonexistent `TMPDIR`.** To test the "mktemp fails"
  branch, put a failing `mktemp` stub on PATH instead of pointing `TMPDIR` at a missing dir.
- **`sort -V` works on macOS sort (2.3-Apple)**; no shim needed for `version_gte`.
- **`read -p` prompts are silent when stdin is piped**; assert on resulting state, not text.
- **`tools/gen-checksums.sh` refreshes every sidecar in the tree.** When several tracked
  files are modified but only some are being committed, stage only the sidecars of the files
  in that commit; the rest stay unstaged until their own commit. Each pushed tip must have
  every committed sidecar matching its committed file (operators pull `main` immediately).
- **Pre-existing bash-4 constructs that `bash -n` does not catch:** `${var,,}` in
  `confirm()` and `declare -A` in `remove-node.sh`. CI only parse-checks, so grep for them.

- **Run an agent's harness exactly as its driver does.** P3's `mg-harness.sh` gave 16/45 from the
  scratchpad directory and 45/45 from the repo root with the same arguments: it resolved `lib/`
  relative to the cwd. Before calling a gate failed, re-run via the agent's own driver
  (`rerun-all.sh`) or with its documented cwd and arguments; harness usage lines at the top of the
  file say what they need.
- **zsh: a bare word starting with `=` is a command lookup.** `echo =======` as a section
  separator fails with "====== not found" and aborts the chained command. Use `echo ---` or
  `printf '-----\n'` for separators in Bash tool calls (the tool runs under zsh).

## bash 3.2 + `set -e`: `source missing-file || true` still exits

**Symptom:** a `set -e` script ran fine under bash 5 but stopped silently under macOS
`/bin/bash` 3.2 at `source "$HOME/.cargo/env" 2>/dev/null || true` when the file was absent.

**Cause:** bash 3.2 treats a failed `source`/`.` as a fatal shell error that `|| true` does not
rescue; bash 4+ returns 1 and lets the `||` run. `bash -n` cannot see it.

**Rule:** guard the file first: `[ -r "$f" ] && source "$f"` (or `if [ -r "$f" ]; then source
"$f"; fi`). Grep every `source …|| true` and `. … || true` in a script before calling it
bash-3.2 safe. (Found by P4a in setup-node.sh; update-scripts.sh had the same shape — the
pre-fix updater, run from a lone copy on macOS, exited 1 with no output at all.) Under 3.2 with
`set -e`, `|| true` also fails to rescue a failure *inside* a sourced file that is present (a
failing top-level command exits 1, a syntax error exits 2), so keep sourced files free of
failing top-level commands.

## bash 3.2: a redirection on a *function call* leaks the saved descriptor to children

**Symptom:** to keep an inherited lock descriptor away from long-running children, P6 tried
`some_function 9>&-`. Under bash 3.2 the children spawned inside that function still held
fd 9 (bash keeps a saved copy of the redirected descriptor for the duration of the call and
children inherit it); under bash 5 they did not.

**Rule:** put `9>&-` (or any fd close) on the individual external commands (`cargo build 9>&-`,
`sleep 9>&-`), never on a shell function call, when the script must run under bash 3.2. And
release a flock with `flock -u 9` before closing the descriptor, so orphans that already
inherited it cannot keep the lock.

## A harness that diffs against `git show HEAD:` goes stale when the package is committed

**Symptom:** P4a's harness compared its setup-node output with `git show HEAD:setup-node.sh` run
under the same shims. After P4a was committed, "HEAD" became P4a itself, and one case
(`fz-head-bin2`, written for the 1.2.1 behaviour) started failing on P4b's run with no
regression anywhere.

**Rule:** pin the baseline to a commit hash (`git show 7fb7c8d:setup-node.sh`), never to
`HEAD`, when a harness compares new behaviour with the previous release. Record the hash in
the harness so the next reader knows which release it stands for.

## Orchestration lessons from the backlog round (2026-10-02)

- **Independent verifiers earn their cost.** Every verifier (V-L, V-CORE-1/2, V-UI, V-OPS-1/2,
  V-DOC) found at least one error the implementer's own 400+ tests had not: a tokenizer that
  accepted `x>/path` into a root-run wrapper, an `eval` of RPC strings, an updater that installed
  files without a sidecar, a passphrase in every child's environment. Budget one verifier per
  package and give it the spec, not the implementer's claims; read the implementer's checkpoint
  only after writing the harness.
- **The 250k token budget per agent was fiction.** Packages here ran 300–600k each; the ones that
  stayed small were verifiers of one file. Either split packages further (one file, one concern)
  or budget honestly; an agent told "stay under 250k" that needs 500k just stops reporting usage.
- **Docs after all code, or budget follow-ups.** Three docs agents each needed three follow-up
  passes because fix passes kept landing after they started. Run docs only when the last code
  commit is in, and run V-DOC once; or accept one planned follow-up round.
- **Bash tool runs under zsh: `$var` with several file names does not word-split.** `grep … $D`
  passed one argument containing spaces and silently "found nothing". Use explicit names or an
  array; check for "No such file" warnings before trusting a negative grep.
- **The spec's verified-facts preamble paid for itself**, and it still had two stale lines (the
  `getValidator` layout, `set-rpc`'s first release) that agents caught by checking source. Mark
  every fact with how it was verified, and prefer "checked against tag X" over "known".
- **A whole-diff review still finds things after nine package verifiers.** `/code-review high`
  over the full range found eight more issues, and the important ones sat at seams no single
  package owned: the UI kills `sudo` three seconds after its TERM while the library's wait slept
  in the foreground (so a root script outlived the kill holding the lock); the stake helper took
  the fleet-wide lock before an interactive prompt; the UI probed a public RPC on the request
  thread. Verify per package, then review the range as one change.
- **Two session limits in one run.** The second (13:00 reset) again killed three agents that
  were minutes from done; each time the files on disk were complete and green, and the gate
  plus commit took the orchestrator five minutes. Check the tree before resuming an agent: the
  work is often finished and only the report is missing.
- **Docker can vanish for a whole session.** A `git archive` of the release tag plus `cargo build`
  gave a real v0.15.0 binary in 2.5 minutes, and a downloaded Caddy 2.8.4 stood in for the
  container floor. Record the substitutes in the shared spec so every agent uses the same ones.

## Orchestration: a rate limit mid-plan is a pacing problem, not a loss of work

**Symptom:** while planning the followup.md backlog, the task-decomposer agent died on a 429
(Opus session limit) and the decomposition had to be redone inline. Earlier sessions lost work
the same way when several agents ran at once and the limit landed mid-write.

**Cause:** fan-out width was chosen by how independent the work was, with no ceiling, and the
plan put facts the agents needed (ABI selectors, feature-per-release-tag, live probe results)
only in the orchestrator's head, so a dead agent took its context with it.

**Rules:**
1. Cap concurrency (four agents at once here) and know when the limit resets; wave-0 work
   (specs, venvs, baseline gates, context refresh) needs no Opus agent and runs before it.
2. Write a **verified-facts preamble** (`tasks/spec-fu-shared.md`) before any agent starts: every
   fact an implementer would otherwise re-derive, with the date and how it was checked. Re-verify
   the ones that are cheap to check (a `git grep` against release tags corrected the
   "set-rpc from v0.13.0" claim to v0.12.0 in two minutes).
3. Every agent prompt names its checkpoint file and says "read it first, continue from the first
   unfinished section". After a 429, read the checkpoints on disk *before* assuming anything was
   lost, then `SendMessage` the same agent naming the sections that exist.
4. One committer per repo. Agents that cannot commit cannot half-commit.
5. (Added 2026-10-02 00:20) The cap did not prevent a second 429: the limit is a token budget
   over a rolling window, not a concurrency ceiling. Four Opus agents at 300–500k tokens each,
   back to back for five hours, exhausted it at 00:05 and four agents died at once. What saved
   the work was rule 3: every one of them had a checkpoint with `[x]` sections, and all four
   resumed from the first unfinished section with one message each. Budget guidance: plan for
   roughly 4–5M Opus tokens per window; when the running total nears it, let agents finish and
   hold new spawns until the reset rather than spawning into the wall.

## v0.16 release round (2026-10-09): tokens, toolchains, and parallel docs

- **Check `gh auth status` scopes before planning a push or a PR.** The PAT on xerxes reads the org but
  cannot push to telcoin-network over https (403) or create a PR (`Resource not accessible by personal
  access token`). SSH pushes work (`ssh -T git@github.com` says who you are). Plan the tag push and the
  PR as operator steps, or run `gh auth refresh -s repo` first.
- **Toolchains in containers, recorded as commands.** No pango here, so WeasyPrint cannot run natively:
  `tn-pdf-tools` (debian:12 + static pandoc 3.8.3 + venv WeasyPrint 70.0) runs
  `tools/build-partner-pdf.sh` with `-u $(id -u):$(id -g) -e HOME=/tmp`. UI unit tests need Flask:
  `python:3.10-slim` with `ui/requirements.txt`. bash 3.2: `bash:3.2` for `bash -n` and for harness
  runs (busybox tools, no perl: shim it). Record the exact invocations in the spec so verifiers reuse
  them instead of rediscovering.
- **The independent verifier earned its cost again.** After 174 implementer checks, V-A's own harness
  (incl. the EXIT-trap kill path, the unit-never-starts path and a run against the previous lib for
  skew) found five LOW defects: an octal timeout, a `du` field split on paths with spaces, a
  synthesized `done` without the contract fields, a "left running" message for a node that never
  started, and a re-apply that backs up the wrong binary. Write the harness before reading the
  implementer's checkpoint; test the exit trap and old-lib skew every time.
- **Docs in parallel with verification cost one follow-up.** DOC-A recorded the octal timeout as a
  follow-up item while V-A's fix was landing; the orchestrator had to rewrite the item at commit time.
  Either run docs after the fixes land, or hand the docs agent the verifier's findings list before it
  writes follow-ups.
- **Gate the exit-trap fields on the point of no return.** V-A's patch made every one-way apply's
  synthesized `done` carry `storage_migration:true`; a kill during the epoch wait (node still on the
  old release) would then have told the fleet driver "applied". A flag set right before the four first
  starts (`STORAGE_MIGRATION_STARTED`) is four lines and makes the field truthful.
- **No Claude attribution in commits or PRs (operator rule, 2026-10-09).** Every commit on the
  v0.16.0-adiri branch had to be rewritten with `git filter-branch --msg-filter` and force-pushed to
  drop the `Co-Authored-By: Claude …` trailer before the PR could be opened. Commit messages end after
  the body; PR bodies carry no "Generated with" footer.
