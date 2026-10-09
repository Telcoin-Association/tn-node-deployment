status: done (items 1-9)
target: setup-node.sh (backup of pre-fix copy: /tmp/setup-node.pre-fix.sh)
completed:
- 1 NODE_STARTED flag: global; set after "Service is running"; step_public_rpc gates on it (pending w/ follow-up cmd)
- 2 --rpc-public w/o domain: RPC_PRIVATE_NOTE; no error; public_rpc_no_domain_notice (warn + cmd, json `log` event) from init (json) / step_config elif (interactive); public_rpc_cmd optional domain; tr-lowercased value; header comment
- 3 --public-ip space form in both install-caddy calls
- 4 ni via tn_resolve_data_dir (mirrors caddy_node_info_path)
- 5 propagated regex (compact+spaced)
- 6 TLS text + WS_PORT comment (install-caddy write_rpc_block; config-caddy maintainer-only provenance)
- 7 RPC_DOMAIN_GIVEN / empty --rpc-domain warns; 63-char label limit
- self-check: bash -n 3.2+5 OK; shellcheck -x --severity=error clean (all-severity codes unchanged vs pre-fix: SC1091x3 SC2034x3 SC2086x3); offline trace harness /tmp/sn-trace.sh: UI invocations end done ok:true
- 8 lib/fallback.sh: FALLBACK_VERSION 1.0.2; new _tn_meta_data_dir (DATA_DIR abs + -d, prefix-aware); tn_resolve_data_dir returns it for unified + legacy metas, else old paths; fixture-tested bash 3.2+5. Audit: install-caddy gains fix; check/remove/edit/update already meta-first -> unchanged; none worse
- 9 setup-node arg loop: missing_option_value() before main (print_error | --json: fds+trap+error event -> done ok:false), guard case at loop top over the 18 shift-2 options (list verified == shift-2 set); note: common.sh set -e made it a silent exit 1, not an infinite loop
- self-check 8-9: bash -n 3.2+5, shellcheck -x --severity=error clean on both files
