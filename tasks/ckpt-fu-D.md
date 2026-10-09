status: in-progress (fix pass 3)

# Checkpoint: package D (prepare-stake.sh 1.0.0, wiring)

Owned: `prepare-stake.sh` (new, 755), one `SCRIPTS` row in `update-scripts.sh`, one `chmod` line in
`install.sh`. Tests in `<scratchpad>/d-tests/` (`t_d.sh`, `t_rot.sh`, `t_units.sh`, `t_live.sh`,
`lib_t.sh`, `run_case.sh`, `shims/{curl,systemctl,sleep}`, `rec-telcoin`, `argvshims/`, `fx/`).

## Sections

- [x] 1. Skeleton: header, hard guard, set -u, parser, --help, root check, resolution of config dir,
      data dir, node-info path, network, network RPC default, runner; --json shape
- [x] 2. Prepare flow (a)-(j): ps_check_chain (a), ps_read_address (b), ps_check_whitelist (c;
      balance 0 then reads the status so a retired address gets "nothing to do", not "ask for
      approval"), ps_check_status (d; none/0 go on, 1 jumps to the activate block, 2-5/retired
      report via print_validator_onchain_status with the epoch and exit 0), ps_stake_amount (e),
      ps_check_balance (f; need = stake + gasPrice x 1e6 gas; short = not ready, exit 3 at the end,
      commands still printed), ps_export_calldata (g; rc 4 exit 1, other rc or bad line exit 2),
      ps_simulate + ps_explain_revert (h; own ps_rpc_raw because tn_rpc_call drops error data;
      revert = not ready, exit 3, no commands; insufficient funds = not ready; transport/other
      rpc-error = warning), ps_check_sync (i; > 50 blocks warns), ps_print_* (j; `--ledger`
      default plus a key-source note naming --trezor, --interactive, --private-key
      "$VALIDATOR_KEY"; epochs E+1 / E+3 with the live epoch and time left)
- [x] 3. Rotation (--rotate-address): chain check, current address, current status (refuse
      1-5/retired, exit 3; unreadable exit 2), new address status unless equal to the current one
      (refuse 1-5/retired; `none` and 0 allowed), summary, confirm unless --yes (declined: exit 3
      "cancelled"), ps_runner, ps_get_passphrase, record uid/gid/mode, `cp -p` backup
      `node-info.yaml.bak.<UTC stamp>` (+`.$$` on clash), keytool `generate pop` in a subshell
      with the passphrase as a plain (unexported) variable that tn_keytool hands to keytool
      alone, stdout dropped; verify address/BLS/name else ps_rollback (cp -p back, chown/chmod,
      exit 4); chown/chmod; meta_set VALIDATOR_ADDRESS <checksummed>; ps_restart_node
      (tn_wait_restart_window, systemctl restart, sleep 3, is-active; failure exit 1).
- [x] 4. Wiring: `"prepare-stake.sh:prepare-stake.sh:SCRIPT_VERSION"` after check-node.sh in
      `SCRIPTS`; `chmod +x "${INSTALL_DIR}/prepare-stake.sh"` after check-node.sh in install.sh
      (install.sh clones the whole repo, so nothing else is needed). The updater's own
      `get_local_version` reads 1.0.0 from the file under both bashes.
- [x] 5. Tests (C.5) — all green, see "Tests run"
      - [x] 5a. prepare suite 260/260 per bash
      - [x] 5b. rotation suite 170/170 per bash (found and fixed the environment leak below)
      - [x] 5c. units 13/13 per bash
      - [x] 5d. live read-only 25/25 per bash
      - [x] 5e. static checks, updater parse, gen-checksums
- [x] 6. Closing headings

## Notes (design decisions)

