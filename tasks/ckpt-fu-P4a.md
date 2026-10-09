status: done

# Checkpoint: package P4a (setup-node.sh 1.3.0, part a)

Owned file: `setup-node.sh` (`SCRIPT_VERSION` 1.3.0). No other repo file was edited. Tests live in
the scratchpad under `p4a-tests/` (`mk.sh`, `runner.sh`, `t_p4a.sh`, `shims/`, `fakebin/`).

## Sections

- [x] 1. Hard guard after `source lib/common.sh`; `setup_fail`; EXIT trap with exactly one `done`; unknown flags warn on stderr
      (B.1 snippet verbatim; main pre-scans `--json`, swaps fds and installs `json_on_exit` before parsing,
      in both modes (no-op in human mode); `json_event error` records `JSON_LAST_ERROR`, which the trap
      reuses as the done msg; `missing_option_value` removed, a value starting with `-` counts as missing;
      every JSON-reachable `print_error …; exit 1` pair is now `setup_fail`; `setup_fail` sends nothing
      more once a done has gone out)
- [x] 2. URL and IP validation in `init_public_rpc_flags`; invalid `--public-ip` dropped with a warning
      (warnings are collected in `RPC_INPUT_WARNINGS` and printed by `public_rpc_url_warnings`, so the
      interactive `clear` in step_welcome cannot wipe them; a `.local`/`.localhost`/`.internal` domain
      warns too; the header documents the URL rules)
- [x] 3. Version floor (`tn_ref_min_check`) on `--build-ref`, the interactive ref and `--docker-image`, before `check_root`
      (`check_release_floor`; `json_check_install_flags` runs in run_json_mode after json_set_network and
      before check_root, and also refuses an unknown `--install-method`, a keygen without one, a
      malformed `--docker-image`, and a source keygen without `--build-ref`; interactive: the picked or
      typed ref and the typed/default image are checked; a JSON auto-detected image is checked in
      _preflight_docker)
- [x] 4. Install method inputs: `--binary-path`; `DOCKER_IMAGE`/`BINARY_PATH` saved at keygen, read back at finalize; missing → `setup_fail`
      (`init_install_flags`: absolute; implies existing in `--json` mode; ignored with a warning for
      source/docker; `_preflight_existing` uses it, and a `--json` run with no path and nothing found now
      fails clearly instead of dying on a `read` at EOF; `check_binary_path`; keygen records
      INSTALL_METHOD + DOCKER_IMAGE or BINARY_PATH; `finalize_install_inputs` reads INSTALL_METHOD,
      DOCKER_IMAGE and BINARY_PATH back; docker wrapper guard; the source re-derivation no longer applies
      to existing)
- [x] 5. `.node-meta` through `meta_set`/`meta_unset`; `NODE_TYPE` gone; `done` payload (`operator_guide`, `public_rpc`); keytool probe via `tn_keytool_has`
      (`write_node_meta` / `write_node_meta_runner`; BINARY_PATH unset for docker; `public_rpc_json`;
      probe rc 4 gets its own warning wording, same fallback)
- [x] 6. Summary: real P2P ports from node-info, runbook URL; nothing parses `TN_HW_SUMMARY`
      (primary_port + every worker port, fallback P2P_PORT/WORKER_PORT; the firewall line uses them too;
      "Operator runbook:" line; "Full guide" relabelled "Staking guide"; TN_HW_SUMMARY is only passed
      through as the `hardware:` log line)
- [x] 7. Seams for P4b: `init_node_extra_flags`, `prepare_node_extra_flags`
      (`init_node_extra_flags` in main after parsing, both modes, before check_root;
      `prepare_node_extra_flags` in step_create_service once BINARY_PATH is final and before either
      wrapper is written; it sets the global `NODE_EXTRA_FLAGS`, which `node_launch_flags METHOD` appends
      to `tn_node_launch_flags METHOD` in all four heredocs; empty → wrappers byte-identical apart from
      the version comment)
- [x] 8. Tests: 701/701 under `/bin/bash` 3.2.57 and under bash 5.3.15 (below)
- [x] 9. Closing headings

## Operator-visible changes

