status: done
agent: V-CORE-2-lint (verifier of tools/check-bash32.sh, commit 78d9f46)
scratch: <scratchpad>/vcore2-tests/lint/ (gen.sh -> 141 fixtures in fx/, run.sh 4 combos, sem.sh bash 3.2 vs 5 semantics, tree.sh, ec.sh exit codes, patched.sh + cmp-patch.sh candidate fix)

[x] 0. read tool + spec; CI has NO lint step (ci.yml / publish-installer.yml never mention check-bash32)
[x] 1. must-flag: all 25 listed constructs flagged, rc 1
[x] 2. look-alikes: 47 clean; l11 (unquoted heredoc body ${v,,}) flagged by design = correct (3.2: bad substitution)
[x] 3. matrix /bin/bash 3.2.57 + bash 5.3.15 x BSD awk 20200816 + mawk 1.3.4-20200120 (no gawk): every fixture, exit-code case, tree and baseline run identical
[x] 4. tree: 26 files -> rc 0 clean, 4 combos; independent grep: nothing hidden
[x] 5. baseline d1593ae: exactly 7 hits (rn 121-123 declare -A; us 203 declare -ga, 204-205 declare -gA; mg 394 local -n); whole d1593ae tree (24 files) also exactly 7
[x] 6. exit codes: 33 cases all per contract (see report)
[x] 7. static: bash -n both, shellcheck error+warning clean, self-lint clean without # bash32-ok
[x] 8. P3 test-lint.sh: 68 passed / 0 failed under /bin/bash and bash, BSD awk and mawk; no P3 fixture covers case-arm position

Findings:
- F1 error: one-line case arm `x) <construct> ;;` hides every CMDPOS check (declare/typeset/local/readonly, mapfile, readarray, coproc, [ -v/test -v, wait -X, printf %()T). Tree has 519 such arms. Fix: add `)` to CMDPOS anchor class. Validated in scratch: closes it, no regressions (P3 68/68, look-alikes clean, tree clean, baseline 7).
- F2 warn: ${v~} ${v~~} missed. Fix [,^] -> [,^~] (validated).
- F3 warn: arithmetic negative subscripts `(( a[-1] = 5 ))`, `$(( a[-1] + 1 ))` missed.
- F4 warn: construct split by `\` continuation (`declare \` / `-A m`) missed.
- F5 warn: `for((i=0;i<1<<2;i++))`, `if((1<<2))` (valid) -> exit 2.
- F6 warn: CI step not added though spec says CI runs it once the known hits are fixed (they are).
- F7 warn/note: outside spec list: ${v:0:-1}, exec {fd}> (warn); local -, declare -I, unset 'a[-1]', read -N, {1..10..2}, shopt globstar, $'\u', eval declare, redirect-first declare (note).
- notes: unquoted-heredoc deviation correct; FPs (array literal names, case pattern names, continuation arg, multi-line array, printf arg %(x)T, sed s/x[-]=/, mapfile () polyfill); # bash32-ok inside a string suppresses; `a)#it's` and heredoc-on-open-quote-line and EOF) -> exit 2.