- Hard guard verbatim (B.1) right after `source lib/common.sh`. Before it, as the first statements
  of the script: `unset PS_PASS PS_ENV_PASS; PS_ENV_PASS="${TN_BLS_PASSPHRASE:-}"; unset
  TN_BLS_PASSPHRASE`. Found by the argv/env recorder: without this, a passphrase passed in
  TN_BLS_PASSPHRASE was inherited by every command the script ran before the rotation step
  (dirname while sourcing, grep, sort, curl, ...). Now only the keytool process of `generate pop`
  sees it; prepare runs never pass it on (keytool export gets `--bls-passphrase-source
  no-passphrase` from tn_keytool, which is the "untouched, library adds the no-passphrase
  source" behaviour the spec asks for, made strict). The unset also drops an export flag those
  names could arrive with, so the later assignments are never exported.
- errexit off (`set +e`), nounset and pipefail on; every step checks its own rc.
- `--json`: pre-scan, `exec 3>&1; exec 1>&2`, EXIT trap prints ONE object on fd 3 for every way
  out (help, usage error, fail, done): `{"event":"done","ok","exit","state","msg",
  "script_version","network","network_source","expected_chain_id","network_rpc","chain_id",
  "config_dir","data_dir","node_info","runner","service","address","address_checksum",
  "meta_address","whitelisted","nft_balance","status","stake_wei","stake_tel","stake_version",
  "balance_wei","gas_price_wei","gas_allowance_wei","needed_wei","balance_ok","calldata",
  "simulation","simulation_error","simulation_gas","local_rpc","local_block","network_block",
  "sync_lag","epoch","epoch_secs_left","activation_epoch","earliest_seat_epoch","stake_command",
  "activate_command","old_address","new_address","backup","restarted","warnings":[…]}`. Wei and
  block numbers are JSON strings. `state` is one of ready, not-ready, staked, nothing-to-do,
  not-whitelisted, rotated, refused, cancelled, rolled-back, error, help. The B.1 guard keeps its
  own two-line error+done output.
- EIP-55 display checksum through a pure-bash Keccak-256 (`ps_keccak256_hex`, one block, < 136
  bytes): hashlib has no keccak and cast is not on node boxes. Also used to refuse a mixed-case
  `--rotate-address` with a wrong checksum (a typo).
- 256-bit math: `ps_dec_add/sub/mul/cmp/to_hex` on 9-digit limbs or single digits plus the
  library's `tn_hex_to_dec`/`tn_wei_to_tel`; no bash arithmetic above ~2^31 on amounts.
- Contract facts (tn-contracts in the v0.15.0 export): `mint` stamps a status-0 record, so a
  whitelisted address that has not staked reads `0 0 0 0`; `getValidator` reverts only without an
  NFT and not retired. Error selectors from `artifacts/ConsensusRegistry.json` via `cast sig`:
  InvalidProofOfPossession((bytes)) 0xa865bb35, InvalidBLSPubkey() 0x674469f2,
  DuplicateBLSPubkey() 0x8d12779f, InvalidStakeAmount(uint256) 0x88b4590c,
  InvalidTokenId(uint256) 0xed15e6cf, RequiresConsensusNFT() 0x61f51356, InvalidStatus(uint8)
  0x774f7f12, EnforcedPause() 0xd93c0665, LowLevelCallFailure(bytes) 0x37f33ed8, Error(string)
  0x08c379a0, Panic(uint256) 0x4e487b71.
- Live shapes (rpc.adiri.tel): revert `{"code":3,"message":"execution reverted","data":"0x…"}`;
  insufficient funds `{"code":-32003,"message":"insufficient funds for gas * price + value: have
  … want …"}`; gas price 7 wei.
- keytool on the v0.15.0 build: empty passphrase refused at keygen, so empty = none given;
  `generate pop` rewrites node-info in place (inode and mode kept), changes execution_address and
  proof_of_possession only, writes the address in lower case; BLS signatures are deterministic
  (re-signing for the same address gives identical bytes).

## Operator-visible changes

- New script `prepare-stake.sh` (1.0.0), installed by install.sh and fetched by update-scripts.sh.
  `sudo bash prepare-stake.sh` checks, in order and printing each step: the network RPC serves
  the node's chain (testnet 2017 by default, from NETWORK in .node-meta); the validator address
  from node-info.yaml (EIP-55 checksummed; warns when .node-meta records another one); the
  governance whitelist (ConsensusNFT, `balanceOf`); the validator status; the stake amount
  (`stakeConfig(getCurrentStakeVersion())`, shown in TEL and wei); the address's TEL balance
  against the stake plus gas; the stake() calldata exported by the node's own keytool; a
  simulation of stake() from the address (`eth_estimateGas`, reverts decoded with what to do);
  and how far the local node trails the network. It then prints the `cast send` commands for
  stake() and activate() (signing with `--ledger`, with a note on --trezor, --interactive and
  `--private-key "$VALIDATOR_KEY"`) and the epoch arithmetic (active at E+1, earliest committee
  seat E+3). A staked address gets the activate() step only; a later state is reported and the
  run ends with "nothing to do". It never reads, asks for or prints a private key and never sends
  a transaction.
- `sudo bash prepare-stake.sh --rotate-address <0xNEW> [--yes] [--no-restart]` re-signs the proof
  of possession for another execution address with the same BLS key (keytool `generate pop`),
  backs up node-info.yaml beside it, records VALIDATOR_ADDRESS in .node-meta and restarts the node
  (after the epoch wait a committee node gets). Refused once the current address has staked or
  is retired, or when the new address has staked or is retired. The passphrase comes from
  TN_BLS_PASSPHRASE (`sudo --preserve-env=TN_BLS_PASSPHRASE`), then `<config dir>/bls-passphrase`
  (used only when it is a regular file with mode 600 or stricter), then a prompt on a terminal.
- `--json` (both modes): human output on stderr, one JSON object on stdout at the end.
- Exit codes: 0 ready, staked (activate next), nothing to do, or rotated; 1 usage or environment;
  2 network RPC unreachable, wrong chain, or on-chain state unreadable; 3 not ready or refused;
  4 rotation failed and node-info.yaml was restored.

## Changelog text

### prepare-stake v1.0.0 — check a node before staking, print the stake and activate commands
New script. `sudo bash prepare-stake.sh` checks that the network RPC serves this node's chain,
reads the validator address from node-info.yaml, and checks the governance whitelist
(ConsensusNFT), the validator status, the stake amount the registry asks for now, the address's
TEL balance against the stake plus gas, and the stake() calldata the node's own keytool exports.
It then simulates stake() from the address with `eth_estimateGas`; a revert is named
(InvalidProofOfPossession, DuplicateBLSPubkey, InvalidStakeAmount, InvalidStatus, a paused
registry and more) together with what to do. It warns when the local node trails the network by
more than 50 blocks, and prints the exact `cast send` commands for stake() and activate() with
the network RPC, plus the epoch arithmetic: activate() mined in epoch E makes the validator active
at E+1, with its earliest committee seat at E+3. No private key is read, asked for or printed, and
nothing is sent. `--rotate-address <0xNEW>` re-signs the proof of possession for another address
with the same BLS key, keeps a backup of node-info.yaml, records the address in .node-meta and
restarts the node; it is refused once either address has staked or while an update is running,
and a failed re-sign puts node-info.yaml back. `--json` prints one JSON object with every value the run read. Exit codes:
0 ready or nothing to do, 1 usage or environment, 2 RPC or on-chain state unreadable, 3 not ready
or refused, 4 rotation rolled back.

## Tests run

Harness: `<scratchpad>/d-tests/`. Each case runs the script copy (trailing `main "$@"` removed,
`lib/` symlinked) through `run_case.sh` (stubs `ps_is_root`, and `tn_launch_runner` when
TEST_RUNNER is set) in a clean `env -i` environment with a TN_ROOT_PREFIX fixture tree, PATH shims
(`curl`: python3, answers per method and selector from `FX_*` scenario variables and logs every
call; `systemctl`, `sleep`: recorders) and the real v0.15.0 binary
(`<scratchpad>/tn5-target/debug/telcoin-network`) behind the recorder `rec-telcoin`. Fixtures:
node-info + keys generated with `keytool generate validator` under TN_BLS_PASSPHRASE
`T3st pass;phrase#1 $HOME` (address 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed), and the live
address 0x0033…5ccb.

- `bash t_d.sh /bin/bash` and `bash t_d.sh $(command -v bash)`: 260 passed, 0 failed each.
  Ready path human and JSON (amount printed exactly `1,000,000 TEL (1000000000000000000000000 wei,
  stake version 0)`, JSON `stake_wei` "1000000000000000000000000", `stake_tel` "1,000,000"; the
  printed calldata equals the real `export-staking-args --calldata` and starts 0x2fb0d025; the
  printed `cast send` line and JSON `stake_command` contain it; export ran with
  `--bls-passphrase-source no-passphrase`; stdout pure JSON, one line, `jq -e .`); wrong chain
  (exit 2, both ids named, nothing read after); mainnet default RPC answering 2017 (exit 2); RPC
  transport failure and HTTP 429 (2); --network-rpc override; .node-meta address differs (warning
  names `--rotate-address <that address>`); no node-info (1); no .node-meta (testnet default +
  warning); bad NETWORK (1); not whitelisted (3, advice, no keytool); retired with burned NFT (0,
  "Retired", nothing to do); balanceOf unreadable (2); staked → activate block only (0, epochs
  601/603, "ends in about 1h 6m", sync checked, no keytool); statuses 2/3/4/5 (0, report, no
  commands; Exited gives "unstake() becomes eligible at epoch 571. That is now"); malformed and
  429 status (2); stakeConfig malformed (2); a 27-digit stake amount formatted and used as
  --value; balance short (3, shortfall 999,999.000000000007 TEL, commands still printed, simulation
  no-funds), exactly enough with gas price 0 (0), one wei short (3); balance or gas price
  unreadable (warnings, 0); calldata with a wrong selector, two lines, keytool failing (2);
  runner unreadable or binary missing (1); ten decoded reverts (InvalidProofOfPossession with the
  `--rotate-address` advice and no "regenerate"/"generate validator"/"new keys" anywhere,
  InvalidTokenId, DuplicateBLSPubkey, InvalidStakeAmount, InvalidStatus(3), EnforcedPause,
  LowLevelCallFailure, Error("boom!"), Panic(17), an unknown selector) and a revert without data
  (3, no stake command); simulation transport failure and other rpc-error (warnings, 0); sync lag
  148 (warning), 50 (none), local node down (warning); nine usage errors human and JSON (1); help;
  not root (1); the hard guard with lib 1.5.0 beside an unmodified copy (1, the B.1 message; JSON
  mode two lines, both parse, last is `done` ok:false).
- `bash t_rot.sh /bin/bash` and `bash t_rot.sh $(command -v bash)`: 170 passed, 0 failed each.
  Refusals (current status 1-5 and retired; new address 1/3/5/retired; exact wordings): exit 3,
  node-info byte-identical, no backup, keytool never run; current or new status unreadable (2);
  wrong chain (2). Happy path with the real `generate pop`, passphrase from the 0600 file, every
  external command wrapped by an argv/env recorder: exit 0, JSON `rotated`; execution_address is
  the new address, BLS key and name unchanged, PoP changed; mode 640 and owner kept; backup beside
  node-info, identical to the original, mode 640; .node-meta VALIDATOR_ADDRESS = checksummed new
  address, other keys kept, one line, mode 600; with tn_nodeMode CvvActive and 100 s left the
  epoch wait ran (node mode read, poll `sleep 15`, epoch 580→581 rollover, settle) before
  `systemctl restart telcoin`, then `is-active`; keytool argv `-q --datadir <dd> keytool generate
  pop --address <new>` with no passphrase-source flag. Passphrase checks: the recorder log
  exists, the passphrase is in no argv of any process, and the only process whose environment
  held TN_BLS_PASSPHRASE is keytool (once). Same with the passphrase from TN_BLS_PASSPHRASE (no
  file), plus a new address with no NFT allowed with an info line. A prepare run with
  TN_BLS_PASSPHRASE exported: no process at all inherits it, keytool export gets the
  no-passphrase source. Passphrase file mode 644, a symlink, empty env with no file: exit 1,
  nothing touched. Rollback, exit 4 and node-info byte-identical with mode 640, .node-meta and
  service untouched: wrong passphrase (real keytool fails), keytool writing garbage, keytool
  changing the name. Backup impossible (read-only dir): exit 1, nothing touched. --no-restart (no
  systemctl, restarted false); restart failing (exit 1, rotation kept); no service (warning, 0);
  no --yes with no answer (3, cancelled, nothing touched); answering y (0); same address (0,
  identical bytes, one status read); rotate then prepare from the new address (calldata equals
  the real export of the re-signed node-info, no warnings).
- `bash t_units.sh` under both bashes: 13 passed, 0 failed each. 630 rows of
  ps_dec_add/sub/mul/cmp/to_hex against python3 (edges up to 2^256-1, limb carries, leading
  zeros); 47 addresses against `cast to-check-sum-address` (40 random, EIP-55 vectors, live);
  checksum typo detection; ps_word_uint, ps_fmt_secs, tn_wei_to_tel; JSON escaping round-trips
  through jq. Earlier, `ps_keccak256_hex` matched `cast keccak` for every length 0-135 under both.
- `bash t_live.sh` under both bashes against https://rpc.adiri.tel (read-only): 25 passed, 0 failed
  each. tn_stake_amount_wei `1000000000000000000000000 0` equals `cast call … 'stakeConfig(uint8)' 0`
  word 0 at stake version 0 (from `getCurrentStakeVersion()`); `balanceOf(0x0033a370616805b1fd275b7ffab83fc41d665ccb)`
  is 1; its status `3 0 0 0`; the script with real curl on a node-info carrying that address:
  chain 2017 ok, checksum equals cast's, "Status: Active", "Nothing to do: the validator is
  active.", exit 0, JSON one object (epoch 581). Real reverts decoded from live eth_estimateGas:
  InvalidStakeAmount (own PoP, value 0), InvalidProofOfPossession (PoP signed for another address,
  also from 0x…dead), no-funds (value 1e24 from an address holding about 3,070 TEL).
- Static: `bash -n` under /bin/bash 3.2.57 and bash 5 on prepare-stake.sh, update-scripts.sh,
  install.sh; `shellcheck -x --severity=error prepare-stake.sh` clean, and clean at warning level
  (info level: four SC2329 notes for the functions reached through the EXIT trap);
  `/bin/bash tools/check-bash32.sh prepare-stake.sh update-scripts.sh install.sh` clean; no
  apostrophe in a `${var:-…}` word, no `local x="$(…)"`, no `--observer`/`common/` references.
- `bash tools/gen-checksums.sh`: "Generated 35 sidecar(s)", rc 0; `prepare-stake.sh.sha256`
  present and equal to `shasum -a 256 prepare-stake.sh` (1e6191355cf7588303570db53bfb06d43aa960df2f06747838c481d9f790cce2
  at hand-back; any later edit needs a re-run). The run also refreshed the sidecars of other
  packages' in-progress files (setup-node.sh.sha256 now shows modified); left as the tool left
  them, as instructed.

## Open issues

1. Release bookkeeping (orchestrator): commit `prepare-stake.sh` (mode 755) with
   `prepare-stake.sh.sha256` and the updater row; re-run `tools/gen-checksums.sh` before
   committing, since other packages' tracked files are changing. `update-scripts.sh` in the
   working tree also carries another package's hunk (the guarded `source lib/fallback.sh`); it is
   not mine. README changelog entry above; `update-scripts.sh` bump in the release commit.
2. Docs (owner of OPERATOR.md / README / partner guide; AGENTS.md wants all three plus the PDF):
   describe `prepare-stake.sh` and `--rotate-address`. Exact wording operators see, by exit code:
   - 0: "Ready to stake: run the commands above." · "Staked: activate() is next." · "Nothing to do:
     activation is under way." / "…: the validator is active." / "…: the validator is exiting." /
     "…: the validator has exited." / "…: the address is retired and can never stake again." ·
     "Rotated: node-info.yaml now names 0x…."
   - 1: "Unknown argument: X (see --help)." · "--network-rpc needs a value (see --help)." (same for
     --rotate-address) · "--network-rpc X is not an http:// or https:// URL." · "--yes and
     --no-restart only apply to --rotate-address." · "--rotate-address X is not an address (0x and
     40 hex digits)." · "--rotate-address cannot be the zero address." · "--rotate-address X has a
     wrong checksum (the mix of upper and lower case does not match); check it for a typo." ·
     "--json --rotate-address needs --yes: a JSON run cannot ask first." · "Run this as root: sudo
     bash prepare-stake.sh <args>" · "NETWORK=X in <.node-meta> is not testnet, mainnet or
     devnet." · "There is no public RPC for X; pass --network-rpc <URL>." · "No readable
     node-info.yaml at <path>. Generate the node keys first with setup-node.sh." · "<node-info>
     has no usable execution_address." · "Could not tell how this node runs keytool: no docker
     image or node binary was found in its launch file (tn_launch_runner rc N). Check that the
     node was installed with setup-node.sh." · "Could not start keytool with <runner>: <keytool
     error>" · "No BLS key passphrase. Set TN_BLS_PASSPHRASE (sudo drops it unless you run sudo
     --preserve-env=TN_BLS_PASSPHRASE), keep it in <config dir>/bls-passphrase with mode 600, or
     run this on a terminal to type it." · "<node-info> has no bls_public_key; nothing changed." ·
     "Could not read the owner and mode of <node-info>; nothing changed." · "Could not back up
     <node-info>; nothing changed." · "node-info.yaml now names 0x…, but telcoin did not come back
     up after the restart." (after "Check the logs: journalctl -u telcoin -n 50 --no-pager") ·
     "<reason> Putting node-info.yaml back failed too: copy <backup> over <node-info> by hand." ·
     the B.1 guard: "lib/common.sh X is older than 1.6.0. Run update-scripts.sh and try again."
   - 2: "Could not read the chain id from <rpc> (<reason>). Check the URL and the internet access
     of this server, or pass --network-rpc <URL>." · "<rpc> serves chain X (<testnet|mainnet|devnet|
     not a Telcoin network>), not chain Y (<network>). Pass --network-rpc <URL> with an RPC for chain
     Y." (today a mainnet node with the default RPC gets "https://rpc.telcoin.network serves chain
     2017 (testnet), not chain 487 (mainnet)") · "Could not read balanceOf(0x…) on the
     ConsensusRegistry from <rpc> (<reason>)." · "Could not read the validator status of 0x… from
     <rpc> (<reason>)." · "Could not read the stake amount from <rpc> (<reason>)." · "The stake
     amount read from <rpc> is not a number (<answer>)." · "keytool could not export the stake()
     calldata from <node-info> (exit N): <keytool error>" · "keytool did not print one line of
     stake() calldata starting with 0x2fb0d025: <first 80 characters>"
   - 3: "Not ready: 0x… is not whitelisted." (after "0x… holds no ConsensusNFT: governance has not
     whitelisted it yet." and "Send 0x… to the Telcoin Association for governance approval. Once
     governance mints the ConsensusNFT to it, run this script again.") · "Not ready: stake() would
     revert with <Error>. Fix that before you send the stake." · "Not ready: 0x… is short of TEL."
     (after "0x… holds X TEL. The stake needs Y TEL plus up to Z TEL for gas: send at least W TEL
     more to it before you stake.") · "Refused: 0x… has staked (<Staked|PendingActivation|Active|
     PendingExit|Exited>). Its BLS key is registered to it on-chain and cannot move to another
     address." · "Refused: 0x… is retired. Its BLS key stays registered to it and cannot move to
     another address." · "Refused: 0xNEW is retired and can never stake again." · "Refused: 0xNEW
     already has a validator record (<label>): it has staked with another BLS key." · "Refused: an update is in progress (PID N); try again when it has finished." (PID omitted when the holder is unknown) · "Cancelled:
     nothing changed."
   - 4: "<reason> node-info.yaml is back as it was (from <backup>)." where the reason is "keytool
     generate pop failed (exit N): <keytool error>. A wrong passphrase is the usual cause." ·
     "After keytool, node-info.yaml names X, not 0xNEW." · "After keytool, the BLS public key in
     node-info.yaml is different; it must not change." · "After keytool, the node name in
     node-info.yaml is different; it must not change."
   - Revert advice (exit 3), as printed: InvalidProofOfPossession → "the proof of possession in
     node-info.yaml was signed for a different address than 0x…. The keys themselves are fine." +
     "Re-sign it for the address you will stake from (this one, unless you stake from another
     wallet): sudo bash prepare-stake.sh --rotate-address 0x…"; InvalidBLSPubkey → restore
     node-info.yaml from the backup; DuplicateBLSPubkey → "A BLS key can be staked only once."
     + check the other address with check-node.sh --address; InvalidStakeAmount → run again;
     InvalidTokenId → governance approval; InvalidStatus → "(status N), so it cannot stake again";
     EnforcedPause → "staking is closed for now. Try again later."; LowLevelCallFailure, Panic,
     RequiresConsensusNFT, unknown → contact the Telcoin Association; Error(string) → the message.
3. Confirmed by the coordinator: "the new address has a record" means status 1-5 or retired;
   a status-0 whitelist record (what `mint` stamps) is the normal rotation target, and `none`
   (not whitelisted yet) is allowed too, with an info line.
4. Resolved in the follow-up below: rotation takes the update lock.
5. TPM installs delete the plaintext bls-passphrase file after sealing, so rotation there needs
   TN_BLS_PASSPHRASE or the terminal prompt; there is no tpm2_unseal path.
6. Insufficient-funds detection matches reth's message text ("insufficient funds", code -32003,
   checked live). Any other RPC error from the simulation is a warning only, by design.
7. The epoch-wait progress lines come from the library's default printer on stderr, while the rest
   of the human output is on stdout; on a terminal they interleave in order.
8. The `print_validator_onchain_status` texts (labels, "Next step") are the library's; the
   Undefined label still says "stake() on the ConsensusRegistry contract with your BLS public key",
   which prepare-stake now does for the operator.
9. The coordinator's note about `tn_node_parse_check` returning one sanitised line does not affect
   this script (it never calls it).
10. Library backlog: `tn_rpc_call` drops the `data` field of a JSON-RPC error object (it returns
    only `rpc-error <code> <message>`), so a revert's selector and arguments are lost. That is why
    prepare-stake carries a private `ps_rpc_raw` (the same curl call, returning the body when it
    holds an error object) for `eth_estimateGas`. A library variant, say
    `tn_rpc_call … ` returning `rpc-error <code> <message> data=<hex>` or a `tn_rpc_revert_data`
    helper, would let this script (and any later caller simulating a transaction) drop its copy.
    Live shape it must keep: `{"code":3,"message":"execution reverted","data":"0x<selector>…"}`.

## Follow-up (update lock on the rotation path; SCRIPT_VERSION stays 1.0.0)

- [x] F1. Script: after the confirmation and before anything is touched (runner, passphrase,
      backup), `TN_EXIT_TRAP_OWNED=1; tn_acquire_update_lock >/dev/null 2>&1`, as edit-config
      1.3.0 does; on failure `ps_done 3 refused "Refused: an update is in progress (PID N); try
      again when it has finished."` (the PID part only when the holder is known). The EXIT trap
      calls `tn_release_update_lock` (no-op when nothing is held; the flock kind goes with the
      process). The prepare flow takes no lock. Header comment, exit-3 line and usage text
      updated. bash -n both, shellcheck error and warning level, check-bash32: clean.
- [x] F2. Tests. Harness additions: every case gets its own TMPDIR (`$R/tmp`, where the mkdir
      lock lives) and a TN_UPDATE_LOCK_FILE whose directory is absent, so the mkdir kind is used
      unless a case opts into the flock kind (python `flockshim/flock`, which locks the open file
      description behind the inherited fd as util-linux `flock -n 9` does, plus `$R/lock/`);
      `holdlock.py` holds the flock with its PID written in the file like a running update-node;
      `trylock.py` probes it; `rec-telcoin` records at `generate pop` time whether the lock is
      held (`LOCKCHECK_MKDIR` / `LOCKCHECK_FLOCK`). New t_rot.sh rows (45): held lock, mkdir kind
      with a live PID: exit 3, JSON `refused`, msg exactly "Refused: an update is in progress (PID
      <holder>); try again when it has finished.", node-info byte-identical, no backup, no
      keytool, no restart, the holder's lock left alone; the same lock held while a prepare run
      exits 0 untouched; held lock, flock kind with a live holder: exit 3 with the holder's PID,
      nothing touched, the holder still holds it; a status refusal takes no lock (argv recorder:
      no mkdir of the lock); a fresh lock is held while keytool runs and gone after exit 0; a
      stale mkdir lock (dead PID) is taken over by this run and released; exit 4 (wrong
      passphrase) releases the mkdir lock (held during keytool, gone after, the next rotation
      gets it) and the flock (held during keytool, free after); a flock success releases; exit 1
      (passphrase file 644) after the lock: the argv recorder shows `mkdir <lock>` before the
      passphrase file is stat'ed and `rm -rf <lock>` from the exit trap.
      Results, /bin/bash 3.2.57 and bash 5.3: t_d.sh 260/260 each, t_rot.sh 215/215 each (170 +
      45), t_units.sh 13/13 each, t_live.sh 25/25 each (read-only, re-run for completeness). No
      holder process left behind; no /tmp/telcoin-update.lock.d created. `bash -n` both bashes on
      prepare-stake.sh, update-scripts.sh, install.sh; `shellcheck -x --severity=error` clean (and
      at warning level); `/bin/bash tools/check-bash32.sh prepare-stake.sh update-scripts.sh
      install.sh` clean. `tools/gen-checksums.sh` re-run (35 sidecars); `prepare-stake.sh.sha256`
      matches the final file: 17f513e7cb797ea91dc35bbe41def4a7b827572773dd9c09df1aa67f8347792f.
