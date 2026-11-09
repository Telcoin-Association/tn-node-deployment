status: done

Sections:
- [x] S1 edit-config: edit_keytool_verify_run + edit_keytool_verify, called in edit_change_passphrase, edit_reseal, edit_migrate_credential (edit_bls_passphrase reaches all three) -- bfdf000
- [x] S2 tests: edit_passphrase_test.sh KEYS block -- 86aa4c0
- [x] S3 remove-node: destruction sentence in _rm_shred_note -- b12e18b
- [x] S4 tests: remove_test.sh "# KEYS" block at the end -- 87f39da
- [x] S5 gates (all green, see Tests run)
- [x] S6 lib/common: tn_keytool_has returns 1 on probe rc 1/2 only when the output matches `*Usage:*keytool*`, else 4 (V2 K-1) -- f39bae1
- [x] S7 tests: library codes + wrapper-fails (setpriv exit 1) + docker exit 1 + clap-error cases in edit_passphrase_test.sh (keytool_test.sh does not drive tn_keytool_has) -- 7011f32
- [x] S8 edit-config: tn_require_fns also names tn_launch_runner tn_keytool_has tn_keytool _tn_cred_plain_ok _tn_passfile_trim_safe (V2 S-3) -- c81065c; lib_skew_test.sh KEYS block -- b559448
- [x] S9 gates round 2 (all green)

## Operator-visible changes

- edit-config.sh, before the first write of: menu 5 option 1 (change the stored passphrase),
  menu 5 option 2 / `--reseal` (seal the credential again), menu 5 option 2 on a non-credential
  host / the menu's legacy move / `--migrate-credential`: when the node's release lists
  `verify` in `keytool --help` (tn_keytool_has SPEC verify, SPEC from tn_launch_runner of the
  launch file), it runs keytool verify through tn_keytool (service user, global `-q --datadir
  DIR --bls-passphrase-source stdin`, passphrase on stdin only). The command line is in
  `edit_keytool_verify_run` alone (one line: `tn_keytool "$1" "$2" verify`).
- Which passphrase is checked: change = the NEW one; reseal = the value the credential
  decrypts to, or the typed one when it no longer decrypts; move = the unit's value or the
  typed one, else the one line of `/etc/telcoin/bls-passphrase` (only when that file is
  root-owned, regular and one line without edge whitespace, else the migration's own refusal
  stands). The "already on the credential" case writes nothing and checks nothing.
