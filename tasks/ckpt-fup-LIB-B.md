status: done

Package LIB-B (issues #49, #47, #33). Branch fup/LIB-B. Base 0a9db45.

## Sections

- [x] S1 (ce60d68) restart window: epoch-length derivation of margin/settle with clamps + cap raise warning (lib/common.sh tn_wait_restart_window), restart_window_test.sh cases
- [x] S2 (5677e5c setup-node call move, c9213fa lib) check_internet keyed by NETWORK, fails closed (lib/common.sh), network_detect_test.sh LIB-B block
- [x] S3 (c755d39) check-node network RPC without adiri fallback (check-node.sh resolve_network/network_rpc_url), check_node_*_test.sh
- [x] S4 (ad481ed) setup-node _setup_image_example mainnet arm, test case
- [x] S5 #33 late-case docs paragraph (checkpoint only, verified in update-node.sh)
- [x] S6 gates: bash 5.3 + 3.2 fixtures, bash -n both, check-bash32, shellcheck 0.11 + 0.9, full suite bash 5.3
- [x] S7 (2542f49) (follow-up from review) TN_EPOCH_WAIT_MAX kept as set: no raise; a cap shorter than margin + settle + two polls is kept with a warning; contract comment + restart_window_test.sh LIB-B cases
- [x] S8 gates for S7: restart_window/keytool/network_detect under bash 5.3, bash:3.2, ubuntu:24.04; bash -n both; check-bash32; shellcheck 0.11 + 0.9 on lib/common.sh; full suite bash 5.3

## Operator-visible changes

- S1: the epoch wait's margin and settle follow the epoch length read with the boundary
  (6 h testnet epoch: 300/90 unchanged; 7-day: 900/300). Messages "outside the Ns margin",
  "should have ended", and the "Waiting for epoch N to close" step end with one sentence
  naming the values and their source. (S1 raised a short cap; S7 replaced that: the cap is
  kept as set and a short one is warned about, read path only.)
- S7: TN_EPOCH_WAIT_MAX is never raised. A cap shorter than margin + settle + two polls is
  kept, with the warning "TN_EPOCH_WAIT_MAX N is shorter than margin M + settle S + two
  polls; the restart may land before the epoch has settled. Set it to at least X, or
  TN_SKIP_EPOCH_WAIT=1 to skip the wait on purpose." The step line reports the cap as set.
- S2: check_internet probes the chosen network's own RPC (testnet rpc.adiri.tel, mainnet
  rpc.telcoin.network, devnet DEVNET_RPC_URL), then https://1.1.1.1. NETWORK empty or
  unknown: "Cannot check internet connectivity: NETWORK must be testnet, mainnet or devnet
  (it is <value|empty>), so no network RPC was probed." and exit 1, no curl call.
  Interactive setup-node now runs the connectivity check after "Selecting network..."
  (it ran before the prompt); the curl/git package check therefore comes first.
- S3: check-node with an unknown network (no NETWORK in .node-meta, no Telcoin chain id
  from the local RPC) and no --network-rpc no longer compares with adiri: header
  "Network RPC:  none (network unknown; give --network-rpc URL to compare)", section 3
  "Network query skipped (network unknown; give --network-rpc URL to compare)", and the
  committee/headers/on-chain sections give that reason. Header line now labels the
  endpoint: "<url> (mainnet public RPC)" / "<url> (--network-rpc, for testnet)" /
  "(--network-rpc, for an unknown network)". --help: "...mainnet <url>; none when the
  network is unknown)". --no-network output unchanged (no header line).
- S4: setup-node messages on mainnet that give an image example (invalid --docker-image,
  DOCKER_IMAGE in .node-meta not a reference, the interactive "Not usable" prompt) now
  show "ghcr.io/telcoin-association/telcoin-network@sha256:<digest>" instead of the adiri
  GAR image; testnet and devnet unchanged.

## Docs notes

