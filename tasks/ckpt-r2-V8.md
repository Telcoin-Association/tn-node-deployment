status: done

# V8 checkpoint (UPS verification, round 2)

Target: ~/coding/telcoin/tn-r2-packages, branch release-packages-per-network, tip 0ba57016d
over origin/main a0d6e6e26 (read-only; worktree status after all runs: `?? tasks/` only).
Records: tasks/verify-r2/V8/ (REPORT.md + harness; every *.sh shebang, bash -n, shellcheck
0.11 and 0.9 --severity=error clean).

## Checks
- [x] 0 harness built (lib.sh, drive.sh, run_all.sh) before reading the implementer files
- [x] 1 parse matrix (t1_matrix.sh 37/37)
- [x] 2 sign/verify-time package checks (t2_package.sh 82/82)
- [x] 3 RELEASE_IMAGE / RELEASE_REPO (t3_env.sh 35/35)
- [x] 4 alias inside channel package (t4_alias.sh 11/11)
- [x] 5 Makefile dev targets (t5_make.sh 13/13)
- [x] 6 actionlint / shellcheck -S style / bash -n / make release-lint (t6_lint.sh 7/7)
- [x] 7 docs + mdbook 0.5.4 (t7_docs.sh 32/32)
- [x] 8 commit messages / diff scope (t8_commits.sh 15/15)
- [x] X1 first-push path in cmd_build (tx1_build.sh 53/53)
- [x] X2 draft IMAGE_DIGEST fail-closed (tx2_draft.sh 16/22: W1)
- [x] X3 check_version_output before push (tx1 order and badfeat); ghcr premise (tx3, V8_NETWORK=1)
- [x] compared with implementer ckpt-r2-UPS.md and pr-body-UPS.md
- [x] REPORT.md

## Findings
- ERROR: none
- W1 draft drops a malformed digest from a right-package IMAGE_DIGEST silently (exit 0)
- W2 first-push: denied probe skips the RELEASE_REBUILD rule; RELEASE_YES=1 answers the prompt;
  a private package holding :TAG is rebuilt and pushed over
- W3 PR body overstates two guarantees (owner from RELEASE_REPO; "the one place")
- N1-N13 in REPORT.md (cheaper safe resume, redundant sign check, message coverage, ...)

## Operator-visible changes
None (verifier).

## Docs notes
None (verifier). The PR-body wording fixes are W3.

## Tests run
`bash tasks/verify-r2/V8/run_all.sh` (bash 5.3 host; bash:3.2 for bash -n and parse):
301 assertions, 295 pass, 6 fail (all W1). `V8_NETWORK=1 bash tx3_ghcr_probe.sh` once
(anonymous reads only).

## Open issues
- W1 and W3 should be fixed before the draft PR; W2 before the PR leaves draft or the first
  real release of either network.
