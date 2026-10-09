status: complete (report returned to orchestrator)
completed: 1, 2, 3, 4, 5, 6, 7, 8, 9 -- bash -n (/bin/bash 3.2 + brew bash) clean, shellcheck -x all severities clean, sandbox smoke T1-T15 + final move regression pass
added items (coordinator):
- 8: caddy_edit_node_info must handle legacy `worker:` map AND current `workers:` list (set/clear rpc on EVERY entry, never primary); rpc-status advertised_* read both (first worker) -> python get mode; scratch fixtures 1-entry + 2-entry list: set, re-set no-op, clear; report list-shape YAML
- 9: --move-dashboard-to <host> for rpc-enable (json+human): when rpc-domain == dashboard domain + flag -> rewrite dashboard block site address only (bytes otherwise identical), write RPC block, ONE swap + ONE reload; validate host like --domain; refuse == rpc-domain; guard msg prints `sudo bash <path>/install-caddy.sh --phase=rpc-enable --rpc-domain <d> --move-dashboard-to dashboard.<d>` + DNS A record note; fixtures node7.example
design notes:
- tmp registry CADDY_TMP_FILES + caddy_cleanup_tmp; json_on_exit also cleans; main must set trap caddy_cleanup_tmp EXIT for non-runner paths (TODO in item 5)
- WS preflight: ss listen OR non-comment whole-word --ws in tn_node_launch_target file; else tn_node_inject_flags with marker "${flags}$"; launch .tn-bak restored by brick guard on failure; force restart when launch changed even if node-info unchanged
- python editor omits ws line when ws_url empty
- human phases via run_phase_human; check-dns human exit 1 when not propagated
- rpc-status JSON appends advertised_http, advertised_ws, ws_listening
- TODO: track /tmp mktemps in do_* via caddy_tmp_track

smoke: T1 fresh enable (restart, 0644, no bak); T2 guard dies no write; T3 move+rpc+ws inject one swap/reload; T4 rpc-status keys; T5 json idempotent; T6/T6b reload fail restore, no advertise; T7 validate fail live untouched no temp; T8 teardown ok + reload-fail restore; T9 json byte-compat status/check-dns/unknown, rpc-status prefix; T10 dns exit 0/1; T11 legacy fenceless parse identical + move; T14 no --http line -> http-only; T15 brick guard restores launch+node-info; T12 no temp leftovers
