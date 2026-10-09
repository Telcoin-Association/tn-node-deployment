status: done (branch at 13 commits; issue 11 follow-up landed)

- [x] 19. Commit D docs(etc): set TN_BLS_PASSPHRASE before generating keys and starting the node (025bd690;
  etc/README.md only, +9/-2; compose.yaml unchanged because every service already sets TN_BLS_PASSPHRASE=local;
  v0.15.0 build: Step 1 with the var -> exit 0 + bls.kw, without -> exit 1, node without -> exit 1; documented
  Setup/Step 1/Step 2 ran verbatim in an empty env; mdbook exit 0; trailer grep empty)

## Verifier follow-ups (round 2)
- [x] 14. Verify keytool facts on v0.15.0 build (<scratchpad>/tn5-target/debug/telcoin-network)
  - `-q, --quiet` ("Silence all log output") is global (listed in subcommand help); `--log.stdout.filter` also exists.
  - Branch source: passphrase.rs resolve_bls_passphrase: keytool needs a passphrase unless set-rpc
    (KeyArgs::needs_passphrase); default source env; `no-passphrase` disables the check; error text
    "Error passphrase is required, see the option --bls-passphrase-source for options"; main.rs exits 1.
  - Binary, throwaway datadir <scratchpad>/throwaway-keytool (keygen --bls-passphrase-source no-passphrase):
    export-staking-args with env unset and no source -> exit 1 + that error; without -q a $(...) capture holds
    2 lines (INFO Loading configuration on stdout + calldata); with
    `-q --bls-passphrase-source no-passphrase` -> 1 line, 650 chars, 0x2fb0d025...; cast calldata-decode
    'stake(bytes,(bytes))' -> 96-byte key, 48-byte PoP; `cast mktx` (offline, throwaway key) accepts the
    one-line capture and rejects the two-line one with "Function signature does not contain parentheses".
- [x] 15. Commit A docs(staking): keytool needs a passphrase source and quiet output when exporting calldata
  (7765d2af; all four documented capture forms run against the binary: 1 line, cast mktx accepts; -q is
  LogArgs flattened at top level on the branch too; InvalidTokenId via _checkConsensusNFTOwner/_exists;
  DuplicateBLSPubkey before status check in stake(); _unstake returns remaining balance when slashed)
- [x] 16. Commit B docs(operations): advertise RPC through a gateway or proxy, never the raw ports (ea82f72a)
- [x] 17. Commit C docs: say only that a WebSocket upgrade to the balanced URLs gets 405 (584d08e5; live
  405 carries `server: Caddy`, `via: 1.1 google`)
- [x] 18. mdbook exit 0; trailer grep empty; 11 files +178/-73 vs origin/main; no YAML/submodule changes;
  throwaway datadir removed from scratchpad

# Package UP (upstream docs) checkpoint

Repos: `/Users/grant/coding/telcoin/tn-5` branch `docs/operator-docs-backlog` off `origin/main`
(f47a2603), 8 commits; `/Users/grant/coding/telcoin/devnet-genesis` `main`, 1 commit (config.sh only).
Nothing pushed. Local `main` in tn-5 untouched. Submodule pointers in devnet-genesis unchanged.

## Sections
- [x] 1. Branch created; facts verified
- [x] 2. Commit 1 docs(staking): match the live ConsensusRegistry ABI (501a1d25)
- [x] 3. Commit 2 docs(staking): stop advising --force key regeneration (c92571fb)
- [x] 4. Commit 3 docs(network): correct the worker P2P port and drop default-port claims (4b7372d2)
- [x] 5. Commit 4 docs(cli): document the p2p_info.workers node-info shape (5acaf6c5)
- [x] 6. Commit 5 docs(operations): tell validators how to advertise an RPC endpoint (899347be)
- [x] 7. Commit 6 docs: name the canonical RPC endpoints and explorers (0c2aa0d7)
- [x] 8. Commit 7 docs: route the hardware contact to support@telcoin.org (418f54d6)
- [x] 9. Commit 8 docs(chain-configs): explain that the testnet genesis predates the registry fork (7e4e81d4)
- [x] 10. mdbook build, diff stat, trailer check
- [x] 11. devnet-genesis config.sh commit (e732765)
- [x] 12. Final checkpoint
- [x] 13. Follow-up (coordinator request): d1babe41 docs(staking): name requestStakeVersionChange on the
  membership page (why-membership-model.md only; mdbook rebuilt, exit 0; branch now 9 commits)

## Facts verified (section 1)
- cast sig: stake(bytes,(bytes)) 0x2fb0d025, unstake(address,bool) 0xf66a25a4, activate() 0x0f15f4c0,
  getCurrentStakeVersion() 0x67398331, stakeConfig(uint8) 0xa71954ec, getValidator 0x1904bb2e.
