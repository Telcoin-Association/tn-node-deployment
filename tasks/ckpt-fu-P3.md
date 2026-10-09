status: done

# P3 checkpoint (bash 3.2 compatibility pass + lint tool)

Owned files: tools/check-bash32.sh (new), remove-node.sh, migrate-node-naming.sh,
update-scripts.sh, install.sh.

## Sections

- [x] 1. tools/check-bash32.sh (lint + fixtures + before-run on the repo)
- [x] 2. remove-node.sh 1.2.9 (indexed arrays parallel to INSTALLED_UNITS, harness)
- [x] 3. migrate-node-naming.sh 1.2.1 (no local -n, meta_unset NODE_TYPE, stake-status text, harness)
- [x] 4. update-scripts.sh (FILES_TO_UPDATE at top level, unused maps deleted, check_versions harness)
- [x] 5. install.sh (runbook URL at the end; readonly TN_OPERATOR_GUIDE_URL literal mirroring
  lib/common.sh; run with HOME in the scratchpad + a git shim under 3.2 and 5: completes,
  prints "Operator runbook:   <url>", URL byte-identical to the library constant)
- [x] 6. Gates on every touched file
- [x] 7. Closing headings

## Notes

Scratchpad: `<scratchpad>/p3/` holds gen-lint-fixtures.sh, test-lint.sh and the generated
`lint/` fixtures (pos/ 54 files, neg/lookalikes.sh, err/ 3 files, clean.sh, adir/).

### Section 1 (done)

tools/check-bash32.sh, mode 755, bash 3.2 clean, one `LC_ALL=C awk` pass per file (file on
stdin, name via ENVIRON so awk never parses it). Scanner tracks bash quoting across lines
(contexts: top level, `$( )`/`(( ))`, backticks, double, single, `$'...'`), skips comments
(a `#` starting a word), skips heredoc bodies (queue of openers, `<<-` tab-stripped
terminators, quoted/unquoted delimiters), and suppresses lines containing `# bash32-ok`.
Command-style checks need command position (line start or after `; & | ( { !` or a backtick,
then optional keywords `then do command builtin ...` and prefix assignments), so
`command -v mapfile` and `echo mapfile` are quiet.

Decisions beyond the brief (report in the hand-back):
- Unquoted heredoc bodies still get the expansion checks (`${v,,}`, `${v@X}`, `${a[-1]}`),
  because the running shell expands them; `\${v,,}` and quoted heredocs are skipped. The
  brief's negative fixture "`${var,,}` inside a heredoc body" therefore lives in quoted
  heredocs (`<<'EOF'`, `<<"EOF"`, `<<\EOF`) and as `\${var,,}` in unquoted ones.
- Extra constructs in the same families: `declare/typeset/local -l/-u`, `readonly -A`,
  `[ -v` / `test -v`, any `wait` option (`wait -f` too).
- A file that ends inside a quote, substitution or heredoc is exit 2 with a message, so a
  scanner desync can never pass a file silently.
- Quoted `;;&` on a printf line is NOT flagged (quotes are tracked); `# bash32-ok` remains
  available for any false positive.

Fixture results: `test-lint.sh` 68 passed, 0 failed under `/bin/bash` 3.2.57 and under bash
5.3.15. All fixtures parse with bash 5; the negative parses with 3.2. `/bin/bash -n` itself
already rejects `&>>`, `|&`, `;&`, `;;&`, `coproc`, `[[ -v`; it does not catch `declare -A`,
`local -n`, `${v,,}`, `mapfile`, `${a[-1]}`, `${v@Q}`, `printf %()T`, `wait -n`.

Before-fix repo run (`*.sh lib/*.sh ui/*.sh ui/tests/*.sh tools/*.sh lib/wgvpn/*.sh`, 25 files,
same result under bash 3.2 and 5; lib/common.sh and update-node.sh were modified in the tree
by other packages at the time and scanned clean):

```
migrate-node-naming.sh:394: local -n -- local -n moved_ref="$arr_name"   # nameref (bash 4.3+; node is Linux bash 4+)
remove-node.sh:121: declare -A -- declare -A UNIT_DOCKER=()
remove-node.sh:122: declare -A -- declare -A UNIT_USER=()
remove-node.sh:123: declare -A -- declare -A UNIT_GROUP=()
update-scripts.sh:203: declare -ga -- declare -ga FILES_TO_UPDATE=()
update-scripts.sh:204: declare -gA -- declare -gA LOCAL_VERSIONS=()
update-scripts.sh:205: declare -gA -- declare -gA REMOTE_VERSIONS=()
check-bash32: 7 bash-4 construct(s) in 3 of 25 file(s)
```