- [x] F3. Open issue 10 above: tn_rpc_call drops revert data (why ps_rpc_raw exists).

Operator-visible addition: `--rotate-address` refuses with exit 3 while update-node.sh holds the
update lock: "Refused: an update is in progress (PID N); try again when it has finished." The
changelog paragraph for prepare-stake 1.0.0 gains one clause: "…and restarts the node; it is
refused once either address has staked or while an update is running, and a failed re-sign puts
node-info.yaml back."

## Fix pass (V-OPS-2; SCRIPT_VERSION stays 1.0.0; edits to the committed f918d4f file)

Findings read: tasks/ckpt-fu-V-OPS-2.md and ckpt-fu-V-OPS-2-ps.md (ps F0 = warn 3 signals, M1/F2 =
warn 5 --private-key advice, N3 + N4 = notes 12).

- [x] X1. Signals (warn 3). main sets `trap 'PS_SIGNAL=TERM; exit 143' TERM`, `… INT … 130`,
      `… HUP … 129` right after the EXIT trap. ps_on_exit captures `$?` first, ignores further
      TERM/INT/HUP, and when PS_SIGNAL is set calls ps_on_interrupt before
      `tn_release_update_lock`: it waits for the keytool job (PS_KT_PID), then by PS_PHASE either
      puts node-info.yaml back from the backup ("window": from the backup until the re-signed
      file passed its checks), says how to finish ("rotated": re-signed and checked; re-run
      `--rotate-address <new> --yes`, which takes the same-address path, records the address and
      restarts), or says nothing changed. State `interrupted`, ok:false, exit 128+N. keytool now
      runs as a background job `( trap '' TERM INT HUP; …; tn_keytool … ) … 9>&- &` followed by
      `wait`: the job never stops half way through a write, `wait` returns at once on a trapped
      signal, and the job does not hold the flock descriptor. ps_rollback clears PS_PHASE.