- tn-contracts (submodule 10cc12b7) IStakeManager/ConsensusRegistry: stake(bytes, ProofOfPossession{bytes
  signature}) external payable; 96-byte compressed key, 48-byte compressed PoP; delegateStake(...,uint256
  deadline) with DelegationExpired, owner exempt; delegationDigest(bytes,address,address,uint256) also covers
  epoch stake version and delegation nonce; increaseNonce() revokes. stake() prices from
  getCurrentEpochInfo().stakeVersion (== getCurrentStakeVersion()), exact equality; getCurrentStakeConfig()
  returns versions[stakeVersion] = latest authored. unstake(address,bool acceptRewardShortfall): validator or
  delegator; Staked, or Exited with currentEpoch >= exitEpoch + 1; false + underfunded Issuance reverts
  InsufficientBalance; payout push falls back to claimRefund credit; address retired, mint refuses it.
- BLS key never released (blsPubkeyHashToValidator not cleared by _retire); no key-rotation function.
- upgradeValidatorStakeVersion() does not exist: requestStakeVersionChange(address,uint8) payable,
  cancelStakeVersionChange(address), claimRefund(); Staked settles at once (surplus pushed); in-service queued:
  increase at the boundary closing the request epoch, decrease one boundary later.
- epochDuration is seconds (run_epoch.rs epoch_boundary = epoch_start + epochDuration; genesis flag
  --epoch-duration-in-secs).
- keytool: export-staking-args --node-info PATH [--json|--calldata] (default prints two values); generate
  validator|observer flags; generate pop --address rewrites only execution_address + proof_of_possession;
  set-rpc writes node-info back; --worker-id exists only on main. node-info stores key/PoP as base58.
- --chain: NamedChain ValueEnum, kebab-case -> adiri, test-net, main-net; node refuses chain 2017 without the
  adiri feature (and any other chain with it).
- node-info p2p_info: `workers:` list since v0.15.0-adiri (v0.13/v0.14 wrote `worker:`); legacy read in YAML/JSON;
  unset rpc serializes `rpc: ~`. RpcInfo.validate: scheme + length only.
- Ports: no default; node uses node-info addresses (env PRIMARY_/WORKER_LISTENER_MULTIADDR override primary and
  worker 0). chain-configs/testnet/committee.yaml: all 5 validators 49590/49594.
- Observer forwarding (released since v0.13.0-adiri): owner-first by sender slot, fallback to other advertised
  endpoints; PublicOnly policy refuses non-public literals and localhost/.local, no DNS; plain POST, no
  credentials; http allowed but cleartext.
- Live probes 2026-10-01 (read-only): stakeConfig(0) = 1e24 / 1e21 / 2.58e22 / 21600; registry code hash
  0xbd1ade0e == POST_FORK pin; epoch 580; genesis.yaml registry hash 0x5318ebc5 == PRE_FORK pin; genesis
  timestamp 0x69fceea7 == live block 0 timestamp 1778183847; rpc.adiri.tel, adiri.tel, node1-3, rpc.telcoin.network
  all eth_chainId 0x7e1; WebSocket upgrade to rpc.adiri.tel -> 405; telscan.io, www.telscan.xyz, faucet 200.
- --observer: v0.15.0-adiri hidden and ignored; absent on origin/main.

## Operator-visible changes
None until the tn-5 branch is pushed and merged (the docs site deploys from main). Once merged:
- How to Stake: compressed key + 48-byte PoP, stake(bytes,(bytes)) via export-staking-args --calldata, stake
  amount from stakeConfig(getCurrentStakeVersion()), --chain adiri start example with the adiri-feature note,
  delegateStake/delegationDigest with deadline, unstake(address,bool) with eligibility and the shortfall flag,
  troubleshooting and key-management notes that no longer advise --force and point to generate pop.
- How Staking Works: epochDuration in seconds; requestStakeVersionChange semantics.
- Validator Production Operations: no default ports, 49590/49594 convention; new "Advertising an RPC endpoint".
- Networks and RPC Endpoints: both explorers, chain ID in decimal, 405 on WebSocket upgrade, Mainnet section.
- Faucet: fixed link, alternate explorer. Hardware requirements: contact support@telcoin.org.
- CLI README, root README, etc/README, chain-configs/README as listed in the commits.
- devnet-genesis config.sh: comment only (maintainer-facing).

## Changelog text
tn-5 `docs/operator-docs-backlog` (`git log --oneline origin/main..HEAD`, oldest first):
- 501a1d25 docs(staking): match the live ConsensusRegistry ABI: compressed key/PoP, stake(bytes,(bytes)),
  amount from stakeConfig(getCurrentStakeVersion()), deadline, unstake(address,bool), requestStakeVersionChange,
  epochDuration seconds, --chain adiri and the real --chain spellings, etc walkthrough timing.
- c92571fb docs(staking): stop advising --force key regeneration: registered keys are never released; use
  generate pop --address; new validator keys go in a new datadir.
- 4b7372d2 docs(network): correct the worker P2P port and drop default-port claims: 49595 -> 49594, ports
  are a convention, root README keygen example gains --external-worker-addrs.
- 5acaf6c5 docs(cli): document the p2p_info.workers node-info shape: list since v0.15.0-adiri, legacy
  worker: still read, rpc path workers[0].rpc.
