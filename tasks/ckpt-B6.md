status: done (all 4 sections complete; drafts below)

## Completed sections
- [x] 1. server.py registry/stake: _registry_calldata factored out of eth_call_registry;
  STAKED_STATUSES=(1,2,3,4) + registry_stake_status(port,address) -> int | "none" | None;
  onchain_is_validator rewritten (execution_address + getValidator; tn_isValidator removed;
  synced gate + 30s cache kept); dead base58/bls_pubkey_to_hex helpers removed (only caller
  was tn_isValidator); comments updated in resolve_node_type, detect_nodes (+ _log text
  "on-chain staked="), api_nodes, api_status; NETWORK_PUBLIC_WS comment marks
  config-caddy.sh maintainer-only. py_compile OK.
- [x] 2. server.py preflight: HW_TIERS / HW_VALIDATOR_RECOMMENDED / HW_PASS_PCT, helpers
  _hw_floor_kb, _mem_total_kb, _nearest_existing_dir, _hw_disk, hardware_profile();
  api_preflight adds "hardware"; root disk check kept (server ok = pct<90), UI makes it soft.
  DEFAULT_DOCKER_IMAGE :v0.15.0-adiri; UI_VERSION 1.8.8 + history comment (wrapped 2 lines).
- [x] 3. index.html: stepPreflight hard = systemd+internet only; soft = disk ("Disk usage N%
  (warn at ≥ 90%)") + hwTierRows(d.hardware) + docker/rust/tpm; hwInfoRow (detected +
  validator_recommended) appended; new helpers hwTierRows/hwInfoRow before stepNetwork.
  "Observer" -> "Full node" (#roleDetail default, observerRoleLabel, comment); validator
  Node Details value "Staked validator"; docker placeholders v0.15.0-adiri (setup + update
  tab example); tn_isValidator comments -> getValidator stake status. node --check OK.
- [x] 4. Tests: test_public_readonly 7/7 OK (venv Flask 3.1.3); scratchpad B6/harness_b6.py
  16/16 OK (stake contract, calldata, cache, preflight shape via test client with run/urlopen
  stubbed, thresholds, nearest dir, constants); B6/js_check.js (hwTierRows/hwInfoRow) OK;
  py_compile OK.

## README changelog draft

### telcoin-ui v1.8.8 — validator view follows the on-chain stake
The dashboard now picks the validator view from the node's stake in the ConsensusRegistry.
Once the node is synced, the UI calls `getValidator` for its execution address. A status of
Staked, PendingActivation, Active or PendingExit shows the validator dashboard; an unstaked
or exited address, or one the registry never whitelisted (the call reverts), shows the full
node view. `tn_isValidator` is no longer consulted, because it only says a BLS key is
recorded and not retired. While the RPC is down or the node is still syncing, the view
stays where it was.

The setup wizard's preflight no longer blocks on disk usage: 90% or more used is now a
warning. It also checks the host against three hardware tiers (full node, public RPC node,
validator minimum), names any shortfall, and shows the recommended validator spec. These
rows are warnings only. "Observer" now reads "Full node", the validator details read
"Staked validator", the fallback Docker image is `v0.15.0-adiri`, and the bump redeploys
the update engine copies in `/opt/telcoin-ui-update/`.

## Commit message draft

feat(ui): on-chain stake status selects the validator view; warn-only hardware preflight

The validator view now follows getValidator(execution address) on the
ConsensusRegistry: statuses 1-4 select it, while a revert (never whitelisted)
or status 0/5/6 selects the full-node view; unsynced or unreachable keeps the hint.
tn_isValidator and the base58 BLS-key helpers it needed are removed.
/api/setup/preflight gains a hardware object (cpu, ram_kb, disk, three tiers
with gaps, validator_recommended); the wizard shows the tiers and disk usage as
warnings and never blocks on them. Fallback image v0.15.0-adiri; UI 1.8.8.
