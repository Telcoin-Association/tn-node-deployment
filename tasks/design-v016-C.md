I've read through the repo. Below is the design. Line anchors are against the current `main` (6f3c204).

# v0.16.0-adiri roll: design for adiri-genesis

## 0. Findings that shape the design

1. **GCP snapshot names cannot contain dots or uppercase.** The proposed `validator-N-adiri-pre-v0.16.0-adiri-<ts>` would be rejected. Use `validator-10-adiri-pre-v0-16-0-adiri-20261009-153012`, which is 52 characters (limit 63).
2. **config.sh sets the value unconditionally.** `config.sh:266` is `export FORK_CLOSE_EPOCH=553`, so the env override pattern `FORK_CLOSE_EPOCH=… ./adiri-update-all.sh` does nothing. The no-code alternative therefore needs a `config.sh` edit in the middle of the run, which is the working-tree hazard in `tasks/lessons.md:251-262`.
3. **`restart-staggered.sh:401` breaks on `none`.** It calls `tn_epoch_deadline "${FORK_CLOSE_EPOCH}"` under `set -u`, so `none` must be handled inside the library function, not only in the driver.
4. **A snapshot restore is a clean rollback only before the 2c gate passes.** After 2c passes, the chain has advanced on v0.16, and restoring snapshots rewinds finalized history: a reorg for RPC users, plus the committee "forgetting" its own signatures. Two rules follow: restore all 5 committee nodes or none, and the decision rule must name 2c PASS as the point where a clean rollback is no longer possible.
5. **Re-runs must never re-snapshot or re-copy a datadir that may already be migrated.** A re-run after a partial 2b would otherwise record a v2 datadir as the "pre-upgrade" state. Reuse an existing on-node record instead, the same pattern as `tn_cmd_ext_binary_snapshot` (adiri-lib.sh:856-875).
6. **validator-8's datadir `/mnt/data` is a mountpoint.** `mv` cannot rename it, and a sibling copy would land on the root filesystem, which has about 13 GB free. Treat validator-8 as resync-only.
7. **Do not restore by swapping the boot disk.** That needs a VM stop/start, and `startup.sh:154` runs `keytool generate validator` at boot if the startup script is still in metadata. Use attach + rsync instead; the VM stays up.
   - c3 machines use NVMe, so address the restore disk as `/dev/disk/by-id/google-tnrestore-part1`.
   - Check SSD quota (`SSD_TOTAL_GB` ≥ 350 GB of headroom per region) and that `rsync` is installed.
   - The datadir is not readable by tnadmin, so `epoch-*` globs only expand under `sudo sh -c`.
8. **The public `update-node.sh` on main is still `SCRIPT_VERSION="1.2.0"`** (tn-node-deployment/update-node.sh:56). Both refresh paths pull `main` (`git pull origin main`, and update-scripts.sh:28 via raw.githubusercontent). So 1.2.1 must be merged first, then wait about 5 minutes for the CDN.
9. **Small anchor corrections and timeouts.**
   - The 2d verify timeout is the hardcoded `APPLY_VERIFY_TIMEOUT=300` at `:137`, passed at `:1480` and through lib `:353-355` (not `:1493-1495`).
   - The 2c timeout of 600 s also covers v0.16's current-epoch migration at startup, so raise it.
10. **The dry-run matrix is not a script.** It exists only as prose: `tasks/upgrade-v015-agentA-checkpoint.md:16-18` (cases with exit codes), `tasks/plan.md:18` and `tasks/run-record…:38,51`. xerxes has bash 5.3 only (no 3.2) and no shellcheck.
11. **Dry-run flag pitfall.** `TN_DRY_RUN` defaults to `"0"` (driver line 185), so `${TN_DRY_RUN:+--dry-run}` is always non-empty. Use `$(tn_dry_run && echo --dry-run)`.
12. **The rollback window must be advisory, never a refusal.** A halted chain does not close epochs. Refusing a rollback because the wall clock passed the nominal boundary would strand a halted fleet.

## 1. config.sh changes