- `--json` runs (the Node Manager UI) check their input before `check_root` and stop with an `error`
  event and one `done` whose `msg` is the reason: a flag with no value (also when the next word is
  another option), an unknown `--phase`, `--network` or `--install-method`, a keygen without
  `--install-method`, a source keygen without `--build-ref`, a malformed URL flag, a malformed
  `--docker-image`, a relative `--binary-path`, and on testnet a `--build-ref` or `--docker-image` tag
  older than v0.13.0-adiri. `main`, a commit or an image digest is allowed with a warning.
- Failures inside the steps (systemd too old, docker pull, key generation, chain configs missing, the
  service not starting, existing keys) now carry their message in the `error` and `done` events instead
  of `done` "setup exited early (rc=1)". Every `--json` run prints only JSON on stdout and ends with
  exactly one `done`.
- Unknown arguments are reported on stderr ("Unknown argument: X"); they used to be ignored silently.
- `--rpc-http` and `--public-rpc-url` must be `http(s)://` URLs, `--rpc-ws` and `--public-ws-url`
  `ws(s)://` ones; a URL on a private address or name, or a `.local`/`.internal` `--rpc-domain`,
  warns that wallets on the internet cannot reach it. An invalid `--public-ip` is ignored with a
  warning and is no longer written to `.node-meta`.
- Interactive: a picked or typed source ref older than v0.13.0-adiri stops setup before checkout (main
  and commits warn); the typed docker image is held to the same floor.
- New `--binary-path PATH` for `--install-method existing` (in `--json` mode it implies existing).
  Without it, a `--json` existing install still searches PATH, /usr/local/bin, /opt and /home, and
  fails clearly when nothing is found.
- Keygen records `INSTALL_METHOD` and `DOCKER_IMAGE` or `BINARY_PATH` in `.node-meta`, and finalize reads
  them back when its flags leave them out. A UI install whose image was auto-detected at keygen now
  finalizes with that image; under 1.2.1 that finalize died with "DOCKER_IMAGE: unbound variable" half
  way through writing the start wrapper.
- `.node-meta` is updated key by key, so keys other scripts keep there survive a re-run of setup;
  `NODE_TYPE` is removed; `BINARY_PATH` is new (removed again for docker installs).
- Finalize's `done` adds `operator_guide` (the OPERATOR.md URL) and `public_rpc`
  `{"enabled":bool,"domain":…,"http":…,"ws":…}`; `node_type` stays `"observer"`.
- The final summary shows the P2P ports node-info.yaml advertises (every worker), uses them in the
  firewall reminder, and links the operator runbook.
- When the keytool's `--help` cannot run at all, the keygen warning says so instead of claiming the
  release lacks `--rpc-http`.

## Changelog text

