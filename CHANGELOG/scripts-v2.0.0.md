# scripts-v2.0.0 (October 2026)

`scripts-v2.0.0` is the first tagged and signed release of the node scripts, and the one that
prepares them for mainnet. After it, root owns everything the node runs from and the service
account owns only the data dir. The BLS passphrase lives in an encrypted systemd credential and
reaches the node on stdin. Script updates install only from a signed manifest, node releases are
checked against GPG signatures before anything runs, and Docker images run by digest. Every stop
or restart of a committee node first checks that the rest of the committee can carry consensus
without it.

Existing testnet installs move to the new layout in place, in the order given under
[Before you update](#before-you-update). A mainnet host on the old layout is not migrated: it
is installed fresh from a verified `scripts-v*` tag and a verified node release on Ubuntu
24.04.

| Component | Version |
|---|---|
| update-scripts | 2.0.0 |
| setup-node, update-node, edit-config, check-node | 2.0.0 |
| install-caddy, firewall-setup, setup-vpn, setup-observability | 2.0.0 |
| remove-node, migrate-node-naming, prepare-stake | 2.0.0 |
| lib/common (`COMMON_VERSION`) | 2.0.0 |
| lib/fallback (`FALLBACK_VERSION`) | 1.1.0 |
| lib/observability (`OBSERVABILITY_VERSION`) | 2.0.0 |
| testnet add-ons (`TESTNET_ADDONS_VERSION`) | 1.1.0 |
| telcoin-ui (`UI_VERSION`) | 2.0.0, `HELPER_API` 3 |
| install-ui | 2.0.0 |

## What changed

### File layout (all scripts)

A host set up or migrated by this release records `OWNERSHIP_LAYOUT=2` in `.node-meta` and
has this layout:

| Path | Owner and mode |
|---|---|
| `/opt/telcoin`, `/etc/telcoin` | root, 0755; files in them root-owned |
| `/etc/telcoin/.node-meta` | root, 0600 |
| `/etc/telcoin/node.env` (only `PRIMARY_LISTENER_MULTIADDR`, `WORKER_LISTENER_MULTIADDR`, `TN_RPC_ADDR`) | root, 0644 |
| `/etc/telcoin/bls-passphrase.cred` | root, 0600 |
| `/usr/local/libexec/telcoin/tn-start` and `tn-start-docker` | root, 0755 |
| node binary | root-owned, in root-owned directories |
| `/var/lib/telcoin` (data dir) | service account, 0700 |
| `/var/log/telcoin` | root:telcoin-log, 0750; log files 0640 |
| `/var/log/telcoin/node` (`NODE_LOG_DIR`, logs the node writes itself) | service account:telcoin-log, 2750 (setgid) |
| `/var/backups/telcoin` | root, 0700 |
| `/var/lib/telcoin-staging` | root, 0700 |
| `/run/telcoin/update.lock` | directory root 0755, file root 0600 |
| `tn-build` (source builds), home `/var/lib/tn-build` | system account, no login shell |

The start script moved from `/opt/telcoin` to `/usr/local/libexec/telcoin/tn-start`
(`tn-start-docker` for Docker installs). The node's flags stay on its `exec` line. Backups are
root-only copies with a recorded sha256 under `/var/backups/telcoin` instead of copies beside
the file; a restore whose hash does not match is refused. The update lock moved to
`/run/telcoin/update.lock`. The scripts write root-owned files through a temp file and a
rename, never through a path the service account can change, and refuse a target whose parent
directory is not root's.

### setup-node 2.0.0

Install layout and accounts:

- Lays out the host as in the table above and records `OWNERSHIP_LAYOUT=2`; the data dir is
  created by and for the service account, and a data dir under `/home` is refused.
- No longer forces the service account to UID 1101. An existing account with that UID is
  accepted only with a nologin or false shell and no admin group.
- Takes the update lock, and on a host laid out by an older release runs the ownership
  migration before its first write.
- Copies the chain configs as the service account, so they must be readable by it, after
  checking them against the pinned sha256 of the network's files (testnet pins come from
  `v0.16.0-adiri`; mainnet has no pins yet and is refused).
- Writes needrestart and apt drop-ins so an unattended package upgrade does not restart the
  node or reboot the host.
- Refuses a mainnet install while the testnet add-ons (VPN, observability or Caddy) are on the
  host; remove them first.
- Refuses to start when `lib/common.sh` is older than the script, with one message that names
  `update-scripts.sh`.

How the node binary is obtained:

- New `--install-method release` downloads a signed release: `SHA256SUMS` and
  `SHA256SUMS.asc` are checked with `gpgv` against the keys in `lib/release-keys/`, then the
  tarball, `IMAGE_DIGEST` and the three chain-config hashes, and the binary's `--version` is
  checked as the `tn-build` account before root installs it. Release tarballs are published
  for x86_64 only.
- New `--release-tag` names the release (`vX.Y.Z-adiri` on testnet, `vX.Y.Z` on mainnet);
  `--build-ref` is the older name for it, and the two must agree when both are given.
  Branches, commits and `latest` are refused. Testnet also takes a release candidate,
  `vX.Y.Z-adiri-rcN`, when it is named: with `--release-tag`, by its image digest with
  `--docker-image`, or as a tag typed at a prompt. No default picks one (taking one only when
  named is the conservative reading of "release candidates are accepted on testnet"). Mainnet
  takes finals only.
