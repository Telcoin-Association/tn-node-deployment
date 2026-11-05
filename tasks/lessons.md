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

## Mainnet hardening round (2026-10-15)

### bash 3.2: a `case` pattern's `)` inside `$( )` fails only when the line runs

**Symptom:** a function that passed `bash -n` under bash 3.2 and `tools/check-bash32.sh`
failed under 3.2 the first time it ran, with ``syntax error near unexpected token `newline'``
on a line that read fine.

**Cause:** bash 3.2 finds the end of a `$( ... )` by counting parentheses instead of parsing
its body, so the `)` of a `case` pattern such as `x)` closes the substitution early. The body is
parsed only when the line executes: `bash -n` never sees the error, and the lint has no rule
for it.

**Rule:** inside `$( )`, never write a `case` with bare `pat)` patterns. Move the `case` into a
function and call the function in the substitution, or write each pattern with its optional
leading parenthesis, `(pat)`. Run new `$( )` code under `bash:3.2` itself, not only `bash -n`.

### A test stub on `PATH` calls the tool it wraps by absolute path

**Symptom:** a fixture test spawned about 70,000 processes on the host before it was killed.

**Cause:** the test put a directory of wrapper stubs first on `PATH`, and the `env` stub ran
the real command through `env`. That `env` resolved through `PATH` to the stub itself, which
called itself again without end.

**Rule:** a stub that wraps a tool calls the real one by absolute path, resolved before the
stub directory goes on `PATH` (`real_env="$(command -v env)"` first, then prepend the stub
dir). Never call the wrapped tool by its bare name from inside the stub.

### Harness counters do not survive a `( ... )` subshell

**Symptom:** a refusal check failed and printed its `FAIL` line, yet the test file's totals
said 0 failed and it exited 0, so the run passed.

**Cause:** `check` counts in `CHECKS` and `FAILS`, variables of the shell that runs it. A check
inside `( export VAR=1; check ... )` runs in a subshell, and its counts vanish when the
subshell exits. The same holds inside `$( )` and in the body of a `... | while` loop.

**Rule:** call `check` only in the test's own shell. To give one call its own environment,
`export` the variable before the call and `unset` it after, or capture the output and exit
code in the subshell and run `check` on them outside it.

### A check pinned to a line breaks when a merge reflows that line

**Symptom:** after a merge, several verifier checks failed although the behaviour they guarded
had not changed. The merge had only rewrapped or moved the lines they matched.

**Cause:** the checks matched a whole source line with a regex, or read a `file:LINE`
position, so they tested the layout of the code rather than what it does.

**Rule:** check behaviour: run the function against a fixture and compare its output, its exit
code or the files it wrote. When a text check is the only option, match the smallest token that
carries the meaning, never a line number or a whole line.

### Nested heredocs need distinct delimiters

**Symptom:** a test that wrote a fixture script through `cat > fx.sh <<'EOF'` got a fixture
cut short, and the rest of the fixture's text ran as commands of the test itself.

**Cause:** the fixture held a heredoc of its own that ended in `EOF`. The first line that is
exactly the delimiter ends the outer heredoc, wherever it sits, so the inner `EOF` closed the
outer document early.

**Rule:** give every heredoc level its own delimiter (the tests use names such as `FIX`,
`STUB`, `SHIM` and `DRV`), and never reuse `EOF` inside a heredoc body. When a fixture looks
truncated, look for its delimiter inside the body first.

### A reader that gains a failure code needs every caller swept

**Symptom:** once `meta_get` returned 2 for a key that appears twice in `.node-meta`, a review
found callers across most scripts and the library that carried on with a default instead: the
default data dir, RPC port 8545, the `binary` install method, testnet as the network.

**Cause:** those callers read `v="$(meta_get KEY 2>/dev/null)" || v=default` (or `|| true`).
They were written when the only failure was a missing key, so they turned the new "duplicated
key" result into the default without a word.

**Rule:** when a helper gains a return code, grep every caller and decide for each one. A value
that picks a path, a network, a binary, a port or an address fails closed with a clear message
(`addon_meta_get` and `rm_meta_get` stop on a duplicate). A read used only for display may fall
back but says so (check-node's `meta_flag` reports the value as unknown with a warning). Never
hide a new failure mode behind `2>/dev/null`.

### A trailing echo hides a background command's exit status (2026-10-21)

A long attestation run was started in the background as `attest.sh X; echo "exit=$?"`. The
notification said "exit code 0" because the echo was the last command, the run had in fact
failed one test, and the branch was pushed before the log was read.

**Rule:** a background command whose exit status decides the next step ends with that command
(or `rc=$?; ...; exit $rc`), never with an echo. Read the run's own result line in its log
before any push, merge or "done"; the harness's exit summary is not the evidence.

### An unreadable answer is not a negative answer (2026-10-30)

**Symptom:** the committee guard treated a node whose `tn_nodeMode` call failed (timeout,
connection refused, method not found) as "authored nothing, so already among the down" and let
it stop. A voting node with a slow or mis-ported RPC is among the authors of the latest commit,
so the prospective count was one short and the guard could allow the stop that halts consensus.

**Cause:** a failed read was folded into one of the two real answers instead of being kept as a
third state. The epoch wait next to it already failed closed on the same input.

**Rule:** when a check reads a fact that decides a destructive step, a read that fails is its own
case and takes the safe branch. The unsafe branch needs a positive proof from another source
(here: `tn_info` on the node itself returning an authority id that is absent from the counted
commit). Grep for the sibling checks that read the same fact and make them agree.

### A cleanup that reuses a rollback helper restores what must stay (2026-10-30)

**Symptom:** the one-way update's failure path said "Not rolled back" and then called the
`--discard` helper to clear the pending state, which also put the old unit, start script and
node.env back while the new release was running on a migrated data dir.

**Cause:** "clear the state" and "undo the apply" were one function because every earlier caller
wanted both.

**Rule:** split "forget" from "undo". A failure path after an irreversible step clears bookkeeping
with a helper that restores nothing, and the irreversible step persists a marker so a later
`--discard` run by a different process makes the same choice. Write a static fixture check that
the failure function never calls the restore helper.

### A render helper with optional arguments lets a second caller drop installation-specific settings (2026-10-30)

**Symptom:** the Alloy config writer took `dest`, `logdir` and `group` as optional arguments; the
enable path passed the native log dir and the service group, the partial-disable paths passed
nothing, so a native host got a root-owned config pointing at the wrong log path, and the restart
failure after it was hidden by `|| true`.

**Cause:** the knowledge of what the installation needs lived in one caller, not in the helper.

**Rule:** a helper that renders a file for an installation derives the installation-specific
values itself (from `.node-meta`) and takes no optional arguments for them; callers that need a
different file call a different helper. A restart whose success the caller reports must be
checked (is-active for a few seconds) and its failure propagated, never `|| true`.


## Partner documents round (2026-10-15): WeasyPrint determinism, review scope, agent conventions

- **WeasyPrint names raster image objects after `md5(url)` of the resolved file URL** (images.py
  line 327 in 70.0), so a stylesheet that references a PNG by path makes the PDF's bytes depend on
  the checkout path: the guide (fonts and SVG logos only) was byte-identical from any path, the
  specification (cover PNG) was not, and a fresh clone reported "toolchain drift" for unchanged
  sources. Fonts are embedded by content and SVGs are drawn as vectors. Fix at build time: stage
  the stylesheet beside the HTML with raster `url()`s inlined as data URIs (10b666e). Test
  "byte-identical" claims from a second worktree at a different path, not with a second run in
  the same tree.
- **Re-verify every PR pointer in an approved plan against `git log <old>..<new>` before briefing
  agents.** The plan listed the region-aware committee draw (#1279); #1328 removed it before the
  tag. The facts preamble (`tasks/spec-refresh-facts.md`) caught it in two minutes and no agent
  wrote it up.
- **"Missing" findings inflate a refresh.** Eight reviewers returned 40 additions beside 108
  corrections and the document grew from 493 to 742 lines (25 to 38 pages) before the fidelity
  reviewer classified every addition (5 partner-needed, 18 out of scope). Next time: brief
  reviewers that `missing` means a fact without which a corrected sentence is untrue, and have
  consolidators apply only riders attached to a correction, with standalone additions listed for
  triage instead of applied.
- **Two transcribers diverged on one rule.** T1 and T2 got the same code-span instruction and
  applied it differently (type names, status names); the consolidators had to harmonise and C1's
  reading had to be relayed to C2 mid-flight. Give a convention as an explicit list with examples
  of both sides, not a principle.
- **Independent reviewers converged on the same error from different chapters** (the committee
  "N+2" sentence, found by Q1 from chapter 6's wording and by Q2a and Q2b from the contract).
  Cross-chapter consistency checks in the review briefs paid for themselves; keep them.
- **A reference artefact captured mid-stream caused a false alarm.** The pdftotext reference was
  taken at 35 pages, one sentence tightening later made it stale, and a `diff && commit` chain
  silently skipped the commit. Compare against the committed object (`git show HEAD:path`), and
  never chain a commit behind a check whose failure is silent.
- **Splitting the consolidation into two agents on scratch copies joined at a chapter heading**
  (C1: title and chapters 1-5, C2: chapters 6-10, each with its own log) kept both under 220k
  tokens and let C1 start before the last reviewer finished. The join was one `sed` and a diff
  of the untouched half. Reuse the pattern for long documents.

## Guide 1.4 refresh (2026-10-15): numbers in a facts preamble need the code line that computes them

- **A figure derived from doc prose plus one code constant was wrong.** The plan computed the
  header reject threshold as "1 s rounded tolerance + 5 s vote timeout = 6 s" from the upstream
  hardware page and `vote_timeout`'s default. The code rounds the tolerance only for the hold
  check and adds `vote_timeout` to the raw 250 ms for the reject check (handler.rs:775-788), so
  the honest figure is 5.25 s on a current config and 6 s only on an older one. The verifier
  caught it because its brief said "re-derive from the source FIRST, then read the facts file".
  Rule: every number in a facts preamble cites the line that performs the arithmetic, not the
  prose that describes it, and the verifier always reads the code before the writers' notes.
- **A PR title is not a cause.** "#1543 worker RPC keeps its port bound" became "a node with
  more workers than the network requires", but the code only deactivates a worker that was
  active and then dropped by a lower on-chain count; an extra worker is never initialised.
  Rule: for a troubleshooting row, read the code path that produces the symptom, not the
  change description.
- **"Shutdown" in a log line is not process exit.** `initiating node shutdown` fires a per-epoch
  notifier; the process stays up with a sticky failure latch. Leaving the row's wording
  deliberately neutral and giving the verifier the exact trace (task manager exit arms, the
  epoch loop, the latch) settled it in one pass. Rule: when a plan says "the verifier settles
  it", hand the verifier the file list and the question, and keep the writer's text neutral.

## Partner documents refresh to main (2026-11-03): a release-vs-main wording needs each fact checked at the tag

**Symptom:** the orchestrator's decision for the writers said "on `v0.16.0-adiri` move
`consensus-db/epoch` aside" for the `Cannot check database (epoch)` row. Two verifiers found the
tag has no such check at all (`epoch_db_recovery.rs` came with #1572, after the tag), so the
"today's behaviour" half of the sentence described a release that never prints the line. The
same gap hit the six opt-in `network-config` keys, the two `-32000` worker messages and the
62 GiB reservation: all main-only, all written as if the tag had them.

**Cause:** the facts units were told to cite main at the pinned sha, and the earlier guide (1.4)
had already described main at 98849a221 as current behaviour. When the new round added "name
the release where an operator acts differently", nobody checked which side of the tag each
fact sat on; the decision was written from the facts file, not from `git grep <string> <tag>`.

**Rule:** a document that names a release for "today's behaviour" needs, for every such fact, a
citation at that tag (`git -C <wt> show <tag>:<path>` or `git grep -n '<string>' <tag>`) beside
the one at main. The facts units record both or say "absent at the tag". A wording decision that
contrasts two releases is itself a fact to verify, and the verifier's brief lists the tag check.

## Follow-ups round (2026-11-03, scripts-v2.1.0): toolchains, lints and agent rounds

### The `bash:3.2` image is busybox, not macOS

**Symptom:** every fixture passed locally under bash 5.3, `bash:3.2` and `ubuntu:24.04`, and the
CI job "fixture tests (macOS bash 3.2)" was red on three successive tips: a library line used
GNU `stat -c %Y` (the shared test library's BSD shim maps `-c` formats to `-f` and lacked `%Y`,
so macOS printed an empty mtime), and a fixture passed a multi-line value through `awk -v`,
which BSD awk refuses.

**Rule:** the macOS runner is the only BSD-userland gate; the three local environments do not
cover it. Grep every new `stat -c`, `awk -v` with newlines, `sed -i`, `date -d`, `readlink -f`
and `sha256sum` in fixtures and in library lines a fixture exercises; keep the test library's
shim table complete (`tools/tests/lib.sh`, now with `%Y`); watch the macOS job after every push
and read its FAIL lines, not only the local counts. A `check_has` on the whole line prints the
actual output in the CI log; a yes/no `check` hides it. The update lock is the other BSD
difference: macOS has no `flock`, so the library takes its mkdir fallback and removes the lock
directory on release; a fixture that infers "the lock was taken" from what persists after the
run passes only with flock. Record the lock kind from inside the locked call instead, and run
the fixture once in `bash:3.2` with `flock` removed (`rm -f /usr/bin/flock`) to see the fallback.

### Verifier harness files are tracked scripts: CI lints them

**Symptom:** V2's committed reproduction scripts had no shebang and one harness called a
wrapped tool before its function was defined, so the shellcheck job would have gone red on the
records commit.

**Rule:** every verifier brief says that its `tasks/verify-fup/<name>/*.sh` files pass
`shellcheck --severity=error` under 0.9 and 0.11, `bash -n` under 5.3 and 3.2 and
`tools/check-bash32.sh`, with a shebang; the orchestrator runs those lints on the records before
cherry-picking them.

### A tree-wide lint applies to the orchestrator's own commits

**Symptom:** a one-line comment I wrote named a testnet host, the new network-hits lint failed
on the tree, and the fixture that runs the lint over the repository would have failed CI.

**Rule:** once a tree-wide lint lands, the quick gate runs it before every push, including the
orchestrator's seam fixes; comment lines count.

### Commit messages go through a file, never a chained heredoc

**Symptom:** six commits lost their subject lines because the agent wrote
`git commit -F - <<'MSG' && …`: the heredoc's first line became part of the command.

**Rule:** write the message to a file and `git commit -F <file>`; check `git log --format=%s`
before handing back. The orchestrator amends on cherry-pick when it happens anyway.

### An independent verifier per package, then a round back to the implementer, paid again

Six verifiers over nine packages found one latent fail-open path (a Docker image given by
digest skipped the mainnet rule in setup-node), one regression (a push-URL override lost on
rotate and partial disable), a boot-persistence gap in the firewall limit, a probe-wrapper
failure read as a negative answer, and twenty-odd warnings, after the implementers' own 4,000
checks had passed. Sending each list back to the implementer that owns the file (with its
checkpoint and worktree still in place) cost one short round per package and kept one owner per
file; the orchestrator fixed only the seams between packages.

### Cherry-pick order within a batch does not matter; conflicts at file tails do

Packages that append test blocks to the same fixture file conflict trivially at the tail; a
"# PKG" block header and a note to append before `finish` made every one a keep-both
resolution. The order of cherry-picks only changes which side is HEAD.

## Round 2 on PR #59 (2026-11-04): a `printf | grep -q` check under an inherited pipefail

**Symptom:** `remove_test.sh` under `bash:3.2` reported `FAIL legacy key shredded` with
`missing line: shred -u -- …/bls.key` while the very same line was the first line of the
output it printed, plus `tools/tests/lib.sh: line 182: printf: write error: Broken pipe`.
One run in ten; never on the host.

**Cause:** the fixture sources `remove-node.sh`, which sources `lib/common.sh`, which sets
`pipefail`. `check_has` ran `printf '%s\n' "$3" | grep -qxF -- "$2"`: grep matched the first
line and exited, printf got EPIPE on the rest, and with pipefail the pipeline failed.

**Rule:** a test helper that feeds a `grep -q` never uses a pipe; use a here-string
(`grep -qxF -- "$2" <<< "$3"`) or a file. More generally, assume every fixture runs with
pipefail inherited from the library it exercises, and grep the test library for
`| grep -q` after adding a helper.

## Round 2 on PR #59 (2026-11-04/05): budgets, refused report files, load flakes

### Package sizes were wrong by a factor of two

**Symptom:** the three main implementers finished at 430k (SIG), 458k (IMG) and 312k (UPS)
tokens against a "well under 250k" budget; the two V7 verifiers at 366k and 401k. None stopped
to checkpoint and hand back; all finished green.

**Rule:** a package that touches three self-contained scripts plus their fixtures (SIG) or six
call sites plus UI twins (IMG) is two packages. Split by file ownership before spawning
(release-scripts + install.sh / update-scripts + cut-release; library + UI / call sites), and
give a verifier one package, not two. When an agent is over budget at hand-back, spawn a fresh
agent for its fix round from the integration tip instead of resuming it (IMG-2 did this).

### A verifier may be refused its own report file; plan the hand-back

**Symptom:** both V7 verifiers had `Write` refused for `tasks/verify-r2/<name>/REPORT.md`
("report-file rule") while their harness scripts wrote fine; V8 wrote its report without issue.
They returned the full text in the final answer and the orchestrator saved it unchanged.

**Rule:** every verifier brief says what to do when Write is refused (return the complete text,
never work around it), and the orchestrator budgets the save: one heredoc per report, then lint
and commit the records together.

### Fixture flakes under host load are not package failures

**Symptom:** with four agents running fixture suites at once (load average around 20),
`host_baseline_test`, `docker_image_test` and `remove_test` each failed one run and passed every
rerun; the macOS CI job failed one check with an empty captured output on a commit whose code
had been green before and was green after.

**Rule:** a single failing run under load is rerun alone before anything is changed; a CI
failure on a commit that touches no code the failing fixture exercises is confirmed against the
next push before it is investigated. Record the flake, not a fix.

### An agent that mounts `$PWD` into a container must be in its worktree

**Symptom:** a backgrounded subshell in IMG lost its `cd` and ran two container fixture suites
against the main checkout (another stream's tree) instead of the worktree; read-only, but the
results were for the wrong tree and had to be discarded.

**Rule:** in agent briefs, every docker command uses the worktree's absolute path
(`-v /home/.../tnd-r2-<pkg>:/w`), never `$PWD`, and a hand-back names the tree each count was
measured on.
