status: complete (items 1-10 done, self-checks green)
original: scratchpad/fix-ic/install-caddy.v130.orig.sh ; tests: scratchpad/fix-ic/sb/t_*.sh
completed items:
- 1 brick guard: reset-failed before recovery restart; caddy_node_stays_active (~10s poll) -> die states back up vs STILL DOWN (+ start cmd); docker = same unit
- 2 caddy_launch_inject_target (replicates lib rule; ok only if non-comment, no trailing #, not continued, `node` in logical cmd) + caddy_launch_verify_inject post-check (restore bak, http-only); has_flag accepts quoted flags; caddy_launch_http_line_continued removed (subsumed)
- 3 caddy_apply_live: restore only on failed reload cmd; reload ok but inactive -> die, new config kept
- 4 caddy_backup_admin_off -> one-time systemctl restart with reason
- 5 clear-mode edit failure -> warning + manual instructions, vhost still removed
- 6 caddy_port_proc/caddy_port_holder split; caddy_ws_holder_is_node; foreign holder -> http-only naming process (deviation: skips launch rule/injection)
- 7 teardown w/o caddy binary: rewrite (novalidate), no reload, close ports; early return only if no Caddyfile and no .tn-orig
- 8 domain <=253, labels 1-63; interactive dashboard.<d> pre-check
- 9 TERM/INT/HUP traps before EXIT trap
- 10 header rewritten (reload rule, WS preflight, brick guard window)
self-check: bash -n 3.2+5 OK; shellcheck --severity=error OK (all-severity findings identical to v1.3.0); fixtures t_launch 14/14, t_preflight 26/26, t_misc 14/14, t_guard 10/10, t_teardown 7/7, t_clear ok, signal test rc=143/129 + temp cleanup