Exactly the shared spec's "still present until P3 lands" list; no extra hits.

### Section 2 (done)

remove-node.sh 1.2.9: `UNIT_DOCKER`/`UNIT_USER`/`UNIT_GROUP` are `declare -a` arrays aligned
with `INSTALLED_UNITS`; new `unit_index UNIT` (prints index, rc 1 when absent) and
`forget_unit UNIT` (rebuilds all four, keeps empty-string slots). `detect_node_installs`
appends to all four together; `show_detected` walks by index; `remove_node_unit` reads the
unit's docker/user/group by index once at the start and prunes with `forget_unit`. Empty-safe
`${a[@]+"${a[@]}"}` in `unit_index`, `forget_unit`, `remove_all_nodes` (snapshot and loop),
`wipe_chain_data_only`, `scan_custom_installs` (custom_svcs, custom_ctrs). `partial_items`
loops left as-is (only reached when non-empty).

Harness `<scratchpad>/p3/rn-harness.sh` (fake root via TN_ROOT_PREFIX + sed of
/etc/systemd/system in the copy; shims for systemctl, docker, timeout, find, pgrep, getent;
side-effecting steps stubbed to a call log):
- unit mode: 21 passed, 0 failed under /bin/bash 3.2.57 and bash 5.3.15 (lookup and prune
  with zero, one, three units incl. empty user/group slots; detection of 0/1/3 units;
  remove_all_nodes, wipe_chain_data_only, scan_custom_installs with zero units survive set -u).
- scenarios: new file transcripts identical under 3.2 and 5. HEAD (bash 5) vs new (bash 5):
  identical call logs (stop, docker-rm only for docker units, user/group args, shared
  remaining=3,2,1, ui-offer); only diff is the post-run state line, where HEAD left the
  name-keyed maps populated (n=0,3,3,3) and the new prune clears all four (n=0,0,0,0).
- HEAD under /bin/bash 3.2: dies at source time, `declare: -A: invalid option`.

### Section 3 (done)

migrate-node-naming.sh 1.2.1: `relocate_dir` no longer uses `local -n`; it refuses any list
name other than CONFIG_MOVED/DATA_MOVED before moving anything, appends through a `case`,
and counts with a local `moved` for the summary line. Rollback loops use
`${X_MOVED[@]+"${X_MOVED[@]}"}` (it still runs `set +eu`). `update_meta` removes NODE_TYPE
with `meta_unset` (soft guard: when lib/common.sh predates 1.5.0, `sed -i -E
'/^NODE_TYPE=/d'` instead, so a half-updated box does not roll the migration back on
"command not found"). The already-migrated branch no longer calls `tn_resolve_node_type`
("Nothing to do." only, still a no-op). Header, usage text, update_meta comment and report
now say the validator view follows the on-chain stake status (ConsensusRegistry
getValidator / node_stake_status) instead of `tn_isValidator`. The UI reads a missing
NODE_TYPE as "observer" (ui/server.py resolve_node_type), the value 1.2.0 used to write.

Harness `<scratchpad>/p3/mg-harness.sh` (readonly /etc,/var,/opt paths sed-pointed at a fake
root; shims for systemctl and a GNU-style `sed -i`): 37 passed, 0 failed under /bin/bash
3.2.57 and bash 5.3.15. Covers relocate_dir with dotfiles+subdir under the armed ERR trap,
src==dst, empty source dir (0 entries, set -u), unknown list name, collision (flag stays
false); rollback with empty lists under set -u and with real lists (entries moved back);
update_meta under the armed trap with meta_unset and with the pre-1.5.0 fallback (NODE_TYPE
gone, foreign keys kept, mode 600, VALIDATOR_ADDRESS recorded); already-migrated branch;
usage text. HEAD under /bin/bash 3.2: relocate_dir fails `local: -n: invalid option`, the ERR
trap fires and the migration rolls back; HEAD under bash 5 passes the same relocate case.
Note: `rollback` returns 1 when META_BAK is empty (its last line is `[[ -n ... ]] && ...`);
pre-existing and harmless, on_error exits 1 anyway.

### Section 4 (done)

update-scripts.sh (SCRIPT_VERSION left at 1.1.69 for the release commit): `FILES_TO_UPDATE=()`
at top level after the bundle arrays, with a comment; `check_versions` resets it with a plain
assignment; `declare -ga FILES_TO_UPDATE`, `declare -gA LOCAL_VERSIONS`/`REMOTE_VERSIONS` and
the two map writes deleted (grep of the whole repo: written, never read). download_updates
loops untouched (only reached with a non-empty list). gen-checksums' extraction of the
three arrays gives the same 34 paths from HEAD and the edited file.

