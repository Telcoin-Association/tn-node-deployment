status: done

## Sections
- [x] 1+2. lib/common: TN_MAINNET_ENABLED + tn_mainnet_enabled; select_network option 2 gated;
      setup-node json_set_network refusal; network_detect_test block (773ca02)
- [x] 3. (in 773ca02: json_set_network is the only setup-node path that takes --network; the
      interactive counterpart is the library's select_network)
- [x] 4. ui helper: cmd_setup refuses mainnet unless tn_mainnet_enabled (+ helper_test) (4c668d3)
- [x] 5. update-node + edit-config: floor at the eight entry points (+ source_ref_test) (415cfab)
- [x] 6. lib/common: tn_docker_resolve_ref mainnet digest refusal (+ docker_image_test) (caf82f5)
- [x] 6b. tests: setup_passphrase_test (unowned; broken by the gate) runs its mainnet cases with
      tn_mainnet_enabled stood in (33e79eb)
- [x] 7. Gates (all green, see Tests run)

## Operator-visible changes
- Interactive menu (setup-node): option 2 still says "(coming soon)" and loops with "Mainnet has
  not launched yet." while TN_MAINNET_ENABLED=0; at 1 it selects mainnet (chain 487,
  https://rpc.telcoin.network) and the "(coming soon)" text goes.
- setup-node --json --network mainnet: refused by json_set_network before the install flags,
  the root check or the lock (nothing on the host written).
- Node Manager UI helper setup-keygen / setup-finalize on mainnet: refused while the engine
  library says mainnet is not enabled, or has no tn_mainnet_enabled (older library).
- update-node prepare (source, release, Docker; interactive and --json) and edit-config Docker
  image change (menu and --json docker_image): a target below the network's oldest supported
  release is refused before any fetch. Until now only setup-node applied the floor.
- tn_docker_resolve_ref on mainnet: a digest given alone is refused unless .node-meta records a
  mainnet release tag for it (affects update-node and edit-config Docker paths on mainnet).

## Docs notes
- Constant: lib/common.sh `readonly TN_MAINNET_ENABLED=0` (next to MAINNET_*);
  `tn_mainnet_enabled` rc 0 only when it is 1. Flipping it to 1 enables: interactive option 2
  (select_network), `--network mainnet` in a setup-node --json run, and UI setups on mainnet
  (the helper asks tn_mainnet_enabled). Flipped at launch in the same release that pins the
  mainnet chain configs (tn_chain_config_pin) and sets MIN_SOURCE_VERSION_MAINNET.
- Refusal messages, verbatim:
  1. setup-node (--json, via setup_fail, error + done event):
     "Mainnet is not enabled in this script release (lib/common.sh TN_MAINNET_ENABLED); nothing on this host was changed."
  2. UI helper (die, stderr, audit "refused"):
     "mainnet is not enabled in this script release (TN_MAINNET_ENABLED in /opt/telcoin-ui-update/lib/common.sh); nothing was changed"
  3. tn_docker_resolve_ref on mainnet (print_warn, stderr):
     "Image refused: on mainnet an image is named by its release tag, so the digest comes from the signed release; sha256:<digest> is not the image of a mainnet release this node has installed. Give the mainnet release tag instead."
- Floor: tn_ref_min_check now applies on update-node prepare (all three install methods,
  interactive and --json) and edit-config's Docker image change (menu and --json), not only
  setup. Refusal = tn_ref_min_check's text ("<ref> is older than v<floor>, the oldest <network>
  release these scripts support (...). Pick v<floor> or a newer release.") plus " Nothing was
  changed." (update-node) or " The image is not changed." (edit-config); interactive [ERROR],
  --json error event. Docker: a release tag (alone or <repo>:<tag>) is checked as given; a
  digest alone by the RELEASE_TAG .node-meta records for that digest (none recorded: not
  checked, tn_docker_resolve_ref warns); a value that is not a release tag is left to the
  resolver, which refuses it. Floors: testnet 0.13.0; mainnet "" (none until launch).
- Mainnet digest rule: testnet and mainnet share ghcr.io/telcoin-association/telcoin-network,
  so on mainnet an image is named by its release tag (digest from the signed release); a bare
  digest is taken only when .node-meta has DOCKER_IMAGE_DIGEST=<that digest> and a mainnet
  RELEASE_TAG (vX.Y.Z). Testnet and devnet digests unchanged (taken with the warning).

## Tests run
- bash 5.3 (host) / bash 3.2 (bash:3.2 image):
  network_detect_test.sh 123/0 | 123/0; source_ref_test.sh 197/0 | 144/0 (2 SKIP: git, build
  account); docker_image_test.sh 233/0 | 233/0; setup_passphrase_test.sh 80/0 | 80/0;
  ui/tests/helper_test.sh 505/0 | 505/0.
- ubuntu:24.04 (root, bash 5.2): the four tools/tests fixtures 123/0, 159/0 (1 SKIP), 233/0, 80/0.
- New refusal checks fail against main: network_detect 11, source_ref 25, docker_image 8,
  helper 8 (run from a git-archive of HEAD~ with the new test copied in).
- Full suite `bash tools/tests/run.sh` (bash 5.3): 59 files, 0 failed.
- `bash tools/tests/run.sh root_write_pipe_test.sh passphrase_print_test.sh`: 2 files, 0 failed.
- bash -n (5.3 and 3.2), tools/check-bash32.sh, shellcheck 0.11.0 and koalaman 0.9.0
  `-x --severity=error`: clean on lib/common.sh setup-node.sh update-node.sh edit-config.sh
  ui/telcoin-ui-helper.sh and the five touched tests. check-perl-interp: clean (100 files).
- ui pytest (python:3.10-slim): 258 passed.

## Open issues
- tools/tests/setup_passphrase_test.sh is not in any package's list; the gate broke its four
  mainnet checks, so I changed it minimally (33e79eb). Orchestrator: confirm.
- setup-node.sh / update-node.sh / edit-config.sh tn_require_fns lists do not name
  tn_mainnet_enabled (setup-node) or tn_docker_recorded_tag (update-node, edit-config; it is in
  2.0.x libraries already). Not my lines (AUDIT edits nearby). An older library makes
  tn_mainnet_enabled rc 127, which refuses mainnet (fail closed). Suggested: add
  tn_mainnet_enabled to setup-node's list.
- Stale wording on mainnet after the digest rule (not in my owned lines):
  update-node.sh docker_resolve_target comment "a <repo>@sha256:<digest> reference is taken as
  given"; edit-config.sh set_docker_image --json refusal "give a ${net} release tag, or this
  network's image by digest" (on mainnet a bare digest is taken only for a recorded release).
- UI-S: ui/server.py TN_MAINNET_ENABLED tie-in test can match `readonly TN_MAINNET_ENABLED=0`.
