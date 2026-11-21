status: done

# HW-SH checkpoint (branch req/hw-sh, base 01664cc)

Commit: 7d12626c72c50f69d3b2446fd8b3a90e25926677 "HW-SH: hardware check per network" (lib/common.sh, setup-node.sh only)

Sections:
- [x] constants (lib/common.sh 85-102: 24 HW_TESTNET_*/HW_MAINNET_* readonly, mirror regex finds 24; no "adiri"; block grew +12 lines)
- [x] helpers and check_hardware (_tn_hw_cores_label after _tn_hw_disk_label; _tn_hw_role spec/need use it; check_hardware 3rd arg, case -> tier arrays, Comparing line after logical note, rec line per set, single-core sentence; old HW_NODE/RPC/VAL names gone; bash -n ok)
- [x] step_preflight move (check_hardware + --json block moved to just after check_internet, call passes "$NETWORK"; comment above check_internet names check_hardware; mkdir stays; bash -n ok)
- [x] harness outputs (harness + outputs in /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/hw-harness-1/, five-outputs.txt; extra.sh covers 350 GB boundary, 2-core, bogus net, logical fallback; same in bash:3.2)
- [x] gates (tree = worktree with the change, pre-commit = 7d12626 content: 4 named tests 0 failed on host / ubuntu:26.04 / bash:3.2; full suite 81 files 0 failed host and ubuntu:26.04; bash32 clean 211; network-hits clean 153; perl-interp clean 211; shellcheck error clean, warnings 14/0 identical to HEAD copies; 26.04 counts 4/1)

Notes:
- grep: only stubs of check_hardware are tasks/verify-fup/V1/v1_test.sh:695 and tasks/verify-r2/V7-IMG/t_order.sh:48 (both `check_hardware() { :; }`); no test file in tools/tests names check_hardware, HW_* or TN_HW_*.