Harness `<scratchpad>/p3/us-harness.sh` (copy installed in a fake SCRIPT_DIR, PATH curl shim
serving a fake raw tree, every scenario under `set -e`): A full 18-row table (2 rows served,
14 MISSING, 2 Cannot check) -> rc 0, 14 entries; B two current rows -> "All scripts are up to
date", exit 0; C one update -> 1 entry; D offline -> "Cannot reach", exit 1; E check_versions
then download_updates "y" -> 3 files downloaded and sha256-verified, new content installed.
New file: transcript identical under /bin/bash 3.2.57 and bash 5.3.15. HEAD under bash 5:
identical to the new file. HEAD under /bin/bash 3.2: A, C and E die with `declare: -g:
invalid option` (exit 2) right after the connectivity probe.

### Section 6 (done)

All five files: `/bin/bash -n` and `bash -n` pass; `shellcheck -x --severity=error` clean;
`/bin/bash tools/check-bash32.sh <five files>` clean. Warning-level shellcheck, HEAD vs new by
code+message: remove-node 5 = 5, migrate 0 = 0, install 0 = 0, update-scripts 4 -> 2 (the two
SC2034 "LOCAL_VERSIONS/REMOTE_VERSIONS appears unused" are gone), check-bash32.sh 0. After-fix
repo run: `check-bash32: clean, 25 file(s) scanned`, exit 0, under /bin/bash and bash 5; also
clean over `git ls-files '*.sh'` plus the new tool.

## Operator-visible changes

- remove-node.sh 1.2.9: runs under macOS /bin/bash 3.2 (it stopped at `declare: -A: invalid
  option` while being sourced). On Linux the prompts, teardown order and output are unchanged.
- migrate-node-naming.sh 1.2.1: after migrating, `.node-meta` has no `NODE_TYPE` line (1.2.0
  wrote `NODE_TYPE=observer`; the UI reads a missing hint as observer). New text: usage says it
  "removes the old NODE_TYPE hint from .node-meta (the validator view follows the on-chain stake
  status)"; the step line says "NODE_TYPE removed"; the report shows "NODE_TYPE:  removed (the
  validator view follows the on-chain stake status)" and its closing paragraph names
  ConsensusRegistry getValidator instead of tn_isValidator; the already-migrated message is
  "Nothing to do." (no "NODE_TYPE=<x>." line). Relocation works under bash 3.2.
- update-scripts.sh: runs under macOS /bin/bash 3.2 (check_versions exited 2 with `declare: -g:
  invalid option` right after the connectivity check). Linux output unchanged. No version bump
  in this package.
- install.sh: the closing block adds `Operator runbook:   https://github.com/Telcoin-Association/tn-node-deployment/blob/main/OPERATOR.md`
  above the existing "Full documentation" line.
- tools/check-bash32.sh: maintainer only, never shipped.

## Changelog text

### remove-node v1.2.9 — runs under macOS /bin/bash 3.2
The install method, service user and service group of each detected unit moved from three
associative arrays (`declare -A`, bash 4 only) to indexed arrays kept in step with the list of
installed units, so the script no longer stops at `declare: -A: invalid option` on macOS.
Removing a node prunes all four lists together, and the lists that can be empty (no node
installed, no custom installs found) no longer abort with "unbound variable" under bash 3.2.
Prompts, teardown order and output are unchanged.

### migrate-node-naming v1.2.1 — no nameref; NODE_TYPE removed instead of written
The directory move no longer uses a bash 4.3 nameref (`local -n`), which failed under bash
3.2 and rolled every migration back. The migration now removes the old `NODE_TYPE` hint from
`.node-meta` instead of writing `NODE_TYPE=observer`; a missing hint reads as the plain
full-node view, as before. The already-migrated check no longer prints the hint, and the help
text and final report say the validator view follows the on-chain stake status (ConsensusRegistry
`getValidator`) rather than `tn_isValidator`.

### update-scripts v<set in the release commit> — runs under macOS /bin/bash 3.2
`check_versions` declared its update list with `declare -ga` and two version maps with
`declare -gA`. bash 3.2 has no `declare -g`, so on macOS the updater exited with `declare: -g:
invalid option` right after the connectivity check. The list is now a top-level array and the
two maps, which nothing read, are gone. Linux behaviour and output are unchanged.

Not updater-tracked, for CHANGELOG.md or the release notes if wanted: `install.sh` ends with a
link to the operator runbook (`OPERATOR.md`); new maintainer tool `tools/check-bash32.sh` flags
bash 4+ syntax that `bash -n` under 3.2 does not catch.

