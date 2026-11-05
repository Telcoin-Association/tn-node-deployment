status: in-progress (SIG done and handed back; IMG not started)

# V7 checkpoint (SIG now, IMG after the orchestrator's message)

## SIG
- [x] 1 Harness (lib.sh: GNUPGHOME, keys valid/second/expired/revoked/old/foreign, release built by release-scripts, file:// curl shim)
- [x] 2 Policy matrix across the three verifiers (t_policy.sh 89/89; t_parser.sh 48/48 x3 envs)
- [x] 3 Dearmor cases (t_dearmor.sh 42/42; NOTE garbage-body key poisons keyring -> NOSIG)
- [x] 4 Bootstrap cases (t_bootstrap_install.sh; TOFU NOTE; allowed_signers left on host)
- [x] 5 Installer cases (t_bootstrap_install.sh 67/68 + t_crlf.sh 4/5: WARN CRLF key file -> installer drops the key, CI gate passes)
- [x] 6 cut-release.sh (t_cut_release.sh 64/64)
- [x] 7 CI grep, P0-05, leftover grep (t_ci.sh 22/22; AGENTS.md etc stale = DOCS-2)
- [x] 8 Fixtures in envs (match SIG claims); mutants 39: fixtures real 35, fakes 36, fixtures 36, V7 harness 33, any 37, +t_check_gaps 39/39. Survivors of the fixtures: M15, U04, U06 (M19 real-only)
- [x] Compare with ckpt-r2-SIG.md (it lives in ~/coding/telcoin/tnd-r2-SIG/tasks/, not this worktree): counts match; no CRLF mention
- [x] REPORT.md SIG section: Write REFUSED (report-file rule); complete text returned in the SIG handback for the orchestrator to save as tasks/verify-r2/V7/REPORT.md. Harness lint (10 files) clean.

## IMG
- IMG message received mid-SIG: worktree fast-forwarded to c0716f3 (SIG+EPOCH+IMG). SIG files unchanged cff2f63..c0716f3 (only lib/common.sh changed; _tn_gpg_status_verdict identical), so SIG results hold at both tips.
- Plan: hand back SIG first (SubagentHandback ends this run), IMG starts when resumed. Do NOT read tasks/ckpt-r2-IMG.md before the IMG harness exists.
- Extra IMG judgements asked: --json fail-closed order (error event then done only); docker run failure/timeout of the feature check refused; unknown-network floor default (testnet floor); any path still pulling from the old package or tn-dev on testnet/mainnet.
- [ ] IMG 1 repo_for/repos_for/repo_ok + pull_repo_ok/pull_repos_for per network; resolve_ref refusals
- [ ] IMG 2 IMAGE_DIGEST naming another package refused on mainnet
- [ ] IMG 3 storage_migration_floor per network
- [ ] IMG 4 feature check (stub docker), order in setup-node/update-node/edit-config, mutation removing the check
- [ ] IMG 5 --json paths
- [ ] IMG 6 UI twins, pytest 3.10/3.12
- [ ] IMG 7 remove-node container scan

## Operator-visible changes
(none: verifier)

## Docs notes
(none yet)

## Tests run
- fixtures host bash 5.3 real gpg: release_scripts 147, updater_manifest 215, install 109, cut_release 68; 0 fail 0 skip (40 s)
- t_policy.sh host: 89 passed 0 failed
- t_parser.sh host / bash:3.2 / ubuntu:24.04: 48/48 each
- fixtures bash:3.2 + ubuntu:24.04: release_scripts 44+2skip, updater_manifest 211+2, install 108+1, cut_release 0+1skip (no git); host fakes: 147, 214+1, 108+1, 68
- t_ci.sh 22/0; harness lint: sc 0.11 + 0.9, bash -n 5.3 + 3.2, check-bash32 clean
- t_check_gaps.sh 8/0 (pins U04, U06); t_mutants.sh 39 mutants
- t_dearmor.sh 42/0; t_bootstrap_install.sh 67/1 (CRLF finding); t_crlf.sh 4/1 (finding); t_cut_release.sh 64/0

## Open issues
- WARN CRLF key file: prepare/--check pass, installer splitter drops the key (t_crlf.sh)
- NOTE garbage-body key file poisons keyring (NOSIG)
- NOTE bootstrap TOFU; NOTE allowed_signers left on hosts (spec-allowed, noted by SIG)
- WARN fixture gap U04: --check vs a newest release whose MANIFEST.asc fails (updater_manifest_test.sh)
- WARN fixture gap M15: non-key .asc beside a good key must be refused (release_scripts_test.sh)
- NOTE U06 unpinned bad-path rule (hash self-reference still refuses)
- Context near budget: IMG should go to a fresh agent reading this checkpoint
