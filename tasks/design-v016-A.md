I could not write a plan file in read-only mode, so the full design is below. Line numbers are from the current tree (HEAD df82deb).

## Corrections to the brief

1. **There are four apply functions, not two.** `apply_docker_update` (update-node.sh:545) and `apply_source_update` (:887) are interactive. `json_apply_source` (:1585) and `json_apply_docker` (:1678) are the `--json` paths. The binary backups are at :930-932 and :1600-1602. The docker launch-file backups are at :570 and :1691-1694.
2. **`OLD_REF` cannot be trusted as the running version on source installs.** It is `git describe` of the checkout at prepare time (:700-701, :1427-1428). Suppose an operator prepares v0.16, discards it, and prepares again. The second prepare records `OLD_REF=v0.16.0-adiri` while v0.15 is still running. The script would then call the update non-migrating and auto-roll back onto a migrated datadir.
   - **Source:** use the marker `/opt/telcoin/telcoin-network.version` instead. It is written only by setup (setup-node.sh:536) and by verified applies (:1008, :1650), per lib/common.sh:1291-1307, and the UI already treats it as the running version (server.py:850-860). It was introduced on 2026-06-18 (90ec9dc), so a missing marker means the binary predates v0.16.
   - **Docker:** `OLD_IMAGE` is reliable, because apply's substitution fails unless that image is in the launch file (:593, :1709).
3. **Rejected the on-disk signal.** I could not verify whether v0.15 creates `telcoin.pid` or whether v0.16 removes it on exit, and reading the pack header means parsing a binary format. It isn't needed: treating an unknown running version as "migrating" only costs the automatic rollback.
4. **The UI drops unknown event names.** `ui/static/index.html:2236` ends `streamLineHtml` with `} else return null;`. I grepped that file (outside your read list) to answer the UI question. So no new event name.

## Where the helper lives

Put it in update-node.sh, not lib/common.sh. update-node.sh is the only consumer, and the helper needs only `version_gte` (lib/common.sh:1089), which every lib version has. A lib home would need a `COMMON_VERSION` bump plus a `declare -F` skew guard like the one at :457. `COMMON_VERSION` stays 1.6.0.

## Changes in update-node.sh

**:61-71** (explicit means numeric, the same test as today):
```bash
VERIFY_TIMEOUT_EXPLICIT=false
if [[ "${TN_UPDATE_VERIFY_TIMEOUT:-}" =~ ^[0-9]+$ ]]; then
    readonly VERIFY_TIMEOUT_SECONDS="${TN_UPDATE_VERIFY_TIMEOUT}"
    VERIFY_TIMEOUT_EXPLICIT=true
else
    readonly VERIFY_TIMEOUT_SECONDS=45
fi
readonly VERIFY_TIMEOUT_EXPLICIT
readonly STORAGE_MIGRATION_FLOOR="0.16.0"
readonly STORAGE_MIGRATION_VERIFY_SECONDS=600
STORAGE_MIGRATION=false
```
`${TN_UPDATE_VERIFY_TIMEOUT+x}` works in bash 3.2 and under `set -u`. But it would count an empty or garbage value as explicit, and :65 already sends those to the default.

The UI helper never passes this variable: it runs `sudo -n` then `exec bash` (telcoin-ui-helper.sh:365), and sudo resets the environment. The UI therefore always gets the 600 s default.

