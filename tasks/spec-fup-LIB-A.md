# LIB-A: mainnet refusals (issues #45, #46, #51)

Read `tasks/spec-fup-shared.md` first. Worktree `~/coding/telcoin/tnd-fup-LIB-A`, branch
`fup/LIB-A`, checkpoint `tasks/ckpt-fup-LIB-A.md`.

## Goal

Mainnet selection, release floor and image digests fail closed in one place, so flipping one
library constant at launch is the whole enablement, and nothing on the JSON, helper or
interactive paths lets a mainnet install through before that.

## Owned files

`lib/common.sh` (only: the new `TN_MAINNET_ENABLED` constant and `tn_mainnet_enabled`, the
`select_network` function, `tn_docker_resolve_ref`'s digest arm), `setup-node.sh`
(`json_set_network` and its interactive counterpart only), `update-node.sh` and
`edit-config.sh` (floor call sites only), `ui/telcoin-ui-helper.sh` (`cmd_setup` only),
tests `tools/tests/network_detect_test.sh`, `tools/tests/source_ref_test.sh`,
`tools/tests/docker_image_test.sh`, `ui/tests/helper_test.sh` (setup cases only).
LIB-B edits `check_internet` and `tn_wait_restart_window` in lib/common.sh and
`_setup_image_example` in setup-node.sh at the same time; AUDIT adds `tn_host_baseline_*`
and a setup-node flag. Touch nothing near those.

## Facts (main 1187ddb)

- lib/common.sh: `MAINNET_*` constants :26-29; `MIN_SOURCE_VERSION_MAINNET=""` :83 (stays
  empty: the user sets it at launch); `tn_ref_min_check` :1973 (rc 0/1/2, message on stdout
  when rc is not 0; empty floor = rc 0); `select_network` :2630 (option 2 prints "Mainnet has
  not launched yet." and loops); `tn_docker_resolve_ref` :7305 (a `<repo>@sha256:<digest>` of
  an allowed repository is taken as given; `tn_docker_recorded_tag IMAGE` :7349 prints the
  `RELEASE_TAG` from `.node-meta` when `DOCKER_IMAGE_DIGEST` there names the digest, rc 1
  otherwise); `TN_MAINNET_IMAGE_REPO="$TN_GHCR_IMAGE_REPO"` :6286, so a testnet image digest
  passes `tn_docker_repo_ok mainnet`. `tn_release_tag_ok NETWORK TAG` accepts mainnet `vX.Y.Z`.
- setup-node.sh: `json_set_network` :2932 sets the mainnet values for `mainnet`; the only
  `tn_ref_min_check` caller in the tree is setup-node.sh:1689.
- update-node.sh: `prepare_docker_update` :1581, `prepare_source_build` :1971,
  `prepare_release_update` :1995, `pick_release_version` :2316, `json_prepare_source` :2897,
  `json_prepare_release` :2909, `json_prepare_docker` :2926: none calls `tn_ref_min_check`.
- edit-config.sh: `edit_docker_image` :2329 (interactive, resolves at :2382) and the `--json`
  image path at :1385: neither calls `tn_ref_min_check`.
- ui/telcoin-ui-helper.sh: `cmd_setup` :1480 (`net_rule=mainnet` :1520) runs setup-node with
  `--network mainnet`; the helper reaches the library through `_lib_call FN ARGS…` (the
  root-owned engine copy `HELPER_LIB=/opt/telcoin-ui-update/lib/common.sh` :137; rc 127 when
  the function is absent, see `node_network` :507).
- ui/server.py has its own `TN_MAINNET_ENABLED = False` (:2856); UI-S ties it to the library
  constant by a test. You do not touch ui/server.py.

## Required behaviour

1. `readonly TN_MAINNET_ENABLED=0` next to the `MAINNET_*` constants, with a comment that
   says what flipping it to 1 enables (interactive option 2, `--network mainnet` in JSON and
   helper runs) and that it is flipped together with the genesis pins and
   `MIN_SOURCE_VERSION_MAINNET` at launch. Add `tn_mainnet_enabled()` (rc 0 when the constant
   is 1) beside it so scripts and the helper ask one function.
2. `select_network`: option 2 sets `NETWORK=mainnet` and the four mainnet values and breaks
   when `tn_mainnet_enabled`; otherwise today's three lines and the Enter prompt, unchanged.
   The menu line says "(coming soon)" only while disabled.
3. `json_set_network mainnet` (setup-node.sh) fails via `setup_fail` while disabled, message:
   "Mainnet is not enabled in this script release (lib/common.sh TN_MAINNET_ENABLED); nothing
   on this host was changed." Any other setup-node path that accepts `--network mainnet`
   before `json_set_network` (grep `--network`) gets the same refusal before any side effect.
4. `cmd_setup` (helper): after `net_rule=mainnet` is decided, `_lib_call tn_mainnet_enabled`
   must succeed, else `die` with a message that names the library constant; rc 127 (older
   engine library without the function) counts as disabled.
5. Release floor on every path that installs or switches a release: update-node's three
   interactive prepare functions and the three `json_prepare_*` functions, edit-config's
   `edit_docker_image` and its `--json` path call `tn_ref_min_check "$ref" "$NETWORK"` before
   any download or write: rc 1 stops with the message (interactive `print_error` + return/
   exit as the surrounding code does; JSON `json_fail`), rc 2 prints the message as a warning
   and continues, rc 0 is silent. Keep the call where the ref is final (after the tag is
   picked, before resolution). On mainnet the floor is empty today, so rc 0: the stub test
   below proves the wiring.
6. `tn_docker_resolve_ref mainnet <repo>@sha256:<digest>`: refused (rc 1, reason on stderr:
   "on mainnet an image is named by its release tag, so the digest comes from the signed
   release; <digest> is not the image of a mainnet release this node has installed") unless
   `tn_docker_recorded_tag` returns a tag `tn_release_tag_ok mainnet` accepts. Testnet and
   devnet digests keep today's behaviour exactly (the warning about downgrade checks stays).

## Tests

- `network_detect_test.sh`: `select_network` with "2" on stdin loops to the Enter prompt and
  then "1" gives testnet while disabled; with the constant patched to 1 (the test sources a
  sed-patched copy of lib/common.sh into a temp dir: see how `lib_skew_test.sh` or
  `tn_test_source_common` load the library, never a test hook in production code) "2" gives
  `NETWORK=mainnet`, `CHAIN_ID=487`, `RPC_URL=https://rpc.telcoin.network`.
  `json_set_network mainnet` fails closed with the message; patched copy: sets the values.
- `source_ref_test.sh`: with a patched `MIN_SOURCE_VERSION_MAINNET="1.0.0"`, each of the
  eight call sites refuses `v0.9.0` on mainnet (stub the download/resolve functions so the
  test proves the order: refusal before any fetch) and accepts `v1.0.0`; testnet floor
  unchanged (`v0.12.0-adiri` refused, `v0.13.0-adiri` accepted) at every site.
- `docker_image_test.sh`: mainnet digest refused without a recorded tag; accepted when
  `.node-meta` records `RELEASE_TAG=v1.0.0` with that digest; testnet digest unchanged.
- `ui/tests/helper_test.sh`: `setup` with network mainnet dies with the constant named while
  the stub library's `tn_mainnet_enabled` returns 1, and with rc 127 (function absent).

Run the four fixtures under bash 5.3 and `bash:3.2`; `bash -n` both; `tools/check-bash32.sh`
and shellcheck (0.9 + 0.11, `--severity=error`) on every touched file.

## Docs notes to hand over (in the checkpoint)

The constant and what flips it; the three refusal messages verbatim; the floor now applies on
update and edit paths (today setup only); the mainnet digest rule.

## Not in scope

`MIN_SOURCE_VERSION_MAINNET` value, genesis hashes, `TN_MAINNET_ENABLED` in ui/server.py (UI-S),
check-node, docs.
