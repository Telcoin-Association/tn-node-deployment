# V-CHAIN report: the mainnet chain id is 731

Verifier V-CHAIN, worktree `/home/drtnarg/coding/telcoin/tnd-req-v-chain` (branch `req/v-chain`) at the integrated tip `1a3404b`. Upstream: the local `telcoin-network` clone, fetched 2026-11-21, `origin/main` at `33bf2a206`. Harness: `tasks/verify-req/V-CHAIN/harness/`, written before I read the implementers' checkpoints. Checkpoint: `tasks/verify-req/V-CHAIN/ckpt.md`.

Verdict: the code change is complete and correct. No code or test line still gives 487 as the current mainnet id, and every place that names 731 means mainnet. Every chain comparison behaves as intended for 731, `0x2db`, 487, `0x1e7`, 2017, `0x7e1`, 32285 and an unknown id. Setting the library constant back to 487 makes exactly the nine changed fixtures fail, plus the UI tie test.

The findings are:
- one wrong instruction for the document wave;
- one misleading message that the change makes reachable;
- one pre-existing trust gap;
- some observations.

## Findings

| Id | Severity | One line |
|---|---|---|
| VC-1 | Medium | The doc-wave instruction for `followup.md` keeps `TN_ALLOW_FAUCET_ON_CHAIN_487` and "the devnet's chain-487 genesis". Upstream renamed the opt-in, and the devnet runs 32285. |
| VC-2 | Low | install-caddy's refusal for a host with no `NETWORK` and a 487 genesis says "no readable genesis chain id", although 487 was read. |
| VC-3 | Low | `caddy_mainnet_gate` asks `https://rpc.telcoin.network` for a mainnet stake without checking that it serves chain 731 (pre-existing). |
| VC-4 | Low | Spec section 4's document list misses `OPERATOR.md:814`, the guide's `:674`, `followup.md:139` and `:166`. |
| VC-5 | Info | Devnet means "exactly 32285" in check-node, update-node and the heartbeat, but "any other id" in the gateway and `OPERATOR.md:1885` (pre-existing). |
| VC-6 | Info | For a node on an unknown live chain (487), the UI shows the `.node-meta` name with `configured: true` and no mismatch warning (accepted in 6.1). |
| VC-7 | Info | A host whose `alerts.env` was written before `1a3404b` with `NETWORK=mainnet` keeps `ALERTS_CHAIN_ID=487` until `setup-alerts.sh` refreshes it. |
| VC-8 | Info | CHAIN-UI left a root-owned `.pytest_cache` in its worktree `tnd-req-chain-ui` (housekeeping). |

### VC-1 (Medium): the followup.md guidance is out of date

**Expected:** the doc wave rewrites the U-3/U-5 item of `followup.md` to match upstream `origin/main`.

**Got:** spec section 4 says "the sentence about the devnet deployment's chain-487 genesis is about devnet and stays 487". CHAIN-SH's sweep keeps `TN_ALLOW_FAUCET_ON_CHAIN_487` as "upstream env var name". Both are wrong:
- Upstream now has `--allow-faucet-on-chain`, with env `TN_ALLOW_FAUCET_ON_CHAIN`, for any chain other than adiri (2017) and mainnet (731).
- `--allow-faucet-on-chain-487`, `TN_ALLOW_FAUCET_ON_CHAIN_487` and `--allow-cleartext-bls-key` are gone. `node.rs:1219` tests that the cleartext flag is rejected.
- On 731, no flag lifts either refusal (cli README, "Mainnet checks").
- The Association's devnet answers `eth_chainId` with `0x7e1d` (32285), not 487. I checked live on 2026-11-21, and `devnet-genesis/benchmark/README.md:5` says "devnet is 32285".
- The devnet's bench images already carry `ENV TN_ALLOW_FAUCET_ON_CHAIN=true` (`devnet-genesis/benchmark/arms/MANIFEST-FIELDS.md:391`).
- `#1716` is merged (2026-11-12), not "open". No release tag contains it.

**Reproduction:**
- `git -C /home/drtnarg/coding/telcoin/telcoin-network grep -n -E 'ALLOW_FAUCET|allow-cleartext' origin/main -- crates/telcoin-network-cli/src/node.rs crates/telcoin-network-cli/README.md`
- `git -C /home/drtnarg/coding/telcoin/telcoin-network tag --contains 90ed40b39` prints nothing.
- `curl -s -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' https://rpc.devnet.telcoin.network` answers `0x7e1d`.

