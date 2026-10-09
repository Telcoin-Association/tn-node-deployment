status: done

# DOC-4 checkpoint (CHANGELOG.md, AGENTS.md, followup.md)

On start, read this file and continue from the first unfinished section.

## Sections
1. [x] CHANGELOG.md Unreleased (areas + Security + Known remaining)
2. [x] AGENTS.md updates
3. [x] followup.md rewritten (remaining items only)
4. [x] Consistency pass
5. [x] Closing headings

## Notes gathered
- Open-issue extraction was delegated to four read-only opus agents; their per-file results are
  in the scratchpad
  (`/private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/`):
  `doc4-x1.md` (L1, L2, V-L, P3, V-CORE-2*), `doc4-x2.md` (P4a, P4b, P5, P6, V-CORE-1),
  `doc4-x3.md` (A, B, C, D, V-OPS-*), `doc4-x4.md` (UI-*, V-UI, UP, V-UP, DOC-1..3). Each has a
  "Resolved (not carried)" list for auditing the filtering.
- Every old followup.md item maps to work done in this round or to a carry-over; the
  "Superseded" section is dropped.
- HEAD at the end of this package: 1540751. setup-node.sh was being edited on disk by another fix
  pass during this package (see open issues).

## What changed per file

CHANGELOG.md
- New entry at the top of "## Unreleased": "Backlog round, October 2026 -- update-scripts
  v1.1.70", with `####` areas: Library; Setup and configuration; Updates and restarts; Public
  RPC; Health check; Firewall and add-ons; Staking helper; Node Manager UI; Updater and
  integrity; Maintainer tooling and CI; Docs; Security (7 bullets: launch-file metacharacter
  refusal; peers map never echoed and the world-readable rule; helper without the role argument
  and the visudo-last installer; check-node no longer evals RPC strings; updater fails closed and
  verifies its replacement; prepare-stake keeps the passphrase and keys off every command line;
  update lock released on SIGTERM with orphaned children); Known remaining (points at
  followup.md). Each area names the versions it ships in.
- One sentence added to the "Dynamic node role" superseded note: setup-node v1.3.0 and
  migrate-node-naming v1.2.1 remove NODE_TYPE; the UI asks the network first.