- Source builds take release tags only and run as the `tn-build` account with its own Rust
  toolchain (rustup-init 1.29.1, pinned by sha256; Rust 1.94); root only installs the result.
  A tag with a bad signature is refused; on mainnet the tag must be signed by a release key,
  and on testnet an unsigned tag builds with a warning. The build log goes to
  `/var/lib/telcoin-staging`. A devnet source build is refused.
- Each build command runs as `tn-build` with no inherited file descriptors, and every process
  of that account is stopped before root copies the output; `--version` runs as `tn-build` on
  a fresh copy.
- Release, rustup, tag and binary staging directories are named by the run's PID. A run
  removes its own at exit, also after a signal, and the next run that takes the update lock
  removes those of runs that died.
- New `--allow-dirty` (testnet, interactive only) discards local changes in
  `/opt/telcoin-source` instead of stopping.
- Docker comes from Docker's own apt repository after its signing key's fingerprint is checked
  (no `get.docker.com`), and setup merges `"live-restore": true` into
  `/etc/docker/daemon.json` (with python3 or jq; without either it stops and prints the manual
  step). An empty file counts as `{}`, a file that is not exactly one JSON object stops setup,
  and setup says live-restore is on only after reading it back.
- The Docker image is pulled and run by digest. `--docker-image` must be
  `<repository>@sha256:<digest>`, and a release tag resolves to its digest. Setup checks the
  digest of the pulled image. `.node-meta` records `DOCKER_IMAGE_DIGEST` and `RELEASE_TAG`.
- Images come from `ghcr.io/telcoin-association/telcoin-network`, where the release pipeline
  publishes them, on testnet and mainnet; testnet also takes the legacy Artifact Registry
  repository `us-docker.pkg.dev/telcoin-network/tn-public/adiri`, which holds `v0.16.0-adiri`
  and older (`TN_TESTNET_IMAGE_REPOS`). Without an image flag (or on Enter) setup takes the
  newest final release on GitHub by the digest its signed `IMAGE_DIGEST` names. On testnet
  only, while the network has no release on GitHub (`v0.17.0-adiri` will be the first) or the
  Releases API cannot be read, it falls back, with a warning, to the legacy repository's newest
  final tag by its registry digest, then to `DEFAULT_DOCKER_IMAGE`.
- A mainnet Docker install is refused before anything on the host changes until a mainnet
  release can be verified (no mainnet chain-config pins yet), devnet has no image repository,
  and an interactive run refuses `--docker-image` together with `--release-tag`.

BLS passphrase:

- The passphrase leaves setup's environment on the script's first line, so no command setup
  runs inherits it.
- New `--passphrase-stdin` reads it from standard input (one line, no echo); giving it there
  and in `TN_BLS_PASSPHRASE` is an error.
- An empty passphrase is refused on every network, as are line breaks and leading or trailing
  whitespace; mainnet needs at least 16 bytes. The interactive prompt asks again until the
  value is valid.
- Key generation runs as the service account and must leave `node-keys/bls.kw` and no
  cleartext `bls.key`.
- With systemd 250 or later the passphrase is stored only as the encrypted credential
  `/etc/telcoin/bls-passphrase.cred` (`systemd-creds`, key `host+tpm2` when the host has a
  usable TPM2, else `host`), and the unit loads it with `LoadCredentialEncrypted=`. Below
  systemd 250, on testnet and devnet only, it stays in the root-only file
  `/etc/telcoin/bls-passphrase`. `--passphrase-method credential|stdin` forces one of the two.
- Either way the start script feeds it to the node on stdin (`--bls-passphrase-source
  stdin`). It is never on a command line or in a unit `Environment=`.
- On mainnet: credential only, systemd 255 (Ubuntu 24.04) or later, and a host without a TPM2
  needs `--allow-no-tpm`. New `--bind-pcrs <list>` also binds the credential to TPM PCRs.
- The old TPM-unseal method is gone: `--passphrase-method tpm` is refused.
- New `--audit` prints a summary of the host's hardening (disk encryption, core dumps, ptrace
  scope, passphrase storage) and exits.

Unit, start script and logs:

- The unit of a binary install runs the node with no capabilities (`CapabilityBoundingSet=`),
  `ProtectHome=yes`, `PrivateDevices=yes`, `MemoryDenyWriteExecute=yes`, a system-call filter,
  no core dumps and `UnsetEnvironment=TN_BLS_PASSPHRASE`, and the node can no longer write
  the log dir.
- The Docker start script runs the container with every capability dropped,
  `no-new-privileges`, a read-only root file system, 4096 pids, a memory cap (90% of RAM, or
  `TN_DOCKER_MEMORY`), a capped json-file log, `--pull=never` and no config-dir mount.
- New `--log-target journal|file`. Mainnet defaults to the journal, capped by a journald
  drop-in (`SystemMaxUse=4G`, `SystemKeepFree=2G`); elsewhere the default stays the two files
  in `/var/log/telcoin`.
- A node set up with public RPC (`--rpc-domain`) gets RPC limits on its launch line:
  `--rpc.max-blocks-per-filter 10000`, `--rpc.max-logs-per-response 10000`,
  `--rpc.max-subscriptions-per-connection 100`, `--rpc.max-request-size 2` and
  `--http.api eth,net,web3,tn`. Setup checks the release knows each flag, and passes `--yes`
  to install-caddy's public RPC step (`--rpc-domain` is the consent).
- A re-run over a running node restarts it after the epoch wait and the committee check. New
  `--allow-quorum-risk` overrides the committee check for a coordinated restart.