### Epoch wait (#49) — AGENTS.md "Restarts and the epoch boundary" (:144-150), README.md :786-794 table + :2498, OPERATOR.md :1433-1436 table + sample at :602, partner guide mno-node-guide.md :724-727 table
- `TN_EPOCH_MARGIN` and `TN_EPOCH_SETTLE` no longer have fixed defaults on the normal path.
  Left unset (or set to something that is not a whole number of seconds), they follow the
  epoch length (`epochDuration` of `tn_getCurrentEpochInfo`, read with the boundary from the
  local node or the network's public RPC): margin = epochDuration / 72 clamped to 300-900 s;
  settle = epochDuration / 240 clamped to 90-300 s (integer division).
- Testnet numbers unchanged: adiri's 21600 s (6 h) epoch gives 300 and 90. A 7-day epoch
  (604800 s) gives 900 and 300. A 12 h epoch gives 600 and 180.
- A whole number of seconds set in the environment is used as given and never clamped
  (e.g. `TN_EPOCH_MARGIN=120`, `TN_EPOCH_MARGIN=1000`, `TN_EPOCH_SETTLE=20` all stand).
- Before the epoch length is known (the blind wait of a staked node whose mode and epoch
  timing could not be read) the fixed 300 and 90 apply as before: the blind wait is
  `TN_EPOCH_MARGIN` + `TN_EPOCH_SETTLE` (300 + 90 unless set), at most `TN_EPOCH_WAIT_MAX`
  as set, with no warning (unchanged).
- Cap rule (S7, replaces S1's raise). Sentence for AGENTS.md "Restarts and the epoch
  boundary", README and OPERATOR: "`TN_EPOCH_WAIT_MAX` caps the whole wait as set; a cap
  shorter than margin + settle + two polls is kept and warned about." Detail: once the epoch
  length is known, a `TN_EPOCH_WAIT_MAX` that is not 0 and is shorter than margin + settle +
  two polls (`TN_EPOCH_POLL`, 15 by default, held to 5-20) stays in force and the script warns
  `TN_EPOCH_WAIT_MAX <N> is shorter than margin <M> + settle <S> + two polls; the restart may land before the epoch has settled. Set it to at least <X>, or TN_SKIP_EPOCH_WAIT=1 to skip the wait on purpose.`
  Example: `TN_EPOCH_WAIT_MAX=100` on a 7-day epoch -> waits at most 100 s, "Set it to at
  least 1230" (900 + 300 + 30). On testnet with the defaults the sum is 300 + 90 + 30 = 420,
  so a cap below 420 draws the warning. A cap equal to the sum draws none. The default 1800
  covers the largest derived wait, 900 + 300 + 2x20 = 1240, so an unset cap never warns
  unless `TN_EPOCH_MARGIN` or `TN_EPOCH_SETTLE` is set above the clamps (e.g. margin 2000:
  "TN_EPOCH_WAIT_MAX 1800 is shorter than margin 2000 + settle 300 + two polls; ... at least
  2330"). The warning is printed whenever the epoch length was read, also when the boundary
  is far away and no wait follows.
- `TN_EPOCH_WAIT_MAX=0` still turns the wait off, with no warning.
- Messages: "Epoch N ends in X, outside the Ms margin; no need to wait.", "Epoch N should
  have ended X ago and has not; not waiting." and the step "Waiting for epoch N to close
  before restarting: ... Waiting at most Cs (TN_EPOCH_WAIT_MAX); set TN_SKIP_EPOCH_WAIT=1 to
  skip." now end with one sentence: `Margin 300s and settle 90s, derived from a 21600 s epoch.`
  or, when a value comes from the environment, `Margin 120s from TN_EPOCH_MARGIN; settle 300s derived from a 604800 s epoch.`
  (third form `<n>s by default` when the answer carried no epoch length). OPERATOR.md's
  sample step line at :602 gains that sentence.
- "The node team's final mainnet values replace the shares later": the 1/72 and 1/240
  shares and the clamps are interim; when the node team sets mainnet's epoch length and
  restart margins, those numbers replace them (tracked in #49).

### check_internet (#47) — README.md :198 ("Checks internet connectivity and required ports")
- setup-node's connectivity check probes the chosen network's public RPC (testnet
  `https://rpc.adiri.tel`, mainnet `https://rpc.telcoin.network`, devnet `DEVNET_RPC_URL`,
  default `https://rpc.devnet.telcoin.network`), then `https://1.1.1.1`; it no longer
  probes the testnet RPC on every network.
- It now runs right after "Selecting network..." in the pre-flight step (it used to run
  before the network prompt), after the curl/git package check.
- An empty or unknown NETWORK stops with `Cannot check internet connectivity: NETWORK must be testnet, mainnet or devnet (it is <value|empty>), so no network RPC was probed.` (exit 1,
  nothing contacted). Not reachable from the shipped flows after the call move.

### check-node network RPC (#47) — README.md :630, OPERATOR.md :439 + :1082, partner guide :507 + :1082
- Default comparison RPC is the public RPC of the node's network (NETWORK in .node-meta,
  else the network of a Telcoin chain id read from the local RPC). When the network is
  unknown and no `--network-rpc` is given, the comparison is skipped (no adiri fallback):
  header `Network RPC:  none (network unknown; give --network-rpc URL to compare)`, section
  3 `Network query skipped (network unknown; give --network-rpc URL to compare)`, and the
  sections that fall back to the local view name that reason. It does not count as an issue.
- The header line now says which network the endpoint belongs to:
  `Network RPC:  https://rpc.telcoin.network (mainnet public RPC)`,
  `Network RPC:  <url> (--network-rpc, for testnet)`,
  `Network RPC:  <url> (--network-rpc, for an unknown network)`. With `--no-network` there
  is no Network RPC line (unchanged).
- `--help`: `--network-rpc <URL>  Network RPC for ground truth (default: the public RPC of
  the network in .node-meta: testnet ..., devnet ..., mainnet ...; none when the network is
  unknown)`.

### setup-node image example (#47)
- On mainnet, setup-node's messages that give an image example now show
  `ghcr.io/telcoin-association/telcoin-network@sha256:<digest>` (tn_docker_repo_for mainnet),
  not the adiri GAR default image. Testnet (DEFAULT_DOCKER_IMAGE) and devnet unchanged.

### #33 late case (partner guide, one paragraph; verified in update-node.sh verify_consensus_participation / _uc_vote_late / update_vote_field / update_vote_note / storage_migration_begin)
Suggested paragraph (after the "It then checks that the node follows consensus" item):

> When that window runs out (the consensus header has not advanced, or a node that was
> voting before the update is not voting again, within `TN_UPDATE_VOTE_TIMEOUT` seconds,
> 600 by default, read every `TN_UPDATE_VOTE_POLL` seconds, 10 by default) while the unit
> is active and its RPC still answers `eth_chainId`, the update is not failed: catching up
> after the restart can take longer than the window. The new release keeps running, nothing
> is rolled back, and the script warns `... Not rolled back: the unit is active and its RPC
> answers, so the new release keeps running while it catches up. Watch it with check-node.sh
> or journalctl -u <service> -f (TN_UPDATE_VOTE_ROLLBACK=1 rolls back on this instead).`
> An interactive run then says `<service> runs the new release but is not following
> consensus or voting yet; it was not rolled back.` and `Check it again in a few minutes:
> bash ~/telcoin-node-scripts/check-node.sh`; a `--json` apply ends with `"ok":true` and
> `"voting":false` in its `done` line. To treat this case as a failed check instead, set
> `TN_UPDATE_VOTE_ROLLBACK=1` (off by default; only the value `1` turns it on), for example
> `sudo TN_UPDATE_VOTE_ROLLBACK=1 bash ~/telcoin-node-scripts/update-node.sh`: the run then
> fails with `(TN_UPDATE_VOTE_ROLLBACK=1: failing the update.)` and, like any failed check,
> offers the rollback (a `--json` apply rolls back on its own). After the one-way update to
> `v0.16.0-adiri` it fails without a rollback. Leave it unset for the one-way update from
> `v0.16.0-adiri` to the next release, whose failed check still rolls back (see the item on
> that update). A wrong chain ID, a unit that is no longer active or an RPC that no longer
> answers fails the check whatever the setting.

Verified facts behind it: defaults `_uc_vote_setting TN_UPDATE_VOTE_POLL 10` and
`TN_UPDATE_VOTE_TIMEOUT 600` (1 to 99999 accepted); late needs `systemctl is-active` and an
`eth_chainId` answer, else `update_fail` (rc 1); `TN_UPDATE_VOTE_ROLLBACK` compared with
`== "1"`; `update_vote_field` emits `,"voting":false` for late and failed; the ok:true done
lines at the source (`new_ref`/`new_version`) and docker (`new_image`) --json apply paths
carry it; `STORAGE_MIGRATION` is set only by `storage_migrating_upgrade` (crossing 0.16.0),
so the v0.16 -> next update takes the normal rollback path. Decision 5 (no code change)
holds: nothing in update-node.sh was edited.

## Tests run

- S8 (tip 2542f49): restart_window 43/0, keytool 45/0, network_detect 121/0 under bash 5.3.9,
  bash:3.2 (3.2.57) and ubuntu:24.04 (5.2.21, root): 3 files 0 failed in each. Full suite
  bash 5.3: 59 files, 0 failed (3770 checks, 0 failures, 49 skipped); keytool's "mode read,
  epoch unreadable: continues without a blind wait" and "the blind wait is capped by
  TN_EPOCH_WAIT_MAX" pass. bash -n under 5.3 and 3.2, check-bash32, shellcheck 0.11.0 and
  0.9.0 (--severity=error) clean on lib/common.sh and restart_window_test.sh. Mutation: 7 of
  the new checks FAIL against ad481ed (the raise). The commit's patch applies cleanly on an
  export of hardening-followups (aa643a1), and there restart_window 43/0, keytool 45/0,
  network_detect 143/0.

- S6 final (tip ad481ed): full suite `bash tools/tests/run.sh` under bash 5.3.9: 59 test
  files, 0 failed (3766 checks, 0 failures, 49 skipped), incl. keytool_test.sh "wait: mode
  read, epoch unreadable: continues without a blind wait" and "wait: the blind wait is
  capped by TN_EPOCH_WAIT_MAX". Touched fixtures under `bash:3.2` (3.2.57): restart_window
  39/0, keytool 45/0, network_detect 121/0, check_node_unit 37/0, check_node_hardening
  29/0 (4 skip); 5 files 0 failed. Extra: same five in ubuntu:24.04 (root, bash 5.2.21):
  0 failed; ui/tests/helper_test.sh 494/0 (bash 5.3). `bash -n` under 5.3 and 3.2,
  `tools/check-bash32.sh` (6 files clean), shellcheck 0.11.0 and koalaman/shellcheck:v0.9.0
  `-x --severity=error` clean on lib/common.sh setup-node.sh check-node.sh
  restart_window_test.sh network_detect_test.sh check_node_unit_test.sh; perl lint over
  every tracked *.sh clean (100 files).

- S4: network_detect_test.sh 121/121 bash 5.3 and 3.2 (6 image-example checks; the 4
  mainnet ones FAIL on 0a9db45's setup-node.sh). bash -n both, check-bash32, shellcheck
  0.11 + 0.9 clean on setup-node.sh and network_detect_test.sh.
- S3: check_node_unit_test.sh 37/37 bash 5.3 and 3.2 (LIB-B block 22 checks; 12 FAIL on
  0a9db45's check-node.sh); check_node_hardening_test.sh 29/0/4 skip both bashes.
  End-to-end smoke (scratch TN_ROOT_PREFIX, --rpc http://127.0.0.1:1): unknown network
  prints the none/skip lines and contacts no network RPC; NETWORK=mainnet labels
  rpc.telcoin.network "(mainnet public RPC)" and the existing chain check warns it serves
  2017; --no-network unchanged. bash -n both, check-bash32, shellcheck 0.11 + 0.9 clean.
- S2: network_detect_test.sh 115/115 bash 5.3 and bash 3.2 (LIB-B block: 15 checks incl.
  the static step_preflight order check, which says "no" on 0a9db45's setup-node.sh);
  mutation check: 10 check_internet cases FAIL on 0a9db45's lib. bash -n both, check-bash32,
  shellcheck 0.11 + 0.9 clean on lib/common.sh, network_detect_test.sh, setup-node.sh.
- S1: restart_window_test.sh 39/39 bash 5.3 and bash 3.2; keytool_test.sh 45/45 bash 5.3
  and 3.2 (unchanged, incl. "mode read, epoch unreadable: continues without a blind wait"
  and "the blind wait is capped by TN_EPOCH_WAIT_MAX"=100); mutation check: 16 of the new
  checks FAIL against lib/common.sh of 0a9db45, the testnet-unchanged ones pass there.
  caddy/credential/obs/edit_backup/consensus_participation/prepare_stake/update_guard
  exit 0; ui/tests/helper_test.sh 494/0. bash -n (5.3 + 3.2), check-bash32, shellcheck
  0.11 + 0.9 clean on lib/common.sh + restart_window_test.sh.

## Open issues

- S2 caller finding (spec "callers set NETWORK before preflight" is wrong for one path):
  interactive setup-node.sh step_preflight called check_internet BEFORE `json_mode ||
  select_network`, with NETWORK="" (set at the top of setup-node). Only the --json path set
  NETWORK first (json_set_network in run_json_mode). check_internet is called nowhere
  else (grep). Fixed by moving the one call to right after `json_mode || select_network`
  in step_preflight, as its own commit 5677e5c (outside _setup_image_example: please keep
  it when cherry-picking, or the interactive setup exits at the connectivity check). If
  LIB-A or AUDIT edit step_preflight near "Selecting network...", expect a trivial
  conflict there.

- Spec conflict (S1, now moot after S7): Required behaviour 2's raise would have broken
  keytool_test.sh's blind-wait cap pin; S1 raised on the read path only. S7 removed the raise
  entirely (review follow-up): the cap is kept as set everywhere, and the read path warns.
- S7 choice to flag: the coordinator's rule was "explicit cap that is short: keep and warn;
  default cap: no raise needed". S7 compares the cap with margin + settle + two polls
  whatever its source, so the one case the rule did not cover (cap unset, TN_EPOCH_MARGIN or
  TN_EPOCH_SETTLE set above the clamps, sum over 1800) also warns instead of silently cutting
  the wait. With derived values an unset cap never warns (pinned by the fixture).
- restart_window_test.sh's jitter case still uses TN_EPOCH_MARGIN=10 and cap 60 (S1); with
  no raise, main's original cap-40 form would also pass. Left as is to keep S7 inside the
  LIB-B block; its "no warning" check now greps the new text.
- restart_window_test.sh's existing "the pause stays inside TN_EPOCH_WAIT_MAX" used cap 40
  with margin 300 + settle 20 + 2x15 = 350, which the new rule raises; the case now uses
  TN_EPOCH_MARGIN=10 and cap 60 (= the sum, not raised) and checks <= 60.
- Sidecars: lib/common.sh.sha256, setup-node.sh.sha256 and check-node.sh.sha256 are stale on
  this branch by design (no gen-checksums); "checksum freshness" stays red until release prep.
- Cherry-pick notes: network_detect_test.sh has two LIB-B blocks at the end, just before
  `finish` (check_internet + step_preflight order; image example); check_node_unit_test.sh
  has one LIB-B block before `finish`. LIB-A / REL appending at the same tail will conflict
  trivially (keep both). check-node.sh edits: the globals after EXPECTED_CHAIN_ID, the
  --network-rpc help line, resolve_network, network_gap_reason, the header "Network RPC:"
  line and the section 3 "Network query skipped" line (REL's release block may sit near the
  header).
- Spec facts that were wrong or incomplete against the code: (1) "callers set NETWORK before
  preflight" is false for interactive setup-node (see above); (2) Required behaviour 2 as
  written conflicts with keytool_test.sh's blind-wait cap pin (see above); (3) neither
  check_node_unit_test.sh nor check_node_hardening_test.sh drove resolve_network before; the
  cases went into check_node_unit_test.sh; (4) _setup_image_example has 7 callers, not 3
  (:921 :974 :3025 plus :3102 :3105 :3108 devnet-only and :3135, the generic invalid
  --docker-image message, which on mainnet now shows the ghcr example); (5) the #33 late case
  needs the unit active AND an eth_chainId answer, else it fails (rc 1); and the v0.16 ->
  next one-way update is not flagged STORAGE_MIGRATION, so TN_UPDATE_VOTE_ROLLBACK=1 there
  turns a late check into a rollback (docs note says leave it unset). All line anchors in
  the spec matched within a line or two.