```diff
@@ :39-46
-# CURRENT FLEET / rollback target (v0.15 roll 2026-09-24)…
-export DOCKER_IMAGE="…/adiri:v0.15.0-adiri"
+# v0.15.0-adiri: forks 554/567/570/574 (all fired). Fleet until the v0.16 roll and
+# the ROLLBACK target below. FLOOR: v0.14 cannot follow the chain past 554.
+# export DOCKER_IMAGE="…/adiri:v0.15.0-adiri"
+# v0.16.0-adiri (d72cc2bc) arms NO adiri fork (subsecond=u32::MAX) but its first
+# start migrates consensus storage ONE-WAY (pack v1->v2); v0.15 cannot open it.
+# Rolled all-at-once with DATADIR_SNAPSHOT=1 (plan.md Runbook v5).
+export DOCKER_IMAGE="us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.16.0-adiri"
@@ :196-218   (move the v0.15 pins + their evidence into a history comment)
-export EXPECTED_SHA="5736cc30…"
+export EXPECTED_SHA="d72cc2bcfceb2e61b968915d72dc7e3761dd7e0b"
-export EXPECTED_IMAGE_DIGEST="sha256:3b0a0ec2…"
+export EXPECTED_IMAGE_DIGEST="REPLACE-ME-FROM-GAR"   # §A step 3; P0 refuses until filled
-export EXPECTED_IMAGE_DIGEST_AMD64="sha256:5946…"
+export EXPECTED_IMAGE_DIGEST_AMD64=""                # optional amd64 child of the same push
@@ :222,:230  EXPECTED_FORK_EPOCH=383 / EXPECTED_REGISTRY_FORK_EPOCH=407 unchanged (comment: "unchanged in v0.16")
@@ :237
-export EXPECTED_FORK_FIELDS="…six…"
+export EXPECTED_FORK_FIELDS="consensus_registry_fork_epoch=407 seed_signature_fork_epoch=383 multi_workers_fork_epoch=570 prevrandao_fork_epoch=574 leader_seeded_ordering_fork_epoch=567 subsecond_timestamp_fork_epoch=4294967295 governance_safe_fork_epoch=554"
@@ :241-253  (rewrite comment: floor v0.15; one-way migration ⇒ rollback = datadir restore)
-export ROLLBACK_IMAGE="…:v0.14.0-adiri"   ROLLBACK_SHA="5f1c0b49…"  ROLLBACK_IMAGE_DIGEST="sha256:eecb53b1…"
-export ROLLBACK_FORK_FIELDS="consensus_registry_fork_epoch=407 seed_signature_fork_epoch=383"
+export ROLLBACK_IMAGE="us-docker.pkg.dev/telcoin-network/tn-public/adiri:v0.15.0-adiri"
+export ROLLBACK_SHA="5736cc30012c5ff25913898e318a74df308f13d9"
+export ROLLBACK_IMAGE_DIGEST="sha256:3b0a0ec2239f59418ed73e0984056119228acd5f82b2942881ccec8a0fec247d"
+export ROLLBACK_FORK_FIELDS="consensus_registry_fork_epoch=407 seed_signature_fork_epoch=383 multi_workers_fork_epoch=570 prevrandao_fork_epoch=574 leader_seeded_ordering_fork_epoch=567 governance_safe_fork_epoch=554"
@@ :255-286
-export FORK_CLOSE_EPOCH=553
+export FORK_CLOSE_EPOCH=none          # no armed fork: deadline gates off, epoch window on
+export EPOCH_WINDOW_MIN_OPEN_SECS=600 # cutover >= 10 min after an epoch opens
+export EPOCH_WINDOW_MIN_LEFT_SECS=3600 # … and >= 1 h before its early close edge (T-skew)
+export DATADIR_SNAPSHOT=1            # 2s committee snapshot, 2d follower copy, R0/R4/R6 restore
+export SNAPSHOT_CREATE_TIMEOUT_SECS=300 SNAPSHOT_READY_WAIT_SECS=1800
+export FOLLOWER_COPY_MIN_PCT=120 FOLLOWER_COPY_TIMEOUT_SECS=3600
+export APPLY_VERIFY_TIMEOUT=900      # first start migrates the current epoch
-export COMMITTEE_GATE_TIMEOUT_SECS=600
+export COMMITTEE_GATE_TIMEOUT_SECS=1200
```

- `HARD_FLOOR`, `MIN_MARGIN` and `ROLLBACK_MIN_MARGIN` stay, with a comment that they are inactive while `FORK_CLOSE_EPOCH=none`.
- Retext the `LEGACY_FLAG_DENY_RE` comment (`:294-305`): v0.16 now rejects `--observer` at parse time.
- With these pins, `FORBIDDEN_KEYS` (driver `:369-374`) becomes `subsecond_timestamp_fork_epoch`. That is correct for R5.