**Suggested fix:** use the FU-3 wording in the worklist, and correct spec section 4 before wave 3 starts.

### VC-2 (Low): misleading refusal in install-caddy

**Expected:** a host with no `NETWORK` in `.node-meta` and a readable genesis on chain 487 is refused with a reason that names what was found. 1a3404b makes this case reachable: pre-change mainnet rehearsal hosts and upstream docker devnets sit on 487.

**Got:** `install-caddy.sh:2489` prints `The network of this node cannot be told (no NETWORK in .node-meta and no readable genesis chain id), so this run cannot confirm it is not a staked mainnet validator. ...`. The genesis id was read; it is 487. The refusal fails safe; only the reason is wrong.

**Reproduction:** `bash tasks/verify-req/V-CHAIN/harness/h_entry.sh caddy` (the rows "genesis 487 key -").

**Suggested fix:** either print `no NETWORK in .node-meta, and the genesis chain id is neither ${MAINNET_CHAIN_ID} (mainnet) nor ${TESTNET_CHAIN_ID} (testnet)`, or print `tn_detect_network`'s own stderr reason instead of dropping it with `2>/dev/null`. This needs an install-caddy version bump, which is outside this round's packages.

### VC-3 (Low): the caddy gate's public-RPC fallback has no chain check (pre-existing)

**Expected:** like `_tn_guard_unreadable` (`lib/common.sh:4367`) and `_tn_mode_unknown_wait_url` (`:4999`), the gate reads a mainnet stake from the public RPC only after `_tn_rpc_chain_is "$pub" "$MAINNET_CHAIN_ID"` succeeds.

**Got:** `install-caddy.sh:2500` calls `node_is_staked_validator "$addr" "$MAINNET_RPC_URL"` whenever the local read fails (rc 2), without that check.
- `https://rpc.telcoin.network` answers `0x7e1` today.
- A mainnet address read from the testnet registry returns rc 1 ("not staked"), and the gate then passes.
- This cannot happen while `TN_MAINNET_ENABLED=0`.
- After launch the gap is open only if the public RPC serves another chain while a staked validator's own RPC is down.

**Reproduction:** compare `install-caddy.sh:2496-2506` with `lib/common.sh:4366-4370`. The harness shows the quorum guard refusing a public RPC that answers `0x1e7` (`h_common.sh`, "_tn_guard_unreadable ... public 0x1e7": rc 2). The caddy gate has no such step.

**Suggested fix:** add `_tn_rpc_chain_is "$MAINNET_RPC_URL" "$MAINNET_CHAIN_ID" || rc=2` before the fallback read. A failure then lands in the existing "Could not read the stake status" refusal.

### VC-4 (Low): spec section 4's list of document lines is incomplete

**Expected:** the list names every line that states the id.

**Got:** the list names `OPERATOR.md:187, :210, :249, :2263`, the guide's `:208, :242`, the one-pager's `:36`, `README.md:1804` "and any other line above `## Changelog`", and the `followup.md` items in general. It does not name:
- `OPERATOR.md:814` and the guide's `:674`, which quote check-node's message `... not chain 487 (mainnet) -- skipping the network comparison` (the code now prints 731);
- `README.md:748` and `:1159`, although "any other line" covers them;
- `followup.md:139` (the fork-epoch refusal "on chains 487 and 2017");
- `followup.md:166` ("the chain 487 guard branch adds the startup line").

**Reproduction:** `git grep -n -I -i -E '487|1e7' -- '*.md' ':!tasks/'`

**Suggested fix:** give the doc writers the worklist below instead of the spec's list.

### VC-5 (Info): devnet has two models (pre-existing, not from 1a3404b)

check-node, `verify_consensus_participation` and `alerts_write_env` hold a `NETWORK=devnet` node to chain 32285. The gateway's `_gw_chain_fits devnet` accepts any id except 731 and 2017, and `OPERATOR.md:1885` says "a devnet is any other". Spec section 4 says "a devnet is any other chain id" stays true, but that holds only for the gateway.

For a `NETWORK=devnet` node on upstream's 487 devnet genesis:
- check-node reports `Chain ID mismatch: 0x1e7 (487) -- .node-meta says devnet (chain 32285)`;
- the update-node apply fails with `telcoin runs chain id 487, not 32285 (devnet).` (rc 1);
- the heartbeat reports `wrong chain: rpc reports 487, expected 32285`.