- 899347be docs(operations): tell validators how to advertise an RPC endpoint: loopback RPC, TLS proxy,
  https URL, never a private address, CLI README pointer and security-note exception.
- 0c2aa0d7 docs: name the canonical RPC endpoints and explorers: telscan.io + www.telscan.xyz, 405 on
  WebSocket upgrade, mainnet 487 / rpc.telcoin.network not launched, faucet link fix.
- 418f54d6 docs: route the hardware contact to support@telcoin.org.
- 7e4e81d4 docs(chain-configs): explain that the testnet genesis predates the registry fork: testnet is the
  live Adiri genesis with pre-fork registry code, swapped at epoch 407; do not edit; mainnet placeholders.
- d1babe41 docs(staking): name requestStakeVersionChange on the membership page: replaces the non-existent
  upgradeValidatorStakeVersion(); rest of the sentence checked against the contract.
- 7765d2af docs(staking): keytool needs a passphrase source and quiet output when exporting calldata:
  --bls-passphrase-source no-passphrase in every export example, -q on every capture, DuplicateBLSPubkey
  retry note, InvalidTokenId row, acceptRewardShortfall wording.
- ea82f72a docs(operations): advertise RPC through a gateway or proxy, never the raw ports: set-rpc example
  URLs, gateway-first section, private-resolving hostname failure mode.
- 584d08e5 docs: say only that a WebSocket upgrade to the balanced URLs gets 405.
- 025bd690 docs(etc): set TN_BLS_PASSPHRASE before generating keys and starting the node: Setup exports it,
  Steps 1 and 8 note they use it, Step 2 keeps no-passphrase.
devnet-genesis `main`:
- e732765 config: node 5 is an observer by committee membership.

## Tests run
- `cast sig` for all selectors above: match the spec.
- Live read-only `cast call` of the documented snippets verbatim (getCurrentStakeVersion, stakeConfig): ok;
  raw calldata in cast's SIG position (`cast call <reg> 0x67398331`): ok (cast 1.5.1).
- Code-hash, timestamp, endpoint, explorer, WebSocket-upgrade and faucet probes listed above.
- `mdbook build docs -d <scratchpad>/tn5-book` (mdbook 0.5.4): exit 0, no warnings; new anchors
  (#advertising-an-rpc-endpoint, #observer, #network-topology, #mainnet) and cross-links present in HTML.
- `git diff origin/main --stat`: 10 files, +150 / -58; no chain-configs YAML or tn-contracts change.
- `git log --format='%B' origin/main..HEAD | grep -i -E 'co-authored|generated with'`: empty. devnet-genesis
  commit message: no trailers.
- Stale-string grep over touched files: only the intentional Docker Compose 49595 row remains.
- `bash -n` and `/bin/bash -n` (3.2) on devnet-genesis config.sh: ok.
- Not run: no local telcoin-network binary and docker daemon unavailable, so keytool output and --chain
  parsing were verified from source only.

## Open issues
1. RESOLVED in d1babe41: why-membership-model.md now names `requestStakeVersionChange()`; no
   `upgradeValidatorStakeVersion` remains anywhere in the docs or READMEs.
2. etc/compose.yaml sets WORKER_LISTENER_MULTIADDR to udp/49595 on its private bridge network; the CLI README
   Docker env table mirrors it and was kept. Off-convention but harmless; changing it is a config change.
3. tn-contracts IStakeManager StakeConfig natspec says epochDuration is "in L2 blocks"; the node uses seconds.
   Upstream tn-contracts fix.
4. https://rpc.telcoin.network answers eth_chainId 0x7e1 (Adiri) today. The docs say it does not serve mainnet
   before launch and to check for 0x1e7. Anything that treats it as mainnet today talks to the testnet.
5. CLI README drift left alone (sections not touched): keytool generate flags table omits --rpc-http/--rpc-ws;
   --workers row says "1-4, must be 1" while clap accepts 1..=65536 (real limit: on-chain worker count, 1).
6. set-rpc --worker-id (main only) is not documented; the docs name worker 0's entry, right for every release.
7. Spec vs source: how-staking-works.md and etc/README.md needed more than the spec listed
   (requestStakeVersionChange; activation timing); fixed inside commit 1 since both files were in its list.
8. Commit 8's subject is 80 characters because the spec fixes the title.
9. Pushing: the tn-5 PR check verify-on-chain has no docs exemption, so a maintainer must attest the head SHA
   (make attest) after the final push (from .claude/project-context.md).
10. The human-writing skill's format-output pass was skipped on purpose: it would re-wrap untouched lines;
    each file's existing line layout was matched by hand.
11. RESOLVED in 025bd690: etc/README Setup exports TN_BLS_PASSPHRASE; Steps 1 and 8 use it.
12. Not re-verified against a binary built from this branch (only the v0.15.0 debug build); source shows the
    same passphrase gate (passphrase.rs) and the same LogArgs (-q) on the branch.