**New helpers, inserted after `observer_strip_needed` (:326), before :328:**
```bash
installed_source_ref() {
    head -n 1 "${DEFAULT_INSTALL_DIR}/telcoin-network.version" 2>/dev/null || true
}

# storage_migrating_upgrade <running> <target>: rc 0 when target >= floor (no x.y.z = newest)
# and running < floor (no x.y.z = unknown = older).
storage_migrating_upgrade() {
    local ver_re run_v new_v
    ver_re='([0-9]+\.[0-9]+\.[0-9]+)'
    run_v=""
    new_v=""
    if [[ "${2:-}" =~ $ver_re ]]; then new_v="${BASH_REMATCH[1]}"; fi
    if [[ -n "$new_v" ]] && ! version_gte "$new_v" "$STORAGE_MIGRATION_FLOOR"; then return 1; fi
    if [[ "${1:-}" =~ $ver_re ]]; then run_v="${BASH_REMATCH[1]}"; fi
    [[ -n "$run_v" ]] || return 0
    ! version_gte "$run_v" "$STORAGE_MIGRATION_FLOOR"
}

update_verify_window() {
    if [[ "$STORAGE_MIGRATION" == "true" && "$VERIFY_TIMEOUT_EXPLICIT" != "true" ]]; then
        printf '%s\n' "$STORAGE_MIGRATION_VERIFY_SECONDS"
    else
        printf '%s\n' "$VERIFY_TIMEOUT_SECONDS"
    fi
}

# rc 0 + message when free space < 2x largest epoch-N; rc 1 when enough or unknown.
storage_migration_space_shortfall() {
    local epochs largest_kb avail_kb
    epochs="${1:-}/consensus-db/epochs"
    [[ -n "${1:-}" && -d "$epochs" ]] || return 1
    largest_kb="$(du -sk "$epochs"/epoch-* 2>/dev/null | awk '$2 !~ /\.migrating$/ && $1 > m { m = $1 } END { print m + 0 }')"
    avail_kb="$(df -Pk "$epochs" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    [[ "$largest_kb" =~ ^[0-9]+$ && "$avail_kb" =~ ^[0-9]+$ ]] || return 1
    (( avail_kb < 2 * largest_kb )) || return 1
    printf 'Low disk: %s MiB free under %s; the migration needs at least %s MiB (twice the largest epoch-N).\n' \
        "$(( avail_kb / 1024 ))" "$epochs" "$(( largest_kb * 2 / 1024 ))"
}

# storage_migration_begin <running> <target>: sets STORAGE_MIGRATION, warns, and confirms
# in interactive mode. rc 1 only when the operator declines.
storage_migration_begin() {
    local dd short
    STORAGE_MIGRATION=false
    storage_migrating_upgrade "${1:-}" "${2:-}" || return 0
    STORAGE_MIGRATION=true
    dd="$(tn_resolve_data_dir 2>/dev/null || true)"
    update_wait_say warn "One-way update: ${2} migrates the consensus store in ${dd:-the data dir} on first start and older releases cannot open it afterwards. Only a data dir snapshot taken before the update can undo it; a failed health check will not roll back."
    if short="$(storage_migration_space_shortfall "$dd")"; then update_wait_say warn "$short"; fi
    [[ "$JSON_MODE" == "true" ]] && return 0
    if ! confirm "You have a snapshot of ${dd:-the data dir} and want this one-way update?"; then
        print_info "Cancelled. The prepared update is kept."
        return 1
    fi
}

# storage_migration_verify_failed <what> <undo-cmd>: no rollback; node left running. rc 1.
storage_migration_verify_failed() {
    local dd msg
    dd="$(tn_resolve_data_dir 2>/dev/null || true)"
    clear_pending_state
    msg="${SERVICE_NAME} did not answer within $(update_verify_window)s of starting ${1}. Not rolled back: the previous release cannot open the migrated data dir. The node was left running and may still be migrating (journalctl -u ${SERVICE_NAME} -f). To go back: systemctl stop ${SERVICE_NAME}; restore ${dd:-the data dir} from the pre-update snapshot; ${2}; systemctl start ${SERVICE_NAME}."
    if [[ "$JSON_MODE" == "true" ]]; then
        json_event error "$msg"
        json_emit "{\"event\":\"done\",\"ok\":false,\"phase\":\"apply\",\"rolled_back\":false,\"storage_migration\":true,\"msg\":\"$(json_escape "$msg")\"}"
    else
        print_error "$msg"
    fi
    return 1
}
```
`update_wait_say` (:426) already means "a warn event in `--json` mode, `print_warn` otherwise", so it is reused here.

**`verify_health_after_restart` (:330-353):** add `local limit; limit="$(update_verify_window)"`, then use `$limit` at :333 and :352. Rollback verifies keep 45 s, because `STORAGE_MIGRATION` is never true when a rollback runs.

**The four apply paths.** Each one gets one call before the stop, and one block just before its rollback block:

| Function | Before the stop | Failure block before | `<undo-cmd>` |
|---|---|---|---|
| `apply_docker_update` | before :560: `storage_migration_begin "${old_image##*/}" "${new_image##*/}" \|\| return 1` | :650 | `cp -p ${backup} ${launch_file} && systemctl daemon-reload` |
| `apply_source_update` | before :921: `storage_migration_begin "$(installed_source_ref)" "$new_ref" \|\| return 1` | :1018 | `cp -p ${backup} ${installed}${wrapper_backup:+ && cp -p ${wrapper_backup} ${wrapper}}` |
| `json_apply_source` | after :1598 (same call) | :1655 | same as source |
| `json_apply_docker` | after :1690 (same call) | :1748 | same as docker |

