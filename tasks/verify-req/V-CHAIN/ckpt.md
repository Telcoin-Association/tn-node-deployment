# V-CHAIN checkpoint
status: done
tree: 1a3404b (req/v-chain)

## Sections
- [x] C1 upstream
- [x] C2 code sweep
- [x] C3 behaviour harness
- [x] C4 twin tests + mutation
- [x] C5 documents worklist
- [x] C6 sibling repositories
- [x] REPORT.md: Write refused; full text returned in the hand-back for the orchestrator to save

## C1 (done) upstream telcoin-network, fetched 2026-11-21, origin/main 33bf2a206
- origin/main: crates/types/src/genesis.rs:119 `pub const MAINNET_CHAIN_ID: u64 = 731;` doc `(0x2db)`,
  :117 "Devnet genesis files (`etc/genesis.sh`) use 487, so the chain id alone identifies mainnet."
  chain-configs/mainnet/genesis.yaml:3 `chainId: 731`. Commit 90ed40b39 (#1716, 2026-11-12).
- v0.16.0-adiri (d72cc2bcf) and v0.17.0-adiri (5362a4649): genesis.yaml `chainId: 487`, no
  MAINNET_CHAIN_ID constant; `git tag --contains 90ed40b39` empty. CONFIRMED.
- Other upstream statements (origin/main):
  - docs/src/networks-and-rpc-endpoints.md:24 "Mainnet has not launched. It will use chain ID `0x2db` (731)
    and the public RPC URL https://rpc.telcoin.network ... check that `eth_chainId` returns `0x2db`"
    (tags say `0x1e7` (487)).
  - docs/src/evm-compatibility.md:106 `| Mainnet | 731 |`, :217 "731 (mainnet), 2017 (testnet)".
  - chain-configs/README.md:42 "`mainnet/` (chain ID 731) holds placeholders"; bootstrap_servers.yaml:1.
  - cli README "### Mainnet checks": "Mainnet uses chain id 731. On that chain id the node refuses to
    start in two cases, and no flag lifts either": cleartext bls.key without passphrase
    (e.g. `--bls-passphrase-source no-passphrase`); a faucet build (also refuses the embedded mainnet
    genesis hash whatever its chain id). WARN for stale bls.key beside bls.kw on mainnet.
  - Faucet opt-in is now `--allow-faucet-on-chain` / env `TN_ALLOW_FAUCET_ON_CHAIN` (any chain other than
    adiri or mainnet; adiri needs none). `--allow-faucet-on-chain-487` / `TN_ALLOW_FAUCET_ON_CHAIN_487`
    are GONE; `--allow-cleartext-bls-key` removed (rejected by clap; test node.rs:1219).
  - Startup line: `node build: faucet=<bool> adiri=<bool> chain_id=<n> genesis_hash=<0x..>`
    (README example `chain_id=731`).
  - Messages: "this binary was built with the faucet feature and refuses mainnet (chain id 731)";
    "refusing to start on mainnet (chain id 731) with a cleartext BLS key: ...".
  - Devnet: etc/genesis.sh:63 and etc/local-testnet.sh `--chain-id 0x1e7`; etc/README.md:191
    "The chain id is `0x1e7`"; etc/compose.yaml NODE_RECORD_API_CHAIN_ID "487".
  - None of this (cleartext refusal, faucet flag, startup line) is in v0.16.0/v0.17.0-adiri.

## C2 (done) code sweep at 1a3404b (275 files: tracked minus tasks/, vendor/, genesis.d/, *.sha256)
Patterns: -i '487|1e7' (no word boundary, so dd487/chain-487/0x01e7/1E7 included), '731|2db',
run-time hex (printf %x, 16#, hex(), int(,16), toString(16), parseInt), chainId/chain_id/--chain-id,
TN_CHAIN, observability/, aws/, .github/, index.html, ui/dev/serve.py.
- A (mainnet id stated as current, still 487) in CODE: NONE.
- B: lib/common.sh:26 (comment "it was 487 before"); ui/server.py:1407 (comment); tests:
  check_node_unit_test.sh:141-148, consensus_participation_test.sh:158-168, gateway_setup_test.sh:960-964,
  network_detect_test.sh:92-98, prepare_stake_test.sh:243-246, primitives_test.sh:602-678,
  quorum_guard_test.sh:142-145, ui/test_csrf.py:441-449, ui/test_server_chain.py:408-417 (negative tests).
- C: prepare-stake.sh:1169 0x4e487b71 (Panic(uint256) selector); alerts_test.sh:455 %0487d (padding);
  hashes in aws/requirements-ci.txt (5), ui/requirements.txt (2), ui/tests/requirements-dev.txt (4),
  MANIFEST (2), MANIFEST.asc (1); SVG path data (docs/partner/assets/logos, 4 files).
- Documents: CHANGELOG.md, followup.md, OPERATOR.md, README.md, guide, mainnet one-pager -> C5.
- Run-time hex: every site converts hex->decimal before comparing (lib/common.sh:4345, update-node.sh:1237,
  gateway.sh:281, tn-heartbeat.sh:274, check-node hex_to_dec, ui hex_to_dec); none builds a hex id.
- observability: chain label is the NAME (TN_CHAIN telcoin/adiri/devnet), no id. aws/, .github/: no id.
  index.html: no chain-id table (names by slug; tooltip shows s.chain_id). serve.py: only 2017.
- Reverse sweep 731/0x2db: all code hits mean mainnet (lib/common.sh:28 constant, comments check-node:2880,
  update-node:323/1204, lib/common.sh:3232, ui/server.py:1406-1427, tests). chain_configs_refresh_test.sh:368
  `node mainnet 731` (FIX-B fixture) right. Docs: only `#1731` issue numbers (C). Nothing else keyed by 731.

## C3 (harness written, all green) tasks/verify-req/V-CHAIN/harness/
h_common.sh 56 ok; h_check.sh 12 ok; h_update.sh 10 ok; h_addons.sh 10 ok; h_stake.sh 4 ok;
h_entry.sh setup 2 / edit 8 / caddy 2 ok; h_ui.py 16 ok (python:3.10-slim).
Surprising answers (candidates):
- caddy_mainnet_gate, no NETWORK key + genesis 487: refusal text says "no readable genesis chain id"
  although 487 was read (misleading wording; fails safe).
- UI resolve_network: unknown live chain id falls back to .node-meta NETWORK with configured=True:
  chain 487 + NETWORK=mainnet -> Telcoin Mainnet; chain 487 + NETWORK=testnet -> Adiri Testnet
  (6.1 accepted "named through .node-meta"; labels only, stake/compare use the chain id -> none).
- devnet is 32285-only in check-node (mismatch), update-node verify_consensus_participation
  (rc 1 "runs chain id 487, not 32285 (devnet)") and alerts (ALERTS_CHAIN_ID=32285 -> heartbeat
  "wrong chain"), while gateway treats devnet as "any other id": pre-existing, not from 1a3404b.
- caddy_mainnet_gate's public-RPC fallback (node_is_staked_validator addr MAINNET_RPC_URL) has no
  _tn_rpc_chain_is check, unlike the quorum guard and _tn_mode_unknown_wait_url (pre-existing).
- Pre-change mainnet rehearsal host with genesis 487: with NETWORK=mainnet everything still says mainnet
  and the chain checks then refuse (check-node mismatch, update apply rc 1, heartbeat wrong chain if
  alerts.env re-rendered; an old alerts.env keeps ALERTS_CHAIN_ID=487 until setup-alerts refresh).
  Without the key: detect rc 1 -> update refuses, caddy refuses, quorum guard rc 2; all fail closed.
C3 gates: 6 *.sh shebang, bash -n (bash 5 and bash:3.2), shellcheck --severity=error clean,
check-bash32 clean. Harness also green in ubuntu:26.04 and bash:3.2 (same counts).

## C4 (done)
- Nine changed fixtures: host 9/9 exit 0 (bash 5.3.9); ubuntu:26.04 9/9; bash:3.2 9/9 (0 failed).
- UI: python:3.10-slim, ro mount, PYTHONDONTWRITEBYTECODE=1, -p no:cacheprovider: 312 passed, 1277 subtests.
- Mutation (scratch copies via git archive):
  mut-lib (MAINNET_CHAIN_ID="487" only): full tools/tests suite 84 files, 9 failed = exactly the nine
  fixtures (FAIL counts: alerts 1, check_node_unit 3, consensus_participation 3, gateway_setup 5,
  network_detect 8, prepare_stake 1, primitives 9, quorum_guard 12, setup_passphrase 2); UI 1 failed
  (ChainIdTieTest.test_the_server_keys_the_library_chain_ids); my harness fails 67 checks.
  mut-ui (NETWORKS key only -> 487): UI 3 failed (test_csrf test_chain_487_is_no_longer_mainnet,
  test_chain_731; ChainIdTieTest); test_server_chain does not notice (it patches NETWORK_PUBLIC_RPC).
  mut-ui2 (NETWORKS + NETWORK_PUBLIC_RPC keys): same 3. The tie test ties NETWORKS only;
  NETWORK_PUBLIC_RPC's key is pinned by test_csrf's literal [731] lookup.

## C5 (done; table goes into REPORT) -- PDFs: mainnet one-pager p1; guide p10, p11, p27; spec and
testnet one-pager none. Live run.telcoin.network (source_commit 01664cc): mainnet one-pager 1 hit, guide 3.
Live eth_chainId 2026-11-21: rpc.devnet.telcoin.network 0x7e1d (32285), rpc.telcoin.network 0x7e1, rpc.adiri.tel 0x7e1.
=> followup.md:134 "devnet deployment runs a faucet image on a chain-487 genesis" is not what the devnet runs
   (32285; devnet-genesis benchmark/README.md:5 "devnet is 32285", bench images ENV TN_ALLOW_FAUCET_ON_CHAIN=true),
   and TN_ALLOW_FAUCET_ON_CHAIN_487 is renamed upstream to TN_ALLOW_FAUCET_ON_CHAIN. Spec 4 "stays 487" is wrong.

## C6 (done)
Sibling repositories checked read-only; the list went to the maintainer and is not in this public record.