- [x] X2. Key note (warn 5): --private-key removed; --ledger, --trezor, --account <name> (cast
      wallet import <name> --interactive), --interactive, and why --private-key is unsafe.
- [x] X3. Notes 12: in a rotation the .node-meta mismatch line no longer suggests
      `--rotate-address` (it says the rotation brings node-info in line with .node-meta, or
      replaces the recorded address). The InvalidProofOfPossession advice is only reachable from
      the prepare flow (the simulation never runs during a rotation), so the self-suggestion the
      verifier saw (N3) came from the mismatch warning, fixed above. keytool stderr goes through
      the new ps_keytool_error (first paragraph: the Error line plus a hint line, joined with
      "; ", no Location trailer, no final period, cut at a word boundary past 500 characters
      with " ..."; 500 rather than 300 because keytool puts the data-dir path in its error line), used by the export and the rollback messages: no mid-word cut, no " ." .
- [x] X4. Tests.
      - New `t_sig.sh BASH` (123 rows): the script runs in its own session (python setsid, with
        SIGINT/SIGQUIT reset to default first: a job started with & from a non-interactive shell
        inherits SIGINT ignored, and bash cannot trap a signal ignored at entry; a terminal Ctrl-C
        has no such issue). keytool is the slow recorder (marker, 3 s, real `generate pop`,
        marker). Six window cases — SIGTERM to the PID (mkdir lock; flock lock), SIGINT to the
        process group (mkdir; flock), SIGTERM to the group (flock), SIGHUP to the PID (mkdir) — each:
        lock held while keytool runs; exit 143/130/129; JSON one line, ok:false, the same exit,
        state `interrupted`, "Interrupted by SIG<X> while the proof of possession was being
        signed; node-info.yaml is back as it was"; keytool finished (waited for, not killed);
        no stray keytool process; node-info byte-identical to the backup and the original, mode
        640, still so a second later; .node-meta untouched; no restart; lock released (mkdir dir
        gone; flock free). After the window (SIGTERM during a slow `systemctl restart`): exit 143,
        node-info stays rotated, the "To finish, run … --rotate-address <new> --yes" message, lock
        released, and that re-run finishes (exit 0, restarted). Prepare flow: SIGTERM during a slow
        eth_getBalance → 143, ok:false, "Interrupted by SIGTERM; nothing was changed."; Ctrl-C to
        the group → 130, ok:false, state interrupted.
      - Updated/added rows: t_d.sh key note (5 lines exact, no VALIDATOR_KEY, `--private-key` only
        in the warning); t_rot.sh rollback message carries keytool's error and hint joined with
        "; ", no " .", no Location; rotation to the address .node-meta records (info line, no
        rotate suggestion, no warning) and to another one (replaces it); t_units.sh
        ps_keytool_error on real v0.15.0 stderr (wrong passphrase with hint, the one-line
        "passphrase is required", export with a Location trailer) and synthetic edges (a 900-char
        message cut at a word boundary with " ...", a 700-char word cut at 500 + " ...", final
        period dropped, leading blank lines skipped). flockshim gained `-u` (the library now
        releases the flock kind with `flock -u 9`).
      - Results, /bin/bash 3.2.57 and bash 5.3 (same each): t_d.sh 266/266, t_rot.sh 226/226,
        t_units.sh 22/22, t_sig.sh 123/123. No stray processes afterwards.
      - `bash -n` both bashes, `shellcheck -x --severity=error` clean (warning level clean too),
        `/bin/bash tools/check-bash32.sh prepare-stake.sh` clean. `VALIDATOR_KEY` appears nowhere
        in the script; `--private-key` only in the "Do not use" sentence. `tools/gen-checksums.sh`
        re-run: prepare-stake.sh.sha256 matches the edited file
        (74d468c3ab07f3a2465ad12181b61615792e295caf495a7c3f0d2e701f98a32e); both show as modified
        against f918d4f in the working tree.