`--json` mode (the Node Manager UI):

- Accepts `--network mainnet` (the interactive menu still offers testnet only).
- Keygen and finalize refuse when the node unit already exists.
- Finalize refuses an empty or malformed listener multiaddr, and flags that differ from what
  keygen recorded (install method, data dir, image, binary path).
- TERM, INT and HUP end the run with 143, 130 and 129, and the final `done` names the signal;
  a TERM during apt or cargo takes effect when that command returns.

### update-node 2.0.0

- Takes release tags only: `vX.Y.Z-adiri` on testnet, or a release candidate
  `vX.Y.Z-adiri-rcN` that is named (`--ref`, a typed tag); `vX.Y.Z` on mainnet. Branches,
  commits and `latest` are refused, and so is a source tag whose signature is bad or that moved
  on origin; on mainnet the tag must be signed by a release key.
- Source updates build as `tn-build` and stage the binary root-only; release installs
  download and verify the signed release; Docker installs pull the network's release image by
  digest and check the digest after the pull. The staged binary is removed after apply,
  rollback or discard.
- The source picker offers release tags only, its default the newest final. A release install's
  prompt defaults to the newest final release on GitHub. The Docker tag menu lists the final
  tags of the network's repositories (ghcr.io and, on testnet, the legacy repository); a
  release candidate is taken as a custom tag. A Docker image given by digest alone takes its
  release tag from `.node-meta` when the recorded digest matches; when the running release is
  not recorded, the downgrade check warns that it cannot tell and goes on.
- A changed binary between prepare and apply is a refusal, not a question.
- Downgrades are refused (`"downgrade":true` in the `--json` done, plus `"storage_downgrade"`).
  Releases order rc1 < rc2 < the final of the same version < any rc of a higher version, so a
  final over its rc and rc2 over rc1 are upgrades and an rc over its final is a downgrade.
  New `--allow-downgrade` (testnet, interactive only) allows one. New `--allow-dirty` works as
  in setup-node.
