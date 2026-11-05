status: done
agent: V2 (verify KEYS + AUDIT + seam c4322d4)
worktree: /home/drtnarg/coding/telcoin/tnd-verify-V2 (verify/V2 @ ac9a605)

## Sections
- [x] 1. Read specs, diff, AGENTS.md, lessons
- [x] 2. Harness: keys_v2.sh+keys_drv.sh, audit_v2.sh, hooks_v2.sh+hooks_drv.sh, real_v2.sh, run.sh, mutate.py.
      Full run records/summary.txt: host 371+39+101=511 (fails: A-2 x2, A-3, A-5), b32 831+99+112=1042 (K-1 x4, A-2 x3, A-4, A-5),
      ubuntu 831+99+112+38=1080 (A-2 x3, A-4, A-5). Every FAIL is a [finding] check.
- [x] 2b. Real-tool run (ubuntu:24.04 auditd + aide): records/ubuntu-real_v2.txt 38/0/0, AIDE 0.18.6, auditd 1:3.1.2-2.1ubuntu0.1
- [x] 2c. Mutation run: 28/28 killed (32 harness runs); A8 survived once, harness strengthened (clean tn_host_audit rc check), then killed
- [x] 3. Compared with ckpt-fup-KEYS.md / ckpt-fup-AUDIT.md (main repo, read-only). Claims match the harness except:
      D-1 AUDIT docs note "Not after: ... the credential actions (--migrate-credential, --reseal, menu 5)" is false at the tip (c4322d4 refreshes on edit_cred_report rc 0)
      D-2 AUDIT op-visible "remove-node ... (menu, --json any scope, leftovers): 'Host baseline removed ...'" -- in --json the line is stderr only (A-4)
      D-3 KEYS docs note quotes "a registered BLS key cannot move to another address" -- operator sees "Refused: <addr> has staked (<st>). Its BLS key is registered to it on-chain and cannot move to another address."
      check-node --audit runs without sudo -> A-3 reachable there (non-root user): "host baseline: off" on a baseline host
- [x] 4. Repo gates (records/gates/): run.sh bash 5.3 60 files 0 failed (4050 checks/50 skip); bash:3.2 60/0 (3975/48);
      ubuntu:24.04 60/0 (4238/15); passphrase_print + root_write_pipe 2/0; shellcheck 0.11 + 0.9.0 --severity=error clean on the 5;
      check-bash32 clean (5 files); bash -n 5.3 and 3.2 clean
      real_v2 rerun: 40 checks, 1 FAIL = [finding N-2] Alloy env file (token at this tip) is in the AIDE db; db root 0600 ok
- [x] 5. Commits 06c1017 + f918bea on verify/V2 (tasks/verify-fup/V2 only); final report handed back

## Commits in range 0a9db45..ac9a605
KEYS: aa149f5 (edit-config verify), 8d08ab0 (remove-node note), 13a92a7, 6cbf52e (tests)
AUDIT: 57f2903 (lib), dad6f33 (setup-node), cf3421f (hooks), 5bf19ce (remove-node), 91ab3d7 (test)
seam: c4322d4 (edit_cred_report rc0 -> edit_baseline_refresh)

## Candidate findings to prove (from reading; each needs a repro)
- edit_change_passphrase verifies only the NEW passphrase before write (spec: OLD before, new after)
- duplicated HOST_BASELINE: refresh/status/remove read with `|| mark=""` -> off; remove leaves dup lines
- non-root tn_host_audit (setup-node --audit runs before check_root): unreadable .node-meta -> "host baseline: off"
- remove-node --json: teardown messages are print_* on stderr, no JSON event
- restart later + menu restart_node: never refreshed
- setup-node does not list tn_host_baseline_install in tn_require_fns (AGENTS.md rule)
- spec drop-in /etc/aide/aide.conf.d/99_telcoin vs impl /etc/aide/telcoin-node.conf (justified deviation?)

## Reproduced findings so far (harness check names carry [finding X])
- K-1 WARN busybox setpriv (bash:3.2 root, binary: spec): tn_keytool_has rc1 from the wrapper -> "not in this release; skipped", wrong passphrase proceeds to _tn_cred_switch
- A-2 WARN dup HOST_BASELINE: refresh silent no-op, status "off" rc0, remove leaves 2 marker lines (root)
- A-3 WARN non-root status with unreadable .node-meta -> "host baseline: off"
- A-4 NOTE remove-node --json: teardown messages only on stderr, no event
- A-5 WARN menu Restart node after "restart later" never refreshes
- SIGTERM during aide --init: leaves marker + rules + conf, no db; status warns (observation)
- interactive update verify-fail + keep new release: no refresh (observation)
- S-3 NOTE setup-node: tn_host_baseline_install not in tn_require_fns -> "command not found" exit 127 (repro with stripped lib)
- N-1 WARN _tn_hb_aide_db renames into an existing /var/lib/aide owned by another account (0777 nobody): install rc 0 (tn_root_dir_ok rc 1)
- K-1 repro: bash:3.2 root, tn_keytool_has binary:/opt/b/tn verify -> rc 1 while the help lists verify
- A-6 NOTE remove with augenrules missing: rules file removed, no reload, no warning (harness hash artifact fixed; audit_v2 ubuntu 99/4/1)
- N-2 NOTE Alloy env file /etc/telcoin/alloy/telcoin-alloy.env (token at this tip) is hashed in the AIDE db (real_v2 40/1/0)
TODO at end: rerun audit_v2 in 3 envs (records), mutations finish, second commit, final report
