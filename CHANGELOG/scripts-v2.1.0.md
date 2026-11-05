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
--check` reports it. Nothing read from a testnet endpoint is used on another network.

It closes #47. #34, the documentation reconciliation, closed after scripts-v2.0.0 merged; the
nine wording findings a re-read found afterwards are fixed here. The other issues named below stay open as trackers; the last
section says what is left on each.

| Component | Version |
|---|---|
| update-scripts | 2.1.0 |
| setup-node, update-node, edit-config, check-node | 2.1.0 |
| install-caddy, firewall-setup, setup-vpn, setup-observability | 2.1.0 |
| remove-node | 2.1.0 |
| migrate-node-naming, prepare-stake | 2.0.0 (unchanged) |
| lib/common (`COMMON_VERSION`) | 2.1.0 |
| lib/fallback (`FALLBACK_VERSION`) | 1.1.0 (unchanged) |
| lib/observability (`OBSERVABILITY_VERSION`) | 2.1.0 (`observability/config.alloy` changed) |
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

### lib/common 2.1.0

The library carries most of the above: the mainnet switch, the floor and digest rules, the epoch
derivation, the connectivity probe and the host baseline functions (`tn_host_baseline_install`,
the refresh and the status lines in `tn_host_audit`). `tn_keytool_has` reports "not listed" only
when the node's own usage text says so; a wrapper that fails (busybox `setpriv`, a docker error)
counts as a probe that could not run. Its setup prompts call the ingest token the hub's token
from the Association, not a per-operator one (#34).

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
full setup is a warning and setup goes on. update-node, edit-config and the four add-ons make the
baseline again after their own changes, so those do not show up as differences. A
`/var/lib/aide` that root alone does not own (aide-common makes it `_aide:root`) is refused.

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

## New environment variables

| Variable | Default | Effect |
|---|---|---|
| `TN_P2P_NEW_FLOW_RATE` | 20 | Packets of new, not yet answered P2P flows per minute from one source (firewall-setup, one run) |
| `TN_P2P_NEW_FLOW_BURST` | 40 | Such packets one source may send before the rate applies |
| `TN_EPOCH_MARGIN`, `TN_EPOCH_SETTLE` | derived from the epoch length | Existing names; unset, they now follow the epoch length |

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

## Left open

Each tracker stays open with what is left on it; `followup.md` lists the smaller items.

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
- #41: the optional committee allowlist waits for the Association's signed address-manifest
  format; a format proposal was posted in the issue on 2026-11-04.
- #43: disk encryption and process memory hygiene; nothing runs `aide --check` on a schedule.
- #44: reproducible builds.
- #45, #46, #51: the mainnet chain-config pins and `MIN_SOURCE_VERSION_MAINNET` (set with the
  switch), the image pipeline that publishes each channel to its package (the scheme was
  confirmed on 2026-11-04; telcoin-network draft PR #1784, #1728, U-6), and the final mainnet
  artifacts (telcoin-network #1735, U-13).
- #49: nothing is left on it in this repository: mainnet's 6-hour epoch is confirmed and the
  restart margins stay derived from the epoch length.
