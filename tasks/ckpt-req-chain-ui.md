status: done
agent: CHAIN-UI (worktree /home/drtnarg/coding/telcoin/tnd-req-chain-ui, branch req/chain-ui, base 01664cc)

## Sections
- [x] sweep
- [x] uses
- [x] server
- [x] tests
- [x] gates
- [x] final sweep

## sweep (at 01664cc)
`git grep -n -I -i -E '487|1e7' -- ui`:

| Hit | Class |
|---|---|
| ui/requirements.txt:61, :145 (sha256 hashes) | keep: substring of a hash |
| ui/tests/requirements-dev.txt:42, :86, :92, :95 (sha256 hashes) | keep: substring of a hash |
| ui/server.py:1408 `487: {"name": "Telcoin Mainnet", "slug": "mainnet"}` | change -> 731 |
| ui/server.py:1422 comment "Mainnet (chain 487)" | change -> 731 |
| ui/server.py:1424 `487:   [],` | change -> 731 |
| ui/test_csrf.py:434 `def test_chain_487` | change (rename to 731) |
| ui/test_csrf.py:435-436 resolve_network(487)/NETWORK_PUBLIC_RPC[487] | change -> 731 |
| ui/test_server_chain.py:401, :403, :431 (487 as mainnet) | change -> 731 |

Other forms: no `0x1e7`/`0x01e7`/`hex(487)` anywhere in ui/. `0x7e1`/2017/32285 hits are testnet/devnet (keep).
index.html: networks keyed by slug (netLabel at :4175 maps testnet/devnet/mainnet slugs to names); chainId only stored/displayed (:461, :964, :4189) -> no chain-id table, nothing to change.
ui/dev/serve.py:495 chain_id 2017 testnet fixture (keep). telcoin-ui-helper.sh, install-ui.sh: no chain id.
test_server_contract.py, test_page_wiring.py: no 487/1e7 (nothing for other agents).

## uses
- resolve_network (server.py:1441): dict lookup on chain id; unknown -> .node-meta NETWORK slug fallback (configured True if slug known, else (slug, Slug, False)); no meta -> ("", "", False).
- _node_chain_id (:1935): reverse slug->chain id from NETWORKS (stopped node with NETWORK=mainnet gets the mainnet key).
- network_stake_status (:2316) / _endpoint_plan (:2276): NUMERIC dependency: an endpoint is trusted only when its eth_chainId equals the key (served != chain_id -> skip/log). So the mainnet key must equal what the mainnet public RPC answers (731 = 0x2db). Mainnet list is empty today, so no effect yet.
- _network_consensus (:5676): NETWORK_PUBLIC_RPC.get lookup; empty -> {} -> compare cards "-".
- KNOWN_SLUGS (:5635), status-page name (:5869): slugs/names only, no numeric value.
- Net effect of the old 487 key: a devnet node on upstream's 487 genesis would be labelled "Telcoin Mainnet" (chain id is authoritative); a mainnet node (731) would fall to the .node-meta fallback.

## server
ui/server.py: NETWORKS key 487 -> 731 (comment: mainnet is 731 = MAINNET_CHAIN_ID / #1716; 487 is an upstream devnet genesis id, not listed, resolves as unknown); NETWORK_PUBLIC_RPC key 487 -> 731, comment "Mainnet (chain 731)". +2 comment lines (later line numbers shift by 2).

## tests
- ui/test_csrf.py MainnetAndImagesTest: test_chain_487 -> test_chain_731 (+ only key with slug mainnet is 731); new test_chain_487_is_no_longer_mainnet (not in NETWORKS/RPC; resolve_network(487) == ("", "", False); with .node-meta NETWORK=devnet -> ("devnet", "Adiri Devnet", True)).
- ui/test_server_chain.py: 487 -> 731 at the mainnet-hostname test and test_nothing_to_ask; new test_a_mainnet_answer_needs_chain_731 (endpoint answering 0x1e7 untrusted + logged "serves chain 487, not 731"; endpoint answering 0x2db trusted).
- ui/test_mainnet_flag.py: new ChainIdTieTest (library *_CHAIN_ID vs NETWORKS keys; env TN_UI_TEST_LIB_COMMON overrides the library path) + parser test.

## gates (tree = worktree at commit ad9805c; lib/common.sh still 487)
- pytest (python:3.10-slim): 1 failed, 290 passed, 1277 subtests. Only red: test_mainnet_flag.py::ChainIdTieTest::test_the_server_keys_the_library_chain_ids (lib says 487, expected).
- same with TN_UI_TEST_LIB_COMMON=<copy of lib/common.sh with 731>: 291 passed, 1277 subtests.
- baseline 01664cc (full git archive): 287 passed, 1273 subtests.
- py_compile ui/server.py OK; check-network-hits clean (153 annotated, unchanged).

## final sweep
Remaining 487/1e7 hits under ui/: requirements hashes (keep); server.py:1407 comment naming 487 as the earlier id (keep: history/explanation); test_csrf.py:441-449 and test_server_chain.py:408-417 (keep: assert 487 is NOT mainnet). No hit states 487 as the current mainnet id.

## commit
ad9805c CHAIN-UI: the mainnet chain id is 731 (ui/server.py, ui/test_csrf.py, ui/test_mainnet_flag.py, ui/test_server_chain.py)
Leftover: ./.pytest_cache is root-owned (from the docker run); rm was refused by the safety check, left for the user.
