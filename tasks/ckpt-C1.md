status: DONE (review round 2 applied; 856 lines; links re-checked)
task: write OPERATOR.md (operator runbook) at repo root
Completed sections:
- inputs read (ckpt-R-C, ckpt-B2, README, project-context); facts verified against working tree
- header + contents + section 0 written
- section 1 written
- section 2 written
- section 3 written
- section 4 written
- section 5 written
- section 6 written (with coordinator status-6 correction)
- section 7 written
- section 8 written
- section 9, 10, appendix written
Notes:
- Coordinator correction (6.10/6.11): retire via unstake sets currentStatus=6 (Any) AND isRetired=true; getValidator still answers. Status 6 alone = reserved sentinel (never expected); 6 + isRetired=true = normal retired state (NFT burned, cannot re-stake same identity). check_validator_onchain_status prints "Status: Retired" for that; appends " (Retired)" to any other status when isRetired set. node_is_staked_validator: 1-4 staked; 0/5/6/none not staked.
- Verified: setup-node 1.2.0 main order; DEFAULT_DOCKER_IMAGE fallback v0.15.0-adiri; HW tiers in lib/common.sh 1.4.0; docker export cmd in display_node_info = docker run --rm -v <data>:/home/nonroot/data:ro <img> telcoin keytool export-staking-args --node-info /home/nonroot/data/node-info.yaml --calldata; binary = /opt/telcoin/telcoin-network keytool ...
- Unverified in working tree at time of writing (re-check at end): check-node EVM_SYNC_THRESHOLD is readonly 50 (not env); check-node/update-node still accept --observer/--validator as force-view (no warning yet); update-node does not yet call tn_target_drops_observer/tn_node_strip_observer_flag (helpers exist in lib/common.sh).
- Upstream verified (tn-3): stakeConfig(uint8); getCurrentEpochInfo returns (address[],uint256,uint64,uint32,uint32,uint8); unstake retires + burns NFT; beginExit needs Active and committee-size check.
- Style: sentence-per-line prose; no line numbers; anchors to README checked at end.
- verification pass done: links/anchors OK (29 links, 0 bad), heading levels OK, no common/devnet-genesis, no file:line, no role-flag examples, AI-vocab scan clean; 854 lines
- format-output agent launched on OPERATOR.md (post-processing); after it returns: re-run scratchpad/checklinks.py + forbidden-pattern grep, re-check check-node EVM_SYNC_THRESHOLD and display_node_info docker form, then hand back
- format-output: no changes; final re-verify passed (0 bad links; volatile facts unchanged)
- review round 2: findings 1-8 being applied
- review round 2 findings 1-8 applied; checklinks BAD: []
