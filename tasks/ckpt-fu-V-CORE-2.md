status: done (V-CORE-2 verifier)
harness dir: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/vcore2-tests/
sub-agent checkpoints: tasks/ckpt-fu-V-CORE-2-lint.md, tasks/ckpt-fu-V-CORE-2-us.md, tasks/ckpt-fu-V-CORE-2-rn.md (all status: done)

## sections
- [x] read specs (shared, core B.1/B.4/B.5, lessons, AGENTS)
- [x] remove-node (#2) via rn sub-agent
- [x] update-scripts (#4) via us sub-agent; integrity errors confirmed by my own code read
- [x] lint (#5) via lint sub-agent; F1 (case arm) and F2 (${v~~}) confirmed by my own fixtures
- [x] update-node (#1): un/t1.sh 138/138, un/t3.sh 48/48, un/t2.sh + t4.sh SIGTERM, t5.sh error paths
- [x] migrate-node-naming (#3): mg/t-mg.sh 88/88
- [x] install.sh (#6): inst/
- [x] static (#7)
- [x] cross-check (#8): P6 520/523 (3 = stale HEAD baseline), sete 24/24; P3 rn 21/21, mg 45/45, us 3.2==5, lint 68/68
- [x] prose (#9)
- [x] final report handed back

## findings (final)
update-node: F-UN-1 warn flock lock held by orphaned child after SIGTERM; F-UN-2 warn interactive custom ref `--detach` reaches git; notes: generic done msg for non-root/no-node, `--ref -v1` message, `step "warning:"` vs warn event.
remove-node: no P3 defect; pre-existing warns (EOF loop in main_menu; mixed-host legacy unit uses unified meta) and notes.
migrate: no findings (follow-up landed as eb73857 with matching sidecar).
update-scripts: errors (pre-existing) missing-sidecar installs unverified, self_bootstrap unverified; release blocker version 1.1.69 == published; warns get_remote_version unbound var, exit 0 on failure, network-only summary, pair not atomic.
install.sh: warn chmod +x prepare-stake.sh fatal if shipped without prepare-stake.sh.
lint: error case-arm blind spot; warns ${v~}, arithmetic negative subscripts, continuation split, `<<` in (( )) -> exit 2, no CI step.

## Operator-visible changes
none (verifier)
## Changelog text
none (verifier)
## Tests run
see sections above
## Open issues
see findings