New key note text (printed after the cast commands):

```
  Signing: --ledger signs on a Ledger; use --trezor for a Trezor. For a key in
  software, use --account <name>, an encrypted keystore you create once with
  'cast wallet import <name> --interactive', or --interactive to paste the key
  when cast asks for it. Do not use --private-key: the key would be on the
  command line of cast, where any user of that machine can read it with ps.
```

Operator-visible changes in this pass: Ctrl-C, SIGTERM or SIGHUP now end any run with exit
130/143/129 and (--json) ok:false, state `interrupted`; a rotation interrupted while signing waits
for keytool, puts node-info.yaml back from the backup and then releases the update lock; one
interrupted after the re-signed file passed its checks says how to finish. The signing note no
longer suggests --private-key. keytool errors in the export and rollback messages are keytool's
error line and hint, whole. A rotation no longer suggests --rotate-address for itself.

Open after this pass (not asked for): V-OPS-2-ps F1, a .node-meta written with CRLF line ends gives
`NETWORK=testnet\r … is not testnet, mainnet or devnet` (exit 1): `meta_get` keeps the CR. A fix
belongs in the library (strip a trailing CR in meta_get) or as a `tr -d '\r'` on NETWORK here.

## Fix pass 3 (code review; SCRIPT_VERSION stays 1.0.0; edits to the committed 77e043b file)

