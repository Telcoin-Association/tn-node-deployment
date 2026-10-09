status: done (re-verification pass R2: d1babe41..025bd690)

# V-UP checkpoint (independent verifier for package UP)

## R2 sections (re-verification of fix commits 7765d2af ea82f72a 584d08e5 025bd690)
- [x] R2.1 List commits, files, trailers (4 commits, no trailers; tip 025bd690; main 45d9b986)
- [x] R2.2 Read diff and check each new claim
- [x] R2.3 Run etc/README Setup + Step 1 + Step 2 verbatim under env -i; one how-to-stake capture
- [x] R2.4 Links/anchors, mdbook from git archive 025bd690
- [x] R2.5 Original findings 1-12 status
- [x] R2.6 Verdict

## R2 results
- Scope: 6 files (README.md, CLI README, how-to-stake.md, etc/README.md, validator-operations.md,
  networks-and-rpc-endpoints.md); no .claude/, tasks/, chain-configs, tn-contracts. Subjects docs(scope)/docs:,
  max 89 chars (upstream max 93). Author/committer grantkee <grant@kee.ai>. No trailers.
- etc/README Setup + Step 1 + Step 2 extracted verbatim from 025bd690 (only NEW_VALIDATOR placeholder replaced),
  run with `env -i /bin/bash`, v0.15.0-adiri build as target/release/telcoin-network: exit 0; node-keys/bls.kw
  written (no-passphrase run writes bls.key instead); STAKE_CALLDATA 1 line, 0x2fb0d025..., cast mktx accepts it
  offline. Step 1 without TN_BLS_PASSPHRASE: exit 1 "Error passphrase is required, ...".
- how-to-stake CALLDATA example run verbatim (path substituted) under env -i: 1 line, 0x2fb0d025.
- -q is global (accepted after the subcommand too); -q --json parses with jq (keys blsPubkey, signature).
- InvalidTokenId(uint256) 0xed15e6cf declared in IStakeManager.sol and present in live registry code.
- compose.yaml sets TN_BLS_PASSPHRASE for its services.
- mdbook 0.5.4 from git archive 025bd690 docs: exit 0, no warnings; #network-topology,
  #advertising-an-rpc-endpoint, ../architecture/network.html#observer resolve.
- Original findings 1-7, 9-11 resolved; 8 and 12 need no change.
- New: one optional note (private-resolving hostname "fail to reach it" is not guaranteed for an observer
  inside the same private network). No open errors or warnings.
- Verdict: ready to hand to the user as a PR branch (maintainer still has to run make attest after pushing).

Branch `docs/operator-docs-backlog` in tn-5 at d1babe41 (9 commits on origin/main f47a2603). Local main still
45d9b986. devnet-genesis main e732765 (ahead 1, not pushed).

## Sections
- [x] 0. Read spec-fu-shared.md and spec-fu-upstream.md
- [x] 1. Read full diff origin/main..docs/operator-docs-backlog (9 commits incl. d1babe41)
- [x] 2. Factual claims vs source / chain / v0.15.0-adiri build
- [x] 3. Link targets (relative, anchors in built HTML, external URLs)
- [x] 4. Commit hygiene
- [x] 5. mdbook build from git archive (rebuilt after d1babe41): exit 0, no warnings
- [x] 6. devnet-genesis commit
- [x] 7. Prose spot-check
- [x] 8. Compared with author's checkpoint ckpt-fu-UP.md (author ran no binary; source-only for keytool)
- [x] 9. Final findings and verdict

## Verified OK
- Selectors (cast sig) all present as PUSH4 in live registry code: stake(bytes,(bytes)) 0x2fb0d025,
  getCurrentStakeVersion 0x67398331, stakeConfig(uint8) 0xa71954ec, unstake(address,bool) 0xf66a25a4,
  delegateStake(bytes,(bytes),address,bytes,uint256) 0x127ce8e8, delegationDigest(bytes,address,address,uint256)
  0xad6cfb86, increaseNonce 0xc53a0292, claimRefund 0xb5545a3c, requestStakeVersionChange 0xe5a22827,
  cancelStakeVersionChange 0x0f4346fa.