AGENTS.md
- Boundary list gains `edit-config.sh`, `prepare-stake.sh`, `install.sh` and the deprecated
  `setup-observer.sh` / `setup-validator.sh` shims (edit-config, install.sh and the shims were
  missing against the tree; the shims and edit-config are in the updater's SCRIPTS array).
- Node role: the UI asks the network first (public RPC with a matching chain ID, then the node,
  then the cached answer, else full node); `.node-meta` no longer carries NODE_TYPE (stale line
  possible after a 1.2.0 migration); `tn_resolve_node_type` is a deprecated stub, no new callers.
- New section "Restarts and the epoch boundary": `tn_wait_restart_window`, `TN_EPOCH_MARGIN`
  (300), `TN_EPOCH_SETTLE` (90), `TN_EPOCH_WAIT_MAX` (1800, 0 off), `TN_SKIP_EPOCH_WAIT=1`,
  `--no-epoch-wait`; wait first, then stop; rollbacks never wait; `TN_EXIT_TRAP_OWNED` with
  `tn_release_update_lock`.
- New section "Staking helper": prepare-stake.sh never sends a transaction or reads a private
  key; the passphrase reaches only the re-signing keytool call through its environment; keep it
  that way.
- Self-update and integrity: the updater fails closed, installs the library pair together and
  verifies its own replacement; the CI bullet names the parse check and the lint; step 3 runs the
  lint; new lint paragraph (what it flags in one sentence, both runners, `# bash32-ok`); the
  untracked list gains `tools/check-bash32.sh`, `ui/tests/`, `ui/dev/`, `ui/test_*.py`.
- Unchanged: the `config-caddy.sh` rule, the partner-guide section (it names no version), the
  vendored-files section.

followup.md
- Rewritten from scratch: header (what the file is; previous backlog cleared on 2026-10-02 in
  commits `7fb7c8d..HEAD`; CHANGELOG.md summarises the round; sources are packages or verifiers),
  then only open items, each with a "Why:" line and sources in parentheses.

## Carried-over items: 77
Security 5; Multiple workers 2; Setup and configuration 9; Updates, removal and migration 4;
Library 8; Public RPC 6; Health check 2; Firewall and observability 2; Staking helper 2; Node
Manager UI 14; Updater 4; Maintainer tooling and CI 6; Docs in this repo 6; Maintainer repos 2;
Upstream 5. All 25 items the orchestrator listed are in (KNOWN-24 worded as "not recorded" only,
see open issues); 52 are new from the checkpoints.

## Consistency checks run
- No line-number references in the three files; no `--observer`/`--validator` instruction (the
  only mentions are AGENTS.md's existing prohibitions); the only e-mail is support@telcoin.org;
  URLs are the canonical ones (`rpc.adiri.tel`, `rpc.telcoin.network`, `telscan.io`, the repo
  blob URL) plus the two status-page URLs that followup.md reports as inconsistent.
- No line over 100 characters in followup.md or AGENTS.md or the new CHANGELOG text; no em dash
  added; AI-vocabulary grep clean.
- Every file name AGENTS.md mentions exists; the updater arrays match the boundary list; docs,
  tools/ and the UI tests and dev runner carry no `.sha256` sidecar.

## Open issues
- update-scripts.sh still says `SCRIPT_VERSION="1.1.69"` while README.md and CHANGELOG.md say
  v1.1.70. REL must bump it and regenerate its sidecar before main is pushed, or nodes on 1.1.69
  never receive the fail-closed updater or prepare-stake.sh (flagged security by the extraction).
- setup-node.sh was mid-fix on disk during this package (port prompts through `prompt_port`;
  listener multiaddrs and `--address` validated in the JSON path). It is not described in
  CHANGELOG.md. When it lands, add a Security bullet (a pasted port answer can no longer reach the
  root-run start wrapper or `.node-meta`) and a phrase in "Setup and configuration". followup.md
  words the listener item as "not recorded at keygen" only; if the fix does not land, add back
  "not validated" there and the port-prompt injection under Security.
- Release steps kept out of followup.md: the partner PDF's links to `blob/main/prepare-stake.sh`
  and to the new README anchors resolve only after main is pushed (DOC-3); the tn-5 branch and
  devnet-genesis e732765 are unpushed (listed in followup.md as upstream / maintainer items).
- Not carried, because they could not be verified or the verifier closed them: V-UI's
  "setup-node.sh stale comment" note (detail only in V-UI's hand-back, not its checkpoint); V-UP
  round 2's optional wording note (verdict: no open findings); the wizard's `stepPreflight` race
  (unreachable from the page).
- Budget: over. The run counter reads about 300k tokens for this package, above the 200k asked;
  the four extraction agents used 143k to 167k each, above the 120k they were given.

## Follow-up (coordinator, after babb69d)

Source: the "Fix pass 2" section of `tasks/ckpt-fu-P4b.md` (setup-node validates every answer and
flag that reaches the start wrapper, the unit or `.node-meta`; version stays 1.3.0).

- [x] CHANGELOG.md "Setup and configuration": added "A `--json` keygen now requires `--address`."
      and rewrapped the paragraph's last four lines.
- [x] CHANGELOG.md "Security": new second bullet. Every interactive answer and `--json` flag that
      reaches the root-run start wrapper, the unit or `.node-meta` is validated (ports,
      directories, the Docker image, the binary path, the execution address, the listener
      addresses); a pasted value such as `9101;id` can no longer be written there, and a prompt
      asks again until its answer is valid (setup-node v1.3.0). Security now has 8 bullets.
- [x] followup.md: no item says the listener addresses are "not validated" (the item says only
      that keygen does not record them). Two Library items added from P4b's fix-pass-2 open
      issues: `validate_port` accepts leading zeros (`0101` read as octal 65, `09101` refused);
      `prompt_testnet_addons` takes the region label unchecked (setup-node cuts it afterwards).
      Count now 79 (Library 10).
- [x] AGENTS.md: fixed one over-long line in the Node role paragraph left by my earlier edit
      (wrapping only, no wording change).
- [x] Checks re-run: no line-number references; e-mail only support@telcoin.org; URLs only the
      canonical ones plus the two status-page URLs that followup.md reports; no
      `--observer`/`--validator` in new text; no line over 100 characters in the three files.
- The earlier open issue about the in-progress setup-node fix is resolved by babb69d and these
  edits.

## Follow-up 2 (V-DOC findings 15-18, 33, 36, 37, 40; HEAD 13f6309)

- [x] CHANGELOG.md (15): Security bullet, update-node refuses refs that start with `-` in
      `--json` runs and at the interactive prompt (e28e8e5, f9c47df).
- [x] CHANGELOG.md (36): Security bullets for observability input checks (`METRICS_PORT` must be
      a port number; launch-file edits rehearsed before Alloy is touched; 1540751) and the 2 MB
      request-body cap (7acc653). Security now has 11 bullets. "Updates and restarts" names
      `prepare-stake.sh --rotate-address` (v1.0.0) among the epoch-aware restarts. "Updater and
      integrity": `--help` prints the usage without contacting GitHub, unknown arguments are
      refused (13f6309). Rewrapped both paragraphs I touched.
- [x] AGENTS.md (16): `open-ui.sh` next to `install.sh` in the boundary list.
- [x] AGENTS.md (37): epoch paragraph names `prepare-stake.sh --rotate-address`; says update-node
      waits just before the stop, install-caddy before its first node edit, edit-config and the
      observability add-on write the launch file first and wait before the restart; "wait first,
      then stop" is about the stop. CI bullet lists Linux `bash -n`, the macOS 3.2 parse check,
      shellcheck errors (warnings advisory), the lint on both runners and the UI test job
      (checked against `.github/workflows/ci.yml`).
- [x] followup.md (17): shellcheck item gives the real count, re-run here on HEAD: 32 warnings in
      12 files (24 SC2034; SC2206 in update-scripts 2, lib/common.sh 1, firewall-setup 1; SC1090
      in update-node 2; SC2115 in remove-node 2).
- [x] followup.md (18): the `--help` item never named update-scripts.sh, so nothing to remove.
- [x] followup.md (finding 3 via the coordinator): new Security item, firewall-setup's "Remove a
      whitelist entry" leaves the `(v6)` twin, so SSH stays open over IPv6.
- [x] followup.md (33): new Setup item, "Overwrite existing keys? Yes" always fails because
      keytool refuses a non-empty `node-keys/` without `--force`; candidate fix: move the keys and
      `node-info.yaml` aside into a timestamped backup, never `--force`.
- [x] Config-save-abort item kept open: `tasks/ckpt-fu-P5.md` has no "Fix pass 3 (V-DOC)".
- [x] Finding 40: the update-node item is already fixed in the tree (`existing_binary_path` names
      the recorded binary), so not added; the lib/fallback comment item was already tracked.
- followup.md now has 81 items: Security 6, Setup and configuration 10, Library 10, others
  unchanged.
- [x] Checks re-run: no line-number references; e-mail only support@telcoin.org; canonical URLs
      only (plus the two status-page URLs the UI item reports); no `--observer`/`--validator` in
      new text; no line over 100 characters in the three files; no em dash added.

## Follow-up 3 (edit-config fix pass 3, 48a4c42; setup-node 509bedb)

Sources: `tasks/ckpt-fu-P5.md` "Fix pass 3 (V-DOC)" and its open issues; the 509bedb message.

- [x] CHANGELOG.md "Setup and configuration": "A `--json` keygen now requires `--address`" became
      "A `--json` keygen refuses up front, before root and before any build, when `--address`, one
      of the four multiaddrs or `TN_BLS_PASSPHRASE` is missing" (509bedb); added "An edit
      interrupted before its restart is rolled back." (48a4c42). Paragraph rewrapped.
- [x] CHANGELOG.md "Security": new bullet, an interrupted UI config save can no longer leave an
      unapplied edit on disk for the next restart (edit-config v1.3.0). Security has 12 bullets.
- [x] followup.md: the config-save-abort item (DOC-3) is replaced by P5's three remaining
      limits: the rollback runs at the next poll of the wait (`TN_EPOCH_POLL`, 15 s) or when a
      Docker pull or parse check returns; "Refresh chain configs" keeps its new files (no backups,
      by design); a signal between the BLS passphrase edit's stop and start leaves the node
      stopped. Count 83 (Setup and configuration 12).
- [x] Checks re-run: no line-number references; e-mail only support@telcoin.org; canonical URLs
      only (plus the two status-page URLs the UI item reports); no `--observer`/`--validator` in
      new text; no line over 100 characters; no em dash added.