## Tests run

Scratchpad `<scratchpad>/p3/`; every harness sources its copy at top level.

- Lint fixtures: `/bin/bash p3/gen-lint-fixtures.sh p3/lint`, then `test-lint.sh /bin/bash p3/lint`
  and `test-lint.sh bash p3/lint`: 68 passed, 0 failed on each (54 positive files, each exactly
  one hit with the expected label; the negative look-alike file clean; usage, directory, missing
  file, unknown option, `--`, open quote/heredoc/substitution exit codes; mixed-run summary;
  self-check).
- Lint before fixes, repo (`*.sh lib/*.sh ui/*.sh ui/tests/*.sh tools/*.sh lib/wgvpn/*.sh`, 25
  files), exit 1:
  `migrate-node-naming.sh:394 local -n`; `remove-node.sh:121/122/123 declare -A`;
  `update-scripts.sh:203 declare -ga`, `:204 declare -gA`, `:205 declare -gA`
  ("7 bash-4 construct(s) in 3 of 25 file(s)"). Exactly the known list.
- Lint after fixes, same set: "check-bash32: clean, 25 file(s) scanned", exit 0 (bash 3.2 and 5).
- remove-node: `rn-harness.sh <file> unit` 21/21 under /bin/bash 3.2.57 and bash 5.3.15;
  scenario transcripts new(3.2) == new(5); HEAD(5) vs new(5) identical call logs, only the
  post-prune state line differs (HEAD kept stale map keys); HEAD under 3.2 fails at source.
- migrate-node-naming: `mg-harness.sh <file> full` 37/37 under 3.2 and 5; HEAD relocate case
  under 3.2 fails `local: -n: invalid option` and rolls back, passes under 5.
- update-scripts: `us-harness.sh <file>` transcripts new(3.2) == new(5) == HEAD(5) for five
  scenarios (full table, all current/exit 0, one update, offline/exit 1, download_updates with
  sha256 sidecars); HEAD under 3.2 exits 2 `declare: -g: invalid option`. gen-checksums'
  extraction yields the same 34 tracked paths from HEAD and the edited file.
- install.sh: run with HOME in the scratchpad and a git shim, `--yes`, under 3.2 and 5:
  completes, runbook URL byte-identical to `TN_OPERATOR_GUIDE_URL` in lib/common.sh.
- Gates: see section 6.

## Open issues

1. CI wiring (orchestrator owns `.github/`): add to the macOS job, after the parse check,
   `/bin/bash tools/check-bash32.sh $(git ls-files '*.sh')`. Clean on today's tree.
2. Deliberate departures from the brief in the lint, for review: (a) unquoted heredoc bodies
   still get the expansion checks, because the running shell expands `${v,,}` there; quoted
   heredocs and `\${v,,}` are skipped, and the negative fixture's heredoc case uses those forms;
   (b) extra same-family constructs: `declare/typeset/local -l/-u`, `readonly -A`, `[ -v` /
   `test -v`, any `wait` option; (c) a file that ends inside an open quote, substitution or
   heredoc exits 2 with a message rather than passing unchecked; (d) quoted `;;&` on a printf
   line is not flagged (quotes are tracked).
3. The lint was run only with macOS awk (BWK, version 20200816); no mawk or gawk on this host.
   The program avoids interval expressions, POSIX character classes and gawk extensions; it
   uses ENVIRON and /dev/stderr, which mawk and gawk support.
4. Extra lint hits outside my files: none, before or after.
5. Docs (handled centrally): README.md lines 68-70 say `.node-meta` "still records a
   `NODE_TYPE=` key (new installs write `NODE_TYPE=observer`)". Once setup-node 1.3.0 (P4a)
   and migrate-node-naming 1.2.1 land, neither writes it. README line 1137 is a historical
   changelog entry; leave it.
6. Nodes migrated by 1.2.0 keep `NODE_TYPE=observer`; re-running 1.2.1 on them stays a no-op
   (idempotency kept), so the line stays until something else rewrites the meta. Harmless:
   the UI treats it the same as a missing hint.
7. Pre-existing, left alone (compatibility pass): migrate-node-naming.sh defines its own
   `meta_set` (sed with `#` as delimiter) that shadows lib/common.sh's validated `meta_set`;
   a value containing `#` would break it. `rollback()` returns 1 when there is no meta backup;
   on_error exits 1 regardless.
8. update-scripts.sh `download_updates` loops still use plain `"${FILES_TO_UPDATE[@]}"`. They
   are safe because the list is never empty there (check_versions exits 0 first); left as-is
   to keep the updater diff minimal.
