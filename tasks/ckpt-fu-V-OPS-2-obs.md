status: done

# V-OPS-2-obs checkpoint (item 3 observability, item 7 prose, item 6 cross-check for t_obs.sh)

Harness: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/vops2-tests/obs/
- t_v.sh (41 cases; driver drv.sh, fixtures fx.sh, shims/ + shims-noufw/, trees/{new,old,prel1,obs101})
- Paths: TN_ROOT_PREFIX=<fixture> for fallback resolvers + node_meta_path, plus path-rewritten
  copies of lib/common.sh (DEFAULT_* readonly dirs, legacy unit path in tn_node_launch_target) and
  lib/observability.sh (OBS_ETC_DIR, OBS_DATA_DIR, alloy unit path, build-info) prefixed with it.
- Final: /bin/bash 3.2.57 153 pass 0 fail; bash 5.3.15 153 pass 0 fail.
- Implementer t_obs.sh: 144/0 under 3.2.57, 144/0 under 5.3.15.

## Sections
- [x] read setup-observability.sh + lib/observability.sh + lib helpers
- [x] build shims + fixtures + harness
- [x] cases: metrics comment (new vs 8185d00) -- old bug reproduced, new fixed
- [x] cases: inject rc 1/2/3/4 messages
- [x] cases: wait ordering (node restarts vs alloy restarts vs disable vs rollback; real wait near boundary)
- [x] cases: --json --enable-health no node service; flag add failure
- [x] cases: success paths vs 8185d00 (ufw active/inactive/absent); docker log dir follows DATA_DIR
- [x] cases: wording greps; pre-L1 lib; obs lib 1.0.1 fallback
- [x] read ckpt-fu-C.md; run c-tests/t_obs.sh both bashes
- [x] prose review
- [x] report (returned to V-OPS-2)

## Findings
- F-a warn (pre-existing, also 8185d00): obs_status dies under set -e/pipefail when logs/metrics
  enabled and Alloy /metrics lacks the series (Alloy down/just started) -> show_status rc 1.
- F-b warn (pre-existing): value flag last (`--json --enable-logs --token`) -> rc 1, no stdout, no done.
- F-c note: rc 1 "already on the node command" then "not on the node command" (trailing-comment marker).
- F-d note: json_fail_flags done msg awkward/wrong for no node service; "Nothing was changed" false after
  a same-call disable.
- F-e note: rc 3 passthrough says "FLAGS are not single shell words" and repeats a bad METRICS_PORT value.
- F-f note: interactive enable_health with no node service records ENABLE_HEALTHCHECK_MONITOR=true
  (deliberate per ckpt-fu-C; code comment says otherwise).
- F-g note: flag failure after Alloy re-render/restart (documented); .node-meta unchanged (spec met).
- F-h note: --enable-logs --enable-metrics in one call: 2 Alloy + 2 node restarts (same on 8185d00).
- F-i note: soft-guard warnings stderr-only in --json.
- F-j note: JSON health warn advises a plain systemctl restart (no epoch wait).
- context: lib/common 1.4.0 confirm ${response,,} dies under bash 3.2 (pre-L1 lib bug, not obs).