- Documented cast reads run verbatim against rpc.adiri.tel: version 0, stakeConfig(0) = 1e24/1e21/2.58e22/21600.
- Contract semantics (ConsensusRegistry.sol, StakeManager.sol @ 10cc12b7): stake() prices from current epoch
  version; getCurrentStakeConfig = latest authored; deadline/DelegationExpired; digest covers epoch version +
  nonce; increaseNonce; unstake caller + eligibility + shortfall flag + claimRefund fallback + retire/mint
  AlreadyDefined; requestStakeVersionChange Staked-immediate / queued, STAKE_DECREASE_DELAY_EPOCHS = 1, boundary
  refunds credited; cancel returns escrow; BLS key never cleared, no rotation function.
- Activation timing: pool at close of E includes PendingActivation (block.rs read_committee_eligible_pool),
  committee stored for E+3 (_updateEpochInfo) -> "Active next transition, earliest committee two epochs after".
- epochDuration seconds (run_epoch.rs). NamedChain adiri/test-net/main-net; adiri feature gate (node.rs).
- chain-configs embedded (types/src/genesis.rs include_str!); fork epoch 407; genesis registry/WorkerConfigs code
  hash = PRE_FORK pins; live = POST_FORK pins; genesis timestamp = live block 0; regenerate_mainnet_chain_configs #[ignore].
- generate pop rewrites execution_address + proof_of_possession; --external-worker-addrs comma list; --rpc-http;
  set-rpc http/https accepted; no default P2P ports; WORKER_LISTENER_MULTIADDR worker 0 only; committee.yaml
  5x49590/49594; .env.example agrees; compose 49595.
- node-info: v0.14.0-adiri `worker:`, v0.15.0-adiri `workers:`; legacy read; `rpc: ~` on primary and workers
  (confirmed by generating keys with the v0.15.0-adiri build).
- Forwarding (forward.rs): owner-first, fallback, PublicOnly default, no DNS, http cleartext.
- --http.addr default 127.0.0.1; --observer hidden no-op at v0.15.0-adiri, rejected on origin/main.
- Links: #observer, #network-topology, #advertising-an-rpc-endpoint ids present in built HTML; CLI README
  relative links resolve; GitHub README URL 200 and `### \`allow_private_forward_targets\`` heading on main;
  faucet 200 (redirect), telscan.io GET 200 (HEAD 405), www.telscan.xyz 200; 487 = 0x1e7.
- Hygiene: no trailers; docs(scope)/docs: subjects; per-commit files match subjects; no .claude/, tasks/,
  report-*, genesis.yaml or tn-contracts paths; devnet-genesis commit touches only comment lines in config.sh,
  bash -n ok under 3.2 and 5.3.

## Findings
1. error how-to-stake.md "It needs only node-info.yaml: no BLS key, passphrase, or datadir." (passphrase gate)
2. error how-to-stake.md CALLDATA=$(... --calldata) captures the INFO log line on stdout; cast send fails
3. error networks-and-rpc-endpoints.md "the balancer answers a WebSocket upgrade with HTTP 405" (it is Caddy)
4. warn how-to-stake.md DuplicateBLSPubkey row misses the repeated-stake() cause
5. warn CLI README set-rpc example advertises :8545/:8546 next to "never the node's RPC port"
6. warn validator-operations same-host proxy vs the page's own topology rules
7. note DNS rule consequence unstated
8. note refusal list omits non-unicast
9. note "stake is still returned in full" (slashed validator)
10. note websocket/WebSocket in one sentence
11. note pre-existing RequiresConsensusNFT row (real revert InvalidTokenId)
12. note cross-fork dedup edge on Adiri (keys of validators retired before epoch 407)
(Full text with evidence is in the final report handed back to the orchestrator.)

## Verdict
Not ready as-is: fix 1-3 (and the same two keytool defects that pre-exist in README.md, CLI README, etc/README.md),
preferably 4-6; everything else checks out.
