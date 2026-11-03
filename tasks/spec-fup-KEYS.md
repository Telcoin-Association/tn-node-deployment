# KEYS: keytool verify before credential edits; destruction rule (issue #32)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-KEYS`, branch
`fup/KEYS`, checkpoint `tasks/ckpt-fup-KEYS.md`.

## Goal

Every edit-config action that rewrites the BLS credential proves the key still opens with
the passphrase it is about to keep, on releases whose keytool can verify; remove-node tells
the operator that shredding is not destruction.

## Owned files

`edit-config.sh` (the credential actions only), `remove-node.sh` (`_rm_shred_note` text only;
AUDIT adds a teardown step and OBS a token shred to the same file elsewhere: do not reflow),
tests `tools/tests/edit_passphrase_test.sh`, `tools/tests/credential_test.sh`,
`tools/tests/remove_test.sh` (append your cases at the end under a `# KEYS` block; OBS appends
its own block to remove_test.sh).

## Facts (main 1187ddb)

- edit-config.sh: `edit_migrate_credential` :2074 (`--migrate-credential` and the menu: moves
  the passphrase into the encrypted credential `/etc/telcoin/bls-passphrase.cred`),
  `edit_reseal` :2107, the passphrase actions `edit_bls_passphrase` / `edit_change_passphrase`
  (grep for the exact names; they re-seal or rewrite the credential and restart the node with
  rollback on failure). No `tn_keytool_has` call in the file today.
- lib/common.sh `tn_keytool_has SPEC WORD [SUBCMD…]` :9013: rc 0 when `keytool SUBCMD… --help`
  lists WORD, 1 when not or the subcommand is unknown to the release, 4 when the probe could
  not run. SPEC is the install spec (`binary:/path` or `docker:<image>`); grep how edit-config
  builds it for `tn_node_launch_target` / keytool calls. `keytool verify` is upstream work
  (telcoin-network #1730, open): today no release has it, so the gate is rc 1 everywhere and
  the hook must be a no-op there.
- The passphrase is fed on stdin / `TN_BLS_PASSPHRASE` through the existing feed helpers
  (`passphrase_print_test.sh` forbids any echo of it); keep using them.
- remove-node.sh `_rm_shred_note` :341 prints once: "Overwriting files with shred before
  deleting them is best effort on SSDs, copy-on-write and cloud disks."

## Required behaviour

1. A helper in edit-config.sh, `edit_keytool_verify PASSPHRASE_SOURCE` (name yours), that runs
   `keytool verify` (the upstream CLI shape is not final: run `keytool verify --datadir DIR`
   with the passphrase on the same channel the other keytool calls use, and isolate the
   command line in one place so the final shape is a one-line change) when
   `tn_keytool_has "$spec" verify keytool` is rc 0; rc 1 skips silently (log line: "keytool
   verify is not in this release; skipped"); rc 4 warns that the probe could not run and
   skips. When verify runs and fails, the action stops before any file is written, with the
   message that the passphrase does not open the key (never the passphrase itself).
2. Call it in `edit_bls_passphrase`, `edit_change_passphrase` (verify the OLD passphrase
   before rewriting, the new one after), `edit_reseal` and `edit_migrate_credential`, before
   the first write. The restart-and-rollback behaviour after the write is unchanged.
3. `_rm_shred_note`: add one sentence: decommissioning a host that held a key means
   destroying or crypto-erasing the disk and deleting every snapshot and image taken from it;
   shred alone does not do that. Keep the once-per-run behaviour.

## Tests

- `edit_passphrase_test.sh` / `credential_test.sh`: with a stub keytool whose `--help` lists
  `verify`: a failing verify stops the action before the credential file changes (compare the
  file's bytes and mtime); a passing verify proceeds as today; a stub without `verify` in
  `--help` skips with the log line and proceeds; a stub whose probe exits 4 warns and
  proceeds. Cover all four actions. The passphrase never appears in the stub's argv log.
- `remove_test.sh`: the note contains the destruction sentence and still prints once.

Run under bash 5.3 and `bash:3.2`; `bash -n` both; `check-bash32`; shellcheck 0.9 + 0.11;
`bash tools/tests/run.sh passphrase_print_test.sh root_write_pipe_test.sh`.

## Docs notes to hand over (the runbook chapter DOCS writes in OPERATOR.md)

Backup (what to copy: `node-keys/`, the credential, `.node-meta`; where it must not go);
restore only after the old host is gone (two hosts with one key equivocate); snapshots beside
the original count as copies; rotation (`prepare-stake.sh --rotate-address` for the execution
address; the BLS key cannot rotate without a new validator record); decommissioning
(destroy/crypto-erase + snapshots); lost passphrase (the key is lost: unstake with the
execution key, generate a new validator). Verified facts only: say which script does which
step today, and mark what waits on #1730.
