status: done

# V-DOC-O checkpoint (OPERATOR.md read-only verification)

Sections
- [x] intro (lines 1-24)
- [x] 0. Who this is for and vocabulary (--observer hidden no-op confirmed in v0.15.0 source node.rs: "Deprecated and ignored", hide = true)
- [x] 1. Before you start (hardware lines, systemd msg, CVE paths, ipify, firewall menu 1), chain ids, check-node/prepare-stake chain mismatch all match)
- [x] 2. Install (prompts, step order, floors, peers-file checks, firewall enable/status text, keygen staking printout match; state-export-keep N>=2 matches upstream help)
- [x] 3. Confirm the node is syncing, then synced (verdict lines, threshold 50 (>), wrong-chain warn not counted, epoch/committee lines, workers error, macOS memory note)
- [x] 4. Day-2 operations (update-scripts, update-node menus/CONFIRM/45s/lock/ref msg, epoch-wait msg + 300/90/1800/15 clamp 5-20 + CvvActive gate, edit-config menu 1-13 incl. BLS passphrase 5 / refresh 11 / restart 12 / exit 13, .bak.<UTC>, --set rollback/no-op, lock msg, refresh msgs, start-wrapper msg + 0750 root:root, UI role order network->local->cached, helper msg)
- [x] 5. Public RPC + set-rpc dry run (all install-caddy/check-node quotes match; 413 live-tested; `all` = upstream defaults)
- [x] 6. Validators + cast + keytool dry runs (all prepare-stake quotes/exit codes/rotation rules match; registry fns exist at v0.15.0; hidden anchor OK)
- [x] 7. Automation
- [x] 8. Legacy installs
- [x] 9. Troubleshooting (every quoted message grepped; all present)
- [x] 10. Getting help
- [x] Appendix (wording: "prepared locally ... will be opened as a pull request after make attest" — correct)
- [x] Final report

Dry runs (exact)
- cast, RPC=https://rpc.adiri.tel, REG=0x07E1..7E1, ADDR=committee[0] from tn_getCurrentEpochInfo = 0x0033a370616805b1fd275b7ffab83fc41d665ccb (epoch 581):
  balanceOf -> 1; getValidator(address)(address,uint32,uint32,uint8,bool,uint8,uint8) -> 7 lines addr/0/0/3/false/0/0, status 4th;
  getCurrentEpoch()(uint32) -> 581; getCurrentEpochInfo()((address[],uint256,uint64,uint32,uint32,uint8)) -> starts with the 5-address committee;
  VERSION=$(getCurrentStakeVersion()(uint8)) -> 0; stakeConfig(uint8)(...) -> 1e24 / 1e21 / 2.58e22 / 21600;
  STAKE=$(... | awk 'NR==1 {print $1}') -> 1000000000000000000000000 exactly. All read as the runbook says.
- keytool, SCRATCH/tn5-target/debug/telcoin-network, datadir SCRATCH/vdoc/V-DOC-O/dd:
  TN_BLS_PASSPHRASE=x telcoin-network --datadir D keytool generate validator --address 0x..AA -> rc 0.
  Runbook 6.10 source line as written (binary + node-info path substituted, no sudo), in $(...): rc 0, exactly 1 line, 0x2fb0d025..., len 650; runbook `cast sig` check prints "calldata OK".
  Same without -q: 2 lines (INFO Loading configuration). Without a passphrase source and no env: rc 1 "passphrase is required". No default datadir created under $HOME.
  Docker export line not runnable (no docker); its IMAGE capture fits the unquoted .node-meta values.
- set-rpc: runbook shows no literal set-rpc line (prose only). Script form `-q --datadir D keytool set-rpc --http https://node7.example.com/ --ws wss://node7.example.com/` -> rc 0, no passphrase source needed, only workers[0].rpc changed; `set-rpc --clear` -> rc 0, file byte-identical to before.
- Caddy body cap (2.8.4 and 2.11.4, `request_body { max_size 2MB }`): 1,999,000 B -> 200; 2,000,001 B -> 413.
- Second `keytool generate validator` on a non-empty node-keys without --force -> rc 1 (keytool/mod.rs init_path).