- `--check` adds `"tag_moved"`, and `current_ref` is the running release. `latest_ref` is the
  newest final release, never a release candidate: from GitHub for release and Docker installs
  (on testnet, while the network has no release there or GitHub cannot be read, a Docker
  install takes the registries' newest final tag), from origin's tags for source installs. `update_available` is true only when `latest_ref` is newer than the running release in release order (a node on a release candidate is not offered the older final). Docker installs take the running release from the recorded release tag of the running digest (a digest equal to the newest release's is that release); a digest whose release tag is not known reports `"tag_unknown":true`, never an update.
- After the restart, apply checks that the node is on its network's chain, that its consensus
  header advances, and that a node that was voting before the update votes again within
  `TN_UPDATE_VOTE_TIMEOUT` seconds (default 600; `TN_UPDATE_VOTE_POLL` 10). A failure rolls
  back, except on a one-way update; the `--json` done carries `"voting":false`.
- Apply re-renders the start script, `node.env` and the unit from `.node-meta` while the node
  is stopped, so hand edits outside the node line are not kept. On an observability host it
  moves `--log.file.directory` to `/var/log/telcoin/node`.
- An image swap renders the start script again instead of editing it, and backs up the unit
  and `node.env` with it.
- Before the stop, the committee check runs inside the epoch wait; `--allow-quorum-risk`
  overrides it.
- The pending update and backups are root 0600 and read as data; a duplicated or malformed key
  refuses the whole pending update. Every rollback checks the backup's recorded hash.
- The first root run on a host laid out by an older release runs the ownership migration
  under the update lock.
- A unit that still holds the BLS passphrase, runs the node command inline, or uses the old
  TPM method is refused with the `edit-config.sh --migrate-credential` hint.
- An `existing` install is still refused; the message now prints the `gpgv` and `sha256sum`
  commands that check a downloaded release by hand.
- When a run ends with the node stopped, it says so and prints how to start it; it never
  starts the node by itself. A duplicated `RPC_PORT` stops the run instead of falling back to
  8545.

### edit-config 2.0.0

- On mainnet the Docker image item is refused until a mainnet release can be verified (`No
  mainnet release can be verified yet ...`); on testnet it takes a release candidate tag too.
- New `--migrate-credential` moves the passphrase into the encrypted credential and shreds the
  old copies. It also moves a unit that holds the passphrase, runs docker inline or runs the
  node binary inline, and a TPM-sealed install, to the current start script and unit. When
  no stored copy can be read (a TPM-sealed install, for example) it asks for the passphrase.
  On a testnet host below systemd 250, a unit that holds the passphrase moves to the root-only
  file instead.
- A node in one of those legacy states refuses every other edit until `--migrate-credential`
  has run.
- New `--reseal` encrypts the credential again for the host's current TPM and PCR state, and
  asks for the passphrase when the credential no longer decrypts. `--allow-no-tpm` and
  `--bind-pcrs <list>|none` go with either flag.
- Changing the passphrase goes through the credential path. `--no-epoch-wait` covers
  passphrase moves too.
- Listener multiaddrs live in `node.env`. An install from before this release is moved to the
  current start script, unit and `node.env` (all backed up) before an edit that needs them. A
  `--set` listener must keep the UDP port the node advertises.
- Verbosity is changed by rendering the start script again, and RPC bind and metrics through
  the launch-line editor; no value reaches perl or sed any more. A rewrite of the whole start
  script drops hand edits outside the node line.
- The RPC menu offers private (127.0.0.1) or public (0.0.0.0, which also adds the public RPC
  limits); public is refused on mainnet, where public RPC goes through install-caddy.sh. The
  "disabled" option is gone.
- Metrics bind to 127.0.0.1 only; a root operator outside `--json` can pass
  `--allow-public-metrics`. `--json` caps verbosity at `-vvv`.
- The Docker image is given as a release tag (resolved to its digest) or as
  `<repository>@sha256:<digest>` of the network's repository; `latest` and other repositories
  are refused, and the digest is checked after the pull.
- Every restart and stop runs the committee check; `--allow-quorum-risk` overrides it. A
  refused restart puts a menu edit back.
- Refresh chain configs checks the pinned hashes and never pulls on mainnet.
- On a mainnet host with the old layout every edit is refused ("must be installed fresh").

### check-node 2.0.0

New checks:

- the BLS key on disk: a failure for `bls.key` without `bls.kw`, a warning when both exist;
- the update lock: its directory, owner, mode 0600 and holder;
- the ownership layout: the old layout warns on testnet and fails on mainnet; layout 2 is
  checked against the owner and mode table, and any non-root entry in the install, config or
  libexec trees is listed;
- how the passphrase reaches the node, read from the unit and the start script: a failure
  when the unit's environment, an `EnvironmentFile=` or the start script carries it;
- the unit sandbox, the Docker container hardening and the unit's exposure score;
- on mainnet, a failure when the testnet health monitor is on.

New `--audit` audits only the host's node security settings (systemd floor, passphrase
delivery, credential, unit) and exits 1 on any warning. A duplicated `.node-meta` key reads
as unknown, with a warning, and an older library makes check-node say once which checks it
skipped.

### update-scripts 2.0.0 and install.sh

- update-scripts reads `RELEASE` on main (tag and date) and fetches `MANIFEST` and
  `MANIFEST.sig` from that `scripts-v*` tag. It verifies them with
  `ssh-keygen -Y verify -f lib/allowed_signers -I release@telcoin.org -n tn-node-scripts`.
- It refuses a malformed manifest, a lower serial than the installed one, and the same serial
  with different content.
- When the manifest's `min_updater` is newer than the running updater, it prints the installer
  one-liner and changes nothing.
- It stages every changed file and checks it (manifest hash, the `.sha256` sidecar when one is
  published, `bash -n`) before installing anything, then installs all of it or none and
  removes files the release no longer ships. A sidecar that is not a hash is refused.
- A release that ships a new updater runs that verified copy from the staging directory, and
  it installs everything, itself included, in one pass.
- The installed release is recorded in `$SCRIPT_DIR/MANIFEST` and `MANIFEST.sig`.
- The updater no longer redeploys the Node Manager UI by itself: when UI files changed it
  prints `sudo bash ui/install-ui.sh --update` for you to run.
- It takes no options besides `--help`; unknown arguments exit 2. It takes no lock.
- install.sh is pinned to one tag and carries the signer list inside it. It verifies
  `MANIFEST.sig` and every file before it moves an existing install aside
  (`~/.telcoin-node-scripts.old.<ts>.*`, put back on failure). The copy on main names no
  release and refuses to run, so the old raw `.../main/install.sh` fallback is gone. Install
  with `curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash`
  (`| bash -s -- --yes` to overwrite without the prompt).
- A host on update-scripts 1.1.72 or older takes update-scripts 2.0.0 once through the old
  sidecar channel; see [Before you update](#before-you-update).

### install-caddy 2.0.0

- Caddy's apt key is pinned by fingerprint; any other key stops the install before apt-get
  runs.
- The admin API listens on a unix socket (`/run/caddy/admin.sock`, 0600) through the drop-in
  `/etc/systemd/system/caddy.service.d/tn-admin.conf`; the first apply after the switch
  restarts Caddy.
- `/etc/caddy/Caddyfile` is root:caddy 0640. `Caddyfile.bak.<ts>` (the newest 5 kept) and
  `Caddyfile.tn-orig` are root 0600.
- The dashboard password must be at least 16 characters. New `--password-stdin` reads it from
  one line of stdin. `TN_CADDY_PASSWORD` is still read and unset at once, and giving both is an
  error; the interactive run offers to generate one.
- The dashboard site sends security headers (HSTS, `nosniff`, `X-Frame-Options DENY`,
  `Referrer-Policy no-referrer`, no `Server`) and caps request bodies at 64 KB. An older
  dashboard gets them when it is enabled again.
- The dashboard and public RPC are refused on a mainnet node that is a staked validator, whose
  stake cannot be read, or that has no `VALIDATOR_ADDRESS` in `.node-meta`. Caddy is refused
  when the node's network cannot be told.
- rpc-enable shows an exposure summary: the terminal asks, `--json` sends it as a `warn` event
  and takes the UI action as the consent, and anything else needs `--yes`.
- Proxy ports come from the launch file, then `.node-meta`, then 8545/8546; ports outside
  1024-65535, 8080 and duplicated keys are refused.
- Node edits (`node-info.yaml`, the `--ws` flag) run as the service account through a temp
  file and a rename.
- Each node restart runs the committee check, then the epoch wait, right before the restart.
  A refusal or a signal puts `node-info.yaml` and the `--ws` edit back. rpc-disable goes
  through the same check.
- Stops with "run update-scripts.sh" on an older library.

### firewall-setup 2.0.0

- Every input is checked before any rule changes. The ufw rule files are saved first, allows
  go in before the default deny, and the firewall is enabled last.
- A failed step or a TERM, INT or HUP puts the saved rules back. Exit status: 0 done, 1
  refused with nothing changed, 2 a step failed and the old rules are back, 3 the restore
  failed (the message names the saved files). The `--json` done carries `rc` and `active`.
- New `--ssh-from CIDR[,CIDR]|FILE` and `--p2p-from CIDR[,CIDR]|FILE` limit SSH and P2P to
  those sources, stored as `SSH_ALLOW_FROM` and `P2P_ALLOW_FROM`. `--ssh-anywhere` and
  `--p2p-anywhere` drop a stored list.
- On a Google Cloud VM the IAP range is added to the SSH sources, and on a testnet VPN host
  the maintainer overlay range.
- On mainnet, enabling needs an SSH source list or `--ssh-anywhere`.
- Sources with leading-zero octets or masks shorter than /8 are refused. A replaced list
  removes the old sources' rules.
- The health-port and overlay-SSH rules are testnet and devnet only, and are deleted
  elsewhere; a delete that fails off testnet is a failed step. The health port is never open
  to everyone.
- SSH hardening goes into the drop-in `/etc/ssh/sshd_config.d/00-telcoin-hardening.conf`
  (password and keyboard-interactive logins off, root login off), with a warning when
  `sshd_config` has no `Include` for it.
- P2P ports are also read from `/etc/telcoin/node.env`. `--enable` works without `--json`.
- Stops on an older library before any change.

### setup-vpn 2.0.0 (testnet add-on)

- Maintainer keys come from `lib/wgvpn/peers/ssh/KEYS`: one `<name> SHA256:<fingerprint>`
  line per maintainer. Only the listed `<name>.pub` files are read, and each must hold exactly
  that key.
- `# revoked: <fingerprint> <name> <date>` lines take a key away at the next `--sync-keys` or
  self-heal after update-scripts. A local deny list goes in `/etc/wgvpn/tnadmin.revoked`.
- Keys live in `/etc/wgvpn/tnadmin.keys` and `/etc/wgvpn/tnadmin.authorized_keys` (0644);
  `~tnadmin/.ssh/authorized_keys.tnvpn` is retired.
- The sshd drop-in admits `tnadmin` only from the maintainer overlay range
  (`TN_OVERLAY_ADMIN_CIDR`, `Match Address` and `AllowUsers tnadmin`).
- `tnadmin` gets a fixed list of recovery commands through sudo (status, start, stop and
  restart of the node unit, its journal, and check-node.sh when the scripts tree is
  root-owned), written to `/etc/sudoers.d/90-tnadmin` and checked with `visudo`. Full root
  needs `--grant-maintainer-root`, and `--revoke-maintainer-root` takes it back (recorded as
  `VPN_MAINTAINER_ROOT`). Existing hosts lose `NOPASSWD:ALL` at the next sync or self-heal.
- Self-heal runs from the root-owned helper `/usr/local/sbin/tn-vpn-selfheal`, which removes
  its units and itself off testnet and devnet.
- `--status` and `--disable` work on any network (`--status` takes no lock; `--disable`
  tears down on an old layout too); enable, `--sync-keys` and `--apply-firewall` are testnet
  only. Enable refuses a symlinked `~tnadmin`, `.ssh` or key file.

### setup-observability 2.0.0 and lib/observability 2.0.0 (testnet add-on)

- Push URLs are empty off testnet and devnet, even with an override.
- Native Alloy runs as its own `telcoin-alloy` account (log access through the `telcoin-log`
  group) in a sandbox that cannot see `/var/lib/telcoin`, the data dir or the passphrase
  files. `config.alloy` is root:telcoin-alloy 0640.
- An Alloy tarball install needs a matching `SHA256SUMS` line. The Grafana apt key is pinned
  by fingerprint.
- The node's JSON logs go to `/var/log/telcoin/node/telcoin-network-logs/` (`NODE_LOG_DIR`,
  setgid group `telcoin-log`; the unit joins that group with `UMask=0027`), and enabling, the
  ownership move and update-node move an older `--log.file.directory` there.
- The health check is refused while ufw is missing or inactive.
- New `--token-stdin` reads the ingest token from one line of stdin; `--token` still works
  and warns that the token shows on the command line.
- The menu session holds the update lock, and writes run the ownership migration first.
- Each node restart runs the committee check, then the epoch wait; `TN_ALLOW_QUORUM_RISK=1`
  overrides the check.
- Stops on an older library before any change. A duplicated `.node-meta` key stops the run
  instead of falling back to a default.

### remove-node 2.0.0

- Takes the update lock, and finishes a removal that stopped part way when it is run again.
- Shreds the credential, the plaintext passphrase file, unit and passphrase backups, and the
  node keys when the chain data goes. Key shredding runs as the service account before that
  account is removed; shred is best effort on SSDs and copy-on-write disks, and the run says
  so.
- Removes the files this release adds: the libexec start scripts, `node.env`, the backups
  directory, the logrotate file and the drop-ins setup wrote, `/var/lib/telcoin-staging`, the
  `tn-build` account with `/var/lib/tn-build`, and `/run/telcoin`.
- Asks before it removes the `telcoin-log` group when the service account is kept.
- Stops the `tn-build` account's processes before it removes the account, and reports a
  failed `userdel`.
- With the testnet add-ons, also removes the VPN self-heal units and helper, the tnadmin key
  files, the overlay SSH rules and the `telcoin-alloy` account.
- With the UI, also removes its venv, token and state directory, and keeps the UI audit log in
  `/var/log/telcoin-ui`.
- A duplicated `.node-meta` key stops the run.

### migrate-node-naming 2.0.0

- Holds the update lock from the confirmation to the end, and waits for the restart window
  right before it stops the legacy node.
- Runs the committee check before the stop; new `--allow-quorum-risk` overrides it.
- Writes the new unit and the start script `/usr/local/libexec/telcoin/tn-start[-docker]`
  (no longer under `/opt/telcoin`) through the library writers.
- Moves a passphrase the legacy unit holds into the credential and shreds the old copies;
  migrates units that run the node binary inline. A TPM-sealed install is refused until
  `edit-config.sh --migrate-credential` has run.
- Removes the legacy unit and wrapper only after the new unit is verified. A signal before
  that point rolls back; after it, the migration is kept.
- Backups are root-only copies in `/var/backups/telcoin`. A duplicated `DATA_DIR`, `RPC_PORT`,
  `INSTALL_METHOD` or `HOST_SERVICE_GROUP` stops the run.
- Moved entries keep their owners until the next update-node.sh or edit-config.sh run, which
  migrates the ownership.

### prepare-stake 2.0.0

- `--rotate-address` hands the BLS passphrase to the keytool on stdin, not through its
  environment.
- Uses the service account from `HOST_SERVICE_USER`/`HOST_SERVICE_GROUP`, and requires
  `node-info.yaml` to be a regular file that account owns; its backup and restore run as that
  account.
- `--rotate-address` takes the update lock after the passphrase and runs the ownership
  migration before it changes anything; on a mainnet host with the old layout it exits 3
  ("must be installed fresh").
- A duplicated `NETWORK`, `VALIDATOR_ADDRESS`, `HOST_SERVICE_*`, `DATA_DIR` or `RPC_PORT` exits
  1.
- It still never sends a transaction and never reads, asks for or prints a private key.

### lib/common 2.0.0 and lib/fallback 1.1.0

- The required-helper lists of setup-node, update-node and edit-config include the release
  helpers, so a script refuses to run against a library without them.
- New root-write primitives: write through a temp file and a rename, a backup with a recorded
  hash, a hash-checked restore, a root-owned binary install, and a service-account runner.
  Every script above writes through them.
- New `tn_migrate_ownership`: makes the install and config trees root-owned, the log dir
  root:telcoin-log, and moves the start script to libexec. It prints what it changed, stops on
  a symlink, a special file or an unexpected owner, and never restarts the node. It warns that
  the node binary was writable by the service account and should be reinstalled from a verified
  release.
- New writers render `node.env`, the start script and the unit from `.node-meta`.
- New committee check (`tn_committee_down_guard`): a stop is refused when the members already
  down plus this one would halt consensus. Down means no header in the latest consensus commit,
  so a slow member counts as down. When the count cannot be made, a mainnet node not known to
  be unstaked, or a node of an unknown network, is refused; testnet and devnet warn and go
  ahead.
- The restart window reads epoch timing from the public RPC, then the local RPC; when neither
  answers it warns and waits the margin plus settle time, capped by `TN_EPOCH_WAIT_MAX`.
- Release verification (`gpgv` against `lib/release-keys/*.asc`: a good signature by a shipped
  key is required; BADSIG by any key, EXPKEYSIG, REVKEYSIG and EXPSIG refuse; a further
  signature by a key not shipped yet warns with its key id), release-tag rules, the image-by-digest resolver, the `tn-build`
  account and its pinned rustup, and the chain-config pins
  (`TESTNET_CHAIN_CONFIGS_TAG="v0.16.0-adiri"`).
- The first release key ships: `lib/release-keys/grantkee.asc` (primary
  `4E36D35A4AB61B589861D01AC7173F2377CA7573`, expires 2028-10-16). update-scripts tracks it
  like the scripts, and the UI's engine copy takes it with `install-ui.sh --update`.
- Release tags: testnet `vX.Y.Z-adiri` and its release candidate `vX.Y.Z-adiri-rcN`, mainnet
  `vX.Y.Z`. `tn_release_tag_final` keeps release candidates out of every newest-release pick,
  and `tn_release_tag_key` orders tags by release (rc1 < rc2 < final < any rc of a higher
  version) where `sort -V` put an rc above its final. A release candidate's binary must report
  `Version: X.Y.Z`, without the suffix.
- Images: `ghcr.io/telcoin-association/telcoin-network` is the repository of testnet and
  mainnet, the legacy `us-docker.pkg.dev/telcoin-network/tn-public/adiri` stays in
  `TN_TESTNET_IMAGE_REPOS`, and calls to ghcr.io send its anonymous pull token (a ghcr.io
  that gives none, as for a package that is not public, counts as unreadable).
  `tn_release_newest_tag` reads the GitHub Releases API (drafts skipped, pre-releases counted
  on testnet only), and `latest_docker_image` takes that release's signed `IMAGE_DIGEST`. On
  testnet only, while there is no release or the API cannot be read, it falls back to the
  legacy repository's newest final tag and then `DEFAULT_DOCKER_IMAGE`, each with a warning.
  `tn_docker_network_ok` refuses a mainnet Docker install or image change while no mainnet
  release can be verified.
- `DEFAULT_DOCKER_IMAGE` is `v0.16.0-adiri` in digest form,
  `us-docker.pkg.dev/telcoin-network/tn-public/adiri@sha256:b905b0982e87d5ca608e2f29192d0c5582793ae0043630074cddb9be1162ffea`.
  It stays until the first signed testnet release.
- `.node-meta` reads refuse a duplicated key (rc 2) instead of taking the first line. lib/fallback
  applies the same rule to `DATA_DIR`, so no script acts on a guessed data dir.
- The node binary path is resolved one link at a time, each link root-owned in a root-only
  directory; an `existing` install that names a symlink is updated at the link's target.
- Submodule sync is https only and checks the recorded commit.

### Testnet add-ons 1.1.0

`lib/testnet-addons.env` adds `TN_OVERLAY_ADMIN_CIDR`, the maintainer overlay range that is the
only overlay source sshd admits. The bundle gains `lib/wgvpn/peers/ssh/KEYS`.

### Node Manager UI 2.0.0, install-ui 2.0.0 and open-ui.sh

- Every API call carries a per-install token, stored in `/etc/telcoin-ui/token`
  (root:telcoin-ui 0640) and replaced with `sudo bash ui/install-ui.sh --rotate-token`.
- open-ui.sh reads the token over SSH and opens `http://127.0.0.1:8080/#t=<token>`; the token
  travels in the URL fragment, which the browser does not send. The tunnel listens on
  127.0.0.1 only, and fails rather than open a browser when the port is taken.
- The server answers only on a local Host (421 otherwise) and same-origin requests (403).
  Writes are POST with JSON only (415), 401 without the token, and 405 for GET on a writing
  route.
- Request bodies are capped at 64 KiB (413), changes at 30 a minute (429), and live log
  streams at 8. Responses carry security headers.
- Log streams cut every spelling of a secret. Secrets reach the scripts on stdin only.
- The helper checks every argument against a pattern and writes each call, refused ones
  included, to the root-only `/var/log/telcoin-ui/audit.log`.
- New helper subcommands for `node.env`, the journal, the committee check, the logrotate
  seed, the credential (`credential migrate|reseal`), enabling the firewall with an SSH source
  list, and the host audit; `HELPER_API` and `HELPER_API_REQUIRED` are 3.
- The helper refuses an action when the engine library lacks a function it needs or an engine
  script lacks its stdin flag, and says to run update-scripts.sh. Its own copies of the
  library functions are gone. `config-set` applies the same listener-port rule as edit-config.
- The setup wizard refuses when a node unit or `.node-meta` exists and holds the dashboard
  password to 16 bytes. It installs a signed release, a source build of a release tag, or
  Docker; the tag field starts at the latest release tag, and the Docker field takes a release
  tag or a digest (`latest` refused). The Docker default is the library's newest-image pick
  (`latest_docker_image`), never a release candidate; images from both testnet repositories
  are accepted, and so is a release candidate tag typed on testnet. The mainnet defaults are
  the signed release and journal logging, and `--allow-no-tpm` is offered only when the host
  audit finds no TPM2. The Mainnet card stays disabled until the mainnet release. Public `/api/nodes` and `/api/system` drop
  operator-only fields.
- The Config tab moves the passphrase to the encrypted credential and re-seals it
  (`edit-config.sh --migrate-credential` / `--reseal`).
- The System tab shows the host audit (`check-node.sh --audit`) and, when the firewall is off,
  enables it with an SSH source list passed as `--ssh-from`; on mainnet an empty list is
  refused with firewall-setup's own message.
- Before public RPC is enabled, the page shows the exposure summary install-caddy prints.
- The update panel reports a refused downgrade, a node that is not voting after an update, and
  a release tag that moved.
- install-ui installs the app and a venv as root-owned trees (`/opt/telcoin-ui`,
  `/opt/telcoin-ui-venv`) from the hashed `ui/requirements.txt` (`--require-hashes`; flask
  3.1.3, werkzeug 3.1.9). It checks the sudoers file with `visudo`, and runs updates and setup
  in their own `systemd-run --scope`. It copies check-node.sh into the engine dir and keeps two
  more non-secret setup values across sudo (`TN_SETUP_LOG_TARGET`, `TN_SETUP_ALLOW_NO_TPM`);
  hosts that already run the UI re-run `install-ui.sh --update` for them.
- The UI unit gets `TasksMax=256`, `MemoryMax=512M` and `CPUQuota=50%`.
- install-ui reads the library only after checking the checkout: no symlinks, nothing writable
  by other users, owned by root or the operator. A `su -` root shell installs only from a
  root-owned checkout.

### Maintainer tools and CI

`tools/release-scripts.sh` prepares a release (`MANIFEST`, `RELEASE`, the signer block in
install.sh) and checks one with `--check`. CI adds fixture tests on Linux and macOS, a
hardening lint (no passphrase printed, no perl program that expands a shell variable), a
manifest check and VM assertions. Workflow actions are pinned and tokens scoped, and the
installer is published from a `scripts-v*` tag.

## Before you update

On an existing testnet install, in this order:

1. Run `update-scripts.sh` once. On a host on update-scripts 1.1.72 or older, the old updater
   takes update-scripts 2.0.0 through the old sidecar channel (hashes from main, unsigned) and
   relaunches it. The new updater fetches `lib/allowed_signers` once through its sidecar and
   installs the rest of the release from the signed manifest. From then on every update is a
   signed manifest.
2. The first root run of update-node.sh, edit-config.sh, install-caddy.sh or
   `prepare-stake.sh --rotate-address` takes the update lock and moves the host to the
   root-owned layout (`tn_migrate_ownership`); the add-on scripts do the same before their
   first `.node-meta` write. It prints what it changed and stops on a symlink or an
   unexpected owner. Review what it lists, fix it, and run again. It does not restart the
   node; the moved start script takes effect at the next restart. When it warns about the
   node binary, reinstall the binary from a verified release.
3. At a time you choose, run `sudo bash edit-config.sh --migrate-credential` (systemd 250 or
   later, Ubuntu 24.04). The restart waits for the epoch window. A unit that holds the
   passphrase, runs the node command inline or uses the old TPM method must take this step
   before any other edit or update. On a testnet host below systemd 250 (Ubuntu 22.04) the
   passphrase stays in the root-only file `/etc/telcoin/bls-passphrase` until the OS is
   upgraded.
4. On a host with the Node Manager UI, run the `sudo bash ui/install-ui.sh --update` that
   update-scripts prints, then reopen the UI with the new `open-ui.sh`. The old one opens
   without the token, and every API call is refused.
5. Docker hosts take the new start script and unit through update-node.sh: the next apply
   writes them.

A mainnet host on the old layout is refused by every script that writes ("must be installed
fresh"). Mainnet installs fresh from a verified `scripts-v*` tag and a verified node release,
on Ubuntu 24.04.

## Refusals you may now see

| Message (shortened) | What to do |
|---|---|
| `lib/common.sh ... is older than this <script>: run update-scripts.sh` | A partial update. Run `update-scripts.sh`. |
| `Release ... needs update-scripts.sh X or newer` | Reinstall with the installer one-liner it prints. |
| `Release ... is older than the installed release` / `reuses the installed serial` | Nothing was installed. The published release is older than yours or changed after signing; report it to support@telcoin.org. |
| `This copy of install.sh names no release` | Use `curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network \| bash`. |
| `... must be installed fresh; it is not migrated in place` | A mainnet host on the old layout. Install it fresh on Ubuntu 24.04. |
| `The ownership migration stopped` | Fix the paths it lists (symlinks, special files, other owners) and run again. |
| `... still holds the BLS passphrase` / `runs the node command inline` / `sealed with the old TPM method` | `sudo bash edit-config.sh --migrate-credential`, then repeat the edit or update. |
| `Not restarting` / `Not stopping ...: the committee check refused it` | Too many committee members are down. Wait, or coordinate and pass `--allow-quorum-risk` (`TN_ALLOW_QUORUM_RISK=1` for the add-ons). |
| `... is not a <network> release tag` | Give `vX.Y.Z-adiri` or a release candidate `vX.Y.Z-adiri-rcN` (testnet), or `vX.Y.Z` (mainnet, finals only); branches, commits and `latest` are refused. |
| `Release ... did not verify` / `No release signing key` | The signature or a hash failed, or `lib/release-keys/` holds no key for the release. Run `update-scripts.sh` to take the current keys; if it still fails, report it to support@telcoin.org. |
| `image refused ... by digest` | Give a release tag or `<repository>@sha256:<digest>` of the network's repository. |
| `No mainnet release can be verified yet` | Mainnet Docker installs and image changes wait for the mainnet chain-config pins (see Still open). |
| `The registry gave no digest for <tag> ...` | The registry could not be read or lacks the tag. ghcr.io wants an anonymous pull token even for a public package; a 401, 403 or 404 there counts as unreadable. Check that the host reaches `https://ghcr.io`; report a published release it refuses to support@telcoin.org. |
| `The chain configs ... do not match the ... pins` | The files differ from the pinned release, or mainnet pins are not set yet. |
| `--passphrase-method tpm is no longer offered` | Use `credential` (default) or `stdin`. |
| `No usable TPM2 on this host: on mainnet pass --allow-no-tpm` | Add `--allow-no-tpm` to accept the host key alone. |
| `systemd ... is below the mainnet floor (255)` | Mainnet needs Ubuntu 24.04. |
| `Testnet add-ons are present on this host` | Remove the VPN, observability and Caddy add-ons before a mainnet install. |
| `Mainnet: give the SSH sources with --ssh-from` | Pass `--ssh-from CIDR[,CIDR]` or `--ssh-anywhere`. |
| `downgrade` in an update | Testnet: `--allow-downgrade` in an interactive run. Mainnet: not offered. |
| `metrics bind to 127.0.0.1 only` | Root, outside `--json`: `--allow-public-metrics`. |
| `a mainnet node keeps its RPC on 127.0.0.1` | Serve public RPC through install-caddy.sh. |
| Dashboard or public RPC refused on a staked mainnet validator | A mainnet validator serves neither. |
| Dashboard password shorter than 16 characters | Use 16 or more (or let the interactive run generate one). |
| `... holds the update lock` | Another setup, update, edit or removal is running. Wait for it (its PID is printed) and try again. |

On testnet, until the first signed release, a Docker setup warns `No testnet release is
published on GitHub yet.` and takes the legacy repository's newest final image by its registry
digest (`Taking ..., the newest image of the legacy repository ...`). A host that cannot reach
`api.github.com` warns `Cannot read the telcoin-network releases from GitHub ...` and falls back
the same way on testnet; mainnet never falls back.

## Still open

- The mainnet genesis, committee and parameters hashes (`MAINNET_*_SHA256`) are empty, so no
  mainnet release can be verified (the mainnet image repository is set: ghcr.io, as for
  testnet): mainnet setup, mainnet release downloads and mainnet Docker installs and image
  changes are refused until they are set.
- The mainnet public RPC is set at launch.

`followup.md` lists the remaining work.
