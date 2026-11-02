# Plan: mainnet hardening round (2026-10-15)

Done on branch `mainnet-hardening`, forked from `main` at 037c810: 155 commits up to 417fbe2,
then the docs and release prep. The previous plan (the followup.md backlog round of
2026-10-01) is complete; its review is in `tasks/todo.md`.

## Goal

Make the scripts fit to run a mainnet validator. In practice that means:

- the install tree is root-owned, and root never runs or trusts a file the service account can
  write;
- the BLS passphrase never sits on a command line, in a unit `Environment=` line or in an
  exported variable;
- script updates install only from a signed manifest, node releases only from a signed
  `SHA256SUMS`, and Docker images only by digest;
- every node restart waits for the epoch window and refuses when it would cost the committee
  its quorum;
- the add-ons and the Node Manager UI follow the same rules.

What this round could not finish is in `followup.md`.

## How the round ran

- One integration branch. Each package worked on its own branch in its own worktree, was
  rebased onto the tip and merged fast-forward, so the history stays linear. One person merged.
- Packages did not bump version constants or edit the updater arrays (`SCRIPTS`, `UI_BUNDLE`,
  `TESTNET_ADDONS_BUNDLE`); release prep does both once.
- The shared primitives landed first, so every later package coded against one set of helpers.
- After each package merged, an independent verifier wrote its own harness against the spec,
  and a fix pass on its own branch closed what the verifier found.
- Every package ran the same gates: `bash -n` under bash 5 and bash 3.2,
  `tools/check-bash32.sh`, `shellcheck -x --severity=error`, the fixture suite
  `tools/tests/run.sh` under bash 5, under `bash:3.2` and as root in `ubuntu:24.04`, the UI
  tests, and from the credential package on, `tools/check-perl-interp.sh`. Suite counts below
  are checks passed / failed / skipped.

## Packages

- [x] Test runner and root-write primitives. `tools/tests/` with a runner and shared check
      helpers; `tn_root_dir_ok`, `tn_write_root_file`, `tn_backup_file`, `tn_restore_backup`,
      `tn_install_root_binary`, `tn_as_service_user`, `tn_detect_network`,
      `tn_passphrase_ok`, `tn_release_tag_ok`, `tn_start_script_path`; `meta_get` refuses a
      duplicated key. Gates: bash 5 193/0/5, bash 3.2 233/0/2, Ubuntu as root 248/0/0.
- [x] update-node rollback. The pending update is written root 0600 and parsed as
      `KEY=value` data; backups go through `tn_backup_file` with recorded hashes, and every
      rollback through `tn_restore_backup`, which refuses a hash mismatch; the binary is
      installed with `tn_install_root_binary` and hashed before start; source builds pick
      their cargo features from a known network only. edit-config writes the BLS passphrase
      root-only. Gates: suite green at merge.
- [x] Release signing and updater. `update-scripts.sh` installs only from a `MANIFEST` signed
      with `ssh-keygen -Y` and published under a `scripts-v*` tag: serial check, `min_updater`,
      all-or-nothing staging. `install.sh` is pinned to a release tag. New
      `tools/release-scripts.sh` and `lib/allowed_signers`. CI gained pinned actions,
      per-job permissions, the fixture suites (Linux and macOS), the hardening lints, a
      manifest check, the VM assertions in `integration.yml` and an installer publish from
      `scripts-v*` tags; CODEOWNERS added. Gates: after its fix pass `updater_manifest_test.sh`
      89 checks and `install_test.sh` 47, all green in the three environments.
- [x] Node Manager UI. Per-install token, Host and Origin checks, POST with JSON only, body
      cap, rate limit, security headers, an audit log and redacted streams; every helper
      argument checked against a pattern and secrets passed on stdin; install-ui builds a
      root-owned venv from hashed requirements and checks sudoers with `visudo`. Gates: pytest
      178, `helper_test.sh` 302 under both bashes, `open_ui_test.sh` 8.
- [x] Lock and root-owned layout. The update lock moved to `/run/telcoin/update.lock`;
      `create_directories` stopped using `chown -R`; `/etc/telcoin`, `.node-meta`, the start
      scripts and the binary are root-owned and the data directory belongs to the service
      account; `tn_migrate_ownership` converts an existing host under the lock. setup-node
      takes `--passphrase-stdin` and runs the keytool as the service account; prepare-stake
      and migrate-node-naming take the lock and wait for the epoch window; check-node reports
      a cleartext key, the lock state and the ownership table. Gates at merge: bash 5
      740/0/32, bash 3.2 772/0/25, Ubuntu as root 946/0/5.
- [x] Add-ons. firewall-setup checks its inputs first, saves and restores the ufw rules on any
      failure, takes `--ssh-from` and `--p2p-from` source lists and hardens sshd through a
      drop-in; setup-vpn reads maintainer keys from a `KEYS` file with a revocation list and
      runs a root-owned self-heal; install-caddy moved the Caddy admin API to a unix socket,
      pins the Caddy apt key and takes the dashboard password on stdin; observability runs
      Alloy as its own account, pins the Grafana apt key and pushes only on testnet. Gates at
      merge: bash 5 1139/0/32, bash 3.2 1171/0/25, Ubuntu as root 1345/0/5 (24 test files).