9. Sidecars: I never ran gen-checksums.sh or touched a `.sha256`. Another run regenerated every
   sidecar at 20:55:03, after my last edit (20:53:01); remove-node.sh.sha256,
   migrate-node-naming.sh.sha256 and update-scripts.sh.sha256 match my final files. The
   update-scripts.sh sidecar changed while its SCRIPT_VERSION is still 1.1.69 (bump pending in
   the release commit).

## Follow-up (coordinator, 2026-10-02)

status: done. Versions unchanged (migrate-node-naming 1.2.1, update-scripts 1.1.69). The
committed P3 files (78d9f46) were edited in place; package D's uncommitted prepare-stake.sh
rows in update-scripts.sh and install.sh are kept. Baselines in the harnesses are now pinned:
d1593ae (parent of 78d9f46, before P3) and 78d9f46 (P3 as committed); `p3/rerun-all.sh`
re-runs everything.

- [x] F1. migrate-node-naming.sh: the private sed-based `meta_set` is deleted; the four calls
  (DATA_DIR, RPC_PORT, WS_PORT, VALIDATOR_ADDRESS, all into `${UNIFIED_CONFIG_DIR}/.node-meta`)
  are unchanged and now reach lib/common.sh's `meta_set`. No old-library fallback: the library
  has defined `meta_set KEY VAL [FILE]` since 1.3.0 (4fe6351, 2026-06-17), and this script was
  added in a12c8b4 (2026-06-25) beside library 1.3.4, which already had it. Differences from the
  private copy: the key moves to the end of the file and duplicate `KEY=` lines collapse to one
  (readers take the first match either way); `#`, `&`, `\` and `=` in a value are stored as given
  (the old sed failed on `#`, which tripped the ERR trap and rolled the migration back, and
  turned `&` into the matched text). Header comment now names meta_set/meta_unset as library
  helpers; the `meta_unset` soft guard (1.5.0) stays.
- [x] F2. update-scripts.sh: `source lib/fallback.sh 2>/dev/null || true` is now
  `if [ -r "$f" ]; then source "$f" 2>/dev/null || true; fi`. The inner `|| true` is kept on
  purpose so a present file behaves exactly as before on bash 5. Probe: under 3.2 + `set -e`,
  `|| true` rescues neither a missing file (exit 1) nor a failure inside a present file
  (failing top-level command exit 1, syntax error exit 2); bash 5 rescues all three. So on 3.2
  the guarded form equals `[ -r ] && source`, and on 5 it keeps the old tolerance. fallback.sh
  ends with a function definition and sources cleanly.
- [x] F3. grep of remove-node.sh, migrate-node-naming.sh, update-scripts.sh, install.sh and
  tools/check-bash32.sh: no other `source … || true` / `. … || true`. The plain
  `source lib/common.sh` in remove-node.sh and migrate-node-naming.sh stays unguarded: both
  scripts need the library and cannot run without it.

Tests (`/bin/bash p3/rerun-all.sh`):
- lint fixtures 68/68 (3.2), 68/68 (5).
- remove-node: unit 21/21 (3.2), 21/21 (5); scenarios new 3.2 == new 5; d1593ae(5) vs new(5)
  differ only in the two post-prune state lines; file unchanged since 78d9f46.
- migrate-node-naming: full 45/45 (3.2), 45/45 (5) (37 earlier + T12 meta_set is the library's,
  no sed + T13 DATA_DIR `ROOT/mnt/data #1=a&b c` stored once and exactly, read back by meta_get,
  foreign `KEEP=x=y z` untouched, RPC/WS updated, trap armed, no rollback). metadump new vs
  78d9f46: identical under 3.2 and 5 for ordinary values and for duplicate keys; for the
  special-character data dir 78d9f46 rolls back (DATA_DIR and RPC_PORT left unchanged) and the
  new file completes with the exact value. d1593ae under 3.2 still shows `local: -n`.
- update-scripts: five scenarios new 3.2 == new 5; vs 78d9f46(5) the only differences are
  package D's prepare-stake.sh row (one more MISSING row, 15 instead of 14). d1593ae under 3.2:
  4 of 5 scenarios (A, B, C, E) die on `declare -g` (my earlier note said A, C, E; B dies too).
  Lone copy (directory holding only update-scripts.sh, main included, curl+clear shims, "y"):
  new file rc 0 under 3.2 and 5, lib/fallback.sh downloaded with its sidecar verified and
  installed; 78d9f46 under 3.2 rc 1 with no output at all (died at the source line).