**Reproduction:** `h_check.sh` ("meta devnet, local 0x1e7"), `h_update.sh` ("0x1e7 NETWORK=devnet"), `h_addons.sh`.

**Suggested fix:** nothing this round. If devnets on upstream's genesis matter, pick one rule and document it.

### VC-6 (Info): the UI labels by `.node-meta` for an unknown live chain

`resolve_network(487, t)` gives:

| NETWORK in .node-meta | Result |
|---|---|
| mainnet | `("mainnet", "Telcoin Mainnet", True)` |
| testnet | `("testnet", "Adiri Testnet", True)` |
| devnet | `("devnet", "Adiri Devnet", True)` |

The page shows that name in the nav pill, with tooltip `· chain id 487`, and never says the chain is wrong. Stake reads and the compare cards key on the chain id, and 487 is not in `NETWORK_PUBLIC_RPC`, so nothing is asked of the wrong network. Section 6.1 accepts this ("a node on 487 is named through .node-meta"). I record it because the shell reports the same node as a mismatch.

**Reproduction:** `h_ui.py`.

### VC-7 (Info): an old alerts.env on a rehearsal host

`alerts_write_env` now writes `ALERTS_CHAIN_ID=731` for mainnet (`h_addons.sh`). A file written by an older library keeps `487` until `setup-alerts.sh` rewrites it (enable or refresh). Once that node's RPC answers `0x2db`, the heartbeat reports `wrong chain: rpc reports 731, expected 487`.

Setup refuses mainnet while `TN_MAINNET_ENABLED=0`, so only a hand-made rehearsal host can have such a file. The fix is to run the refresh: `sudo bash setup-alerts.sh`.

### VC-8 (Info): root-owned leftover

`/home/drtnarg/coding/telcoin/tnd-req-chain-ui/.pytest_cache` is root-owned. It came from CHAIN-UI's Docker pytest run, which did not pass `-p no:cacheprovider`; CHAIN-UI's checkpoint mentions it. The user removes it with sudo.

## C1. Upstream (confirmed)

