status: done

# CHAIN-SH checkpoint

Sections:
- [x] sweep
- [x] uses of the constant
- [x] constant and comments (lib/common.sh:24-28 + :3185, check-node.sh:2880, update-node.sh:323,1204)
- [x] fixtures
- [x] new cases
- [x] gates
- [x] final sweep

## 1. Sweep (tree 01664cc)

`git grep -n -I -i -w -E '487|0x1e7|1e7|0x01e7'` outside tasks/, *.sha256, *.svg, vendor/,
tools/tests/genesis.d/ (vm.d has no hit), plus a non-word-boundary pass and `printf '%x'`.

Mine (change):
- lib/common.sh:24-26 constant + comment; :3183 tn_detect_network comment
- check-node.sh:2880 comment; update-node.sh:323, :1204 comments
- tools/tests/alerts_test.sh:533 (env mainnet chain id)
- tools/tests/consensus_participation_test.sh:135,137,138 (testnet node answering the mainnet id)
- tools/tests/gateway_setup_test.sh:930,937,946,950,955 (devnet upstream on the mainnet chain)
- tools/tests/network_detect_test.sh:84,87,88 (genesis mainnet), :100, :415 (mainnet genesis that a
  fallback would pick), :148, :184 (mainnet pick/set strings). NOT 542-547.
- tools/tests/primitives_test.sh:602-659 (dd487, gen-487, dup-gen487, chainId 487, root3)
- tools/tests/quorum_guard_test.sh:87,88,139,141 (local/public RPC on mainnet chain)
- tools/tests/setup_passphrase_test.sh:237,250
- tools/tests/check_node_unit_test.sh:138 derives hex from $MAINNET_CHAIN_ID (no literal; add cases)

Ignore (not a chain id):
- prepare-stake.sh:1169 `0x4e487b71` (Solidity Panic(uint256) selector)
- tools/tests/alerts_test.sh:455 `%0487d` (pads a long webhook URL)
- MANIFEST:8,24, MANIFEST.asc:6, aws/requirements-ci.txt, ui/requirements.txt,
  ui/tests/requirements-dev.txt (hashes / signature)

Other owners (not edited):
- ui/: server.py:1408,1422,1424; test_csrf.py:434 (name test_chain_487),435,436;
  test_server_chain.py:401,403,431  -> CHAIN-UI
- docs: OPERATOR.md:187,210,249,814,2263; README.md:748,1159,1804,3394; CHANGELOG.md:380 (history);
  docs/partner/mainnet-node-requirements/...md:36; docs/partner/mno-node-guide/...md:208,242,674;
  followup.md:118,119,121,132,134 (devnet chain-487 genesis: stays),135 (`TN_ALLOW_FAUCET_ON_CHAIN_487`,
  upstream env var name),139,166

## 2. Uses of MAINNET_CHAIN_ID

All equality only. lib/common.sh:2163 (tn_is_public_chain_id, case), :3098/:3100 (menu text,
3 digits either way), :3119 (CHAIN_ID=), :3215/:3218 (tn_detect_network case + message),
:4269/:4271/:4345/:4901 (_tn_rpc_chain_is: RPC hex -> 16# decimal, string ==);
lib/alerts.sh:447 (ALERTS_CHAIN_ID decimal; tn-heartbeat reads `^[0-9]{0,10}$`, 10#, compares to
the RPC's decimal); lib/gateway.sh:291,294,300 (==/!=, name); check-node.sh:329,343,2896;
prepare-stake.sh:698,811 (==, message); setup-node.sh:3359; update-node.sh:1227 (want, compared
after 16#). install-caddy.sh has no direct use (goes through tn_detect_network). Widths:
`{1,15}` hex, `{1,18}` decimal, `{0,10}` heartbeat: 731 fits. No sort, no regex built from the
value, no shell default RPC keyed by id (keyed by network name). Tests: check_node_unit_test.sh:138
converts the constant with printf %x (value-independent). The UI's NETWORK_PUBLIC_RPC is keyed by
id (CHAIN-UI).

## 3-5. Constant, comments, fixtures, new cases (done)

Changed: lib/common.sh, check-node.sh, update-node.sh; tools/tests/{alerts,consensus_participation,
gateway_setup,network_detect,primitives,quorum_guard,setup_passphrase,check_node_unit,prepare_stake}_test.sh.
New cases: network_detect (genesis 731, 0x2db -> mainnet; 487 -> rc 1 + neither-nor message),
primitives (gen-487 rc 1 + message; tn_is_public_chain_id 2017/32285/731/0x2db rc0, 487 rc1),
consensus_participation (mainnet node on 731 passes, on 487 refused), quorum_guard (public RPC on
487 not counted, names 731), gateway_setup (devnet upstream on 0x1e7 fits devnet),
check_node_unit (chain_network 731/487; resolve_network with 0x2db / 0x1e7), prepare_stake
(ps_chain_name 731/2017/32285/487).
Host: all 9 files pass. Against HEAD's lib/common.sh (487) every one of the 9 files fails (pins value).

## 6. Gates (tree: 01664cc + working-tree changes, uncommitted)

Per file (ok/FAIL/skip) host | ubuntu:26.04 | bash:3.2 — all 0 FAIL:
alerts 288/0/3 | 280/0/2 | 280/0/2; consensus_participation 44 | 44 | 44; gateway_setup 488/0/0 |
483/0/3 | 483/0/3; network_detect 165 | 165 | 165; primitives 249/0/6 | 311/0/0 | 291/0/2;
quorum_guard 87 | 87 | 87; setup_passphrase 82 | 82 | 82; check_node_unit 61 | 61 | 61;
prepare_stake 44 | 44 | 44.
check-bash32 clean (211); network-hits clean (153 annotated, 29 files); perl-interp clean (211);
shellcheck --severity=error clean on the 12 changed files; warnings: no new ones
(check_node_unit_test.sh 10 -> 8: two SC2034 gone because the new cases read the vars).
Whole suite: host 81 files 0 failed; ubuntu:26.04 81 files 0 failed (tree f3c72c5 content, before commit). Sidecars of lib/common.sh, check-node.sh, update-node.sh are stale (expected; no test failed on it).
Commit: f3c72c5.

## 7. Final sweep (done)

Outside ui/ and docs: every remaining 487/0x1e7 hit is "keep" (the old id as a negative case or
the comment saying it moved: lib/common.sh:26, the new cases in 8 test files) or "ignore"
(prepare-stake.sh:1169 selector, alerts_test.sh:455 padding, hashes). No pre-existing 731 elsewhere.