### setup-node v1.3.0 — input checks before root, release floor, finalize reads keygen's choices
setup-node now needs lib/common 1.6.0 and says so when the library is older ("Run update-scripts.sh
and try again"), as an error event in `--json` mode. `--json` runs check every input before
`check_root`: a flag with no value, an unknown phase, network or install method, a malformed
`--rpc-http`, `--rpc-ws`, `--public-rpc-url`, `--public-ws-url` or `--docker-image`, and on testnet a
`--build-ref` or image tag older than v0.13.0-adiri each stop the run with an `error` event and one
`done` that carries the reason. A ref that is not a release tag (`main`, a commit, an image digest)
warns and goes on. Interactive setup applies the same floor to the ref picked or typed for a source
build and to the docker image typed at the prompt. Failures later in setup now carry their message in
the `done` event too, every `--json` run ends with exactly one `done`, and unknown arguments are
reported on stderr instead of being ignored.

A URL flag on a private address or name (loopback, RFC 1918, `.local`, `.internal`) warns that
wallets on the internet cannot reach it; an invalid `--public-ip` is ignored with a warning.
`--binary-path PATH` names the binary of an `--install-method existing` install. Keygen records the
install method and the docker image or binary in `.node-meta`, and finalize reads them back when its
flags leave them out, so a UI install whose image was picked automatically at keygen finalizes with
that image instead of failing while it writes the start wrapper. `.node-meta` is now updated one key
at a time: keys that other scripts keep there survive a re-run, and the old `NODE_TYPE` hint is
removed. Finalize's `done` event adds `operator_guide` and `public_rpc`. The closing summary shows the
P2P ports `node-info.yaml` advertises and links the operator runbook.

## Tests run

Harness `<scratchpad>/p4a-tests/`: `mk.sh` builds four copies of setup-node.sh with the hard-coded
`/etc/systemd/system/`, `/home/<user>` and `/opt/telcoin-source` paths prefixed by `TN_ROOT_PREFIX`
(nothing else differs; `main "$@"` removed in `sut/` and `head/`): `sut/` (working tree), `sutfull/`
(run as a script), `sutold/` (beside `git show 1e2d2f1:lib/common.sh`, 1.5.0) and `head/` (HEAD). PATH
shims: docker (records argv; `run … telcoin keytool …` runs the real v0.15.0 binary with the
container data dir mapped back to the `-v` host path; `DOCKER_HELP=norpc` and `DOCKER_RUN_RC=125`
variants), systemctl, useradd, groupadd, usermod, getent, id, chown, ufw, curl (offline), sleep, git,
cargo, rustup, dpkg, df. Fake binaries `fakebin/norpc` (help without `--rpc-http`) and `fakebin/broken`
(`--help` exits 126), both otherwise the real v0.15.0 binary. `runner.sh` runs one case per process,
sourcing the copy at top level under the bash that runs the driver, with stubs for check_root (records
calls; `STOP_AT_ROOT=1` exits 3 there), hardware, internet, ports, user creation and RPC checks.

- `/bin/bash t_p4a.sh` (3.2.57): 701 passed, 0 failed. `bash t_p4a.sh` (5.3.15): 701 passed, 0 failed.
- Coverage: static (bash -n both, version 1.3.0, no `NODE_TYPE=` write or expansion, `TN_HW_SUMMARY`
  only passed through, no "CPUs", no `--observer`/`--validator`, guard text verbatim); hard guard with
  the 1.5.0 library in JSON (exactly error + done, rc 1, stderr empty) and human mode ([ERROR] on
  stderr, stdout empty), and with 1.6.0 reaching main in both modes; all 23 value flags missing as the
  last word (JSON and human) and followed by another option; `--rpc-domain ""` still legal; unknown
  arguments on stderr only; 12 malformed URL rows (error + done before check_root), 7 private rows
  (warning, run continues to check_root), a public row (no warning), a private domain, an invalid and a
  valid `--public-ip`, and the interactive ordering (init prints nothing; the warnings print later);
  the release floor: v0.11.0 and v0.12.0 refused before check_root (keygen and finalize), the v0.11.0
  image refused, v0.13.0/v0.15.0 and the v0.15.0 image pass silently, `main` and an image digest warn
  and pass, devnet has no floor, plus the unknown/missing install method, missing build ref, malformed
  image and unsupported network; interactive pick (v0.11.0 stops before checkout; v0.15.0 and main go
  on to checkout, main with a warning; no ref) and docker prompt (old image stops before the pull; Enter
  pulls the default); `--binary-path` relative, ignored for docker, implying existing (JSON only), a
  missing file, and existing with nothing found; full docker keygen + finalize with the real keytool
  (foreign keys, a value with `=`, a third-party key kept; `NODE_TYPE` and a stale `BINARY_PATH`
  removed; mode 600; each of 25 keys exactly once after finalize; image only in meta, no image, an
  empty image, the flag overriding meta, method read from meta, TPM wrapper); public_rpc private,
  pending, enabled (fake install-caddy.sh) and URL-only; full existing keygen with `--rpc-domain` (the
  probe finds `--rpc-http`, node-info advertises the derived URLs) and finalize with `--binary-path`,
  from meta, TPM, none (error), a missing file (error), source from meta and re-derived; the probe rc 0
  (v0.15.0, tn-4), 1 (norpc binary, norpc image), 4 (broken binary, missing binary, docker failing)
  and keygen's two warning wordings; the summary with real node-info ports (41000/41004), two workers
  (plural label), the legacy `worker:` map and no file (constants); a UI-shaped keygen + finalize with
  the image left blank; an interactive docker install end to end through main with piped answers;
  the EXIT trap after a `set -e` death (generic msg), reusing the last error, silent in human mode, and
  `setup_fail` after a done. Every JSON run: each stdout line passes `jq -e .`, exactly one done, last.
- Every rendered wrapper (docker and binary, LoadCredential and TPM) passes `/bin/bash -n` and `bash -n`.
  Docker and binary wrappers and units are byte-identical to HEAD's apart from the version comment.
- The UI-shaped finalize under HEAD dies with `DOCKER_IMAGE: unbound variable` while writing the
  wrapper (a truncated start-telcoin.sh, done "setup exited early"); 1.3.0 runs the recorded image.
- `/bin/bash -n setup-node.sh`, `bash -n setup-node.sh`: clean. `shellcheck -x --severity=error
  setup-node.sh`: clean; at warning level only the SC2034 on `USE_LOAD_CREDENTIAL` that HEAD has.
  `/bin/bash tools/check-bash32.sh setup-node.sh`: clean. Added lines grepped for bash-4 constructs,
  apostrophes in `${…:-…}`, `local x="$(…)"`, line-number references and package names: none.

## Open issues

1. Release bookkeeping (orchestrator): `setup-node.sh.sha256` in the working tree was rewritten at
   21:32:53 by another package's `tools/gen-checksums.sh` run, from an in-progress copy of
   setup-node.sh; it does not match the final file. Regenerate at commit time. README changelog entry
   above; `update-scripts.sh` bump in the release commit.
2. Docs (README "setup-node flags", OPERATOR.md automation, partner guide if it covers `--json`): add
   `--binary-path <path>`; the `--install-method` row ("With `--json`, use `source` or `docker`;
   `existing` assumes the binary is already at /opt/telcoin/telcoin-network") is now: existing works
   with `--binary-path` (or the keygen search), and finalize reads the path back; the `--docker-image`
   row ("Pass it to both `--json` phases") can say finalize reads keygen's image back when it is left
   out; mention the URL checks, the ignored invalid `--public-ip`, and the v0.13.0-adiri floor for
   `--build-ref`/`--docker-image` on testnet. A finalize whose keygen ran under 1.2.1 has no recorded
   binary for `existing`, so it needs `--binary-path`.
3. UI (helper, server, page):
   - Finalize's `done` now has `operator_guide` (string) and `public_rpc` (`enabled` true only when
     setup finished the enable; `domain`, `http`, `ws` are `.node-meta` PUBLIC_RPC_DOMAIN,
     PUBLIC_RPC_URL, PUBLIC_WS_URL, so a derived URL has no trailing slash; null when unset). The
     completion card could link the runbook and show the public RPC state from it. `node_type` is still
     "observer"; keygen's `done` is unchanged.
   - Failure `done` events now carry the reason in `msg`, which the existing toast shows.
   - The helper never sends `--binary-path`, so an `existing` install from the wizard relies on the
     keygen search. A path field would map to `TN_SETUP_BINARY_PATH` → `--binary-path` (absolute path,
     safe charset).
   - Nothing else changes for the helper: it may keep passing `--docker-image` to both phases.
4. Listener multiaddrs are neither validated nor recorded for finalize: a finalize without
   `--listener-primary`/`--listener-worker` writes a wrapper with empty listener variables (as in 1.2.1;
   the UI always sends them). They could be recorded at keygen and read back like the install inputs.
5. Lesson for `tasks/lessons.md` (not my file): under `set -e`, macOS `/bin/bash` 3.2 exits on
   `source MISSING_FILE` even with `|| true`; bash 5 continues. Guard with `[[ -f F ]] && source F`.
   setup-node's two `~/.cargo/env` lines are now guarded as update-node's already were;
   `update-scripts.sh` has `source "${SCRIPT_DIR}/lib/fallback.sh" 2>/dev/null || true` near the top,
   worth checking under 3.2. Also for harness writers: `_preflight_source` prepends `~/.cargo/bin` to
   PATH, ahead of any shim, so a test of it needs `HOME` pointed at a sandbox.
6. Cosmetic: `init_install_flags`'s "--binary-path is used only with --install-method existing"
   warning prints before step_welcome's `clear` in human mode. It is reachable only when
   `--install-method` is also passed interactively, where the menu overrides it anyway.
7. For P4b: `init_node_extra_flags` runs in main after parsing (both modes, before check_root);
   `prepare_node_extra_flags` runs in step_create_service after BINARY_PATH is final and before either
   wrapper is written, so `tn_node_has_flag "docker:${DOCKER_IMAGE}"` or `"binary:${BINARY_PATH}"` works
   there. Set `NODE_EXTRA_FLAGS` to the flag text (for example `--bootstrap-peers "$(cat
   /etc/telcoin/bootstrap-peers.yaml)"`); `node_launch_flags` appends it in all four heredocs, and
   heredoc expansion keeps the `$(cat …)` literal in the wrapper. Persist with `write_node_meta
   "KEY=VAL"`. To let a finalize see keygen-time values, record them at keygen and read them back the way
   `finalize_install_inputs` does.