**origin/main:**
- `crates/types/src/genesis.rs:119`: `pub const MAINNET_CHAIN_ID: u64 = 731;`, documented as `0x2db`.
- `:117`: "Devnet genesis files (`etc/genesis.sh`) use 487, so the chain id alone identifies mainnet."
- `chain-configs/mainnet/genesis.yaml:3`: `chainId: 731`.
- The change came in `90ed40b39` (#1716, 2026-11-12).

**Tags:** at `v0.16.0-adiri` (`d72cc2bcf`) and `v0.17.0-adiri` (`5362a4649`), `genesis.yaml` says `chainId: 487` and there is no `MAINNET_CHAIN_ID`. `git tag --contains 90ed40b39` is empty.

**Other upstream statements an operator document here should agree with (origin/main):**
- `docs/src/networks-and-rpc-endpoints.md:24`: "Mainnet has not launched. It will use chain ID `0x2db` (731) and the public RPC URL https://rpc.telcoin.network ... check that `eth_chainId` returns `0x2db` before sending anything through it." Both tags say `0x1e7` (487) here.
- `docs/src/evm-compatibility.md:106, :217`: mainnet 731.
- `chain-configs/README.md:42`: "`mainnet/` (chain ID 731) holds placeholders".
- cli README, "Mainnet checks": "Mainnet uses chain id 731. On that chain id the node refuses to start in two cases, and no flag lifts either":
  - a cleartext `bls.key` read without a passphrase (for example `--bls-passphrase-source no-passphrase`);
  - a `faucet` build. A faucet build also refuses the embedded mainnet genesis hash, whatever its chain id.
- On mainnet, a stale `bls.key` beside `bls.kw` gives a WARN.
- The faucet opt-in is `--allow-faucet-on-chain`, with env `TN_ALLOW_FAUCET_ON_CHAIN`:
  - it accepts 1/0, true/false, yes/no, on/off, t/f and y/n, and an empty value counts as unset;
  - it applies to chains other than adiri and mainnet, and adiri needs no flag;
  - the `_487` names and `--allow-cleartext-bls-key` are gone.
- At startup the node logs `node build: faucet=<bool> adiri=<bool> chain_id=<n> genesis_hash=<0x..>` (the README example shows `chain_id=731`).
- `--version` lists `faucet` for a faucet build and `adiri,faucet` for an adiri build.
- Messages: `this binary was built with the faucet feature and refuses mainnet (chain id 731)` and `refusing to start on mainnet (chain id 731) with a cleartext BLS key: ...`.
- Devnet: `etc/genesis.sh:63` and `etc/local-testnet.sh:114, :123` use `--chain-id 0x1e7`, and `etc/README.md:191` says "The chain id is `0x1e7`".
- None of the above is in `v0.16.0-adiri` or `v0.17.0-adiri`.
- The fork-epoch override refusal (#1734, U-12) is not merged.

## C2. Code sweep at 1a3404b

**Scope:** 275 tracked files, excluding `tasks/`, `vendor/`, `tools/tests/genesis.d/` and `*.sha256`.

**Passes:**
- `487|1e7`, case-insensitive with no word boundary, so `dd487`, `chain-487`, `0x01e7` and `1E7` are all caught;
- `731|2db`;
- run-time hex: `printf '%x'`, `16#`, `hex(`, `int(…,16)`, `toString(16)`, `parseInt`;
- `chainId`, `chain_id`, `--chain-id`, `TN_CHAIN`;
- the directories `observability/`, `aws/`, `.github/`, plus `ui/static/index.html` and `ui/dev/serve.py`.

**Classes:**
- **A (the mainnet id given as the current value, still 487), in code:** none.
- **B (487 kept on purpose):**
  - comments: `lib/common.sh:26` ("it was 487 before") and `ui/server.py:1407`;
  - negative tests: `check_node_unit_test.sh:141-148`, `consensus_participation_test.sh:158-168`, `gateway_setup_test.sh:960-964`, `network_detect_test.sh:92-98`, `prepare_stake_test.sh:243-246`, `primitives_test.sh:602-678`, `quorum_guard_test.sh:142-145`, `ui/test_csrf.py:441-449` and `ui/test_server_chain.py:408-417`.
- **C (not a chain id):**
  - `prepare-stake.sh:1169` `0x4e487b71`, the Panic selector;
  - `alerts_test.sh:455` `%0487d`;
  - hashes: `aws/requirements-ci.txt` (5), `ui/requirements.txt` (2), `ui/tests/requirements-dev.txt` (4), `MANIFEST` (2), `MANIFEST.asc` (1);
  - SVG path data in 4 logos.
- **Documents:** see C5.

**Other checks:**
- Every run-time hex site converts the RPC's hex to decimal before comparing; none builds a hex id from the constant.
- `observability/` labels the chain by network name (`TN_CHAIN`), not by id.
- `aws/` and `.github/` contain no chain id.
- `index.html` has no chain-id table: it names networks by slug, and the tooltip shows the server's `chain_id`.
- `serve.py` contains only 2017.

**Reverse sweep:** every 731 in code means mainnet. That covers the constant at `lib/common.sh:28`, the comments at `check-node.sh:2880`, `update-node.sh:323, :1204` and `lib/common.sh:3232`, `ui/server.py:1406-1427`, and the tests (including `chain_configs_refresh_test.sh:368`). Nothing else is keyed by 731. The `#1731` hits in the documents are issue numbers.

**Compared with the implementers' sweep tables (`ckpt-req-chain-sh.md`, `ckpt-req-chain-ui.md`):**
- `followup.md:134`: CHAIN-SH says "devnet chain-487 genesis: stays"; I say it needs rewording (VC-1).
- `followup.md:135`: CHAIN-SH says "`TN_ALLOW_FAUCET_ON_CHAIN_487`, upstream env var name"; that name is gone upstream (VC-1).
- `README.md:3394`: CHAIN-SH listed it without a class; it is history, keep.
- Everything else matches, and neither table missed a code hit.

## C3. Behaviour (my harness: all green on host bash 5.3, ubuntu:26.04 and bash:3.2)

**Library (lib/common.sh):**
- `tn_genesis_chain_id` / `tn_detect_network` with no NETWORK key:
  - 731, `0x2db`, `0x2DB`, `0x02db` and JSON `"0x2db"` give mainnet;
  - 2017 and `0x7e1` give testnet;
  - 487, `0x1e7`, `0x1E7`, `0x01e7`, 32285, `0x7e1d` and 12345 give rc 1, with the reason `... (487) is neither 731 nor 2017`.
- With a NETWORK key, the key decides: `NETWORK=mainnet` over a 487 genesis gives mainnet. `NETWORK=devnet` over a 731 genesis gives rc 1, with no genesis fallback.
- `tn_is_public_chain_id` gives rc 0 for 731, 0x2db, 2017, 0x7e1, 32285 and 0x7e1d, and rc 1 for 487, 0x1e7 and 12345.
- `select_network` prints `  2) Mainnet        (Chain ID: 731)  -- for production (coming soon)` and never 487. With mainnet stubbed on, choice 2 gives `mainnet|731|telcoin|https://rpc.telcoin.network`.
- `json_set_network mainnet` is refused while mainnet is off; stubbed on, it sets 731.
- `_tn_rpc_chain_is` against 731 passes `0x2db`, `0x2DB` and `0x02db`, and fails `0x1e7`, `0x7e1` and `0x7e1d`.
- The quorum guard trusts the public RPC only on `0x2db`. On `0x1e7` it returns rc 2 with `... https://rpc.telcoin.network does not answer with chain 731, so the stake was not read there`.
- `_tn_mode_unknown_wait_url` asks the public RPC on `0x2db` and nobody on `0x1e7`.
- With no key and a 487 genesis, `_tn_guard_network` returns "", so the guard returns rc 2.

**check-node:**
- `chain_network` maps 731 to mainnet and 487 to "".
- Section 2, no meta, local `0x1e7`: `Chain ID 0x1e7 (487) is not a Telcoin network (testnet 2017, mainnet 731, devnet 32285)`, counted as 1 issue.
- Section 2, no meta, local `0x2db`: mainnet, taken from the local chain id.
- Meta says mainnet, local `0x1e7`: `Chain ID mismatch: 0x1e7 (487) -- .node-meta says mainnet (chain 731)`.
- `check_network_chain` reports `serves chain 487, not chain 731 (mainnet)` and `serves chain 2017 (testnet), not chain 731 (mainnet)`.

**update-node:**
- In `verify_consensus_participation`, a mainnet node answering `0x1e7` fails with `telcoin runs chain id 487, not 731 (mainnet).` (rc 1). A node answering `0x2db` passes the chain check.
- With no key and a 487 genesis, the apply check warns "network unknown, chain id (487) not checked".
- In `detect_network` / `image_network`, no key with a 487 genesis gives rc 1, so the update refuses (fails closed). A 731 genesis gives mainnet, with no cargo features.

**prepare-stake:**
- `ps_chain_name` maps 731 to mainnet and 487 to "not a Telcoin network".
- With `NETWORK=mainnet`, `EXPECTED_CHAIN_ID` is 731 and the RPC is `https://rpc.telcoin.network`.
- An RPC answering `0x1e7` gives `serves chain 487 (not a Telcoin network), not chain 731 (mainnet)` and exit 2.

**gateway:**
- `_gw_chain_fits`: mainnet fits only 731, testnet only 2017, and devnet anything else (487 and 32285 both fit).
- A mainnet upstream answering `0x1e7` is refused with `is on chain 487 (neither mainnet nor testnet)`.

**alerts and heartbeat:**
- `alerts_write_env` writes `ALERTS_CHAIN_ID=731` for mainnet.
- The heartbeat accepts `0x2db`, `0x2DB` and `0x02db` against 731. On `0x1e7` it reports `wrong chain: rpc reports 487, expected 731`.

**edit-config, `allow_private_forward_targets=true`:**
- Refused on 731, 0x2db and 2017, with `this node runs chain 731 (mainnet), a public network`.
- Allowed on 487, 0x1e7, 32285 and 12345.

**install-caddy, `caddy_mainnet_gate`:**
- No key and a 731 genesis: treated as mainnet. A staked node is refused; an unstaked node passes.
- No key and a 487 genesis: refused, with the wrong reason (VC-2).
- `NETWORK=mainnet` with a 487 genesis: still mainnet.

**UI:**
- `NETWORKS` and `NETWORK_PUBLIC_RPC` are both keyed `[731, 2017, 32285]`, and `NETWORK_PUBLIC_RPC[731]` is `[]`.
- `resolve_network(731)` gives `("mainnet", "Telcoin Mainnet", True)`. `resolve_network(487)` with no meta gives `("", "", False)`.
- `_node_chain_id` for a stopped `NETWORK=mainnet` node gives 731.
- `network_stake_status` never sends `eth_call` to an endpoint answering `0x1e7`; it logs `serves chain 487, not 731` and takes the answer from the `0x2db` endpoint.
- Page for a node on 731: "Telcoin Mainnet", tooltip `· chain id 731`.
- Page for a node on 487: the `.node-meta` name, or `Network` / `—` with no meta (VC-6).

**A pre-change mainnet rehearsal host on a 487 genesis:**
- With NETWORK=mainnet, every script still says mainnet. The chain checks then refuse: check-node reports a mismatch, the update apply returns rc 1, and the heartbeat reports a wrong chain (VC-7).
- Without the key, `tn_detect_network` returns rc 1. Then update refuses, caddy refuses, the quorum guard returns rc 2, and private forward targets become allowed.
- Everything fails closed except the forward-target setting. Mainnet never ran on 487, so no real host is affected.

## C4. Twin tests and mutation

- The nine changed fixtures pass on host (9/9), in `ubuntu:26.04` (9/9) and in `bash:3.2` (9/9).
- UI suite in `python:3.10-slim` (read-only mount, `PYTHONDONTWRITEBYTECODE=1`, `-p no:cacheprovider`): 312 passed, 1277 subtests.

**Mutation: library constant only, `MAINNET_CHAIN_ID="487"`:**
- Whole `tools/tests` suite: 84 files, 9 failed, exactly the nine changed fixtures.
- Failures per file: alerts 1, check_node_unit 3, consensus_participation 3, gateway_setup 5, network_detect 8, prepare_stake 1, primitives 9, quorum_guard 12, setup_passphrase 2.
- UI suite: only `ChainIdTieTest::test_the_server_keys_the_library_chain_ids` fails.
- My harness: 67 checks fail.

**Mutation: only the UI's NETWORKS key back to 487:**
- 3 UI tests fail: `test_csrf::test_chain_487_is_no_longer_mainnet`, `::test_chain_731` and the tie test.
- `test_server_chain` does not notice, because it patches `NETWORK_PUBLIC_RPC`.

**Mutation: both UI keys back to 487:** the same 3 fail.

The tie test covers `NETWORKS` only; `NETWORK_PUBLIC_RPC`'s key is pinned by the literal `[731]` lookup in `test_csrf`. That is enough coverage.

## C5. Documents worklist (for wave 3)

**Classes:**
- **change:** a current statement; change it to 731 (`0x2db`).
- **history:** an entry for a released version; keep it.
- **devnet:** about devnet; keep 487.
- **reword:** the row gives new text.
- **add:** a new entry.
- **keep:** no change.

Line numbers are at `1a3404b`. Quoted messages must match what the code at the frozen tip prints (shown in C3).

| Row | File:line | Current text | Class | New text |
|---|---|---|---|---|
| RM-1 | `README.md:748` | `any Telcoin chain ID (2017, 487, 32285) passes with a note` | change | `(2017, 731, 32285)` |
| RM-2 | `README.md:1159` | `` `true` is refused on testnet (2017) and mainnet (487) `` | change | `mainnet (731)` |
| RM-3 | `README.md:1804` | `` \| Mainnet \| 487 (`0x1e7`) \| `https://rpc.telcoin.network`, not launched yet \| ... `` | change | `` \| Mainnet \| 731 (`0x2db`) \| `` (F12) |
| RM-4 | `README.md:1807` | `... so check eth_chainId before you trust an answer from it.` | reword (optional) | add ``Mainnet will answer `0x2db` (731).`` |
| RM-5 | `README.md:3394` | `` `MAINNET_CHAIN_ID` is 487 `` (the lib/common v1.6.0 entry, below `## Changelog` at :2044) | history | keep |
| RM-6 | `README.md`, `## Changelog` | no entries yet for lib/common 2.2.4, check-node 2.2.1, update-node 2.1.1 and telcoin-ui 2.1.2 | add | `The mainnet chain id is 731 (0x2db), as on telcoin-network main since #1716; it was 487, which upstream devnet genesis files use now.` |
| OP-1 | `OPERATOR.md:187` | `` \| Mainnet \| 487 (`0x1e7`) \| `https://rpc.telcoin.network` is reserved; ... `` | change | `` 731 (`0x2db`) `` |
| OP-2 | `OPERATOR.md:210` | `` `"result":"0x7e1"` is the testnet, `0x1e7` mainnet and `0x7e1d` devnet. `` | change | `` `0x2db` mainnet `` |
| OP-3 | `OPERATOR.md:249` | `` `2) Mainnet (Chain ID: 487)` is marked coming soon `` | change | `` `2) Mainnet (Chain ID: 731)` `` |
| OP-4 | `OPERATOR.md:814` | `` `https://rpc.telcoin.network serves chain 2017 (testnet), not chain 487 (mainnet) -- skipping the network comparison` `` | change (quoted message) | `not chain 731 (mainnet)` |
| OP-5 | `OPERATOR.md:2263` | `` `https://rpc.telcoin.network serves chain 2017 (testnet), not chain 487 (mainnet)` `` (prepare-stake, exit 2) | change (quoted message) | `not chain 731 (mainnet)` |
| OP-6 | `OPERATOR.md:1885` | `Mainnet and testnet each have one chain id, and a devnet is any other.` | keep | (true for the gateway; see VC-5) |
| OP-7 | `OPERATOR.md:2167` | ``On testnet the answer is `"result":"0x7e1"` (chain ID 2017).`` | keep | testnet |
| GD-1 | `docs/partner/mno-node-guide/mno-node-guide.md:208` | `` \| Mainnet \| 487 (`0x1e7`) \| `https://rpc.telcoin.network` is planned and set at launch \| ... `` | change | `` 731 (`0x2db`) `` |
| GD-2 | `…/mno-node-guide.md:242` | `` `"result":"0x7e1"` is the testnet, `0x1e7` mainnet and `0x7e1d` devnet. `` | change | `` `0x2db` mainnet `` |
| GD-3 | `…/mno-node-guide.md:674` | ``for example `https://rpc.telcoin.network serves chain 2017 (testnet), not chain 487 (mainnet) -- skipping the network comparison` `` | change (quoted message) | `not chain 731 (mainnet)` |
| GD-4 | `…/mno-node-guide.md:1347` | ``On testnet the answer is `"result":"0x7e1"` (chain ID 2017).`` | keep | testnet |
| GD-5 | `docs/partner/mno-node-guide/metadata.yaml:9-10` | `version: "1.12"`, `date: November 2026` | add | bump the version and rebuild the PDF (487 is on PDF pages 10, 11 and 27 today) |
| MP-1 | `docs/partner/mainnet-node-requirements/mainnet-node-requirements.md:36` | `` \| Chain ID \| 487 (`0x1e7`) \| `` | change | `` \| Chain ID \| 731 (`0x2db`) \| `` (F12) |
| MP-2 | `docs/partner/mainnet-node-requirements/metadata.yaml:13-14` | `version: "1.2"` | add | bump the version and rebuild (487 is on PDF page 1 today); check that it stays one page |
| TP-1 | `docs/partner/testnet-node-requirements/*` | `badge: Testnet · chain ID 2017`; `:32` ``\| Chain ID \| 2017 (`0x7e1`) \|`` | keep | no mainnet id |
| TS-1 | `docs/partner/technical-specification/*` | no chain id statement, none in the PDF | keep | no change |
| FU-1 | `followup.md:118-122` | `The public RPC for chain 487 is not settled. The UI's NETWORK_PUBLIC_RPC has an empty list for 487 ... Closes at launch: confirm the endpoint answers chain 487 and fill the UI list.` | reword | `- The public RPC for chain 731 (0x2db) is not settled. The UI's NETWORK_PUBLIC_RPC has an empty list for 731, so its comparison cards show "-", while MAINNET_RPC_URL in lib/common.sh is https://rpc.telcoin.network, which check-node and the restart-window epoch reads use and which answers for chain 2017 until launch. Closes at launch: confirm the endpoint answers 0x2db and fill the UI list.` |
| FU-2 | `followup.md:132-133` | `U-3 and U-5, the chain 487 guard (faucet opt-in, build features in --version and the startup line, cleartext BLS key refused on 487): issues #1725 and #1727, branch mainnet-chain-guard, telcoin-network PR #1716 (open).` | reword | merge into FU-3 as one item |
| FU-3 | `followup.md:134-136` | `The devnet deployment runs a faucet image on a chain-487 genesis and must set TN_ALLOW_FAUCET_ON_CHAIN_487=true before it takes a release with the guard. Closes when it merges and the devnet deployment is updated.` | reword (VC-1; not "devnet, keep 487") | `- U-3 and U-5, the mainnet chain guard: merged on telcoin-network main as PR #1716 (2026-11-12), issues #1725 and #1727; no release carries it yet. It moved mainnet to chain id 731 (0x2db); 487, the old id, is what upstream devnet genesis files use. On chain 731 the node refuses a cleartext BLS key and a faucet build, and no flag lifts either; it logs "node build: faucet=<bool> adiri=<bool> chain_id=<n> genesis_hash=<0x..>" at startup and lists faucet in --version. A faucet build starts on a chain other than adiri only with --allow-faucet-on-chain (env TN_ALLOW_FAUCET_ON_CHAIN=true), so the devnet's faucet image (chain 32285) must set TN_ALLOW_FAUCET_ON_CHAIN=true before it takes a release with #1716. Closes when a node release carries #1716 and the devnet image sets it.` |
| FU-4 | `followup.md:139` | `the node refusing fork-epoch overrides on chains 487 and 2017` (U-12, #1734, not merged) | reword | `on mainnet (731) and testnet (2017)` |
| FU-5 | `followup.md:166` | `(the chain 487 guard branch adds the startup line)` | reword | `(#1716 added the startup line with the genesis hash; no release carries it yet)` |
| FU-6 | `followup.md:499` | `although the genesis chain id would tell it` | keep | no id |
| CL-1 | `CHANGELOG.md:380` | `... and 487 as the mainnet chain ID` (Backlog round, October 2026, update-scripts v1.1.70) | history | keep |
| CL-2 | `CHANGELOG.md`, `## Unreleased` | no entry | add | the id moved from 487 to 731, with the versions named in RM-6 |
| CL-3 | `CHANGELOG/scripts-v2.2.0.md` (pending) | no chain id line under lib/common 2.2.1, check-node 2.2.0 and the other entries | add | the same sentence under lib/common, check-node, update-node and telcoin-ui |
| CL-4 | `CHANGELOG/scripts-v2.0.0.md`, `scripts-v2.1.0.md`, `v0.16.0-adiri.md` | no mainnet id | keep | released |
| OT-1 | `AGENTS.md`, `WGVPN.md`, `DEBUG.md`, `docs/testnet-addons.md` | no mainnet id (`AGENTS.md:105`'s build-feature rule matches upstream) | keep | no change |

**Counts by file and class:**

| File | Count |
|---|---|
| README.md | 3 change, 1 optional reword, 1 history, 1 add |
| OPERATOR.md | 5 change (2 of them quoted messages), 2 keep |
| mno-node-guide.md | 3 change, 1 keep, plus a version bump and PDF rebuild |
| Mainnet one-pager | 1 change, plus a version bump and rebuild |
| followup.md | 4 reword items covering 5 places, 1 keep |
| CHANGELOG.md | 1 history, 1 add |
| CHANGELOG/scripts-v2.2.0.md | 1 add |

No line belongs to "about devnet, keep 487": the only devnet-487 sentence (FU-3) needs rewording.

The live site run.telcoin.network was built from `01664cc` (per `source.txt`) and still shows 487: one hit in the mainnet one-pager and three in the guide. After the doc PR merges, run the tn-partner-site Publish workflow and compare `source_tree`.

## C6. Sibling repositories

The verifier also listed, read-only, where other repositories on the maintainer's host still
name 487. That list is not part of this public record; the orchestrator gave it to the
maintainer with the round's summary. No sibling repository was changed.

## Not proved

- I did not run the whole fixture suite unmutated at 1a3404b, only the nine changed files and the UI suite. The other 75 files pass in the mutant run with 487, so they do not depend on the value.
- No real node binary was run and no page was opened in a browser. Page rendering was read from `index.html`.
- I did not read the upstream GitHub issue bodies (#1725, #1727, #1734) or anything about the next node release. Whether the posted #1734 still says 487 is unknown.
- The devnet's chain id rests on one live `eth_chainId` answer and on devnet-genesis. Whether followup.md's "devnet deployment" meant another faucet devnet on 487 needs the maintainer.
- No PDF was rebuilt. Page fit after the edit (the one-pager staying one page) is wave 3's job.

## Harness

The harness lives in `tasks/verify-req/V-CHAIN/harness/`:
- `h_common.sh`: 56 checks
- `h_check.sh`: 12
- `h_update.sh`: 10
- `h_addons.sh`: 10
- `h_stake.sh`: 4
- `h_entry.sh`: 2 (setup), 8 (edit), 2 (caddy)
- `h_ui.py`: 16, run with `python -I` in python:3.10-slim

Every `*.sh` has a shebang and passes `bash -n` under bash 5 and in `bash:3.2`, `shellcheck --severity=error` and `tools/check-bash32.sh`.