- install.sh: rc 0 under 3.2 and 5, runbook URL equals TN_OPERATOR_GUIDE_URL.
- Gates: bash -n 5/5 files under 3.2 and 5; shellcheck --severity=error clean on all five;
  check-bash32 clean on the five and on the repo (26 files, prepare-stake.sh included);
  warning-level shellcheck vs 78d9f46: migrate 0 = 0, update-scripts 2 = 2.

Changelog additions (append to the P3 entries above):
- migrate-node-naming v1.2.1: "`.node-meta` keys are written with the library's `meta_set`, so a
  custom data directory whose path holds `#` or `&` no longer breaks the migration (the old
  sed-based writer rolled it back on `#` and mangled `&`)."
- update-scripts: "A first run from a lone copy of the updater (no `lib/` yet) no longer exits
  silently under bash 3.2: `lib/fallback.sh` is sourced only when it is present."

For tasks/lessons.md (orchestrator): extend the `source missing-file || true` lesson. Under 3.2
+ `set -e`, `|| true` also does not rescue a failure inside a present sourced file; guard the
file and keep sourced files free of failing top-level commands.

## Fix pass (V-CORE-2)

status: done. Versions stay (update-scripts 1.1.69, remove-node 1.2.9). Pre-fix-pass
baseline pinned to f918d4f (holds every file as committed before this pass).

- [x] lint (findings 4, 11): `)` in the command-position class (one-line case arms);
  `${v~}`/`${v~~}`; negative subscripts inside `(( ))`/`$(( ))` via a new arithmetic view
  (`a[--i]` stays quiet); negative substring length `${v:0:-1}` (negative offsets such as
  `${v: -1}`, valid on 3.2, stay quiet; `${v:-x:-y}` too); `{fd}>`/`{fd}<` redirections;
  backslash-continued lines checked as one logical line, reported at the first; `((` right
  after for/if/elif/while/until is arithmetic, so `for((i=0;i<1<<2;i++))` and `if((1<<2))`
  no longer exit 2. Fixtures: 72 positive files + extended negative file. test-lint.sh 86/86
  under /bin/bash and bash 5, each with macOS awk and mawk 1.3.4. Repo clean (26 files) with
  both awks; d1593ae tree still exactly the 7 known hits with both awks.
- [x] update-scripts (findings 1, 2, 8, 9, 10, 19): us-fix-harness 59/59 under 3.2 and 5, transcripts identical (132 lines); same harness on f918d4f fails 34 checks, each a reported finding
- [x] install.sh (finding 7): chmod list is now a loop that skips a missing name; rc 0 with all 16 scripts (16 executable) and without prepare-stake.sh (15), both shells; f918d4f exits 1 on the missing file
- [x] remove-node (findings 13, 21): rn-fix-harness 20/20 under 3.2 and 5; f918d4f fails 9 (EOF loop still running after 5 s with 312 menu renders, errexit not restored, kept group listed as orphaned)
- [x] rerun-all, gates, reply

Fix-pass details:

- update-scripts.sh. New helper `fetch_published_sha URL` (rc 0 hash; 1 no usable sidecar:
  HTTP error or first field not `^[0-9a-f]{64}$`; 2 network). `download_updates` fails closed
  on rc 1 and counts rc 2 and download/empty errors as network failures; mismatch and syntax
  errors count as verification failures. lib/common.sh + lib/fallback.sh are held as .tmp
  and moved together after the loop, or both dropped. Only `*.sh` gets `chmod +x` (no tracked
  non-.sh file is 100755 in git). Exit 1 when any file was not installed. `self_bootstrap`
  checks the new copy against its sidecar before mv/exec. `get_remote_version` captures the
  body and tests curl's status first. `main` runs `clear 2>/dev/null || true`.
- Exact new updater messages:
  - `FAILED  (no checksum published -- not installed)`
  - `FAILED  (checksum download error)`
  - `verified (waiting for its pair)`
  - `[OK]  Installed lib/common.sh and lib/fallback.sh together.`
  - `[WARN] <lib/x.sh> failed, so <lib/y.sh> was not installed either: the two only work as a matching pair.`
  - `[WARN] N file(s) failed verification and were not installed.`
  - `->  Run the updater again in a few minutes; if they keep failing, contact support@telcoin.org.`
  - `->  N file(s) could not be downloaded -- check your internet connection and try again.`
  - `[WARN] The new updater does not match its published checksum -- not installed; continuing with the current version.`
  - `[WARN] The new updater could not be verified (no checksum available) -- not installed; continuing with the current version.`
  Unchanged: `FAILED  (download error)`, `(empty download)`, `(sha256 mismatch)`, `(syntax
  check)`, `OK      (verified)` (the plain unverified `OK` is gone), `N updated, M failed`.
  The FAILED lines keep the existing two-space column after FAILED.
