# scripts-v2.1.0 (November 2026)

`scripts-v2.1.0` is the first signed release of the node scripts (serial 1). `scripts-v2.0.0`
was never tagged, so this release also carries everything in [scripts-v2.0.0](scripts-v2.0.0.md)
to a host that never took it. It carries the follow-ups to the mainnet hardening round. Script
releases are signed with OpenPGP by the release key that already signs node releases, checked
with `gpgv`; the SSH-signature scheme of the 2.0.0 work never signed a release and is retired.
Each network has its own Docker image package, and a pulled image's build features are checked
against the network before it runs. Mainnet stays
switched off: one constant in `lib/common.sh` now gates it, and the release that pins the mainnet
chain configs turns it on. Docker images on mainnet must come from a signed release, and every
install and update path applies the release floor. A restart waits for the epoch boundary with
margins that follow the epoch length. An opt-in host baseline adds auditd watches and an AIDE
database. The P2P ports get a per-source limit on new flows. The observability ingest token moves
out of Alloy's environment into a file. A script release now expires, and `update-scripts.sh
--check` reports it. Nothing read from a testnet endpoint is used on another network. New on
every network, `setup-alerts.sh` sends a heartbeat from the node host to a monitor you own.
setup-node and edit-config can set the node's connection admission mode, its trusted hubs and its committee launch inventory in `network-config`, for node releases that read them.
A validator can let only the peers its node lists reach its P2P ports (`firewall-setup.sh --p2p-committee on`), through the new `tn-p2p-allow-sync` tool this release pins.

It closes #47 and #60. #34, the documentation reconciliation, closed after scripts-v2.0.0 merged;
the nine wording findings a re-read found afterwards are fixed here. The other issues named below
stay open as trackers; the last section says what is left on each.

| Component | Version |
|---|---|
| update-scripts | 2.1.0 |
| setup-node, update-node, edit-config, check-node | 2.1.0 |
| install-caddy, firewall-setup, setup-vpn, setup-observability | 2.1.0 |
| setup-alerts | 2.1.0 (new) |
| remove-node | 2.1.0 |
| migrate-node-naming | 2.0.0 (its version string is unchanged; it gains the allowlist resync step, see [P2P committee allowlist](#p2p-committee-allowlist-41)) |
| prepare-stake | 2.0.0 (unchanged) |
| lib/common (`COMMON_VERSION`) | 2.1.0 |
| lib/fallback (`FALLBACK_VERSION`) | 1.1.0 (unchanged) |
| lib/observability (`OBSERVABILITY_VERSION`) | 2.1.0 (`observability/config.alloy` changed) |
| lib/alerts (`ALERTS_VERSION`) | 2.1.0 (new) |
| lib/tn-heartbeat (`HEARTBEAT_VERSION`) | 2.1.0 (new) |
| testnet add-ons (`TESTNET_ADDONS_VERSION`) | 1.1.0 (unchanged) |
| telcoin-ui (`UI_VERSION`) | 2.1.0, `HELPER_API` 3 |
| install-ui | 2.1.0 (a comment in the sudoers file it writes) |

`install.sh` changed too (OpenPGP verification with its embedded release keys, the expiry
warning); it is a release file, not an updater entry.

## What changed

### Mainnet switch, release floor and image digests (#45, #46, #51)

- `lib/common.sh` has `readonly TN_MAINNET_ENABLED=0`, and `tn_mainnet_enabled` returns 0 only
  when it is 1. While it is 0, option 2 of the interactive network menu still reads "(coming
  soon)" and loops with "Mainnet has not launched yet.", and `setup-node.sh --json --network
  mainnet` stops before the install flags, the root check or the lock: `Mainnet is not enabled in
  this script release (lib/common.sh TN_MAINNET_ENABLED); nothing on this host was changed.` The
  UI helper's `setup-keygen` and `setup-finalize` refuse mainnet the same way, also when the
  engine library is too old to have `tn_mainnet_enabled`. The release that pins the mainnet chain
  configs and sets `MIN_SOURCE_VERSION_MAINNET` flips the constant, `ui/server.py`'s
  `TN_MAINNET_ENABLED` and the page's `SETUP_MAINNET_ENABLED` together;
  `ui/test_mainnet_flag.py` fails when the three disagree.
- The release floor (`tn_ref_min_check`) now applies to update-node's prepare (source, release and
  Docker; interactive and `--json`) and to edit-config's Docker image change (menu and
  `--set docker_image=`), not only to setup. A target below the network's oldest supported release
  is refused before anything is fetched: `<ref> is older than v<floor>, the oldest <network>
  release these scripts support (...). Pick v<floor> or a newer release.`, followed by `Nothing was
  changed.` (update-node) or `The image is not changed.` (edit-config). The floors are 0.13.0 on
  testnet and none on mainnet until launch.
- On mainnet an image is named by its release tag and the digest comes from the signed release:
  only the release says which digest of the mainnet package is a release image. A digest given
  alone is taken only when `.node-meta` records it (`DOCKER_IMAGE_DIGEST`) as the image of a
  mainnet release tag this node has installed; otherwise: `Image refused: on mainnet an image is named by
  its release tag, so the digest comes from the signed release; sha256:<digest> is not the image
  of a mainnet release this node has installed. Give the mainnet release tag instead.` This holds
  for update-node, edit-config (menu and `--json`) and setup-node (`--docker-image` and the
  prompt), where the message ends `on mainnet give the release tag with --release-tag, so the
  image comes from the signed release. Nothing on this host was changed.` Testnet and devnet
  digests are taken as before.
- On mainnet, setup-node's image examples show
  `ghcr.io/telcoin-association/tn-mainnet@sha256:<digest>` instead of the testnet default image.

### Image packages per network and the image feature check (#46)

- Each network has its own image package, and the channel is a function of the release tag:
  mainnet `ghcr.io/telcoin-association/tn-mainnet` (`TN_MAINNET_IMAGE_REPO`, tags `vX.Y.Z`;
  release candidates are never offered or taken on mainnet), testnet
  `ghcr.io/telcoin-association/tn-testnet` (`TN_TESTNET_IMAGE_REPO`, tags `vX.Y.Z-adiri`).
  Every stage derives the package from the network again (`tn_docker_repo_for`). Testnet also
  takes the legacy Artifact Registry repository; devnet pulls by digest from that repository or
  from `ghcr.io/telcoin-association/tn-dev` (`TN_DEV_IMAGE_REPO`), where the node team's dev
  images go. The pipeline side is telcoin-network draft PR #1784, which publishes each channel
  to its package in `etc/release.sh`; the scheme was confirmed on 2026-11-04.
- The old single package `ghcr.io/telcoin-association/telcoin-network`
  (`TN_GHCR_LEGACY_IMAGE_REPO`) never held a release. On testnet and devnet it is recognised for
  a container that already runs from it (remove-node, the status screens); mainnet never accepts
  it, and every new pull refuses it on every network: `Image refused: <image>. No release was ever published to
  ghcr.io/telcoin-association/telcoin-network, so no image is pulled from it; <network> images
  come from <package>. Give the <network> release tag instead.`
- A signed release's `IMAGE_DIGEST` must name a repository a new pull for the network takes, and
  on mainnet exactly `tn-mainnet`: `Release <tag>: IMAGE_DIGEST names <image>, but a <network>
  release image is <repository>@sha256:<digest> from <package>. The release is refused and
  nothing was pulled; report it to the node team.`
- After the pull and the digest check, and before any container starts or `.node-meta` names
  the image, `tn_docker_image_network_ok` runs the image's `/usr/local/bin/telcoin --version`
  once (`docker run --rm --init --name tn-feature-check-<pid>-<n> --pull=never --network none
  --cap-drop ALL --security-opt no-new-privileges --read-only`, under `timeout -k 5 60` where
  coreutils `timeout` exists, as on Ubuntu, and with no limit elsewhere) and judges its one
  `Build Features:` line: none on mainnet, `adiri` on testnet (`faucet` allowed, nothing else).
  Devnet images are not checked (an info line says so). setup-node (interactive and `--json`),
  update-node's Docker prepare (interactive and `--json`) and edit-config's image change (menu
  and `--set`) stop on a refusal, and a `--json` run ends with an error event and `done`:
  `Image refused: <image> was built with the features <list>, and a <network> image has <none |
  adiri, and faucet at most>, so it is not a <network> image. It is not used and nothing was
  changed; if a <network> release names this image, report it to the node team.` A run cut
  short by the limit (rc 124 or 137) has its container removed with `docker rm -f <name>` and is
  refused: `Image refused: <image> did not finish --version within 60 seconds (docker run exited
  <rc> under timeout), so its build features are not known. ...`
- The storage migration floor is per network (update-node): `STORAGE_MIGRATION_FLOOR_TESTNET` is
  0.16.0, and mainnet and devnet have none, so an update there is never one-way and a downgrade
  there is never refused for the storage reason (`"storage_downgrade":false`). Before, every
  network had the 0.16.0 floor, so any mainnet `v0.1.x` image counted as below it.
- `setup-node --json --phase=finalize` holds the Docker image keygen recorded in `.node-meta` to
  the same pull rule and build-feature check as keygen's preflight, before the config, the unit
  or the container is written or started, and does not pull it: `Refusing the image <image>:
  ... No container was started; to replace it, run finalize again with ...`, naming the way out
  per network (mainnet `--release-tag <tag>`; testnet `--docker-image <repo>@sha256:<digest>` or
  `--release-tag <tag>`; devnet `--docker-image`). An image removed since keygen stops it with
  `Could not run <image> to read its build features ... Check that Docker is running and holds
  the image, then try again.`
- Finalize's `--release-tag <tag>`, or a `--docker-image` that names another image than the
  recorded one, replaces it (both flags together are refused; on mainnet only `--release-tag`
  works, since a digest alone is not taken there). Finalize runs every other input check first,
  then takes the image through keygen's steps (pull rule, release lookup and mainnet digest
  rule, release floor, pull by digest and digest check, build-feature check), and only then
  writes `.node-meta`: the old `RELEASE_TAG` removed, `DOCKER_IMAGE` and `DOCKER_IMAGE_DIGEST`,
  the new `RELEASE_TAG` last. A refusal leaves `.node-meta` unchanged, for example `Refusing the
  image of release <tag> given with --release-tag (see above). No container was started and
  .node-meta was not changed.`
- update-node and edit-config record a changed image in the same order (old `RELEASE_TAG`
  removed first, image and digest written, new tag last), so a failure half way never pairs a
  new digest with an old release tag.
- setup-node's interactive image prompt stops at the end of input with nothing typed instead of
  asking again: `The input ended at the Docker image prompt, so no usable image was given and
  the Docker install stops. Nothing was pulled and no container was started.` A last line typed
  without a newline still counts, and only Enter takes the default.
- The UI helper's `docker-detect` lists containers whose image comes from any repository the
  library recognises for testnet, mainnet or devnet, so a dev-team container from `tn-dev` shows
  in the Node Manager as remove-node's scan lists it; `docker-status` and `docker-logs` accept
  those names too.
- The UI twins follow: `ui/server.py` `DOCKER_REPO`, `docker_pull_repo_ok` and
  `pull_image_allowed`, and the wizard's Docker image field names the network's package;
  `ui/test_csrf.py` keeps the server's repositories equal to the library's.

### Restarts wait by the epoch length (#49)

- `TN_EPOCH_MARGIN` and `TN_EPOCH_SETTLE` follow the epoch length (`epochDuration`, read with the
  boundary from the node or the network's public RPC) when they are not set: the margin is the
  epoch length / 72, held to 300-900 seconds, and the settle time the epoch length / 240, held to
  90-300 seconds. The 6 h epoch of mainnet and testnet keeps 300 and 90; a 12 h epoch gives 600
  and 180, a 7-day epoch 900 and 300. A whole number of seconds set in the environment is used as
  given.
- The wait messages end with one sentence naming the values and where they came from, for
  example `Margin 300s and settle 90s, derived from a 21600 s epoch.`
- A `TN_EPOCH_WAIT_MAX` you set is kept as set and never raised. When it is shorter than margin +
  settle + two polls, the script warns: `TN_EPOCH_WAIT_MAX <N> is shorter than margin <M> + settle
  <S> + two polls; the restart may land before the epoch has settled. Set it to at least <X>, or
  TN_SKIP_EPOCH_WAIT=1 to skip the wait on purpose.` The default 1800 covers the largest derived
  sum, 1240.
- When the epoch length cannot be read (the blind wait of a staked node whose mode cannot be
  read), margin and settle derive the same way from the network's epoch length in `lib/common.sh`
  (`MAINNET_EPOCH_DURATION` and `TESTNET_EPOCH_DURATION`, 21600 s each), so the wait is still
  300 + 90 seconds unless set, at most `TN_EPOCH_WAIT_MAX`. Devnet has no constant and keeps the
  fixed 300 + 90. The warning ends with the source of each value, for example `Margin 300s and
  settle 90s (network default: epoch 21600 s).`
- Mainnet's epoch is 6 hours (21600 s, telcoin-network's `MAINNET_EPOCH_DURATION_SECS`), the same
  as testnet's, so the 1/72 and 1/240 shares stand and the restart margins stay derived.

### setup-node 2.1.0

- New `--host-baseline` (off by default, never asked): see [Host baseline](#host-baseline-43).
  On a host whose node is installed, `sudo ./setup-node.sh --host-baseline` alone makes the
  baseline, or makes it again, and changes nothing else. `--json --phase=finalize
  --host-baseline` reports `"host_baseline":true|false` in its `done` event.
- The connectivity check probes the chosen network's public RPC (testnet `https://rpc.adiri.tel`,
  mainnet `https://rpc.telcoin.network`, devnet `DEVNET_RPC_URL`), then `https://1.1.1.1`. It runs
  right after the network is selected; it used to probe the testnet RPC on every network, before
  the prompt (#47).
- The mainnet switch, the digest rule and the mainnet image example above (#45, #46), and the
  image feature check in the Docker preflight, before any container starts or `.node-meta` is
  written (#46).
- Messages about the passphrase file and the systemd floor say what the code checks: the
  plaintext file is for testnet and devnet only, and credentials need systemd 250 (Ubuntu 24.04
  ships 255) (#34).
- One optional question on every network sets up private alerts once the node runs; see
  [Private alerts](#private-alerts-60) (#60).
- New `--admission open|grace|closed` and `--trusted-nodes <file>`: see [Node admission settings](#node-admission-settings).

### update-node 2.1.0

- The release floor on every prepare path and the mainnet digest rule (#46, #51).
- The storage migration floor by network and the image feature check on the Docker prepare paths
  (#46; see [Image packages per network](#image-packages-per-network-and-the-image-feature-check-46)).
- After each verified apply on a host with `HOST_BASELINE=true`, it makes the AIDE baseline again
  before "Update complete" (or the `done` event). A failure is a warning and never fails the
  apply (#43).
- `--help` says the restart margin follows the epoch length (#49).
- No change to the post-update check (#33): when the vote window runs out while the unit is
  active and its RPC answers, the new release keeps running, the run warns, and a `--json` apply
  ends `"ok":true` with `"voting":false`. `TN_UPDATE_VOTE_ROLLBACK=1` makes that a failed check.
  README, OPERATOR.md and the partner guide now describe this case.

### edit-config 2.1.0

- Before the first write of a passphrase action (menu 5's passphrase change, `--reseal` and
  `--migrate-credential`), edit-config runs `keytool verify` with the passphrase it is about to
  store, when the node's release lists `verify` in `keytool --help` (#32, telcoin-network #1730).
  No release has it yet, so today it logs `keytool verify is not in this release; skipped`. A
  passphrase that does not open the key stops the action: `<The new passphrase|The passphrase> does
  not open the BLS key in <data dir> (keytool verify, exit N); nothing was changed. Use the
  passphrase the key was created with.` A `verify` that is listed but cannot start stops the
  action too; a probe that cannot run the node binary is a warning, and the write goes ahead.
- The release floor and the digest rule on the Docker image change; the menu and `--json`
  refusals on mainnet ask for a mainnet release tag (#46, #51). The changed image's build
  features are checked against the network after the pull, and a refusal leaves the image as it
  was.
- On a host with `HOST_BASELINE=true` it makes the baseline again after a `--set` whose restart
  came back healthy, a menu edit whose restart came back active, the menu's "Restart node" (which
  also covers an edit saved with "restart later"), and a passphrase action that went through
  (#43).
- An older `lib/common.sh` without the keytool and credential helpers is refused with one
  message that names `update-scripts.sh`.
- New `--set admission=open|grace|closed` and `--set trusted_nodes=<path>|none`, and menu items `11) Admission mode` and `12) Trusted nodes`: see [Node admission settings](#node-admission-settings).
  Refresh chain configs, Restart node and Exit move from 11, 12 and 13 to 13, 14 and 15.
- A menu edit whose restart does not come back is put back and the node restarted on the previous files, as `--set` has done; an edit kept for a later restart is not checked.
- An edit that changes only `.node-meta` keeps the change without a restart, in the menu and with `--set`.
- With P2P committee mode on, an edit of `node.env` or the bootstrap peers, the chain-config refresh and `14) Restart node` resync the allowlist once the node came back from its restart (`edit_committee_resync`); a failed sync is a warning.

### check-node 2.1.0

- The comparison RPC is the public RPC of the node's network (`NETWORK` in `.node-meta`, else the
  network of a Telcoin chain id read from the local RPC). With the network unknown and no
  `--network-rpc`, the comparison is skipped instead of made against adiri: `Network RPC:  none
  (network unknown; give --network-rpc URL to compare)`. The header names the endpoint's network
  (`(mainnet public RPC)`, `(--network-rpc, for testnet)`) (#47).
- New block `Checking the script release...` after the public RPC block: the installed release
  (tag, serial, release date, age) and its expiry date. An expired release is a warning that points
  at `update-scripts.sh --check`; a host without a release record is told to run
  `update-scripts.sh`. It reads the record only, checks no signature, contacts nothing and never
  counts a health issue (#40).
- `--audit` lists the host baseline lines (#43), and the observability status lists the ingest
  token file (#35).
- New private alerts block, whose issues count as health issues, and ownership rows for the
  heartbeat runner and `/etc/telcoin/alerts` (#60).
- With P2P committee mode on, `check_p2p_committee` reports the allowlist's tool, table, timer, staleness, consistency with the committee and config drift: see [P2P committee allowlist](#p2p-committee-allowlist-41).

### Signed script releases with OpenPGP (#40)

- `scripts-v2.1.0` is the first signed script release: serial 1 (given with `--serial 1`, since
  no earlier `MANIFEST` exists) and `min_updater` 2.1.0 (the tree's updater version, the default
  for a first release). Every later release raises the serial, and the updater refuses a lower
  one or the same serial with a different manifest.
- `MANIFEST.asc` replaces `MANIFEST.sig`: detached OpenPGP signatures over `MANIFEST`, one
  armored block per signer, by the release keys in `lib/release-keys/*.asc`. Those are the keys
  that already sign telcoin-network releases (today `grantkee.asc`, primary
  `4E36D35A4AB61B589861D01AC7173F2377CA7573`, expires 2028-10-16), and `gpgv` judges the
  signatures with the status rules node releases use: good signatures (`GOODSIG` and `VALIDSIG`)
  by at least `TN_SIG_THRESHOLD` distinct release keys (1, the hook for the 2-of-N policy of
  #40), and any `BADSIG`, `EXPKEYSIG`, `REVKEYSIG`, `EXPSIG` or `ERRSIG` other than a missing key
  refuses. The verdict comes from the status lines, never from `gpgv`'s exit status, which is 0
  for an expired or revoked key. `lib/allowed_signers` is gone from the tree and the updater
  arrays.
- Why: one key, held on a YubiKey, and one verification policy for node and script releases,
  instead of a second SSH key and a second trust file.
- `update-scripts.sh`, `install.sh` and `tools/release-scripts.sh` carry the same verification
  block and build the keyring from the key files with `base64`, so the updater and the installer
  need `gpgv` (Ubuntu ships it; `sudo apt-get install -y gpgv`, macOS `brew install gnupg`) and
  no longer `ssh-keygen`. The installer embeds every key file (its trust root, `TN_RELEASE_KEYS`)
  and installs the release's own key files only when they match the signed `MANIFEST`. Key files
  must use LF line endings and end with a newline: `release-scripts.sh` refuses a key file with
  CR, one without a final newline, and one gpg reads no primary key from, before it can ship.
- The updater records a release (`MANIFEST.asc`, then `MANIFEST`) only after every move and
  removal of the install pass succeeded; after a failed one the old record stays, and the next
  run records the new release.
- A host with no release key and no installed release (one on update-scripts 1.1.72 or older)
  takes the key files once from the release, each through its published `.sha256`, verifies
  `MANIFEST.asc` with them and requires them to match the verified `MANIFEST`: `First signed
  release on this host: fetching the release keys through their published checksums (one time
  only).` Hosts that already carry `lib/release-keys/grantkee.asc` never do this.
- A host running update-scripts 2.0.0 from main (the SSH flow, never tagged) refuses this release
  with `Release scripts-v2.1.0 has no MANIFEST.sig; nothing was changed.` and needs the installer
  once:
  `curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes`.
  A leftover `lib/allowed_signers` on such a host is harmless and is not removed.
- New `tools/cut-release.sh` (maintainer tool, not updater-tracked) runs the release ceremony one
  step at a time, each step printing its command and asking first: `prep TAG [--serial N] [--key
  FPR] [--sig-from FILE] [--yes]` checks the signing key against `lib/release-keys`, makes the
  `release/TAG` branch, prepares, signs (the YubiKey here or through a forwarded gpg-agent;
  `--sig-from` copies a signature made elsewhere), checks, commits signed, pushes and opens the
  pull request, and refuses a `--serial` that differs from the one already prepared on the
  branch; `tag TAG` prints the commit `origin/main` names after the fetch and works on that
  commit only (it refuses to tag when `origin/main` has moved since), checks that it carries the
  release, makes and verifies the signed tag (its signature must be by a release key, read from
  the status lines), pushes it, waits for CI and the installer publish and checks that
  `https://install.telcoin.network` serves it; `status` reports the newest release branch and
  tag. The three checks (prep step 6, tag steps 2 and 4) cannot be skipped. It never changes git
  configuration.
- `tools/release-scripts.sh` needs at least one key file, embeds the keys in `install.sh`, prints
  the `gpg --armor --detach-sign --local-user <FPR>! --output MANIFEST.asc MANIFEST` command,
  and `--check` verifies `MANIFEST.asc` (`--require-sig` and `--tag` require a verifying one) and
  fails when the keys embedded in `install.sh` differ from `lib/release-keys/*.asc`.
- CI: the "release manifest" job runs `release-scripts.sh --check --require-sig` on a change to
  `MANIFEST`, `MANIFEST.asc` or `RELEASE`, and `--check --tag` on a `scripts-v*` tag; the runners
  install nothing new. `.github/CODEOWNERS` lists `/lib/release-keys/`, `/MANIFEST.asc` and
  `/tools/cut-release.sh` among the release-path lines. The VM assertions check for `gpgv`.

### update-scripts 2.1.0 and install.sh

- Releases are verified with OpenPGP (above); `--help` names `gpgv` as the dependency.
- `MANIFEST` gains two optional header keys after `min_updater=`: `date=YYYY-MM-DD` (the release
  date `RELEASE` carries) and `expires=YYYY-MM-DD`. Each may appear once, as a real calendar date
  in ASCII digits; anything else makes the manifest malformed. Updaters and installers of 2.0.0
  ignore both keys (#40).
- A release has expired from the day `expires=` names (UTC). Expiry is a reminder that a newer
  signed release is due, not a revocation: an update run warns `Script release <tag> expired on
  <date>; a newer signed release is overdue. Installing it anyway.` and installs it. install.sh
  prints the same warning before it installs.
- New `bash ~/telcoin-node-scripts/update-scripts.sh --check`: a read-only report of the installed
  and the newest signed release (tag, serial, release date, expiry), whether an update is pending
  and whether either release has expired. It needs no root, asks nothing and installs nothing.
  Exit status 0: current and fresh; 1: an update is pending or a release has expired; 2: no signed
  release is installed, a record or the newest release does not verify or cannot be fetched, or
  the updater would refuse the newest release.
- Tracks `setup-alerts.sh`, `lib/alerts.sh` and `lib/tn-heartbeat.sh`. When the last two change on
  a host with private alerts, it prints the `setup-alerts.sh --refresh` command to run (#60).
- After an install that changed `firewall-setup.sh` or `lib/common.sh` on a host with `telcoin-p2p-allow-sync.timer`, it prints `sudo bash <tree>/firewall-setup.sh --p2p-committee sync` (`p2p_allow_hint`), which rewrites the allowlist's units and installs the tool the new scripts pin; it never runs it.

### install-caddy 2.1.0

- After an rpc-enable or rpc-disable that went through (`--json`, `--phase` and the menu), a host
  with `HOST_BASELINE=true` makes the baseline again before the update lock is released. The
  dashboard site does not refresh it: it writes nothing the baseline covers (#43).

### firewall-setup 2.1.0

- P2P new-flow limit (#41). When P2P is open to every source (no `--p2p-from`, no
  `P2P_ALLOW_FROM`, or `--p2p-anywhere`) on a host with a node, every enable path (`--enable`,
  `--reset`, `--json --enable`, the menu's "Enable recommended defaults") and the menu's "Manage
  node ports" load the nftables table `inet tn_p2p` once the ufw rules are in place. It drops UDP
  packets of new, not yet answered flows to the node's P2P ports from one source (an IPv4 address
  or an IPv6 /64) above 20 per minute after a burst of 40. Answered flows are never limited. The
  chain runs before ufw's and only drops, so ufw still decides every other packet. With a P2P
  source list, or without a node, the table is removed.
- `TN_P2P_NEW_FLOW_RATE` and `TN_P2P_NEW_FLOW_BURST` (whole numbers 1-100000) override 20 and 40
  for one run; they are not stored. A bad value stops the run before any change.
- A boot copy, `/etc/telcoin/p2p-limit.nft`, and the oneshot unit `telcoin-p2p-limit.service` load
  the table again at boot. When the loaded table and its boot copy already match what the run
  would write, nothing is rewritten and the run says the limit is unchanged. A run stopped while
  the limit changes finishes the change or leaves the previous one whole, and says which.
- Without `nft` the run warns and applies the ufw rules as before.
- Every enable path and "Manage node ports" take the update lock around ufw, the table and its
  boot copy.
- The status screen shows the limit and whether it comes back at boot; `--json --status` has a
  `p2p_new_flow_limit` object (`active`, `rate`, `burst`, `reason`, `persistent`,
  `persistent_reason`).
- The status screen shows the health-port block on testnet and devnet only. Elsewhere it says the
  port stays closed, or warns when a rule opens it (#47).
- A change that went through makes the host baseline again (#43).
- New `--p2p-committee on|off|sync|status`, the P2P committee allowlist: see [P2P committee allowlist](#p2p-committee-allowlist-41).
  In committee mode the new-flow limit is removed and reports reason `committee`, the desired-rules hint reads "committee allowlist", and `--enable` and `--reset` resync the allowlist after they store the source list.

### setup-vpn 2.1.0 (testnet add-on)

- On a host with `HOST_BASELINE=true`, an enable, a `--sync-keys` with
  `--grant-maintainer-root` or `--revoke-maintainer-root`, and a `--disable` make the baseline
  again. The other actions write nothing the baseline covers (#43).

### setup-observability 2.1.0 and lib/observability 2.1.0 (testnet add-on)

- The hub ingest token is in `/etc/telcoin/alloy/ingest-token` (root:telcoin-alloy 0640, one
  line), never in `telcoin-alloy.env`, the unit, a command line, Alloy's environment or `docker
  inspect` (#35). Native Alloy reads it with `LoadCredential=ingest-token:...`; the Docker sidecar
  gets it as a read-only bind mount at `/run/credentials/telcoin-alloy/ingest-token` with
  `--group-add` of the `telcoin-alloy` group. Both units carry `LimitCORE=0`, and the container
  `--ulimit core=0`. The Docker `config.alloy` is root:telcoin-alloy 0640, like the native one.
- `observability/config.alloy` reads the token with `bearer_token_file` and pins TLS 1.3 with the
  push URL's host as the server name, for logs and metrics.
- A host still on the env-file token moves to the file the next time Alloy's files are rendered
  (an enable, a partial disable or `--rotate-token`), with one message. Until then it keeps
  shipping, and the status warns.
- New `--rotate-token` (menu entry 8, "Rotate the ingest token"; `--json` too) writes the new
  token, renders the files again and restarts Alloy only, never the node. When Alloy does not stay
  up, it puts every changed file back as it was and exits 1. The token comes from
  `--token-stdin`, a hidden prompt on a terminal, `--token` or `TN_OBS_TOKEN`. Exit is now menu
  entry 9.
- A full disable shreds the token file, so enabling again asks for the token. remove-node shreds
  the token file and the env file.
- A push URL given with `--push-url` or `--metrics-push-url` (or `OBS_PUSH_URL`,
  `OBS_METRICS_PUSH_URL`) is an override: `telcoin-alloy.env` records it with
  `OBS_PUSH_URL_SOURCE=override` (`OBS_METRICS_PUSH_URL_SOURCE=override`), and a rotation or a
  partial disable keeps it. `--push-url default` (`--metrics-push-url default`) drops it. Without
  an override the URL follows the release default in `lib/testnet-addons.env`, and an env file
  written by 2.0.x counts as the default. A render that would leave an enabled pipeline without a
  URL is refused before anything is written.
- The status has a token line, and the Alloy unit's `InaccessiblePaths=` names
  `/etc/telcoin/bls-passphrase.cred` instead of `/etc/credstore.encrypted`.
- The menu, `--rotate-token` and `--json` runs remove an interrupted token write and release the
  update lock when TERM, INT or HUP stops them.
- A change that went through makes the host baseline again; the token file stays out of the
  baseline (#43).
- The vendored `observability/config.alloy` names deploy-networks-common main 18f8485 (PR #8,
  merged 2026-11-04) in its header instead of the branch it was taken from; its body is
  unchanged.

### remove-node 2.1.0

- The shred note adds: `Decommissioning a host that held a validator key means destroying or
  crypto-erasing its disk and deleting every snapshot and image taken from it; shred alone does
  not do that.` (#32)
- With the last node unit on the host it removes the host baseline (the audit rules, unloaded; the
  AIDE config, both databases and the marker; the packages stay) and the P2P new-flow limit
  (`telcoin-p2p-limit.service`, `/etc/telcoin/p2p-limit.nft` and the table). While another node
  unit remains, both stay whole for that node, in the menu and with `--json`, and the run says so.
  The leftover check finds a host where only the boot unit and the table remain (#41, #43).
- It shreds `/etc/telcoin/alloy/ingest-token` and `telcoin-alloy.env` with the add-ons (#35).
- The custom-container scan also offers containers that run an image of the ghcr.io packages
  (`tn-mainnet`, `tn-testnet`, `tn-dev` and the old single package), by digest or by tag (#46).
- It removes private alerts before it stops the node, then says to pause or delete the monitor
  (#60).
- With the last node it removes the P2P committee allowlist (`_rm_p2p_allow`): the timer, the sync service and the boot unit with their files, the table `inet tn_p2p_allow`, `/usr/local/libexec/telcoin/tn-p2p-allow-sync` and `/var/lib/telcoin-p2p-allow`, without running `firewall-setup.sh` or the tool.
  It deletes the table and removes the state dir under `flock -w 30` on the tool's lock (`/var/lib/telcoin-p2p-allow/lock`), as `off` does, so a sync in progress ends first; a lock held for 30 seconds, one that cannot be opened, or no `flock` leaves both for a later run, with a warning, and the binary still goes.
  The leftover check counts the timer unit and the state dir.

### lib/common 2.1.0

The library carries most of the above: the mainnet switch, the floor and digest rules, the epoch
derivation, the connectivity probe and the host baseline functions (`tn_host_baseline_install`,
the refresh and the status lines in `tn_host_audit`). `tn_keytool_has` reports "not listed" only
when the node's own usage text says so; a wrapper that fails (busybox `setpriv`, a docker error)
counts as a probe that could not run. Its setup prompts call the ingest token the hub's token
from the Association, not a per-operator one (#34). It sources `lib/alerts.sh` at its end when the
file is there, as it does `lib/observability.sh` (#60).
The admission renderer and its release gate are new: see [Node admission settings](#node-admission-settings).
The signed-release fetch is split into shared helpers (`_tn_release_tools_ok`, `_tn_release_open`, `_tn_release_fetch_asset`, `_tn_release_sums_shape`) so it serves the node release and the `tn-p2p-allow-sync` release alike; the node path keeps its messages and results.
`tn_p2p_allow_install` installs the pinned tool release, and `tn_release_extract_binary` and `tn_build_version` take the binary's name.
`validate_ipv6` follows the grammar of Rust's `Ipv6Addr::from_str`, which `tn-p2p-allow-sync` parses `P2P_ALLOW_FROM` with, instead of taking any string of hex digits and colons: a typo in an IPv6 entry of `--ssh-from` or `--p2p-from` is refused before anything is written, and the source lists refuse a dotted IPv4 tail (`::ffff:192.0.2.1`; write `::ffff:c000:201`).
`_tn_root_layout_dir` pads a numeric mode to five digits, so an inherited setgid bit is cleared and `/var/lib/telcoin-p2p-allow` ends 0700, not the 02700 the tool refuses.

### Host baseline (#43)

`sudo ./setup-node.sh --host-baseline` installs `auditd` and `aide` with
`--no-install-recommends` (no daily whole-system AIDE timer, no mail packages), then writes:

- `/etc/audit/rules.d/telcoin-node.rules` (root 0640), loaded with `augenrules --load`: watches
  on `<data dir>/node-keys` (key `telcoin-keys`), `/etc/telcoin` (`telcoin-config`) and the node
  unit (`telcoin-unit`). Search with `sudo ausearch -k telcoin-keys`.
- `/etc/aide/telcoin-node.conf` (root 0600), the node's own AIDE config, outside
  `/etc/aide/aide.conf.d`, so a system-wide AIDE run never reads it. It covers `/opt/telcoin`,
  `/usr/local/libexec/telcoin`, `/etc/telcoin`, the unit and the node binary, and leaves out the
  passphrase files, `alloy/ingest-token` and the scripts' temp files.
- `/var/lib/aide/telcoin-node.db` (root 0600), the baseline, and `HOST_BASELINE=true` in
  `.node-meta`.

Check it by hand with `sudo aide --config=/etc/aide/telcoin-node.conf --check`. The audit rules
are written and loaded only after the AIDE prerequisites pass, and removed again on a later
failure, so a failed or refused run leaves no rules, no AIDE config and no marker. A failure in a
full setup is a warning and setup goes on. update-node, edit-config, the four add-ons and
setup-alerts make the baseline again after their own changes, so those do not show up as
differences. A
`/var/lib/aide` that root alone does not own (aide-common makes it `_aide:root`) is refused.

### Private alerts (#60)

New `setup-alerts.sh` sends a heartbeat from the node host to a monitor you own. It works on every
network and is not a testnet add-on: the Telcoin Association is not involved, no port opens on the
host, and `tn_testnet_addons_present` does not count it. Nothing happens until you enable it, with
`sudo bash ~/telcoin-node-scripts/setup-alerts.sh` (a menu: status, enable, change targets, test,
refresh, disable) or the `--json` forms below.

`telcoin-heartbeat.timer` starts the oneshot `telcoin-heartbeat.service` 120 seconds after boot and
then every interval (`--interval`, 60 seconds by default, 30 to 3600). Each run checks the node in
this order, and the first problem decides the status:

| Check | Down when | Reason, for example |
|---|---|---|
| Node unit (`systemctl show`) | not found; restarted after a failure (`NRestarts` rose); inactive, failed or waiting to restart; activating or deactivating for more than 120 s | `service telcoin inactive (dead)` |
| Local RPC (`eth_chainId`) | no answer, after a 120 s grace from the unit's start; a chain id other than the network's | `rpc 127.0.0.1:8545 not answering (refused)`, `wrong chain: rpc reports N, expected M` |
| Consensus header (`tn_latestConsensusHeader`) | unchanged for `--stall-after` seconds (by default the larger of 180 and 3 x the interval; at least the interval + 30) | `consensus stalled at header N for Ns` |
| Node mode (`tn_nodeMode`) | `CvvInactive` for `--inactive-after` seconds (by default the larger of 900 and the stall time; at least the stall time) | `CvvInactive for Ns: committee member not voting` |
| Health port (`/health/network`) | answers 503 | `health 503: node reports the network unreachable` |

Otherwise the run is up, with the mode, block and epoch as its reason (`CvvActive block 1234567
epoch 42`). A node without `tn_latestConsensusHeader`, or without a health port, skips that check.

Up to five targets, of three kinds:

- `kuma`: an Uptime Kuma push URL (`https://<host>/api/push/<token>`). Paste it as the monitor's
  page shows it; the `?status=up&msg=OK&ping=` part is dropped. A run sends `status`, `msg` and,
  when the RPC answered, `ping` (the RPC's answer time in ms).
- `healthchecks`: a healthchecks.io ping URL. A trailing `/fail`, `/start` or `/log` is dropped,
  and a URL with a query string or a fragment is refused. An up run pings `<url>`, a down run
  `<url>/fail`, with `<status>: <reason>` as the body.
- `webhook`: an endpoint that takes a JSON POST with these keys in this order:
  `{"status":"up","reason":"CvvActive block 1234567 epoch 42","node":"<label>","network":"testnet","mode":"CvvActive","block":1234567,"epoch":42,"ts":1762257600,"changed":false}`
  (`block` and `epoch` are `null` when unknown; `changed` is true when the status changed, and on
  the first run).

A target needs `https://`; `http://` is taken for `127.0.0.1`, `[::1]` and `localhost`, or with
`--allow-http`. Every kind gets the status and the reason (the node mode, block and epoch on an
up run, the problem on a down run). A webhook also gets the mode, block and epoch as fields, the
network, the host's label (`--label`, else the host name), the time of the run and whether the
status changed; a Kuma push also gets the local RPC's answer time (`ping`). Nothing else leaves the
host. That field set is an operator-visible contract: monitors and webhook receivers parse it.

- A target URL holds the monitor's token, so the scripts treat it as a secret. It is kept only in
  `/etc/telcoin/alerts/targets` (root 0600), which systemd hands the runner as a credential
  (`LoadCredential=`), and curl reads it from a config file on a process substitution (`-K`), not
  from its command line. Prompts read it with hidden input. Messages, the journal, the state file,
  `--json` events and `.node-meta` name a target only as `kind@host` (`kuma@kuma.example.org`).
- The runner, `/usr/local/libexec/telcoin/tn-heartbeat` (a copy of `lib/tn-heartbeat.sh`), sources
  no other file and runs as a dynamic user (`DynamicUser=yes`) with no capabilities, a read-only
  system, the data dir and the passphrase files out of reach, at most 64 MB of memory and 20% of a
  CPU. Its state is in `/var/lib/private/telcoin-heartbeat`, the one path the scripts set up that
  root does not own. Its journal is `journalctl -u telcoin-heartbeat`.
- A dynamic user cannot reach the system bus, so the runner cannot ask systemd for the node's
  service state itself. Before each run the unit's one root step (`ExecStartPre=-+/bin/sh -c
  '...'`) removes the last answer and writes `systemctl show` of the node's unit to
  `/run/telcoin/heartbeat-service` (root 0644), which the runner reads; without that file it falls
  back to `systemctl show`. A disable and `remove-node.sh` remove the file and leave `/run/telcoin`
  in place.
- Enable, change targets, test, refresh and disable never stop or restart the node, so they run
  neither the quorum guard nor the epoch wait. They take the update lock and, on a host with
  `HOST_BASELINE=true`, make the baseline again after a change that went through (#43).
- An enable needs systemd 247 (`LoadCredential=`) and a node command with `--http`, since the
  runner reads the local RPC. It sends a test heartbeat before it turns the timer on; when no
  target accepts it, the files written for the test are removed and `.node-meta` is left as it was
  (it is not even rewritten), so the alerts stay off and nothing
  on the host changed. A change of targets puts the previous ones back the same way.
- `--json` runs exactly one of `--status`, `--enable`, `--test`, `--refresh` and `--disable`.
  Targets come from exactly one of `--targets-stdin` (one `<kind> <url>` per line),
  `TN_ALERT_TARGETS` (the same lines; unset before anything runs) and a repeated `--target
  kind=url`, which warns because other local users can read a command line. `--interval`,
  `--stall-after`, `--inactive-after`, `--label` and `--allow-http` set the rest. On a node whose
  alerts are on, `--interval`, `--stall-after`, `--inactive-after` and `--label` given with
  `--enable` (with or without targets) or with `--refresh` replace the stored values and restart
  the timer, with no disable in between; with `--interval`, each threshold not given follows the new
  interval, as at an enable. The `done` event carries `applied` (`alerts:enabled`,
  `alerts:targets-changed`, `alerts:refreshed`, `alerts:tested` or `alerts:disabled`; a target
  change that also replaced those values lists `alerts:targets-changed`, then `alerts:refreshed`)
  and `network`. An enable or a test adds `node_status`, `node_reason` and one `{n, provider, host,
  result, code}` entry per target (`why` too for a failed push), and an enable or a refresh adds
  `interval`. `--status` needs neither root nor the lock; without root, when it cannot read
  `.node-meta` (root 0600), on a host with the timer unit it shows the setting as `unknown (run with sudo)` (`"enabled":null`),
  takes on or off from whether `telcoin-heartbeat.timer` is enabled, and does not read the last
  run. Exit status 0: done; 1: refused with nothing changed, which includes an enable that no
  target accepted; 2: the library is older than the script; 3: a step failed after something
  changed.

  ```
  printf 'kuma https://kuma.example.org/api/push/<token>\n' |
    sudo bash ~/telcoin-node-scripts/setup-alerts.sh --json --enable --targets-stdin
  ```

- setup-node asks once, on every network, whether to set up private alerts once the node runs (not
  under `TN_ASSUME_YES`, not in `--json`). A yes records `ENABLE_ALERTS=pending` and runs
  `setup-alerts.sh --enable` near the end of setup when the node is active; otherwise the summary
  says `Private alerts: pending. To finish: sudo bash setup-alerts.sh`. A re-run keeps a live
  `true` or `pending`.
- check-node reports the alerts and counts each issue it finds: alerts on with the timer inactive
  or missing, no run recorded or a last run older than three intervals plus 30 seconds, every push
  of the last run failed or none recorded, a targets file that is missing, not a regular file or
  not `0600 root:root`, a duplicate `ENABLE_ALERTS` line, an installed runner that is missing or of
  another version than the scripts' copy, and an `alerts.env` out of step with the node's service
  or RPC address. Each warning names its fix, most often `setup-alerts.sh --refresh`.
- remove-node removes the alerts before it stops the node, so the heartbeat does not push the stop
  as a failure. It does so at every scope that removes the node and in the leftover clean-up; the
  chain-data wipe leaves them. Then it says `Pause or delete this node's monitor: a push monitor
  alerts on silence.`
- When the runner or its library changed on a host with the timer, update-scripts prints `The
  heartbeat runner or its library changed. Reinstall them on the host:` and `sudo bash <scripts
  dir>/setup-alerts.sh --refresh`. It never runs sudo itself.

Set the monitor's heartbeat interval to about twice the push interval, with one or two retries: a
node update or a restart you run yourself shows as a short down.

### Node admission settings

The node decides which peers it takes connections from by an admission mode it reads, with two maps, from three top-level entries of `<data dir>/network-config`.
The scripts now write them; nothing changes on a node until you ask for a mode.

- `setup-node.sh --admission open|grace|closed` writes `admission` (mode `Open`, `Grace` or `Closed`), `trusted_nodes` from `--trusted-nodes <file>` and, as `committee_peers`, the installed `bootstrap-peers.yaml`; each map is left out when its flag is.
  Closed admits only the previous, current and next committees, the trusted nodes and the bootstrap peers; Grace enforces nothing beyond Open and differs only in the status the node reports.
  Without `--admission`, and with no earlier choice recorded, setup leaves the settings alone on every network.
- The trusted nodes map is checked like a peers map (a regular file of at most 64 KiB that others can read) and installed as `/etc/telcoin/trusted-nodes.yaml` (root 0644) with `tn_write_root_file`.
  `.node-meta` records `ADMISSION_MODE` and `TRUSTED_NODES_FILE`; a `--json` finalize reads them back from keygen's record, and an interactive re-run reads them back too, with `BOOTSTRAP_PEERS_FILE` when a mode is in effect.
- Mainnet validators are expected to run `--admission closed --trusted-nodes <hubs>`; mode closed on mainnet with no trusted nodes map warns, at setup and in edit-config.
- `edit-config.sh --set admission=...` and `--set trusted_nodes=<path>|none` (menu items 11 and 12) render the three entries again from what `.node-meta` records and the bootstrap peers map the node command loads.
  The node has no check for the trusted nodes map, so edit-config checks its shape on a root-only copy first: base58 BLS keys of 131 or 132 characters, each once, each entry `primary` (`network_address`, `network_key`) and `workers` (worker ids 0 to 65535, each with its own address and key) and nothing else, in block YAML.
  `none` removes the map, its entry and its record, and a `bootstrap_peers` edit on a node with a mode writes `network-config` again, so `committee_peers` follows the peers map.
- An edit that writes `network-config` is watched after its restart for `TN_EDIT_VERIFY_TIMEOUT` seconds (default 60): the service must stay active without restarting by itself (`NRestarts`), checked every 5 seconds.
  When it does not stay up, `network-config`, the trusted nodes map and `.node-meta` are put back byte for byte and the node is restarted on them.
- `lib/common.sh` has the renderer, `tn_network_config_render DATA_DIR MODE TRUSTED_FILE COMMITTEE_FILE`, which edits `network-config` as the service user through a `network-config.tn-new` file and one rename.
  It replaces the three entries where the node's default file has them and never appends a second copy, since a key that appears twice stops the node, and keeps a `snapshot_max_age_secs` of the old `admission` entry.
  It refuses, with the file unchanged, a `network-config` whose top-level entries it cannot tell apart (a flow document, a quoted key, a BOM or CRLF line ends) and a map file that does not start with a key or holds a second document.
- The release gate `tn_node_supports_admission` compares the release with `MIN_ADMISSION_VERSION`, 0.17.0: no node release reads the entries yet (`v0.16.0-adiri` ignores them), so the floor is the next minor release and waits for the node team to confirm it.
  Both scripts refuse a release below it and warn, writing anyway, when they cannot tell the release.

### P2P committee allowlist (#41)

A validator can now let only the peers its own node lists reach its P2P ports.
`firewall-setup.sh --p2p-committee on` loads the nftables table `inet tn_p2p_allow`, built by the new signed tool `tn-p2p-allow-sync` from the node's `tn_admissionSnapshot` (every address of every swarm), the bootstrap floor and `P2P_ALLOW_FROM`, and `telcoin-p2p-allow-sync.timer` keeps it in step every 5 minutes.
It is opt-in, and nothing changes on a host until `on`; see the README's [P2P committee allowlist](../README.md#p2p-committee-allowlist) and OPERATOR.md section 2.10.
For validators it replaces the signed address manifest #41 proposed; hubs and observers keep open P2P.

- `--p2p-committee on|off|sync|status` goes alone (with `--json`, `--status`, `--enable`, `--reset` or `--port` it exits 1).
  `on` refuses with nothing changed without a node, an active `ufw`, an executable `/usr/sbin/nft` (the path the tool runs, named in the refusal), an `nft` on `PATH`, `systemctl` and `flock`, with a bad new-flow rate or source list, or when the node's snapshot is not authoritative (`sync --require-authoritative --wait 30` exits 1); the refusal names the tool's `reason=`, and `rpc-method-missing` reads `this node release lacks tn_admissionSnapshot, or tn is not in its --http.api; update the node or add tn to --http.api`.
  An exit 0 counts only with `result=applied` or `result=unchanged` on the tool's line.
  A step after the sync that fails turns committee mode off again (exit 2, or 3 when that did not finish), and a stop from the sync until `P2P_COMMITTEE=on` is written does the same.
- `sync` reinstalls the tool when it is missing or `_tn_p2p_allow_version_ok` refuses its `--version` (the first line, the `config-version` and `snapshot-versions` lines), rewrites `config`, the floor and any unit whose text differs, and runs `sync --wait 30`: exit 0 fresh, 1 refused, 2 failed with the tool's `reason=`, 3 stale or busy.
- `off` is the kill switch and never runs the tool: the earlier P2P `ufw` rules and the new-flow limit come back first, byte for byte, then the units, the table, `/var/lib/telcoin-p2p-allow` (under `flock -w 30` on the tool's lock) and the binary go, and `P2P_COMMITTEE=off` is written last; a lock held for 30 seconds leaves everything in place (exit 3) for a rerun.
- `status` prints the allowlist's lines of the status screen, read key by key from the tool's status file and `tn-p2p-allow-sync status`; it warns at once of `rpc-method-missing`, `snapshot-version-*`, `epoch-regressed` and `state-invalid`, and of any other reason once the tool reports the run stale.
- In committee mode `ufw` keeps its open P2P rules and any per-source rules, and the new-flow limit `inet tn_p2p` (table, boot copy and unit) is removed, because an accept at priority -20 does not stop the limit chain at -10; the limit reports reason `committee`.
  There is no rule for established flows: the table matches addresses only, so a committee-mode validator completes connections only with listed sources.
- `P2P_ALLOW_FROM` becomes static entries of the table while `ufw` stays open; the config writer refuses a multicast, link-local or unspecified host in it and writes a repeated P2P port once.
- The tool comes from a signed release of `Telcoin-Association/tn-p2p-allow-sync` pinned in `lib/common.sh` (`TN_P2P_ALLOW_VERSION` `v0.1.0`, `TN_P2P_ALLOW_TARBALL_SHA256`), checked against `lib/release-keys` like a node release and installed as `/usr/local/libexec/telcoin/tn-p2p-allow-sync` (root 0755).
- Three units: `telcoin-p2p-allow.service` loads the last-good program at boot with `/usr/sbin/nft -f`, the nft the tool runs, written literally, after `ufw` and before the node (a no-op without `current.nft`); `telcoin-p2p-allow-sync.service` runs one sync in a sandbox that keeps `CAP_NET_ADMIN` alone, reaches `localhost` only and cannot see `/etc/telcoin` (`SuccessExitStatus=3 4`); `telcoin-p2p-allow-sync.timer` starts it 2 minutes after boot and 5 minutes after each run.
- The state dir `/var/lib/telcoin-p2p-allow` (root 0700, outside `/etc/telcoin` so a sync touches nothing auditd or AIDE watch) holds the scripts' `config` and the tool's `floor`, `current.nft`, `state.json`, `status` and `lock`; `tn_root_dir_ok` refuses it group-writable.
  The scripts never hold the tool's lock while the tool runs, and the timer never takes the update lock.
- Every writer of the tool's inputs resyncs as a child (`firewall-setup.sh --p2p-committee sync`) after it released its update lock, and only while committee mode is on: `--enable`, `--reset`, the menu's and the UI's enable, `edit-config.sh` after an edit of `node.env` or the bootstrap peers, the chain-config refresh and the menu's Restart node, and `migrate-node-naming.sh` after it rewrote `RPC_PORT`.
  A failed resync is a warning naming the command; `update-node.sh` writes none of the inputs and has no hook.
- `--json --status` ends with `p2p_committee` (`enabled`, `persistent`, `timer`, `reason`, then the tool's `status --json` keys), and the UI's firewall card shows it read-only.
- `check-node.sh` reports the allowlist while committee mode is on: a missing tool or table (failures), the new-flow limit loaded beside it, a timer that is not running, a last good sync older than 2 epochs, at once a failed last sync (`RESULT=error`, with its reason and since when) and a failed last run of `telcoin-p2p-allow-sync.service` (`systemctl show -p Result -p ExecMainStatus`; exit 0, 3 and 4 count as success), `rpc-method-missing`, `snapshot-version-<n>`, `epoch-regressed` and `state-invalid` at once (`state-invalid` with the fix `--p2p-committee off`, then `on`; `epoch-regressed` clears by itself once the node's tracked epoch is back at or above the applied one, after a startup record-sync replay, and needs off and on only when it persists past 2 epochs), up to five current committee addresses the table lacks, up to five keys whose records list other addresses, and a config that no longer matches `.node-meta` or the node's P2P ports.
  It reads the tool's `reason=` from its `error` and `stale` log lines of `check`.
- `remove-node.sh` removes the allowlist with the last node at fixed paths without running the tool; under the tool's lock, as `off` does, it deletes the table when nft lists it, or cannot list the tables while something else of the allowlist is there, and keeps the state dir when nft refuses, so a later run tries again.
- `update-scripts.sh` prints the `--p2p-committee sync` command after an install that changed `firewall-setup.sh` or `lib/common.sh` on a host with the timer.

### Node Manager UI 2.1.0 and install-ui 2.1.0

- The Network tab's status page link follows the node's network: testnet links
  `https://status.adiri.telcoin.network/`; mainnet, devnet and an unknown network show none (#47).
- The firewall card's enable form has a "P2P sources" field next to "SSH sources", with the same
  rule (at most 16 addresses or CIDRs of /8 or narrower). When empty, the engine uses
  `P2P_ALLOW_FROM`, else every address with the new-flow limit. The card shows the kept P2P list
  and the limit row, with "(not restored at boot)" when the limit does not come back at boot (#41).
  Errors name the list (`SSH sources: ...`, `P2P sources: ...`), and a list that is not text is
  refused.
- The helper takes `firewall-enable [<ssh-sources>|-] [<p2p-sources>]` and refuses a file path, a
  list that is not comma-separated, a bad entry, more than 16, and an engine without
  `--p2p-from`. The sudoers file is unchanged.
- The setup wizard and the helper refuse mainnet while the switch is off (#45).
- `ui/telcoin-ui.service` has `LimitCORE=0`; a core dump of the UI or a helper would hold the UI
  token or a setup passphrase.
- install-ui's sudoers comment names no testnet tag; the rules are unchanged. Run `sudo bash
  ui/install-ui.sh --update` when update-scripts prints it.
- The firewall card has a read-only "P2P committee allowlist" row (`fwCommitteeText`) from `p2p_committee`: off, the reason in words, or on with the table state, the addresses allowed, the floor, the static networks, the age of the last good sync and staleness, and whether the boot unit and the timer are in place.
  The limit row words reason `committee` as `the P2P committee allowlist replaces it`, and "P2P sources" reads `committee allowlist` while it is on; `/api/firewall` passes the object through, with no helper subcommand, sudoers line or `HELPER_API` change.

### Maintainer tools, CI and governance (#30, #31, #40, #47)

- `tools/release-scripts.sh` writes `date=` and `expires=` (`--expires DAYS`, 90 by default, 1 to
  3650) and warns when the release would already be expired. `--check` prints the release date and
  expiry; `--require-fresh` fails an expired release.
- New `tools/check-network-hits.sh` finds `adiri` and the testnet hosts and addresses of
  `lib/testnet-addons.env` in the shipped scripts, the UI and `observability/config.alloy`. Each hit
  needs a `# network-gated: <reason>` marker on its line or a marker line right above it (`//` in
  JavaScript and Alloy, `<!-- -->` in HTML). It scans 24 files and finds 146 hits, all annotated.
  It runs in the "hardening lints" job, and `tools/tests/network_hits_test.sh` covers it. The `--help`
  printers of setup-node, edit-config and update-node skip marker lines, so their help text is
  unchanged.
- CI: the hardening lints and UI jobs have no fallback branches; the UI job runs pytest only; the
  macOS and UI jobs run `ui/tests/helper_test.sh`, `install_ui_test.sh` and `open_ui_test.sh`.
  `tools/tests/ci_pins_test.sh` guards ten job display names and fails a required job or step that
  could no longer fail (`if:`, `continue-on-error`, `|| true`), except the advisory shellcheck
  step. publish-installer writes no `.nojekyll`.
- `.github/CODEOWNERS` lists three owners on every line, the default line and each release-path
  line, so the ruleset of #30 can set `require_code_owner_review` and require the pull-request
  review from a code owner; `tools/tests/ci_pins_test.sh` requires at least two owners on every
  owned path.
- AGENTS.md has a "Contributing" note: the required checks, signed commits once the ruleset is
  on, and no job renames.
- New fixtures for the P2P committee allowlist: `tools/tests/p2p_allow_install_test.sh` (the signed install, every refusal leaving an installed binary byte-identical) and `tools/tests/p2p_committee_mode_test.sh` (the verbs, the units, the kill switch, the status object), on a `tn-p2p-allow-sync` stand-in and an nft stub that models `table inet tn_p2p_allow` in `tools/tests/fwstub.sh`; `edit_config_resync_test.sh` covers edit-config's resync hook.
  `check_node_hardening_test.sh`, `remove_test.sh`, `remove_addons_test.sh`, `updater_manifest_test.sh`, `migrate_naming_test.sh` and `addon_oldlib_test.sh` gained their allowlist cases.
- New VM assertion `tools/tests/vm.d/P0-p2p-allow.sh`: the pinned release installed from GitHub, `systemd-analyze verify` on the three units, a sync inside the unit's sandbox, the boot unit's reload, a hand-deleted element healed, the counters across reloads and `off` restoring the limit and `ufw` byte for byte; it reports SKIP when `lib/common.sh` pins no tarball sha256 or the release cannot be downloaded, and `integration.yml` installs `nftables` for it.
- New fixtures for the node admission settings: `network_config_test.sh`, `setup_node_admission_test.sh` and `edit_config_admission_test.sh`.

## New files, units and keys

| Path or key | What it is |
|---|---|
| `MANIFEST.asc` (release metadata, at the tag's root) | Detached OpenPGP signatures over `MANIFEST` by the release keys; kept with `MANIFEST` in the install directory as the installed record |
| `lib/allowed_signers` (removed) | The SSH signer list of the retired scheme; no longer shipped, and left unused where a host has it |
| `tools/cut-release.sh` (maintainer tool, not shipped) | The release ceremony: `prep`, `tag`, `status` |
| `MANIFEST` `date=`, `expires=` | Release date and expiry date (optional; 2.0.0 ignores them) |
| `/etc/telcoin/p2p-limit.nft` (root 0640) | Boot copy of the nftables table `inet tn_p2p` |
| `/etc/systemd/system/telcoin-p2p-limit.service` (root 0644) | Oneshot that loads the boot copy at boot; stopping it deletes the table |
| `/etc/telcoin/alloy/ingest-token` (root:telcoin-alloy 0640) | The hub ingest token Alloy reads as a file |
| `OBS_PUSH_HOST`, `OBS_METRICS_PUSH_HOST` in `telcoin-alloy.env` | Push URL hosts for the TLS server name |
| `OBS_PUSH_URL_SOURCE=override`, `OBS_METRICS_PUSH_URL_SOURCE=override` | A push URL override, kept across renders |
| `/etc/audit/rules.d/telcoin-node.rules` (root 0640) | Host baseline audit watches |
| `/etc/aide/telcoin-node.conf` (root 0600), `/var/lib/aide/telcoin-node.db` (root 0600) | Host baseline AIDE config and database |
| `HOST_BASELINE=true` in `.node-meta` | The host baseline is in place |
| `/usr/local/libexec/telcoin/tn-heartbeat` (root 0755) | The private alerts runner, a copy of `lib/tn-heartbeat.sh` |
| `/etc/systemd/system/telcoin-heartbeat.service`, `telcoin-heartbeat.timer` (root 0644) | The oneshot that runs the checks and pushes, and the timer that starts it every interval |
| `/etc/telcoin/alerts/targets` (root 0600) | The monitor URLs, one `<kind> <url>` per line, at most five; the runner's credential |
| `/etc/telcoin/alerts/alerts.env` (root 0644) | The runner's settings: node unit, local RPC, network, chain id, label, health port, interval and thresholds |
| `/var/lib/private/telcoin-heartbeat/state` (dynamic user, dir 0700) | The runner's last run, status, reason and per-target results |
| `/run/telcoin/heartbeat-service` (root 0644) | The node unit's `systemctl show`, rewritten as root by the heartbeat service before each run and read by the runner |
| `ENABLE_ALERTS=true\|pending\|false` in `.node-meta` | Private alerts on, waiting for the node to run, or off; absent means off |
| `/etc/telcoin/trusted-nodes.yaml` (root 0644) | The trusted nodes map, with `--trusted-nodes` or `edit-config.sh --set trusted_nodes=` |
| `ADMISSION_MODE`, `TRUSTED_NODES_FILE` in `.node-meta` | The admission mode (`open`, `grace` or `closed`, or empty) and the installed trusted nodes map (or empty) |
| `admission`, `trusted_nodes`, `committee_peers` in `<data dir>/network-config` | The node admission settings, written only with an admission mode |
| `/usr/local/libexec/telcoin/tn-p2p-allow-sync` (root 0755) | The P2P committee allowlist sync tool, from its pinned signed release, only in committee mode |
| `/var/lib/telcoin-p2p-allow/` (root 0700) | The allowlist's state: `config` (the scripts'), `floor`, `current.nft`, `state.json`, `status`, `lock` (the tool's, 0600) |
| `/etc/systemd/system/telcoin-p2p-allow.service`, `telcoin-p2p-allow-sync.service`, `telcoin-p2p-allow-sync.timer` (root 0644) | The allowlist's boot unit, sync service and timer |
| nftables table `inet tn_p2p_allow` | The allowlist: sets `allow_v4`, `allow_v6`, `static_v4`, `static_v6`, counters `tn_accept_p2p_listed` and `tn_drop_p2p_unlisted` |
| `P2P_COMMITTEE` in `.node-meta` | `on` or `off`, the committee mode `firewall-setup.sh --p2p-committee` records |
| `TN_P2P_ALLOW_VERSION`, `TN_P2P_ALLOW_TARBALL_SHA256` in `lib/common.sh` | The pinned tool release (`v0.1.0`) and its tarball sha256 |
| `p2p_committee` in `firewall-setup.sh --json --status` | The allowlist's state for the UI |

## New environment variables

| Variable | Default | Effect |
|---|---|---|
| `TN_P2P_NEW_FLOW_RATE` | 20 | Packets of new, not yet answered P2P flows per minute from one source (firewall-setup, one run) |
| `TN_P2P_NEW_FLOW_BURST` | 40 | Such packets one source may send before the rate applies |
| `TN_EPOCH_MARGIN`, `TN_EPOCH_SETTLE` | derived from the epoch length | Existing names; unset, they now follow the epoch length |
| `TN_ALERT_TARGETS` | unset | Targets for `setup-alerts.sh --enable`, one `<kind> <url>` per line; copied and unset before anything runs |
| `TN_EDIT_VERIFY_TIMEOUT` | 60 | Seconds edit-config watches the node after the restart of an edit that writes `network-config` |

## Before you update

1. Make sure `gpgv` is installed (`sudo apt-get install -y gpgv`; Ubuntu ships it), then run
   `update-scripts.sh`. It installs this release from the signed manifest. A host still on
   update-scripts 1.1.72 or older first takes the new updater through the `.sha256` sidecars on
   main and then fetches the release keys once (the layout steps that follow are in
   [scripts-v2.0.0](scripts-v2.0.0.md#before-you-update)). A host whose updater is 2.0.0 from
   main stops with `... has no MANIFEST.sig; nothing was changed.`: run the installer once,
   `curl --proto '=https' --tlsv1.2 -fsSL https://install.telcoin.network | bash -s -- --yes`.
2. On a host with the Node Manager UI, run the `sudo bash ui/install-ui.sh --update` that
   update-scripts prints.
3. On an observability host, move the token into its file with the same token:
   `printf '%s\n' "$TOKEN" | sudo bash ~/telcoin-node-scripts/setup-observability.sh --rotate-token --token-stdin`.
   Until then Alloy keeps reading it from `telcoin-alloy.env`, and the status warns.
4. To add the P2P new-flow limit on a host whose firewall is already on, apply the defaults again:
   `sudo bash ~/telcoin-node-scripts/firewall-setup.sh --enable`, or "Enable recommended
   defaults" in the menu.
5. The host baseline is opt-in: `sudo ./setup-node.sh --host-baseline` on an installed node.
6. A `TN_EPOCH_WAIT_MAX` you set below margin + settle + two polls is now kept and warned about;
   raise it, or leave it unset.
7. Private alerts are opt-in on every network: nothing changes until you run
   `sudo bash ~/telcoin-node-scripts/setup-alerts.sh`. A host that enables them and later updates
   the scripts runs the `setup-alerts.sh --refresh` that update-scripts prints.
8. The P2P committee allowlist is opt-in for validators: this release pins `tn-p2p-allow-sync` v0.1.0, and nothing changes until `firewall-setup.sh --p2p-committee on` is run on a node release that serves `tn_admissionSnapshot`.

## Refusals and warnings you may now see

| Message (shortened) | What to do |
|---|---|
| `Mainnet is not enabled in this script release` | Mainnet waits for the release that pins its chain configs. |
| `<ref> is older than v<floor>, the oldest <network> release these scripts support` | Pick the floor release or a newer one. |
| `Image refused: on mainnet an image is named by its release tag` | Give the mainnet release tag (`--release-tag` at setup). |
| `Image refused: ... No release was ever published to ghcr.io/telcoin-association/telcoin-network` | Give the release tag, or an image by digest from the network's package. |
| `Image refused: <image> was built with the features <list> ...` | The image is not the network's; give the network's release tag. If a release names it, report it to the node team. |
| `Release <tag>: IMAGE_DIGEST names <image>, but a <network> release image is ...` | Nothing was pulled; report it to the node team. |
| `The release manifest is not signed by a Telcoin release key (<reason>); nothing was changed.` | Do not install by hand; tell support@telcoin.org. When the reason says the release key has expired, run the installer one-liner. |
| `gpgv (GnuPG) is needed to verify script releases and is not installed` | `sudo apt-get install -y gpgv` (macOS: `brew install gnupg`), then run the updater again. |
| `Release scripts-v2.1.0 has no MANIFEST.sig; nothing was changed.` (update-scripts 2.0.0 from main) | Run the installer once with `--yes`. |
| `TN_EPOCH_WAIT_MAX <N> is shorter than margin ...` | Raise the cap, or set `TN_SKIP_EPOCH_WAIT=1` to skip the wait on purpose. |
| `... does not open the BLS key in <data dir> (keytool verify, exit N)` | Use the passphrase the key was created with (releases with `keytool verify` only). |
| `Script release <tag> expired on <date>; a newer signed release is overdue` | The release still verifies. If no newer one appears soon, tell support@telcoin.org. |
| `TN_P2P_NEW_FLOW_RATE is '<x>', not a whole number from 1 to 100000` | Fix or unset the variable; nothing was changed. |
| `nftables (nft) is not installed, so the P2P new-flow limit is not applied` | `sudo apt-get install nftables`, then enable again. |
| `The ingest token is still in /etc/telcoin/alloy/telcoin-alloy.env` | Run `setup-observability.sh --rotate-token` (the same token is fine). |
| `There is no logs push URL for network '<net>'` | Pass `--push-url` (or `--metrics-push-url`); nothing was written. |
| `AIDE: /var/lib/aide is not a directory owned and writable by root alone` | `sudo chown root:root /var/lib/aide` or purge aide-common, then run `--host-baseline` again. |
| `The host baseline was not made (see above)` | Fix the cause and run `sudo ./setup-node.sh --host-baseline`. |
| `The node command has no --http, so the runner cannot read the local RPC` | Add `--http` with `edit-config.sh` and enable again; nothing was changed. |
| `No target accepted the test heartbeat; private alerts were not enabled` (or `the previous targets were put back`) | Check the URLs and run it again. |
| `--target puts the URL on the command line, where other local users can read it` | Pipe the targets in with `--targets-stdin`. |
| `http needs --allow-http (the token travels in clear text)` | Use the monitor's `https://` URL, or pass `--allow-http` for a monitor on a network you trust. |
| `healthchecks: a query string or fragment is not allowed` | Paste the check's ping URL without its `?` or `#` part. |
| `Refused: --inactive-after must be a whole number of seconds from <N> (the stall time) to 86400` (or the `--stall-after` and `--interval` range forms) | Give a value in range; with a new `--stall-after`, give `--inactive-after` too. Nothing was changed. |
| `The new targets are in place, but the new settings were not fully applied` (exit 3) | Run `setup-alerts.sh --refresh` again with the same `--interval`, `--stall-after`, `--inactive-after` and `--label`. |
| `Pause or delete this node's monitor: a push monitor alerts on silence.` | After a disable or a removal, pause or delete the node's monitor. |
| `The heartbeat runner or its library changed. Reinstall them on the host:` | Run the `setup-alerts.sh --refresh` line it prints. |
| `--admission needs node release 0.17.0 or later, and this run installs <release>` (setup), `the admission settings need node release 0.17.0 or later` (edit-config) | Install or update to a release that reads the settings, or leave them out. |
| `Admission closed without --trusted-nodes: the node admits only the previous, current and next committees and the bootstrap peers.` | On mainnet, give the hubs (`--trusted-nodes`, or `--set trusted_nodes=`). |
| `<file> is not a trusted nodes map: <reason>.` | Fix the line the reason names; nothing was written. |
| `trusted_nodes needs an admission mode, which goes into network-config with it` | Set `admission` first. |
| `The admission settings were not written to <data dir>/network-config: <reason>` | `network-config` is unchanged; fix the line the reason names, or the map file. |
| `restarted by itself within <n>s of the restart (NRestarts <a> to <b>): it exited` | The node refused the edit and it was rolled back; `journalctl -u telcoin` says why. |
| `The P2P committee allowlist needs /usr/sbin/nft (the path tn-p2p-allow-sync runs)` | `sudo apt-get install nftables`, then `--p2p-committee on` again. Nothing was changed. |
| `P2P committee mode was not turned on: this node release lacks tn_admissionSnapshot, or tn is not in its --http.api; update the node or add tn to --http.api. Nothing was changed.` | Update the node to a release that serves the snapshot, or put `tn` back in the node's `--http.api`. |
| `P2P committee mode was not turned on: the admission snapshot of the node is not authoritative (<token>). Nothing was changed.` | Often right after a restart: wait a few minutes and run `--p2p-committee on` again. |
| `P2P_ALLOW_FROM in .node-meta lists <entry>, an unspecified, multicast or link-local address that is never a peer's source` | Pass `--p2p-from` again without that entry. |
| `P2P committee mode is on, but nftables has no table inet tn_p2p_allow: P2P is open to every source.` (check-node) | `sudo bash firewall-setup.sh --p2p-committee sync`. |
| `P2P committee allowlist lacks <N> address(es) of the current committee` (check-node) | `--p2p-committee sync`. |
| `P2P committee allowlist is stale: no good sync for <age>` (check-node) | Read `journalctl -t tn-p2p-allow -n 20`, fix the cause, then `--p2p-committee sync`. |

## Left open

Each tracker stays open with what is left on it, except #60, which this release closes;
`followup.md` lists the smaller items.

- #30, #31: the main-branch ruleset is a user step (the ruleset JSON in #30 lists eight of the ten
  guarded contexts; with three owners on every line it can require code-owner review).
- #32: `keytool verify` arrives with telcoin-network #1730 (U-8); setup-node does not yet check a
  kept credential against the key.
- #33: the "am I signing" RPC method (telcoin-network #1731, U-9) replaces the post-update
  inference from `tn_nodeMode` and an advancing consensus header.
- #35: per-node ingest tokens need the hub to check a token list; today one token serves every
  operator.
- #39: UI helper as templated root oneshots and a sandboxed UI unit (its own pull request).
- #40: 2-of-N release signatures wait for a second release key; then `TN_SIG_THRESHOLD` rises in
  the three verifiers. The release key expires 2028-10-16, so the extended key must ship in a
  script release before then.
- #41: the P2P committee allowlist replaces the signed address manifest for validators; this release pins `tn-p2p-allow-sync` v0.1.0 (`TN_P2P_ALLOW_TARBALL_SHA256`).
  Its first CI run after the pin confirms the counters across reloads on the runner kernel, the sync unit's sandbox on systemd 255 and the boot unit's first load (`ProtectKernelModules=`).
  Still open: a validator that sends from an address its record does not carry (the static list is the mitigation), the genesis `committee.yaml` that feeds the floor on a node without a peers file (writable by the service user), the x86_64-only release and the pace of a release-key rotation, and a resync after a `setup-node.sh` re-run; provider-edge ACLs, `notrack` and the `DOCKER-USER` block stay separate items.
- #43: disk encryption and process memory hygiene; nothing runs `aide --check` on a schedule.
- #44: reproducible builds.
- #45, #46, #51: the mainnet chain-config pins and `MIN_SOURCE_VERSION_MAINNET` (set with the
  switch), the image pipeline that publishes each channel to its package (the scheme was
  confirmed on 2026-11-04; telcoin-network draft PR #1784, #1728, U-6), and the final mainnet
  artifacts (telcoin-network #1735, U-13).
- #49: nothing is left on it in this repository: mainnet's 6-hour epoch is confirmed and the
  restart margins stay derived from the epoch length.
- Private alerts (#60, closed by this release): three follow-ups are `followup.md` items, namely
  a private alerts card in the Node Manager UI, retiring the Association's pull monitor once its
  Uptime Kuma takes pushes, and a maintenance marker that a planned update or restart writes, so
  the heartbeat reports it as up instead of a short down.
- Node admission settings: `MIN_ADMISSION_VERSION` (0.17.0) waits for the node team to name the first release that reads them.
  `committee_peers` comes from the bootstrap peers map, the right source only when that map lists the committee.
  A node-side check of the trusted nodes map would replace edit-config's shape check (block YAML only, where setup takes any map).
  The Node Manager UI, check-node and update-node do not handle the settings yet, and whether 60 seconds of watching suits every node is open.
