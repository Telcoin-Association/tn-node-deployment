status: complete
task: C2 README.md docs edit (11 edit groups)

## Completed sections
- 1 top callout (OPERATOR.md blockquote before maintainers callout)
- 2 Run a node / Become a validator / One node per VM / System Layout vocabulary (tn_nodeMode, stake status 1-4, NODE_TYPE = old-UI hint)
- 3 Hardware per-role table + preflight warn-only; OS list (Ubuntu 22.04+, Debian 12+, RHEL 9+; RHEL 8/macOS dropped; kernel 3.10 line dropped)
- 4 What the Setup Script Does (hardware warn-only, systemd list, --rpc-domain at keygen, rpc-enable no extra restart)
- 5 Validator Onboarding Flow (calldata stake flow, eth_syncing removed from step 4, activate/exit/unstake commands, status table 0-5 + Retired, OPERATOR links)
- 6 ## Health Check heading added over orphan block; role flags removed; --network-rpc + sudo note; bullets updated
- 7 Docker default tag; Key Backup never-overwrite line; Web UI security model matches install-ui.sh sudoers
- 8 Public RPC > New install: keygen advertisement, .node-meta keys, rpc-enable no restart, explicit-URL overrides
- 9 Quick Reference: tn_nodeMode curl replaces eth_syncing (+ why), role-flags line, ### setup-node flags table, sudo on check-node
- 10 Contributing: macOS note fixed; OPERATOR.md-with-README rule + no-line-numbers rule
- 11 Final sweep done; anchors verified; changelog untouched

## Notes
- leftover sweep hits outside changelog are deliberate (shim note, RHEL 8 unsupported, ignored role flags, --observer warning)