The failure block is:
```bash
if [[ "$STORAGE_MIGRATION" == "true" ]]; then
    storage_migration_verify_failed "$new_ref" "<undo-cmd>"   # $new_image on the docker paths
    return 1
fi
```
`##*/` drops the registry host, so a `host:5000` port is never read as a version, the same way :625 does it.

In the interactive paths, the block comes before the `confirm "Roll back..."` prompt, so the binary/image rollback is never offered for this case.

**JSON prepare:** call `storage_migration_begin` just before the done event in `json_prepare_source` (:1514) and `json_prepare_docker` (:1553, using `${current_image##*/}`). In JSON mode it only warns. UI users can't be prompted at apply time, so prepare is the only moment they can be warned before they press Apply.

## Leave the node running or stop it?

Recommend leaving it running:
- The likeliest cause of a slow verify is that the migration is still copying.
- Stopping it would go through `wait_for_service_stopped`, which sends SIGKILL after 30 s (:280-283) and would interrupt the copy.
- Stopping doesn't help recovery. The only way back is a manual snapshot restore, and that starts with a stop anyway.
- A start that is genuinely broken gets stopped by systemd's start limit (:291-296).
- A validator that finishes migrating rejoins without anyone touching it.

Two more choices in the failure path:
- The pending state is cleared, as the existing "Leaving node on new binary" branch does (:1046).
- The marker is not rewritten, matching the rule at lib/common.sh:1295. A stale "v0.16" marker after an operator restores the snapshot would turn the next retry into an auto-rollback. The cost is that the UI keeps showing the old ref until the next verified apply.

## Disk check: warn, don't block

- The migration copies first, so running out of space fails without damaging the original epoch. With no rollback, the operator can free space and restart.
- `du` is only an estimate of the space the migration needs.
- Past epochs migrate lazily, after the script has exited, so no pre-check can guarantee the space anyway.
- Blocking a `--json` run on a heuristic would stall the fleet.
- In interactive mode the warning prints right before the confirmation, so the operator decides with it in front of them.

## JSON vocabulary and `--check`

The existing events on fd 3 are `step`, `log`, `warn`, `error` and `done`. `done` carries `ok`, `phase`, `msg`, `new_ref`, `new_version`, `new_image` and `rolled_back`. `--check` prints a bare status object with no event key. The server adds `closed` and a synthesized `done`.

New: a boolean `storage_migration` on the failed `done`, not a new event name.

**`--check` field: worth it (about 4 lines).** In `json_check`:
- Set `running="$(installed_source_ref)"` in the source arm, or `running="${img##*/}"` in the docker arm.
- Add `[[ -n "$latest" ]] && storage_migrating_upgrade "$running" "$latest" && mig=true`.
- Append `,\"storage_migration\":${mig}` to the object at :1401.

server.py:3883-3885 passes the field through unchanged, so the fleet driver can refuse to apply until a snapshot is recorded.

**UI: no change needed.** The `error` event and the `done` msg already render (index.html:2220, :2232-2235), and the toast reads "did not complete" (:2341). Showing `storage_migration` on the status card would be a separate UI_VERSION change.

## Tests

The harness follows tasks/lessons.md:40-50 and :78-84: run under `/bin/bash` 3.2 and bash 5, one process per environment variant, sourced at top level.
- `DEFAULT_INSTALL_DIR` is readonly (lib/common.sh:59), so copy `lib/` into the scratch dir with that line sed-replaced, rather than symlinking it.
- Stubs as functions:
  - `systemctl` logs its arguments; `is-active` returns a rc you control.
  - `sleep` is a no-op.
  - `curl` returns `{"result":{}}` when `FAKE_RPC_OK=1`.
  - `docker` serves `inspect`.
  - `update_epoch_wait` is `:` and `node_is_onchain_validator_or_unknown` returns 1.
  - `pending_state_path`, `tn_node_launch_target`, `tn_resolve_data_dir` and `df` point at fixtures.
  - `write_source_version_marker` records that it was called.
- Open fd 3 to a file.
- Make the epoch fixtures from `/dev/urandom`: sparse or zero-filled files fool `du`.

