status: done
agent: V-CORE-2-rn (verify remove-node.sh 1.2.9, commit 78d9f46)
scratch: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/vcore2-tests/rn/  (e2e.sh, all-e2e.sh, u.sh, fx.sh, shims/, run/)

- [x] 0 read sources; rewritten copies src/{new,old}/remove-node.sh (perl: /etc|/var|/opt|/usr|/home|/mnt|/data|/srv|/proc -> ${RN_FAKE:?}/<root>), shared lib copy (check_root EUID test -> 0), logging shims, rm/rmdir shim refuses paths outside RN_FAKE (0 refusals)
- [x] 1 E01-E17 e2e: new runs all to completion under 3.2 and 5, outputs byte-identical across bashes; fs/shim-log assertions match expectations
- [x] 2 alignment u.sh: new 3.2 pass=27 (1 harness-only fail: declare -p format), bash5 pass=28; T9-emptyloops "fail" was EOF read rc, rechecked rc=0
- [x] 3 old vs new (bash 5): only diff is the v1.2.8/v1.2.9 banner in 13 scenarios; old dies at declare -A (line 121) under 3.2; stale map keys in old confirmed via declare -p, not observable in output
- [x] 4 UI: removed only on a yes to offer_ui_removal (per unit, warns if sibling unit file present) or JSON --remove-ui (systemd-run); wipe/no never touch it; rm -rf /opt/telcoin leaves /opt/telcoin-ui; zero-unit path never offers UI removal (E17); node-role.json applies only to same execution address
- [x] 5 set -u: guarded forms everywhere arrays may be empty; spaces/glob unit names (E11, T7) fine; prefix lookup correct
- [x] 6 static: bash -n (3.2,5), shellcheck -x error clean (no warnings on changed lines), check-bash32 clean, no common/ devnet-genesis, no --observer/--validator, SCRIPT_VERSION 1.2.9, sha256 331cc304... matches sidecar
- [x] 7 prose: P3 adds no user-facing message; new comments accurate. pre-existing: "orphaned" group warning after operator chose to keep it (E04)
- [x] 8 P3 rn-harness.sh: unit 21/21 under 3.2.57 and 5.3.15; scenarios rc=0 both, transcripts identical 3.2 vs 5; 0 rm refusals

## Findings so far
- warn (pre-existing, old too): stdin EOF with a node installed -> main_menu loops forever printing "Please enter 1-3 or s." (E15, 15k lines in 20s); cause: show_detected `set +e` never restored + read at EOF
- warn (pre-existing): mixed host (unified telcoin + legacy telcoin-validator docker unit): legacy unit inherits unified .node-meta method/user (config_dir_for_unit ignores unit) -> its container + tnval account left behind (E08)
- note (pre-existing): zero units + leftover UI -> no UI removal offered; JSON needs a node (E17)
- note: menu has no remove-one entry; remove_node_unit only via remove_all_nodes
- note (pre-existing prose): report_orphaned_groups calls a group the operator just chose to keep "orphaned" (E04)
- note: README/CHANGELOG carry no remove-node 1.2.9 entry (spec: handled centrally)
Verdict: no error in the P3 change; equivalent to 1.2.8 under bash 5 except the banner, runs under 3.2.