## 2. `FORK_CLOSE_EPOCH=none` mode

**Gates this mode bypasses:**

| Anchor | Today | With `none` |
|---|---|---|
| P0 numeric check `:440-444` | must be numeric | skip `FORK_CLOSE_EPOCH`; check the new tunables |
| Banner `:483` | "close of epoch N" | "deadline none · window ≥ Xs open / ≥ Ys left" |
| P2 `:593-595` | `deadline_gate` refuses | `window_gate advise` (refuses only if no RPC answers) |
| Re-check before 2a `:1301-1303` | `deadline_gate \|\| exit 1` | `window_gate enforce` (refuse; "nothing stopped") |
| 2d hold `:1561-1567` | holds near T | skipped |
| R1 `:569-575`, `:1301` | margin refusal | `window_gate advise` |
| Confirm plan `:1261`, CHECK `:952`, summary `:1874-1908` | time to T, "UNDER 2h" alarm | epoch position line; retext `:1893`, `:1899`, `:1908` |

**Library change**, in `tn_epoch_deadline` (adiri-lib.sh:1115-1193):

```bash
local nodl=0; case "${close}" in ""|*[!0-9]*) nodl=1 ;; esac
# :1157 synthesized branch: if [ "${nodl}" -eq 1 ]; then e_now=600; else e_now=$((close - 2)); fi
[ "${nodl}" -eq 1 ] && close="${e_now}"          # T := the CURRENT epoch's close
T=$(( t_open + (close + 1 - e_now) * dur ))      # unchanged
# printf … 'NO_DEADLINE=%s\n' "${nodl}"
```

This also fixes `restart-staggered.sh`, and its `T-20m` dry-run hooks become relative to the current epoch's close.

**Driver change**, ported from `restart-staggered.sh:395-416`:

```bash
NO_DEADLINE=0; [ "${FORK_CLOSE_EPOCH}" = none ] && NO_DEADLINE=1
window_gate() {   # <enforce|advise>
  local how="$1" out t0 now since left edge why=""
  out="$(tn_epoch_deadline none)" || { gate_fail "epoch position unprovable (no RPC)"; return 1; }
  DL_E_NOW="$(tn_kv "$out" E_NOW)"; t0="$(tn_kv "$out" T_OPEN)"; now="$(tn_kv "$out" NOW)"
  edge=$((t0 + EPOCH_DURATION_SECS - BOUNDARY_SKEW_SECS)); since=$((now - t0)); left=$((edge - now))
  echo "    epoch ${DL_E_NOW} open $(fmt_dur "$since") · $(fmt_dur "$left") to early edge $(_tn_iso "$edge")"
  [ "$since" -ge "$EPOCH_WINDOW_MIN_OPEN_SECS" ] || why="epoch opened ${since}s ago"
  [ "$left" -ge "$EPOCH_WINDOW_MIN_LEFT_SECS" ] || why="only ${left}s to the early close edge"
  [ -z "$why" ] && { echo "    ✓ epoch window open"; return 0; }
  [ "$how" = advise ] && { echo "    ⚠ $why (advisory; enforced right before downtime)"; return 0; }
  gate_fail "epoch window: $why"
}
deadline_gate() { if [ "$NO_DEADLINE" -eq 1 ]; then [ "$MODE" = rollback ] && set -- advise; window_gate "${1:-enforce}"; return; fi; …existing…; }
```

Call sites: `deadline_gate advise || true` at `:595`, and `deadline_gate enforce || exit 1` at `:1303`.

**Recommendation: implement `none`** (about 50 lines including the library). The no-code alternative is to edit `config.sh` to `FORK_CLOSE_EPOCH=<E_now>`. Its problems:
- It is a mid-run config edit (finding 2).
- It has no "since open" guard.
- Its messages are wrong ("v0.14 node already diverged").
- It refuses any rollback once the epoch rolls over, which is wrong for a halted chain.
- The 2d hold fires within 15 minutes of the boundary.

Keep it only as a fallback if time runs out, and commit the edit.

## 3. Datadir snapshot and copy

### Phase order