Findings (final)
1. warn — 2.2 step 6: "BLS passphrase protection (not asked for Docker). This menu comes after the source build (20 to 40 minutes) or the Docker install and image pull." Self-contradictory: Docker never sees the menu (setup-node.sh step_preflight: `if [[ "$INSTALL_METHOD" != "docker" ]] && ! json_mode; then _select_passphrase_method`). Fix: "...comes after the source build (20 to 40 minutes), or for an existing binary once setup has found it."
2. warn — 2.6: "use `5) Manage trusted IP whitelist` to add your own IP ... then remove the blanket SSH rule from the same menu." `ufw allow <port>/tcp` creates an IPv4 rule and a `(v6)` twin; `2) Remove a whitelist entry` deletes one rule number per run (firewall-setup.sh ~1032-1055). Removing "the" rule leaves SSH open to everyone over IPv6. Fix: "remove both blanket SSH rules, the IPv4 one and its `(v6)` twin; list the rules again before the second delete, because the numbers shift."
3. warn — 2.5 "If you have not staked yet, you can regenerate keys and carry on." and 2.2 step 9 `Overwrite existing keys?`: answering Yes cannot work. setup-node passes no --force (setup-node.sh 1499-1515) and the v0.15.0 keytool refuses a non-empty node-keys/ without it (dry run: rc 1), so setup ends "Key generation failed." Fix (doc): to regenerate an unstaked node, move `node-keys/` and `node-info.yaml` aside first, then re-run setup. Script followup: the prompt offers an overwrite it cannot perform.
4. warn — 9, first row (`unexpected argument '--observer'`): the manual fix names only `/opt/telcoin/start-telcoin.sh` and `systemctl restart telcoin`. Legacy role-named installs, the likeliest carriers of --observer, use `/opt/telcoin/start-telcoin-<role>.sh` and the `telcoin-<role>` unit (migrate-node-naming.sh:84/289; lib/common.sh tn_node_launch_target `start-${svc}.sh`), so `restart telcoin` fails there. Fix: add "on a legacy install, `start-telcoin-observer.sh` or `start-telcoin-validator.sh` and `restart telcoin-observer` or `telcoin-validator`; the check-node warning names the exact file."
5. note — 1.5: "check-node.sh, prepare-stake.sh and the chain-config refresh in edit-config.sh take the network, and from it the public RPC, from that line." The edit-config refresh uses NETWORK only to pick the chain-config directory (edit-config.sh ~1895); it reads no public RPC. Fix: "...take the network from that line; check-node and prepare-stake also take the public RPC from it."
6. note — 4.7: "The removal script asks before each component: service, Docker container and image, ..." The service and container go without their own prompt once `Proceed with node removal?` is answered (remove-node.sh remove_node_unit -> stop_and_disable_service / remove_docker_container). Fix: "After `Proceed with node removal?` it removes the service and its container, then asks before each of: Docker image, chain data, keys, binary, source tree, logs, service user, and the UI."
7. note — rpc.telcoin.network at 3 (372-373 example), 6.2 (line 800) and 9 (row "serves chain <X>"): each says it serves chain 2017 today but not that mainnet is unlaunched (1.5 says both). Fix: add "(mainnet has not launched)" at each, per the endpoint rule.
8. note — 7.3: "`TN_ASSUME_YES=true` answers yes to the scripts' yes/no prompts." Through lib/common.sh confirm() it also accepts destructive prompts, e.g. remove-node `Remove chain data?` (keys stay protected by the typed DELETE). Fix: add "destructive ones included, such as remove-node's `Remove chain data?`."
9. note (incidental, script) — update-node.sh ~1854-1857 tells an `existing` install to "replace the file at /opt/telcoin/telcoin-network manually", but since setup-node 1.3.0 an existing install runs its recorded BINARY_PATH (setup-node.sh 1926, 2262). The runbook (2.3/2.4/4.2) is right; the script message is stale. followup candidate.

Not checked (out of reach or left to the coordinator): the appendix's "13 commits" (needs the telcoin-network checkout, which I must not touch); the Docker export line (no docker); the UI stream-abort wording in 4.5; firewall `--json --port` values; the full pre-root validation list in 7.1.

Verdict: OPERATOR.md is in good shape. Every message the runbook quotes was found in the scripts. The facts held: chain ids, endpoints, registry address and selectors, 1,000,000 TEL, E+1/E+3 arithmetic, epoch-wait defaults, the 2 MB = 2,000,000-byte cap with 413, Caddy 2.8.0, the v0.13.0/v0.15.0 floors, edit-config menu 5/11/12/13, prepare-stake exit codes, helper API 2. The staking, keytool and set-rpc commands run as written: the export capture yields exactly one line with -q and the passphrase source. The appendix branch is worded as prepared locally and to be opened as a PR, and the hidden 6.4 anchor is in place. There are no error-level findings. Four warns need edits before release: the Docker/passphrase-menu contradiction, the IPv6 SSH twin rule, the key-regeneration path that cannot work, and the legacy paths in the --observer fix. The rest are notes.
