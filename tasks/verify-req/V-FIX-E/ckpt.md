status: done

# V-FIX-E checkpoint (menu 13 "Refresh chain configs", tip 1a3404b)

Harness: tasks/verify-req/V-FIX-E/menu13_test.sh (suites main|cmp|oldscript), driver run_all.sh.
Run 1: scratchpad/v-fix-e/run-1 — host main 65/0/1skip; docker main 68/0/0; cmp new/old,
oldscript, E6 tests all rc 0. Gates green (shellcheck error, bash -n 5.3 + 3.2, check-bash32).

Sections:
- [x] E1 — pass; baseline 2x (V-FIX-E-3); F7 confirmed (V-FIX-E-5).
- [x] E2 — pass; deferred-restart message (V-FIX-E-2).
- [x] E3 — no git in 4 variants; prompt before unavoidable refusal (V-FIX-E-7).
- [x] E4 — refusals pass; pinned dir + baseline before refusal (V-FIX-E-6).
- [x] E5 — no deadlock; lock held through Press Enter on old early returns (V-FIX-E-4).
- [x] E6 — existing tests pass; cmp vs 01664cc differs only in baseline count.
- [x] E7 — skew1 refuses up front; skew2 pulls + submodule --force then refuses (V-FIX-E-9).
- [x] E8 — hint verdict Medium (V-FIX-E-1); replacements A (clone --branch) and B (hand copy) tested;
      UI/--json: nothing reaches menu 13; root read of data dir (V-FIX-E-8).

Report: the Write of REPORT.md was refused (subagent rule); full text returned in the final answer
for the orchestrator to save as tasks/verify-req/V-FIX-E/REPORT.md.
