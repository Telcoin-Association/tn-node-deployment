# V4 verify checkpoint (REL)
status: done

## Sections
- [x] 1. Read spec, AGENTS.md, signing.sh, lessons, REL diff
- [x] 2. Harness written (tasks/verify-fup/V4/) + run.sh, runs under bash 5.3 / bash:3.2 / ubuntu:24.04
- [x] 2b. 2.0.0 compatibility
- [x] 2c. Adversarial cases
- [x] 2d. Mutation run
- [x] 3. Compare with implementer ckpt-fup-REL.md + docs notes
- [x] 4. Gate cross-check
- [x] 5. Commit + final report

## Notes
- s1 done: REL code diff read (release-scripts, update-scripts, install.sh, check-node). Date tables generated with python3 (dates_table.txt, adddays_table.txt).
- Harness plan: v4lib.sh + dates/updater/install/release/checknode/compat200 tests, run.sh driver, mutate.sh.
- Leads to reproduce: (a) release-scripts --check accepts empty `expires=`/`date=` (opt_header -> "" -> no expiry) while updater refuses; (b) --check rc 1 for lower-serial/same-serial refusals, undocumented; (c) `expires =D` (space) ignored by `[a-z]*=*`.
- s2 progress: v4lib.sh, updlib.sh, dates_v4_test.sh (14 ok), updater_v4_test.sh (317 ok, bash 5.3) written. Probe: fullwidth digits in expires= under en_US.UTF-8 abort the updater (rc 1, "invalid integer constant"), tree unchanged -> NOTE.
- next: install_v4_test.sh, release_v4_test.sh, checknode_v4_test.sh, compat200_v4_test.sh, run.sh, mutate.sh
- s2/2b/2c done: run.sh host/bash32/ubuntu all consistent; only release_v4 fails 2 checks (finding A: release-scripts --check passes empty expires=/date=).
  counts: host dates14 upd352 inst115 cn30 rel90(2F) compat27; bash32/ubuntu upd 1 skip (root, read-only tree).
- Findings so far: A WARN release-scripts check() opt_header empty value; B WARN --check rc 2 hides installed expiry when fetch fails (probe offline-expired rc=2 mentions=0); C WARN/NOTE --check rc 1 for refused rollback/same-serial (undocumented); D NOTE fullwidth digits abort under UTF-8 locale; E NOTE `expires =` silently ignored; F NOTE expires<date accepted by updater/installer but failed by --check.
- next: mutate.sh
- s4 gate done: implementer tests host 159/78/79/58 ok; bash32 155(2S)/6(1S)/78(1S)/58; ubuntu same as bash32; shellcheck 0.11+0.9 clean, check-bash32 clean, perl lint clean, bash -n 5.3/3.2 clean; release-scripts --check tip: rc0 "No MANIFEST..."; --require-sig rc1; --require-fresh rc1. Records in records/gate-*.log.
- mutation run in progress (background), records/mutation.txt
- s3 done: implementer ckpt read. Claims verified: S0 (2.0.0 updater+installer ignore keys; 2.0.0 release-scripts --check passes a tip-prepared MANIFEST), test counts match gate. Docs-note corrections: (1) "--check also fails on ... malformed date=/expires=" false for empty value (finding A); (2) "printed after the plan is made, before the file downloads" false in the self-replacement path (warning comes from the relaunched copy after self_update staged the files); (3) --check exit-status summary (help text and docs) omits rc 1 for refused rollback/same-serial (docs body lists them) and help omits rc 2 for an unverifiable installed record; (4) rc precedence: installed expired + fetch failure = rc 2 with no expiry line (finding B). New NOTE G: prepare writes an already-expired release silently (--date 2020-01-01 -> expires 2020-03-31, rc 0).
- s2d done: 33 mutations, 32 killed first pass; M18 (unfetchable MANIFEST rc) survived -> 2 cases added -> killed. 33/33.
- final run.sh: host dates14 upd366 inst115 cn30 rel90(2F=finding A) compat27; bash32/ubuntu upd359(1S root) others same.
- s5 committed 476160b "verify: V4 harness and records for REL" (cache/ not committed).