Finding: `--rotate-address` took the fleet-wide update lock before `ps_get_passphrase`, so an
operator who walked away at the "BLS key passphrase:" prompt (`read -s` blocks for ever) left
update-node, edit-config and install-caddy refused with "an update is in progress".

- [x] Y1. Script: `ps_runner` and `ps_get_passphrase` now run before
      `TN_EXIT_TRAP_OWNED=1; tn_acquire_update_lock`; nothing between the confirmation and the
      lock edits state. Everything that edits state (the node-info reads for the checks, the
      owner/mode record, the backup, keytool, meta_set, the restart) stays after the lock.
      Passphrase handling unchanged (environment copy taken at start, file, TTY prompt; only the
      keytool job gets it; the EXIT trap clears it). Comment says why the lock comes after.
- [ ] Y2. Tests: a TTY prompt that never answers holds no lock (mkdir and flock kinds); the
      "exit 1 with no usable passphrase" row now expects no lock at all; re-run t_d, t_rot,
      t_units, t_sig under both bashes; static checks; sidecar

## Fix pass 3 (code review) — recorded by the orchestrator

The agent was cut off by a rate limit after making the change and running part of the tests.
Change: `ps_runner` and `ps_get_passphrase` now run before the update lock is taken, so an
unanswered passphrase prompt never holds the lock. Orchestrator gate, both bashes: t_d 266/266,
t_rot 264/264 (incl. the new lock-order rows), t_units 22/22, t_sig 123/123; bash -n, shellcheck
error level and the lint clean. Committed as 23eb06c.