Cases:
1. **Truth table for `storage_migrating_upgrade`:** v0.15.0→v0.16.0 = 0, v0.16.0→v0.16.1 = 1, ""→v0.16.0 = 0, v0.15.0→main = 0, v0.16.0-adiri-3-gabc→main = 1, v0.16→v0.15 = 1.
2. **`json_apply_source`, marker v0.15 → v0.16, RPC never answers:**
   - "within 600s" is printed.
   - The installed binary is still the new build.
   - There is no `stop` after the `start`.
   - The pending state is cleared and the marker stub was not called.
   - A `warn` comes before "Stopping", then an `error`, then exactly one `done` with `rolled_back:false,storage_migration:true`. rc 1.
3. **Same with marker v0.16.0 → v0.16.1:** 45 s window, the backup is restored, the `done` has `rolled_back:true`, and there is no `storage_migration` field.
4. **`TN_UPDATE_VERIFY_TIMEOUT=300`, migrating:** 300 s window and no rollback. With `=abc` the window is 600 s.
5. **`json_apply_docker`, `localhost:5000/tn/adiri:v0.15.0-adiri` → `:v0.16.0-adiri`:** no rollback, and the launch file still names the new image. v0.16.0→v0.16.1 rolls back.
6. **`json_check`:** docker v0.15→latest v0.16 gives `"storage_migration":true`; v0.16→v0.16 gives false. One object, no `done`.
7. **Interactive `apply_source_update`:** stdin `n` returns 1 with an empty systemctl log and no `.bak`. Stdin `y` with a slow start: no rollback, and the message includes the restore command.
8. **Disk:** largest epoch 3 MiB plus a 10 MiB `epoch-2.migrating`. Avail 5 MiB warns "at least 6 MiB"; 7 MiB doesn't warn.

Then `bash -n`, shellcheck, and `/bin/bash tools/check-bash32.sh update-node.sh`.

## Versions and docs

- update-node.sh:56 → `1.2.1`. Add a paragraph to the header (:15-23), which `--help` prints.
- update-scripts.sh:27 → `1.1.72`.
- `COMMON_VERSION` unchanged.
- Run `bash tools/gen-checksums.sh`; only the two scripts' sidecars should change.

**README**
- Add a bullet after :882: "When the node runs a release older than `v0.16.0-adiri` and the target is `v0.16.0-adiri` or newer (or a branch or commit), apply is one-way. It warns, checks for free space of twice the largest `consensus-db/epochs/epoch-N`, waits up to 600 s unless `TN_UPDATE_VERIFY_TIMEOUT` is set, and never rolls back: a failed check leaves the node running and prints how to restore the pre-update data dir snapshot."
- Changelog, above :1417. There is no 1.1.71 entry; that release was the key vendoring in df82deb.
  - `### update-scripts v1.1.72 — ships update-node v1.2.1`
  - `### update-node v1.2.1 — one-way storage migration for v0.16.0-adiri`: the bullet above, plus the `done` and `--check` `storage_migration` field, the prepare-time warning, and "an unreadable running version counts as one-way".

**OPERATOR.md**
- Change the bullet at :465 to "...except after a one-way update (below)."
- Add a bullet after it: "When the target is `v0.16.0-adiri` or newer and the node runs an older release, the update is one-way. The new release migrates the consensus store on its first start, and older releases cannot open the data dir afterwards. Snapshot the data dir before you apply. The script warns when the disk is short, asks you to confirm, and waits up to 600 seconds. If the check fails it does not roll back; the node keeps running and may still be migrating. To go back, stop the node, restore the snapshot, and run the restore command the script prints."
- In the :1136 row add: "A one-way apply never rolls back; its `done` carries `"storage_migration":true`, and `--check` adds the same boolean."
- Add a §9 troubleshooting row: "Older release fails with `invalid version`" → "restore the pre-update snapshot or run v0.16+".

**Partner guide:** AGENTS.md:20-23 requires docs/partner/mno-node-guide.md to change alongside. I didn't read it (outside your list). Grep it for rollback wording and, if it describes the rollback, update it, rebuild the PDF and bump `metadata.yaml`.

**Fleet driver:** it exports `TN_UPDATE_VERIFY_TIMEOUT=300`, which now wins over the 600 s default. For this rollout, set 900 or leave it unset.

### Critical Files for Implementation
- /home/drtnarg/coding/telcoin/tn-node-deployment/update-node.sh
- /home/drtnarg/coding/telcoin/tn-node-deployment/lib/common.sh (read-only: `version_gte` :1089, marker :1291-1307)
- /home/drtnarg/coding/telcoin/tn-node-deployment/update-scripts.sh
- /home/drtnarg/coding/telcoin/tn-node-deployment/OPERATOR.md
- /home/drtnarg/coding/telcoin/tn-node-deployment/README.md