- Messages (print_* in the menu, JSON `log`/`warn`/`error` events with --json):
  - log: `keytool verify is not in this release; skipped` (every release today: #1730 open)
  - warn: `Could not run the node binary of <spec> to see whether it has keytool verify; skipped`
  - warn: `Cannot tell which node release starts <svc> from <launch file>; keytool verify skipped`
  - log: `keytool verify: the passphrase opens the BLS key in <data dir>`
  - error (stop, nothing written): `<The new passphrase|The passphrase|The passphrase in
    /etc/telcoin/bls-passphrase> does not open the BLS key in <data dir> (keytool verify, exit N);
    nothing was changed. Use the passphrase the key was created with.`
  - error (stop): `keytool verify could not run (exit N[: first line]); nothing was changed. Fix
    the cause and try again.` for exit 4/125/126/127 (tn_keytool or docker could not start it).
  - error (stop): `keytool verify cannot run: the node data dir cannot be read from .node-meta
    (see above); nothing was changed`
  - the change action then prints `Passphrase unchanged.`; `--reseal`/`--migrate-credential`
    exit 1, `--json` done `{"ok":false,"rolled_back":false,"field":"passphrase",...}` as for
    their other refusals.
- The update lock and the idempotent ownership migration (edit_lock) still come first, as on
  every edit-config write path; the committee guard, epoch wait, restart and rollback after
  the write are unchanged.
- Round 2 (V2 K-1): lib/common `tn_keytool_has` maps a probe exit 1 or 2 to rc 1 ("not
  listed") only when the captured output matches `*Usage:*keytool*` (clap 4.6 help and
  errors both print `Usage: <bin> keytool ...`); other output (busybox setpriv rejecting
  --reuid with exit 1, docker exit 1 with its own message) is rc 4. edit-config then warns
  `Could not run the node binary of <spec> to see whether it has keytool verify; skipped` and
  takes the probe-rc-4 path (no check, the write goes ahead as it did before the hook), instead
  of logging `keytool verify is not in this release; skipped`. setup-node's only other caller
  (`keytool_supports_rpc_args`, `tn_keytool_has "$(node_runner_spec)" --rpc-http generate
  validator`) treats every non-zero rc as "no --rpc-http": rc 4 prints `Could not ask the
  keytool whether it can advertise RPC at keygen (its --help did not run), so <http> + <ws>
  reach node-info.yaml when public RPC is enabled after the node starts (install-caddy.sh
  --phase=rpc-enable).`, drops the derived URLs and keygen goes ahead; the only change for
  setup-node is that message on a host whose wrapper fails with 1/2.
- Round 2 (V2 S-3): edit-config's COMMON_VERSION gate also requires tn_launch_runner,
  tn_keytool_has, tn_keytool, _tn_cred_plain_ok, _tn_passfile_trim_safe: a library without
  them gets the one refusal `lib/common.sh <v> is older than this edit-config.sh: run
  update-scripts.sh and try again.` (rc 1; --json: error + done).
- remove-node.sh: the once-per-run shred note has a second line: `Decommissioning a host that
  held a validator key means destroying or crypto-erasing its disk and deleting every snapshot
  and image taken from it; shred alone does not do that.`

## Docs notes

Runbook facts for OPERATOR.md (verified against the code on fup/KEYS; "#1730" marks what waits
on keytool verify upstream):

- What holds the key material on a node: `<data dir>/node-keys/` (default `/var/lib/telcoin`,
  `DATA_DIR` in `.node-meta`; owned by the service user), with the BLS key wrapped by the
  passphrase as `node-keys/bls.kw` (check-node's check_bls_cleartext fails on a cleartext
  `bls.key` without `bls.kw` and warns when both exist); `<data dir>/node-info.yaml`; the
  passphrase in `/etc/telcoin/bls-passphrase.cred` (systemd-creds, `PASSPHRASE_METHOD=credential`,
  key `host` or `host+tpm2`) or `/etc/telcoin/bls-passphrase` (root 0600, `PASSPHRASE_METHOD=stdin`,
  testnet/devnet below systemd 250 only); `.node-meta` in `/etc/telcoin` (records DATA_DIR,
  NETWORK, PASSPHRASE_METHOD, CREDENTIAL_KEY, VALIDATOR_ADDRESS). Root-only copies made by the
  scripts' own edits go to `/var/backups/telcoin` and are shredded after a passphrase move.
- Backup: setup-node prints "BACK UP YOUR KEYS NOW" / "BACK UP your node-info.yaml and
  node-keys/ directory now" after keygen (the UI gates finalize on it). Copy `node-keys/` and
  `node-info.yaml`; keep the passphrase itself offline and apart from them (bls.kw plus the
  passphrase is the key in the clear). The `.cred` is NOT a portable backup: it is sealed to
  the host that wrote it (systemd host key, plus the TPM with `host+tpm2`); `.node-meta` is a
  record of the install, not needed to run the key. A backup must not sit on the node's own
  disk or in a snapshot or image of it (see snapshots). No script makes the backup today.
- Restore (only after the old host is gone and cannot start again: two hosts running one BLS
  key sign conflicting votes; no script detects a second copy): place `node-keys/` and
  `node-info.yaml` in the new data dir (service user's), write the passphrase as the root 0600
  one-line file `/etc/telcoin/bls-passphrase`, run setup-node interactively and answer no to
  "Overwrite existing keys?": setup_keep_stored_passphrase keeps the keys and, on a credential
  host, moves that file into a new `.cred` sealed on this host. `--json` setup refuses existing
  node-keys ("refusing to overwrite in non-interactive mode"). setup-node keeps a `.cred` it
  finds without decrypting it, so do not copy the old host's `.cred`. Once #1730 lands
  edit-config (not setup-node, see Open issues) checks the passphrase against the key before
  a credential write.
- Snapshots: a disk snapshot or image of a node holds `node-keys/`, `node-info.yaml` and the
  `.cred` (or plaintext file); with `CREDENTIAL_KEY=host` (tn_credential_key picks it when there
  is no usable TPM: testnet and devnet, mainnet only with `--allow-no-tpm`) the systemd host key
  that decrypts the `.cred` (systemd behaviour: /var/lib/systemd/credential.secret) is on the
  same disk, so the snapshot alone can start the validator elsewhere. Count every snapshot and image as a copy
  of the key: same restore rule, delete them at decommissioning.
- Rotation: `prepare-stake.sh --rotate-address <0xNEW> [--yes] [--no-restart]` re-signs the
  proof of possession for another execution address with `keytool generate pop` (BLS key
  unchanged; node-info.yaml and VALIDATOR_ADDRESS change; the node restarts). It is refused once
  the current address has staked ("a registered BLS key cannot move to another address"), when
  the new address has staked or is retired, and during an update. The operator sees (exit 3)
  `Refused: <addr> has staked (<status>). Its BLS key is registered to it on-chain and cannot
  move to another address.`; for a retired current address `Refused: <addr> is retired. Its BLS
  key stays registered to it and cannot move to another address.`; for the new address
  `Refused: <new> is retired and can never stake again.` or `Refused: <new> already has a
  validator record (<status>): it has staked with another BLS key.`; an unreadable status exits
  2 (V2 D-3: quote these, not the header comment's paraphrase). Its passphrase comes from
  TN_BLS_PASSPHRASE, then `/etc/telcoin/bls-passphrase`, then a terminal prompt (it does not read
  the `.cred`). The BLS key itself cannot rotate: a new BLS key is a new validator (new keys,
  new ConsensusNFT, new execution address). `edit-config` option 5 changes only the STORED
  passphrase (keys are not re-encrypted); with #1730 it refuses a new passphrase that does not
  open the key.
- Decommissioning: remove-node shreds node-keys, `/etc/telcoin` (the `.cred`, plaintext file,
  `.node-meta`) and `/var/backups/telcoin`, and now says shred is best effort and is not
  decommissioning; destroy or crypto-erase the disk and delete every snapshot and image.
  Validator exit is separate: `beginExit()` while Active, then once Exited and one epoch later
  `unstake(address,bool)` with false (README "Leaving later"; check-node `--address` says when
  unstake is eligible); unstake retires the address and burns its NFT.
- Lost passphrase: the wrapped key (bls.kw) cannot be opened, so the key is lost. While the
  host that sealed the `.cred` still decrypts it, root can read it back by hand with
  `systemd-creds decrypt --name=bls-passphrase /etc/telcoin/bls-passphrase.cred -` (the same
  call `edit-config.sh --reseal` makes into a pipe; it prints the passphrase, so only on that
  host and to a private terminal). Otherwise: exit with the execution wallet (`beginExit()`,
  then `unstake`; neither needs the BLS key) and start over as a new validator (setup-node
  keygen, governance NFT for a new address). Today nothing checks that a passphrase opens the
  key before it is stored; with #1730 edit-config does, before each credential write.

## Tests run

- bash 5.3 (host): edit_passphrase_test.sh 139 checks, 0 failures, 2 skipped (root-only);
  remove_test.sh 305/0/0; credential_test.sh 142/0/0; keytool_test.sh 45/0/0
- bash 3.2 (`docker run ... bash:3.2 bash tools/tests/run.sh ...`): edit_passphrase 139/0/2,
  remove 305/0/0, credential 142/0/0, keytool 45/0/0
- ubuntu:24.04 as root: edit_passphrase 148/0/0, remove 305/0/0
- mutation: with the four verify calls replaced by `true`, 38 KEYS checks fail
- full suite `bash tools/tests/run.sh` (bash 5.3): 59 test files, 0 failed
- `bash tools/tests/run.sh tools/tests/passphrase_print_test.sh tools/tests/root_write_pipe_test.sh`: 2 files, 0 failed
- `bash -n` under bash 5.3 and bash:3.2 on edit-config.sh, remove-node.sh,
  tools/tests/edit_passphrase_test.sh, tools/tests/remove_test.sh: clean
- `bash tools/check-bash32.sh` on the four: clean; `bash tools/check-perl-interp.sh
  edit-config.sh remove-node.sh`: clean
- `shellcheck -x --severity=error` 0.11 (host) and koalaman/shellcheck:v0.9.0 on the four: clean;
  full shellcheck of edit-config.sh: same 2 pre-existing findings as main, none in new code
- Note: run.sh wants paths (`tools/tests/x_test.sh`), not bare names.
- Round 2, per file (bash 5.3 / bash:3.2 / ubuntu:24.04 root):
  edit_passphrase_test 146/0/2, 146/0/2, 155/0/0; credential_test 142/0/0 x3;
  keytool_test 45/0/0 x3; lib_skew_test 144/0/0, 108/0/1, 108/0/1 (the containers skip the
  037c810 part: no git; the KEYS block sits before it so it runs there);
  remove_test, passphrase_print_test, root_write_pipe_test: exit 0 in all three.
- Round 2 mutations: old `1|2) return 1` mapping -> 4 checks fail (both library checks, the
  warning and "not taken for a release without verify"); the require-list line removed -> 7
  lib_skew checks fail.
- Round 2 full suite `bash tools/tests/run.sh` (bash 5.3): 59 files, 0 failed.
- Round 2 `bash -n` 5.3 + 3.2, check-bash32, shellcheck 0.11 + v0.9.0 (--severity=error) on
  edit-config.sh lib/common.sh edit_passphrase_test.sh lib_skew_test.sh: clean.
- Cherry-pick check (read-only `git merge-tree --write-tree`): f39bae1, 7011f32, c81065c,
  b559448 onto hardening-followups 3a730c5: 0 conflicts.

## Open issues

- Spec deviations (code wins): (1) `tn_keytool_has "$spec" verify keytool` would probe
  `keytool keytool --help` (rc 1 always); the call is `tn_keytool_has "$spec" verify`.
  (2) edit_change_passphrase does not re-encrypt the key, so the OLD passphrase opening the key
  is the failure case, not a precondition; only the NEW one is verified. (3) edit_bls_passphrase
  writes nothing itself; it reaches the check through the three actions it calls.
  (4) credential_test.sh tests the library only (it does not source edit-config), so the cases
  went to edit_passphrase_test.sh; credential_test.sh is unchanged. (5) The spec's backup list
  names "the credential": the `.cred` is host-bound and not a restorable backup; the passphrase
  is (Docs notes).
- Decision for review: a verify that is in the release but cannot start (tn_keytool rc 4, docker
  125/126/127) STOPS the action; the spec only fixed rc 4 of the probe (skip with a warning).
- Round 2: the coordinator's expected outcome for the wrapper-fails case said "the credential
  is unchanged"; that holds only for the stop path. The code's rc-4 path is warn-and-skip (the
  spec's item 1), so the fixture asserts the warning and that the write goes ahead. To stop
  instead, change the `*)` arm of the probe case in edit_keytool_verify to edit_error +
  `TN_CRED_PASS=""` + return 1.
- Round 2: `tn_node_has_flag` (lib/common, used by edit-config edit_need_flag and others) has
  the same `1|2) return 1` shape as the old tn_keytool_has; not changed here (not in scope).
- Round 2: first draft of the lib_skew check put a bare-pattern `case` inside `$( )`; bash:3.2
  failed it at run time (the known 3.2 rule); moved into a function. Also the first placement
  at the end of lib_skew_test never ran in the containers because the file calls `finish`
  early without git.
- Not KEYS-owned (setup-node.sh): setup_keep_stored_passphrase keeps an existing `.cred`
  without decrypting it and without a key check; once #1730 lands it would be the place for the
  same verify on a restore. Suggested text for a follow-up issue: "setup-node: when kept keys
  meet a stored passphrase, decrypt the credential and run keytool verify before keeping it".