- remove-node.sh. `show_detected` saves the caller's errexit state and restores it at the end.
  The menu `read` exits 0 at EOF; `clear 2>/dev/null || true` in the menu (same TERM issue as
  the updater). Judgement call: the three menu actions run under `set +e` explicitly (the
  menu itself runs with errexit). Teardown has always run best effort, because the leaked
  `set +e` covered every action; turning errexit on for them would abort a removal halfway
  at the first unguarded failure (a daemon-reload, a busy rm, a read at EOF). The harness
  proves a failing step no longer stops the rest. `KEPT_GROUPS` records groups kept on
  purpose (operator declined, or the sibling-in-use early return) and
  `report_orphaned_groups` lists them under "Telcoin service group(s) kept:" with "remove
  later with: sudo groupdel <g>"; other telcoin groups keep the "Possible orphaned" wording.
- install.sh: `if [ -f ]; then chmod +x; fi` inside the loop rather than `[ -f ] && chmod`,
  so a false test as the loop body's last command can never trip errexit on 3.2.
- Not changed, for the followup: remove-node finding 14 (a legacy unit on a mixed host reads
  the unified .node-meta, so its own container/account can be left behind) and the menu has
  no remove-one entry (remove_node_unit is reached only through remove_all_nodes).

Fix-pass tests (`/bin/bash p3/rerun-all.sh`, pins d1593ae / 78d9f46 / f918d4f):
- lint: test-lint.sh 86/86 x {/bin/bash, bash 5} x {macOS awk, mawk 1.3.4}; repo clean, 26
  files, both awks; d1593ae tree exactly the 7 known hits with both awks.
- remove-node: rn-harness unit 21/21 (3.2, 5); rn-fix-harness 20/20 (3.2, 5); scenarios new
  3.2 == new 5 == f918d4f(5). f918d4f on rn-fix-harness: 9 failures (EOF loop, errexit, kept
  group).
- migrate-node-naming: 45/45 (3.2, 5); unchanged since f918d4f.
- update-scripts: us-fix-harness 59/59 (3.2, 5), transcripts identical (132 lines); f918d4f on
  it: 34 failures, each a reported finding. us-harness five scenarios new 3.2 == new 5; vs
  f918d4f only the pair lines differ. Lone copy: rc 1 by design now (its fake remote has a
  stale check-node.sh without a sidecar, which f918d4f installed unverified), lib/fallback.sh
  installed, both shells.
- install.sh: rc 0 with all 16 scripts and without prepare-stake.sh, both shells; runbook URL
  equals the library constant; f918d4f exits 1 without prepare-stake.sh.
- Gates: bash -n 5/5 under 3.2 and 5; shellcheck --severity=error clean on all five;
  check-bash32 clean on the five; warning-level shellcheck vs f918d4f unchanged (remove-node
  5 = 5, update-scripts 2 = 2, install 0 = 0, check-bash32 0 = 0).

Changelog additions for the release commit:
- remove-node v1.2.9 (append): "At end of input the menu now exits cleanly instead of looping,
  `clear` failing on an unusable terminal no longer ends the run, and a service group you
  chose to keep is listed as kept rather than as possibly orphaned."
- update-scripts (append): "Every file is now checked against its published SHA-256 before it
  is installed: a missing or malformed checksum means the file is not installed. The updater
  checks its own new copy the same way before relaunching, installs lib/common.sh and
  lib/fallback.sh together or not at all, exits 1 when any file failed, says whether files
  failed verification or could not be downloaded, and only marks scripts executable."
- install.sh: "A script missing from the download no longer stops the installer."

Open for the orchestrator: update-scripts SCRIPT_VERSION bump and sidecars in the release
commit (verifier F12); CI step for the lint (verifier lint F6); extend the `source || true`
lesson (see the follow-up section).

## Fix pass 3 (V-DOC)

status: done. update-scripts.sh only, version stays 1.1.69 (REL bumps it); edited the
committed 3c78a6d file in place. Baseline for this pass pinned to 3c78a6d.

- [x] V-DOC finding 18: the updater ignored every argument, so `--help` ran the real update
  check and prompted. Before this pass it accepted no arguments at all: the README documents
  only `bash ~/telcoin-node-scripts/update-scripts.sh`, the UI never runs it, and there is no
  `--yes` or environment switch (the prompt reads stdin; Enter means yes). New `usage()` and
  argument handling at the top of `main`, before `clear`, the banner or any network access:
  `-h`/`--help` anywhere prints usage to stdout and exits 0; any other argument prints
  `update-scripts.sh: unknown argument: <arg>` plus the usage to stderr and exits 2. With no
  arguments the run is unchanged. self_bootstrap still passes "$@" to the relaunched copy,
  which by then is always empty.