- [x] Unit and start-script generator. `tn_write_node_env`, `tn_write_start_script`,
      `tn_write_node_unit` and `tn_rerender_node_launch` render `node.env`, the start script
      under `/usr/local/libexec/telcoin/` and a sandboxed unit (`systemd-analyze security`
      1.4 for the binary unit); the start script feeds the passphrase on stdin; Docker
      containers run read-only with all capabilities dropped; `tn_committee_down_guard` and
      `--allow-quorum-risk` guard every restart; edit-config keeps the listeners in
      `node.env` and no longer edits values with perl or sed; journald gets a size cap.
      Gates: 31 test files green under bash 5, helper 302/0.
- [x] Credential migration. The passphrase is stored as a `systemd-creds` credential
      (`host+tpm2` when a TPM is present, else `host`); the TPM unseal method is gone;
      `edit-config.sh --migrate-credential` and `--reseal` convert and reseal; the testnet
      genesis, committee and parameters files are pinned by hash; mainnet needs systemd 255;
      remove-node shreds secrets and removes every host file the node left. Gates at merge:
      bash 5 1838/0/33, bash 3.2 1881/0/28, Ubuntu as root 2017/0/8, helper 327/0, perl lint
      clean over 77 files.
- [x] Release installs and Docker digests. `--install-method release` downloads a node
      release and checks `SHA256SUMS.asc` with `gpgv` against the keys in `lib/release-keys/`;
      source builds take release tags only and build as the `tn-build` account with a pinned
      rustup; Docker comes from Docker's apt repository after a fingerprint check, with
      live-restore; images run by digest; downgrades are refused; update-node checks after an
      update that the node is voting again. check-node gained `--audit`. Gates: 51 test files
      green in all three environments, perl lint clean.
- [x] Fix passes, one per package after its verifier. Lock file 0600, symlink-chain check for
      the binary, in-flight temp file cleanup, a required-helper check in every root script,
      signal handling in setup-node and firewall-setup, guard-then-wait ordering in the
      add-ons, a release updater that runs from the verified staging directory, safer
      shredding in remove-node and resumable removal, migration of inline-binary legacy
      units, and the UI fixes. Gates after each merge: 42, 43, 46, then 51 test files green;
      helper 327/0; UI pytest 189, `install_ui_test.sh` 13, `open_ui_test.sh` 9.
- [x] Docs. README, OPERATOR.md, the partner guide and its PDF, AGENTS.md, CHANGELOG.md with
      `CHANGELOG/scripts-v2.0.0.md`, `docs/testnet-addons.md`, WGVPN.md, followup.md and these
      task files, all checked against the code on the branch. Gates: partner PDF build, link
      check, old-term grep with every remaining hit intentional.

## telcoin-network branches

- [x] Credential passphrase source (`credential-passphrase-source`): `--bls-passphrase-source
      credential` with `--bls-passphrase-credential <NAME>`, a zeroized passphrase, the
      environment value scrubbed after reading, and `node --bootstrap-peers-file`. 238 tests,
      fmt and clippy clean, attested and pushed. The draft PR is not open yet.
- [x] Chain 487 guard (`mainnet-chain-guard`): chain id constants, faucet refused on chain 487
      without `--allow-faucet-on-chain-487`, build features in `--version` and in the startup
      line, a cleartext BLS key refused on chain 487 without `--allow-cleartext-bls-key`. 523
      and 122 tests, clippy clean with both feature sets, attested and pushed. The draft PR is
      not open yet.
- [x] Release pipeline (`releases-infra`, PR #694, draft): `SHA256SUMS` lists `IMAGE_DIGEST`,
      the tarball and the three chain-config files; mainnet tags refuse any build feature;
      Dockerfile base images pinned by digest; release docs describe how the scripts verify.
      Attested and pushed.

## Merge order

Primitives, update-node rollback, release signing and updater, Node Manager UI, lock and
root-owned layout, add-ons, unit and start-script generator, UI fix pass, credential
migration, updater fix pass, layout fix pass, generator fix pass, add-ons fix pass, release
installs and Docker digests, credential fix pass (417fbe2), docs, release prep.

## Release prep

- [ ] Set the versions: every changed script 2.0.0, `COMMON_VERSION` 2.0.0, `FALLBACK_VERSION`
      1.1.0, `UI_VERSION` 2.0.0, `HELPER_API` and `HELPER_API_REQUIRED` 3,
      `OBSERVABILITY_VERSION` 2.0.0, `TESTNET_ADDONS_VERSION` 1.1.0.
- [ ] Add the new tracked files to the updater arrays (`lib/allowed_signers`,
      `lib/release-keys/*.asc`, `lib/wgvpn/peers/ssh/KEYS`) and run `tools/gen-checksums.sh`.
- [ ] Dry-run `tools/release-scripts.sh`, sign `MANIFEST`, and push the `scripts-v2.0.0` tag
      right after the release merges.
- [ ] Review the whole range and open the PR.
