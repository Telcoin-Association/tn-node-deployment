status: done (all sections complete; report handed back)

# V-CORE-1 checkpoint — independent verifier for setup-node 1.3.0 / edit-config 1.3.0

On start: read this file and continue from the first unfinished section.
Harness: <scratchpad>/vcore1-tests/ — `bash mk.sh` rebuilds cur/ base/ old/ + shims from the working tree;
tests t1_sn_contract.sh, t2a_wrappers.sh, t2b_flows.sh, t3_ec.sh (each runs both bashes; prints FAIL lines + summary).

## Sections
- [x] 0. Read specs (shared, core B.1/B.4/B.5), lessons, setup-node.sh, edit-config.sh, lib parts
- [x] 1. Harness: vcore1-tests/ (shims, path-rewritten copies cur/ base(7fb7c8d)/ old(1e2d2f1 lib))
- [x] 2. setup-node JSON contract (t1)
- [x] 3. setup-node behaviour (t2a, t2b, summary ports)
- [x] 4. edit-config contract and behaviour (t3 570/570, t4 75/78 + t5 25/28 per bash; every fail a harness
      artefact: help reads "$0" (= driver when sourced), print_error goes to stderr, read -p prompt silent)
- [x] 5. Adversarial (t6 64/64 each): metachar/space values refused pre-check_root (setup-node) and with files
      untouched (edit-config); symlink->file followed, symlink->dir and dir refused; read-only launch file -> rc 4
      "could not write", byte-identical; CRLF DATA_DIR tolerated (detect_data_dir falls back).
- [x] 6. Static: /bin/bash -n + bash5 -n both clean; check-bash32 clean (2 scanned); shellcheck -x --severity=error
      clean both; --observer/--validator only edit-config's accept-and-ignore parser case + comments, none emitted
      to the node; only common/ ref is the maintainer-only provenance comment in setup-node (AGENTS.md-sanctioned);
      every JSON-path exit routes through setup_fail / the inline hard-guard done / the EXIT trap (trap installed
      before arg parsing in both). source lines guarded with [[ -f ]] (bash-3.2 safe).
- [x] 7. Cross-check implementer tests: P4a 700/701 each bash (the 1 fail fz-new-bin2 is the stale-HEAD-baseline
      artefact from lessons.md: baseline box primed with the v0.15 abs path vs source-build re-derived path; the
      --http/--ws flags are byte-identical; my t2a pins 7fb7c8d and confirms correctness). P4b 419/419 each.
      P5 527/527 each.
- [x] 8. Prose: new help/warning/error text is plain, specific, accurate (NODE FLAGS help block exemplary).
      Only nit: setup-node install-time error blames "--bootstrap-peers" when the real fault is a CONFIG_DIR with
      spaces/shell chars (F-i, note).
- [x] 9. Report (below + SubagentHandback)
- [x] X. Coordinator asks (2026-10-02): reran on lib 8185d00. (a) CONFIRMED F-e; (b) CONFIRMED F-f.

## Harness notes
- Root paths are readonly constants in lib/common.sh (DEFAULT_*), no env override; lib/fallback.sh
  honours TN_ROOT_PREFIX but tn_node_launch_target (common.sh) uses DEFAULT_INSTALL_DIR and
  /etc/systemd/system directly. So tests run on path-rewritten copies (literal fake root).
- Fixtures: fx/keys1, fx/keys2 (real v0.15.0 keytool), fx/peers.yaml (valid map, 2 real BLS keys),
  fx/badkey.yaml, fx/notyaml.yaml. v0.15.0 rejects `--bootstrap-peers ''` (rc 2).
- flock: python fcntl shim (shims-flock/), real flock semantics on the inherited fd 9.

## Results so far (lib before 8185d00)
- t1_sn_contract.sh: 202/202 under each bash (pre-check_root failures, help, unknown flag, hard guard, non-root).
- t2a_wrappers.sh: 100/100 each (4 wrapper variants: identical to 7fb7c8d but the version line; unit identical;
  bash -n; literal flag; no map inline; map reaches docker/binary as one argv word byte for byte; +healthcheck).
- t2b_flows.sh: 87/88 each; the one fail is a harness bug (calls log truncated at 200 chars), order verified by eye.
  Foreign keys survive, NODE_TYPE removed, image/binary/peers/state export recorded and read back by a bare
  finalize; no image / no binary refused; tn-4 refuses peers/keep before keygen; clap reason surfaced; UI-shaped run ok.
- Summary ports read from node-info (single, two workers, legacy worker: map, missing file -> configured ports).
- t3_ec.sh: 570/570 each — every --set field on docker wrapper, binary wrapper, legacy unit; wait before restart;
  no-op edits do not restart; bootstrap_peers refused on the legacy unit; apft refused at 2017/487, ok at 32285.

## Final test totals (lib 8185d00, both /bin/bash 3.2.57 and bash 5.3.15)
t1 202/202 · t2a 100/100 · t2b 87/88 (1 harness) · t3 570/570 · t4 75/78 (3 harness) · t5 25/28 (3 harness) · t6 64/64.
Implementer: P4a 700/701 (fz-new-bin2 known-stale), P4b 419/419, P5 527/527. All "fails" explained above/below.

## Findings (final)
- F-a (warn) setup-node non-root --json: done msg "setup exited early (rc=1) -- see server logs / journalctl",
  no error event; edit-config reports "must run as root" (edit_require_root). Suggest the same in run_json_mode.
- F-b (note) summary firewall hint with two workers reads "UDP 49590 and 49594, 49600".
- F-c (warn) edit-config allow_private_forward_targets=false with the key absent writes the key and restarts
  (effective value unchanged). Compare with "${current:-false}".
- F-d (note) metrics/state_export add-then-remove leaves the wrapper line without its trailing space (cosmetic).
- F-e (warn, coordinator claim a CONFIRMED) setup-node install_bootstrap_peers -> bootstrap_peers_reason runs the
  binary a 2nd time and prints clap's raw reason, preferred over the library's redacted msg: fx/b58.yaml gives
  `invalid value: string "SECRET0lO", expected ...` from setup-node vs `string "…"` from edit-config. Not UI-reachable
  today (helper cmd_setup passes no --bootstrap-peers). Fix: delete bootstrap_peers_reason, use $msg.
- F-f (error for edit-config / warn for setup-node, claim b CONFIRMED) the probe gets the whole map as argv: a 0600
  source shows in docker/binary argv (setup-node 2 probes, edit-config 1). UI helper allows any absolute path for
  bootstrap_peers, so a UI-side caller can put a root-only file on the process list. Fix: refuse a source others
  cannot read (stat -L mode o+r; it ends up 0644 + in the node's argv anyway); optionally narrow the helper regex.
- Verified OK: lock refusal flock (python fcntl holder) + mkdir (live PID), stale mkdir takeover + release at exit;
  rollback restores launch/unit/params/peers byte for byte (mode too), removes a new peers file; one WAIT before the
  first restart, none on rollback; --no-epoch-wait and TN_SKIP_EPOCH_WAIT=1; hard guard both modes; refresh refusals
  (no NETWORK, bogus NETWORK, id mismatch, unreadable genesis) and match (WAIT then restart); menu 1-13, docs'
  "option 5" still BLS passphrase.
- F-g (note) edit-config --help reads "$0" (setup-node uses BASH_SOURCE); wrong text when sourced.
- F-h (note) two live node --http lines in one launch file: edit silently patches the FIRST and restarts; the
  second is left stale. A real install has one; a hand-corrupted file gets a partial edit, not a refusal.