- Tests: us-harness `args` mode (whole updater, stdin at EOF, curl calls logged), 6/6 under
  /bin/bash 3.2 and bash 5: `--help`, `-h`, `--help --bogus` rc 0, 0 curl calls, usage on
  stdout; `--bogus`, `extra` rc 2, 0 curl calls, usage on stderr; no arguments rc 1 (EOF at
  the prompt, as before) with 21 curl calls. 3c78a6d on the same rows: every argument ran the
  update check (21 curl calls, rc 1). rerun-all.sh (pins d1593ae / 78d9f46 / f918d4f / 3c78a6d):
  lint fixtures 86/86 x 2 bashes x 2 awks; rn unit 21/21, rn fix 20/20; mg 45/45; us fix 59/59;
  five scenarios new 3.2 == new 5 == 3c78a6d(5); install.sh both variants rc 0; bash -n 5/5;
  shellcheck --severity=error clean; check-bash32 clean on the five and on the repo (26 files,
  both awks). Warning-level shellcheck vs 3c78a6d: 2 = 2.
- Changelog addition (update-scripts): "`--help` (or `-h`) prints usage and exits without
  contacting GitHub; any other argument is refused with exit status 2 instead of being
  ignored."

## Fix pass 4 (code review)

status: done. update-scripts.sh only, version stays 1.1.70; edited the committed e5e7f4f
file in place. Baseline for this pass pinned to e5e7f4f.

- [x] (1) `self_bootstrap` now tells the two sidecar failures apart, as `download_updates`
  does. fetch_published_sha rc 2 (DNS, timeout, TLS): `The new updater's checksum could not
  be downloaded (network error) -- not installed; continuing with the current version. Try
  again in a few minutes.` rc 1 (missing or malformed): `The new updater has no checksum
  published -- not installed; continuing with the current version.` Mismatch wording
  unchanged.
- [x] (2) `TMP_CREATED` (top-level list) records every `.tmp` path just before curl writes it,
  in `self_bootstrap` and in the download loop. `cleanup_tmp` removes the listed paths that
  still exist, then prints `Stopped before finishing: removed N downloaded file(s) that were
  not installed.` only when it removed something (message after the removals, guarded, so a
  dead terminal cannot stop the cleanup). `main` sets the traps once, after argument
  handling and before the first download: `trap cleanup_tmp EXIT`, `trap 'exit 130' INT`,
  `trap 'exit 129' HUP`, `trap 'exit 143' TERM`. The signal traps make the EXIT trap run on
  every bash. Normal path: every verified file, the pair included, is moved into place
  before download_updates returns, so the trap finds nothing; `exec` in self_bootstrap
  replaces the process (traps do not carry over). Only listed paths are removed, never an
  installed file or anything this run did not create.
- Tests: us-fix-harness 64/64 under 3.2 and 5 (59 + O5: sidecar curl timeout, exit 28,
  gets the network wording, not the no-checksum one, copy kept, no .tmp; O3 now expects the
  "no checksum published" wording). us-harness `interrupt` mode (whole updater in its own
  process group, curl stalled on the real lib/fallback.sh download, signal sent to the
  group): 2/2 under 3.2 and 5, SIGINT rc 130 and SIGHUP rc 129, `lib/common.sh.tmp` held at
  the signal and gone after, installed pair untouched, cleanup message printed. e5e7f4f on the
  same rows: 0/2, `lib/common.sh.tmp` left behind, both shells. Exit status through the trap:
  declining at the prompt rc 0, stdin at EOF rc 1, unchanged. rerun-all.sh (pins d1593ae /
  78d9f46 / f918d4f / 3c78a6d / e5e7f4f): lint fixtures 86/86 x 2 bashes x 2 awks; rn unit
  21/21, rn fix 20/20; mg 45/45; us fix 64/64; argument rows 6/6; interrupt 2/2; five
  scenarios new 3.2 == new 5 == e5e7f4f(5) (vs 3c78a6d only the 1.1.69 -> 1.1.70 version
  string differs); install.sh both variants rc 0; bash -n 5/5; shellcheck --severity=error
  clean; check-bash32 clean on the five and on the repo (26 files, both awks); warning-level
  shellcheck 2 = 2 (the existing SC2206 pair in version_gt).
- Changelog addition (update-scripts): "An interrupted run (Ctrl-C or a dropped SSH session)
  removes the files it had downloaded but not installed, and a checksum that cannot be
  downloaded for the updater itself is reported as a network error."