| Old | New |
|---|---|
| P0, P1, P2 | P0 (+ `none`, new tunables, `gcloud` present), P1, **R0** (rollback only), P2/R1 advisory window |
| −1, 0 | −1; 0 now gated on update-node.sh ≥ 1.2.1 (§6) |
| CHECK | + datadir probe, `gcloud` boot-disk probe, copy plan, SSD quota |
| 1 / R2 | 1; R2 also surveys the follower copy marker |
| 1b | + network-config and parameters.yaml backups, node-info wildcard check, migration headroom check, copy plan |
| CONFIRM | + plan lines for snapshot and copy |
| P2 re-check | window **enforced** |
| 2a stop followers | unchanged |
| — | **2s (new):** committee graceful stop → `sync` → `disks snapshot --async` ×5 → poll until status ≠ CREATING → write on-node records. Any failure: `docker start telcoin` ×5, start the followers stopped in 2a, exit 1 (nothing migrated) |
| 2b | unchanged (start-validator-node.sh's stop/wait are no-ops; it removes the old container) |
| 2c | unchanged; timeout 1200 s |
| 2d | per follower: **copy (or record resync-only)** → apply; handle `rollback_refused` |
| 3, 4, 5, summary | summary retext; rollback command always includes `--from-run` |

### Effect on the chain halt

The halt still runs from 2s (committee stopped) to 2c PASS. The snapshot adds about 30–90 s typically: graceful stop (seconds; up to 60 s), `sync`, five parallel API calls, CREATING (usually under a minute), and the 5 s poll. The worst case is bounded by `SNAPSHOT_CREATE_TIMEOUT_SECS` (300 s), followed by an automatic resume on v0.15. Expect a total halt of about 3–6 minutes plus v0.16's migration of the current epoch (measure it, see §8 step 6).

Recommended: during the unattended prepare pass, take a **prewarm** snapshot with a runbook loop (no code). The cutover snapshot then has a tiny incremental delta and reaches READY within minutes, which matters because a restore needs READY. The prewarm also proves gcloud auth and IAM before CONFIRM. Snapshot rate limits are about 6 per disk per hour, so a prewarm plus the cutover snapshot fits.

### Follower copies

The copy runs inside each follower's own 2d job, after 2c. It never touches the chain halt and needs no new background-job plumbing. If quorum is lost, there is no copy, and none is needed because the datadir was never migrated.

### New library sketches (bash 3.2-safe)

`tn_cmd_gcp_stop_sync <tag>` (new, near `:1005`):

```bash
printf '%s' "rec=/home/validator/telcoin.pre-$1.snapshot; sudo docker stop -t 60 telcoin >/dev/null 2>&1 || true; \
[ \"\$(sudo docker inspect -f '{{.State.Running}}' telcoin 2>/dev/null)\" = true ] && { echo STOPPED=0; exit 1; }; sync; \
echo STOPPED=1; echo \"EXIT_CODE=\$(sudo docker inspect -f '{{.State.ExitCode}}' telcoin 2>/dev/null)\"; \
echo \"NI_SHA=\$(sudo sha256sum /home/validator/telcoin/node-info.yaml | cut -d' ' -f1)\"; echo \"REC=\$(sudo cat \$rec 2>/dev/null | head -1)\""
```

Local gcloud helpers (new). Each one echoes and returns under dry-run:

```bash
tn_label() { printf '%s' "$1" | tr 'A-Z.' 'a-z-' | tr -cd 'a-z0-9-'; }
tn_snapshot_name() { printf '%s-pre-%s-%s' "$1" "$(tn_label "$2")" "$(date -u +%Y%m%d-%H%M%S)"; }
tn_gcloud() { if tn_dry_run; then _tn_dry_echo "gcloud $*"; return 0; fi; gcloud "$@" --project="${PROJECT_ID}"; }
tn_gcp_boot_disk() { local o; tn_dry_run && { printf '%s' "$1"; return 0; }
  o="$(gcloud compute instances describe "$1" --zone="$2" --project="${PROJECT_ID}" --format='value(disks[0].boot,disks[0].source.basename(),disks[1].source.basename())')" || return 1
  set -- $o; [ "$1" = True ] && [ -n "${2:-}" ] && [ -z "${3:-}" ] && printf '%s' "$2"; }
tn_gcp_snapshot_status() { tn_dry_run && { tn_dry_run_fails "${2:-}" snapshot && echo FAILED || echo READY; return 0; }
  gcloud compute snapshots describe "$1" --project="${PROJECT_ID}" --format='value(status)' 2>/dev/null || true; }
```

Driver, 2s, inserted after `:1313` and run with `run_phase snapshot snapshot_gcp_one -`:

```bash
snapshot_gcp_one() { local n="$1" z out d nm; has "$n" skip && { echo SKIP; return 0; }; z="$(gcp_zone_for "$n")"
  out="$(tn_gcp_ssh "$n" "$z" "$(tn_cmd_gcp_stop_sync "$TARGET_TAG")")" || { echo "stop FAILED"; return 1; }
  if [ -n "$(tn_kv "$out" REC)" ]; then put "$n" dsnap "SNAPSHOT=$(tn_kv "$out" REC)"; echo "REUSED (datadir may be migrated)"; return 0; fi
  d="$(tn_gcp_boot_disk "$n" "$z")" || { echo "boot disk unresolved"; return 1; }; nm="$(tn_snapshot_name "$n" "$TARGET_TAG")"
  tn_gcloud compute disks snapshot "$d" --zone="$z" --snapshot-names="$nm" --async \
    --labels="tn-node=$n,tn-release=$(tn_label "$TARGET_TAG"),tn-kind=pre-upgrade" >/dev/null || { echo "snapshot request FAILED"; return 1; }
  put "$n" dsnap "$(printf 'SNAPSHOT=%s\nDISK=%s\nZONE=%s\nNI_SHA=%s' "$nm" "$d" "$z" "$(tn_kv "$out" NI_SHA)")"; }
# then snapshot_wait_created (poll every 5 s; "" counts as CREATING; FAILED or timeout -> return 1);
# on success: tn_gcp_ssh … "echo <name> | sudo tee /home/validator/telcoin.pre-<tag>.snapshot" for ALL nodes;
# on failure: resume_old_fleet (par_quiet: "sudo docker start telcoin"; tn_cmd_ext_start for `has stopped`) ; exit 1
```

`tn_cmd_ext_datadir_copy <dd> <tag> <pct> <timeout>` (new, after `:908`). The rollback restore counterpart is `mv dd dd.v016-<ts>` followed by `mv c dd`.

```bash
c="${dd}.pre-${tag}"; case "$c" in /*.pre-*) ;; *) exit 1 ;; esac
sudo test -f "$c.complete" && { echo RESULT=reused; exit 0; }; mountpoint -q "$dd" && { echo RESULT=resync-only; echo REASON=datadir-is-mountpoint; exit 0; }
sudo rm -rf "$c"; need=$(sudo du -sk "$dd" | cut -f1); free=$(df -Pk "$(dirname "$dd")" | awk 'NR==2{print $4}')
[ $((free*100)) -ge $((need*pct)) ] || { echo RESULT=resync-only; echo "REASON=free ${free}k < ${pct}% of ${need}k"; exit 0; }
if sudo timeout "$to" cp -a "$dd" "$c" && sudo touch "$c.complete"; then echo RESULT=copied; else sudo rm -rf "$c"; echo RESULT=resync-only; echo REASON=copy-failed; fi
```

In `apply_ext_one` (`:1469`):
- **Copy step:** after the `has stopped` check at `:1473`, run the copy unless the installed binary is already the target (`BIN_SHA == PIN_SHA` means it may already be migrated). Record the result in `put n dcopy`.
- **`rollback_refused` branch:** add it before `rolled_back` at `:1493`. If `tn_json_true "$done_line" rollback_refused`, mark the node `applied` and leave it running; phase 3 judges it. This is the interface contract with update-node.sh 1.2.1: the done line must carry `"rollback_refused":true`.
- **2d hold:** at `:1565`, prefix the condition with `[ "$NO_DEADLINE" -eq 0 ] &&`.
- **Timeout:** change `:137` to `APPLY_VERIFY_TIMEOUT="${APPLY_VERIFY_TIMEOUT:-300}"`.

**1b backups.** In `preflight_*` (`:1145-1192`), also back up `network-config` and `parameters.yaml` with `tn_cmd_nodeinfo_backup <path> FROM_TAG` (it is generic apart from its ERR name). Treat a missing `parameters.yaml` on a follower as `na`. Copy both into `RUN_DIR/backups/<n>.<basename>`. They are never restored automatically, in line with the drift plan's "never restore network-config.bak" rule.

## 4. Rollback

**R0** is new and runs after P1, read-only.
- `--from-run` is required.
- For every committee node, take the snapshot name from `${FROM_RUN}/<n>.dsnap`, falling back to the on-node `/home/validator/telcoin.pre-<tag>.snapshot`. Wait up to `SNAPSHOT_READY_WAIT_SECS` for READY.
- Any committee node without a READY snapshot means refuse with "nothing touched". It is all 5 or none.
- Followers are reported only, as copy, resync-only, or untouched.

**R2** (`phase1_gcp_rb`, `:1037`): after `gcp_skip_if_on_pin`, remove the `skip` file unless the node carries `/home/validator/.tn-restored-<snapshot>`. A node running v0.15 without that marker still gets restored.

**R4** (`apply_gcp_one`, before `:1336`):

```bash
if [ "$MODE" = rollback ] && [ "$DATADIR_SNAPSHOT" -eq 1 ] && ! has "$n" skip; then
  tn_gcp_ssh "$n" "$zone" "$(tn_cmd_gcp_stop_sync "$TARGET_TAG")" >/dev/null || { echo "stop FAILED"; return 1; }
  "${REPO_DIR}/restore-datadir-from-snapshot.sh" "$n" "$zone" "$(tn_kv "$(get_rec "$n" dsnap)" SNAPSHOT)" \
     --expect-nodeinfo-sha "$(tn_kv "$(nodeinfo_record "$n")" SHA)" $(tn_dry_run && echo --dry-run) \
     || { put "$n" apply.rc 97; echo "RESTORE FAILED — not started (v0.15 cannot open a migrated datadir)"; return 1; }
fi
```

**`restore-datadir-from-snapshot.sh <inst> <zone> <snapshot> [--expect-nodeinfo-sha S] [--keep-disk] [--dry-run]`** is a new script that sources adiri-lib.sh, so both transports work. Steps:

1. Confirm the snapshot is READY and the container is not running.
2. `gcloud compute disks create tnr-<inst>-<ts> --source-snapshot … --type pd-ssd --zone`.
3. `trap cleanup EXIT`: umount, `detach-disk`, `disks delete` unless `--keep-disk`.
4. `attach-disk --device-name tnrestore --mode rw`.
5. On the node:
   - Wait for `/dev/disk/by-id/google-tnrestore-part1`, then `mount -o ro`. ext4 replays its journal and a duplicate UUID is fine when mounting by path.
   - Require that the snapshot's `home/validator/telcoin/node-info.yaml` sha equals S. This catches a swapped node, which would mean wrong keys.
   - `rsync -aHX --numeric-ids --delete-before --inplace --exclude=/logs/ src/ /home/validator/telcoin/`, which keeps the v0.16 logs.
   - Run the same rsync with `-n --itemize-changes`; it must report 0 lines.
   - Write the `.tn-restored-<snap>` marker and umount.

Estimated rollback halt: about 8–15 minutes (create 1–2 min, attach, rsync of the files v0.16 changed, detach, then v0.15 start and quorum).

**R6** (`rb_apply_ext_one`, before the binary restore at `:1532`):
- `DCOPY_COMPLETE=1`: restore with the `mv` pair, then continue the existing node-info → wrapper → binary → discard → start sequence.
- No copy, but the follower ran v0.16 (`running.before` BIN_SHA equals `EXPECTED_SHA`, or `FROM_RUN/<n>.apply.json` exists): restore the v0.15 binary (so a reboot fails fast) but do **not** start it. Record `KIND=resync` and have `classify_ext` (`:1817-1846`) report "STOPPED (resync needed)".
- Otherwise: the current path.

Extend `tn_cmd_ext_rollback_sources` (`:885`) with a datadir argument so it emits `DCOPY_COMPLETE`.

## 5. Read-only pre-flight additions

The probe helpers live in adiri-lib.sh: `tn_cmd_discover` :241, `tn_cmd_disk_free` :378, `_tn_gcp_probe` :412, `_tn_ext_probe` :431, `tn_cmd_running_sha_*` :717/743, `tn_cmd_file_sha` :852, `tn_cmd_legacy_flags_check(_gcp)` :929/947. Add **`tn_cmd_datadir_probe <dd>`** after `:380`, which emits:

- `DD_KB` (from `timeout 300 nice du -sk`)
- `DD_FREE_KB` and `DD_MOUNT`
- `EPOCH_MAX_KB` / `EPOCH_MAX` (from `sudo sh -c "du -sk $dd/consensus-db/epochs/epoch-*" | sort -n | tail -1`)
- `COPY_FREE_KB` (df of `dirname dd`) and `DD_IS_MOUNT`
- `PID_FILE` / `PID_LOCKED` (`flock -n`)
- `NI_BAD` / `NI_HITS`, using the grep from the task brief
- `RSYNC`

How results are judged:

| Check | Committee (`check_gcp_one` :832, `preflight_gcp_one` :1145) | Followers (`check_ext_one` :866, `preflight_ext_one` :1163) |
|---|---|---|
| `NI_BAD` | blocker | exclude |
| `DD_FREE < 2×EPOCH_MAX + 10 GB` | blocker | exclude |
| `PID_LOCKED` | blocker | exclude |
| `PID_FILE` alone | warning (v0.16 ran here before?) | warning |
| `DD_MOUNT ≠ /` | blocker (the boot snapshot would not cover it) | — |
| `RSYNC=0` | 1b runs `apt-get install -y rsync` | — |
| `tn_gcp_boot_disk` fails | blocker | — |
| Regional `SSD_TOTAL_GB` headroom < 350 | warning | — |
| Copy plan | — | "copy ✓" or "resync-only" |

`--observer` is already covered by `LEGACY_FLAG_DENY_RE` (P0 `:451`, strip and assert at `:1196-1226`).

## 6. Phase 0 refresh

In adiri-lib.sh:303 and :319, replace the bare grep with a version gate. Keep the `TN_UPDATE_VERIFY_TIMEOUT` grep as well (AND):

```bash
have_marker() { v=\$(sudo sed -n 's/^readonly SCRIPT_VERSION=\"\\([0-9.]*\\)\".*/\\1/p' '${dir}/update-node.sh' | head -1); \
[ -n \"\$v\" ] && [ \"\$(printf '%s\\n%s\\n' '${TN_MIN_UPDATE_NODE_VERSION:-1.2.1}' \"\$v\" | sort -V | head -1)\" = '${TN_MIN_UPDATE_NODE_VERSION:-1.2.1}' ] \
&& sudo grep -q TN_UPDATE_VERIFY_TIMEOUT '${dir}/update-node.sh'; }
```

`tn_cmd_refresh_marker` should also echo `SCRIPT_VERSION=`. **Prerequisite:** 1.2.1 must be on tn-node-deployment `main`. If phase 0 runs before that, every follower is excluded, which is safe but useless.

## 7. Submodule

```bash
git submodule update --init --reference ../deploy-networks-common --dissociate common   # checks out f443045
git -C common checkout --detach dee644f && git add common   # dee644f == origin/main (pushed); commit on a branch
```

Until this is done, `adiri-lib.sh:59` fails to source, and so does every command including `--dry-run`.

## 8. Runbook

```bash
# 0 host (xerxes)
gcloud auth login && gcloud config set project telcoin-network
ping -c1 10.100.0.1; ip -br addr | grep -E '10\.100\.'          # no other VPN claiming 10.100/16
export TN_SSH_TRANSPORT=overlay TN_EXT_TRANSPORT=overlay        # key defaults to ~/.config/tnvpn/id_ed25519
cd ~/coding/telcoin/adiri-genesis   # §7 first; then: source adiri-lib.sh; tn_ssh validator-1-adiri true </dev/null; tn_ssh validator-10-adiri true </dev/null
# 1 REARM (§A) — sha, forks.rs, GAR digest (authenticated) → config.sh; banner must show 7 fields + subsecond=4294967295
# 2 static: bash -n *.sh; shellcheck -x adiri-*.sh restore-datadir-from-snapshot.sh; dry-run matrix (below)
# 3 ./adiri-update-all.sh --check            # 10/10 READY, NI clean, headroom, copy plan, boot disks, marker ABSENT (phase 0 will refresh)
# 4 prewarm (zero downtime):
source config.sh; for i in 0 1 2 3 4; do gcloud compute disks snapshot "${INSTANCE_NAMES[$i]}" --zone "${ZONES[$i]}" \
  --snapshot-names "${INSTANCE_NAMES[$i]}-warm-v0-16-0-adiri-$(date -u +%Y%m%d-%H%M)" --labels tn-kind=warm --async; done
# 5 ./adiri-update-all.sh </dev/null         # prepare pass: refresh 1.2.1, pull, builds, 1b; rc 1 at CONFIRM
# 6 (recommended) migration rehearsal: disk from validator-1's warm snapshot → scratch c3 VM, `docker run --network none` v0.16;
#   time "migrated legacy pack to v2 on open" → tune COMMITTEE_GATE_TIMEOUT_SECS; DELETE the disk (it holds validator keys)
# 7 HUMAN: ./adiri-update-all.sh             # type CONFIRM; window enforced pre-2a
```

**Watch:**
- On the committee: `tn_ssh validator-N-adiri "sudo docker logs --since 30m telcoin 2>&1 | grep -E 'migrated legacy pack to v2 on open|fork schedule \(adiri\)|Received invalid peer record!|skipping severe/fatal penalty for exempt peer|panic'"`. Expect:
  - one migration line per epoch opened (past epochs migrate lazily);
  - the fork line with all 7 tokens, including `subsecond_timestamp_fork_epoch=4294967295`;
  - invalid-record and exempt-penalty lines in bursts during the transition. If they keep coming after 10/10 are on v0.16, that is a finding.
- `curl -s -o /dev/null -w '%{http_code}' 127.0.0.1:43174/health/network` returns 200. Check which port `/health/network` is served on.
- The consensus round advances (driver phase 4, or `tn_latestConsensusHeader`).
- `./adiri-update-all.sh --check` shows 10/10 CONVERGED.
- `df -h /` stays within headroom as past epochs migrate.
- Hold the watch through the first epoch close on v0.16. Delete follower copies and snapshots only after that close passes cleanly.

**Rollback rule:**
- ≥4 committee nodes UPDATED and advancing: never roll back; fix forward.
- QUORUM LOST at 2c (nothing finalized on v0.16): read two nodes' logs. If they are still migrating, wait. If v0.16 is at fault (panic, node-info refusal, WRONG BUILD), run `./adiri-update-all.sh --rollback --from-run logs/<ts>-update-all` and type CONFIRM.
- After 2c PASS, a restore rewinds finalized history. That is a recovery decision, not this command.
- Followers never trigger a rollback.

## Dry-run tests to (re)run

Use a scratch `CONFIG_FILE` with a dummy, well-formed digest, because P0 refuses `REPLACE-ME` even under `--dry-run`. Run under bash 5 here and under 3.2 on the Mac (or `docker run bash:3.2` for `-n`).

1. **The old 15-case matrix,** with `FORK_CLOSE_EPOCH=553` in the scratch config: exit codes must be unchanged.
2. **New `none`-mode cases:**
   - baseline with `TN_DRY_RUN_EPOCH=600` → exit 0; shows the 2s and copy commands;
   - `NOW=T-20m` → P2 advises, pre-2a refuses with exit 1 and "nothing stopped";
   - `NOW=T-5h55m` → refused because the epoch opened too recently;
   - `snapshot:validator-3-adiri` → resume commands, exit 1;
   - `copy:validator-8-adiri` → resync-only, run continues;
   - `nodeinfo:validator-2-adiri` → 1b abort, exit 1; `nodeinfo:validator-9-adiri` → excluded, exit 2;
   - `headroom:validator-4-adiri` → exit 1;
   - `applyrefused:validator-6-adiri` → left running, verified.
3. **Rollback cases:**
   - no `--from-run` → R0 refuses;
   - a `FROM_RUN` missing one dsnap → refuse;
   - `snapready:v1` → refuse;
   - full `FROM_RUN` → R4 helper commands, R6 `mv` restore on copied followers and resync-only quarantine on the rest;
   - `restore:validator-2-adiri` → that node not started, exit 1.
4. **Standalone and live checks:**
   - `restore-datadir-from-snapshot.sh --dry-run`;
   - `restart-staggered.sh --check --dry-run` with `none`;
   - the new remote snippets in a Debian 12 container (as Agent A did);
   - **a live rehearsal on a scratch c3 VM**: 2s stop/snapshot, then the helper end to end. This proves NVMe by-id paths, IAM, quota and rsync before a real emergency needs them.

Optional: commit the matrix as `tasks/dry-run-matrix.sh` so it stops living only in prose.

### Critical Files for Implementation
- /home/drtnarg/coding/telcoin/adiri-genesis/adiri-update-all.sh
- /home/drtnarg/coding/telcoin/adiri-genesis/adiri-lib.sh
- /home/drtnarg/coding/telcoin/adiri-genesis/config.sh
- /home/drtnarg/coding/telcoin/adiri-genesis/restore-datadir-from-snapshot.sh (new)
- /home/drtnarg/coding/telcoin/adiri-genesis/restart-staggered.sh (consumer of `tn_epoch_deadline`, :395-416)