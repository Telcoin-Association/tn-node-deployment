status: done (verdict G1: PASS)
agent: V-B1 (independent verifier, lib/common.sh helpers)
harness: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/8cb015fd-6d45-47e2-b902-7d4ceefc1fda/scratchpad/VB1/
sections:
- [x] 0 read diff (saved VB1/common.diff, added lines VB1/added.txt)
- [x] 1 static checks: bash3 -n OK, bash5 -n OK, shellcheck -x --severity=error (6 files) rc 0; bash-4 scan of 463 added lines: 0 real hits (only false positive `${1:-0}` default); `${m//[\"\\[:cntrl:]]/}` verified on 3.2 + 5.3
- [x] 2 SC-1 stake status: VB1/sc1.sh PASS=158 FAIL=0 on bash 3.2 and 5.3 (negative control sc1_neg.sh -> 10 FAIL as expected). Consumer greps: 1-4 match check-node only; 0/5/6r/none match update-node only; 6+retired=0 matches neither
- [x] 3 SC-2 observer flag: VB1/sc2.sh PASS=134 FAIL=0 both bashes (fixtures a,b,c,d,d2,g,h_noeol,unit,g2_text + e/neg untouched + failure paths ro/only/mktemp-stub); argv after strip == original minus --observer for a,b,c,d,d2,g,h_noeol; VB1/sc2b.sh tn_target_drops_observer PASS=19 FAIL=0 both bashes. (2 harness bugs fixed: bash -n on .service, macOS mktemp ignores bad TMPDIR -> used failing mktemp stub)
- [x] 4 SC-3 hardware: VB1/sc3.sh PASS=141 FAIL=0 both bashes, outputs identical. constants+readonly OK, OBSERVER_MIN_/VALIDATOR_MIN_ gone (no *.sh/*.py refs), DEFAULT_DOCKER_IMAGE ...:v0.15.0-adiri. cases i,ii,ii-b,iii,90/89% boundary,iv,iv-b..f,v(+/var/lib parent, nested, relative, empty) all rc 0. (1 harness expectation bug fixed: ivf gaps=validator is correct since CPU known=4)
- [x] 5 display_node_info text: VB1/dni.sh both bashes, binary+docker+default modes: export-staking-args --node-info .. --calldata, cast send <registry> <CALLDATA> --value, stake(bytes,(bytes)) present, (bytes,bytes) absent. Cross-checked telcoin-network tag v0.15.0-adiri has keytool export-staking-args --node-info/--calldata; ConsensusRegistry.stake(bytes, ProofOfPossession{bytes signature})
- [x] 6 report handed back
notes:
- SC-3 edge: non-ASCII mount (/mnt/données) survives into TN_HW_SUMMARY (comment claims plain ASCII; only quotes/backslash/cntrl are stripped). Callers: setup-node.sh json_event only; contract cases ASCII.
- SC-3 UX: when a role has a shortfall AND an unknown measurement, WARN line omits the 'could not check' note; '1 CPUs' grammar.
- SC-1 edge (outside contract): status decoded from 16 hex (hex:240:16) -> status word ...ffffffffffffffff gives '-1 12 0' rc 0; check_validator_onchain_status then prints 'Empty response' but returns 0 (print rc 1 swallowed by || true). Upper 48 hex of status word ignored (1000..0003 -> Active). ABI-invalid input only.
- status 6 + isRetired=0 prints "Any (reserved status sentinel)" -> update-node.sh pattern no longer matches (HEAD printed Retired for any 6). Fail-safe (warns), outside contract.
- tn_target_drops_observer: first x.y.z wins -> registry host with IP (10.0.0.5:5000/...:v0.14.0) would read 10.0.0 -> rc 0. Edge.
