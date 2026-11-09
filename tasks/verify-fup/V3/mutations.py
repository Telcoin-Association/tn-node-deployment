# V3 mutation table: NAME -> (harness, [(file, old, new), ...]). Each reverts one OBS
# behaviour; mutate.sh applies it to a temp copy of the tree and expects a new FAIL.
M = {
 "M01 token mode 0644": ("lib", [("lib/observability.sh", 'tn_write_root_file "$f" 0640 "$OBS_ALLOY_USER" < <', 'tn_write_root_file "$f" 0644 "$OBS_ALLOY_USER" < <')]),
 "M02 token written through a pipe": ("lib", [("lib/observability.sh", 'if ! tn_write_root_file "$f" 0640 "$OBS_ALLOY_USER" < <(trap - ERR; printf \'%s\\n\' "$1"); then', 'if ! printf \'%s\\n\' "$1" | tn_write_root_file "$f" 0640 "$OBS_ALLOY_USER"; then')]),
 "M03 token through a here-string (bash 3.2 temp file)": ("lib32", [("lib/observability.sh", 'if ! tn_write_root_file "$f" 0640 "$OBS_ALLOY_USER" < <(trap - ERR; printf \'%s\\n\' "$1"); then', 'if ! tn_write_root_file "$f" 0640 "$OBS_ALLOY_USER" <<< "$1"; then')]),
 "M04 env file keeps OBS_INGEST_TOKEN": ("lib", [("lib/observability.sh", 'OBS_PUSH_HOST=$(obs_url_host "$push_url")"', 'OBS_PUSH_HOST=$(obs_url_host "$push_url")\nOBS_INGEST_TOKEN=$(obs_existing_token)"')]),
 "M05 env file without OBS_PUSH_HOST": ("lib", [("lib/observability.sh", 'OBS_PUSH_HOST=$(obs_url_host "$push_url")"', 'X=1"')]),
 "M06 env CREDENTIALS_DIRECTORY for every method": ("lib", [("lib/observability.sh", 'if [[ "$method" == "docker" ]]; then\n        text="${text}\nCREDENTIALS_DIRECTORY', 'if true; then\n        text="${text}\nCREDENTIALS_DIRECTORY')]),
 "M07 native unit without LoadCredential": ("lib", [("lib/observability.sh", '"LoadCredential=${OBS_TOKEN_NAME}:$(obs_token_file)" \\\n', '')]),
 "M08 native unit without LimitCORE": ("lib", [("lib/observability.sh", "        'LimitCORE=0' \\\n", '')]),
 "M09 InaccessiblePaths back to credstore": ("lib", [("lib/observability.sh", '-/etc/telcoin/bls-passphrase.cred -/etc', '-/etc/credstore.encrypted -/etc')]),
 "M10 docker without the token mount": ("lib", [("lib/observability.sh", '--mount type=bind,source=$(obs_token_file),target=${OBS_DOCKER_CRED_DIR}/${OBS_TOKEN_NAME},readonly \\\n', '')]),
 "M11 docker without --group-add": ("lib", [("lib/observability.sh", '--group-add ${gid} \\\n', '')]),
 "M12 docker without --ulimit core=0": ("lib", [("lib/observability.sh", '--ulimit core=0 \\\n', '')]),
 "M13 docker unit without LimitCORE": ("lib", [("lib/observability.sh", 'RestartSec=10\nLimitCORE=0\n', 'RestartSec=10\n')]),
 "M14 docker token via -e": ("lib", [("lib/observability.sh", '--env-file ${envf} \\\n', '--env-file ${envf} -e OBS_INGEST_TOKEN \\\n')]),
 "M15 vendored logs endpoint back to bearer_token env": ("lib", [("observability/config.alloy", '\t\turl               = sys.env("OBS_PUSH_URL")\n\t\tbearer_token_file = sys.env("CREDENTIALS_DIRECTORY") + "/ingest-token"', '\t\turl          = sys.env("OBS_PUSH_URL")\n\t\tbearer_token = sys.env("OBS_INGEST_TOKEN")')]),
 "M16 vendored metrics tls_config min_version TLS12": ("lib", [("observability/config.alloy", 'server_name = sys.env("OBS_METRICS_PUSH_HOST")\n\t\t\tmin_version = "TLS13"', 'server_name = sys.env("OBS_METRICS_PUSH_HOST")\n\t\t\tmin_version = "TLS12"')]),
 "M17 vendored server_name literal": ("lib", [("observability/config.alloy", 'server_name = sys.env("OBS_PUSH_HOST")', 'server_name = "obs.adiri.telcoin.network"')]),
 "M18 fallback logs without tls_config": ("lib", [("lib/observability.sh", '    tls_config {\n      server_name = sys.env("OBS_PUSH_HOST")\n      min_version = "TLS13"\n    }\n', '')]),
 "M19 migration does not move the legacy token": ("lib", [("lib/observability.sh", '        obs_write_token_file "$legacy" || return 1\n', '        :\n')]),
 "M20 migration said every time": ("lib", [("lib/observability.sh", 'if [[ -n "$legacy" && "$OBS_TOKEN_MOVED_SAID" != "true" ]]; then', 'if [[ -n "$legacy" ]]; then')]),
 "M21 existing token: legacy line first": ("lib", [("lib/observability.sh", '    if [[ -f "$f" && ! -L "$f" && -r "$f" ]]; then\n        t="$(head -n 1 -- "$f" 2>/dev/null)" || t=""\n    fi\n    [[ -n "$t" ]] || t="$(_obs_env_token)"', '    t="$(_obs_env_token)"\n    if [[ -z "$t" && -f "$f" && ! -L "$f" && -r "$f" ]]; then\n        t="$(head -n 1 -- "$f" 2>/dev/null)" || t=""\n    fi')]),
 "M22 rotate: no rollback of the files": ("lib", [("lib/observability.sh", '    _obs_restore || true\n    if obs_restart_alloy; then', '    if obs_restart_alloy; then')]),
 "M23 rotate: no restart after the rollback": ("lib", [("lib/observability.sh", '    _obs_restore || true\n    if obs_restart_alloy; then', '    _obs_restore || true\n    if false; then')]),
 "M24 settle: one is-active read": ("lib", [("lib/observability.sh", 'local n="${OBS_ALLOY_SETTLE_SECS:-5}" i=1 state', 'local n=1 i=1 state')]),
 "M25 rotate: restart result not checked": ("lib", [("lib/observability.sh", '    if obs_restart_alloy; then\n        _OBS_SNAP_BODY=()\n        OBS_ROTATE_MSG=""', '    if obs_restart_alloy || true; then\n        _OBS_SNAP_BODY=()\n        OBS_ROTATE_MSG=""')]),
 "M26 rotate: no refusal without the unit": ("lib", [("lib/observability.sh", '    if [[ ! -f "$unitf" ]]; then', '    if false; then')]),
 "M27 rotate: no trim": ("lib", [("lib/observability.sh", 'token="$(_obs_trim_token "${1:-}")"', 'token="${1:-}"')]),
 "M28 disable keeps the token file": ("lib", [("lib/observability.sh", '    _tn_shred "$(obs_token_file)"\n    print_ok "Telemetry shipper stopped', '    print_ok "Telemetry shipper stopped')]),
 "M29 status without the token line": ("lib", [("lib/observability.sh", '    _obs_token_status\n\n    # Pull Alloy', '\n    # Pull Alloy')]),
 "M30 host keeps the port": ("lib", [("lib/observability.sh", '    else\n        h="${h%%:*}"\n    fi', '    fi')]),
 "M31 remove-node without the token shred": ("e2e", [("remove-node.sh", '    _rm_shred "${p}/etc/telcoin/alloy/ingest-token" "${p}/etc/telcoin/alloy/telcoin-alloy.env"\n', '')]),
 "M32 rotate combined with enable allowed": ("e2e", [("setup-observability.sh", '            *true*) arg_fail "--rotate-token runs on its own; run the enable or disable separately." ;;', '            *true*) : ;;')]),
 "M33 rotate cli: no non-tty refusal": ("e2e", [("setup-observability.sh", '        if [[ ! -t 0 ]]; then', '        if false; then')]),
 "M34 json rotate: no token:rotated": ("e2e", [("setup-observability.sh", '    JSON_DID+=("token:rotated")', '    :')]),
 "M35 json_on_exit without tn_remove_inflight_tmp": ("e2e", [("setup-observability.sh", '    tn_remove_inflight_tmp 2>/dev/null || true\n    tn_release_update_lock 2>/dev/null || true\n    [[ "$JSON_DONE_EMITTED"', '    tn_release_update_lock 2>/dev/null || true\n    [[ "$JSON_DONE_EMITTED"')]),
 "M36 gate without obs_rotate_token": ("skew", [("setup-observability.sh", ' obs_node_log_dir \\\n              obs_rotate_token; do', ' obs_node_log_dir; do')]),
 "M37 disable does not shred a legacy env": ("lib", [("lib/observability.sh", '    if [[ -n "$(_obs_env_token)" ]]; then\n        _tn_shred "${OBS_ETC_DIR}/telcoin-alloy.env"\n    fi\n', '')]),
 "M38 rotate token file written 0640 root:root": ("lib", [("lib/observability.sh", 'tn_write_root_file "$f" 0640 "$OBS_ALLOY_USER" < <', 'tn_write_root_file "$f" 0640 root < <')]),
}
import sys, os
if __name__ == "__main__":
    if sys.argv[1] == "list":
        for k, (h, _) in M.items(): print(h + "\t" + k)
        sys.exit(0)
    name, root = sys.argv[1], sys.argv[2]
    for f, old, new in M[name][1]:
        p = os.path.join(root, f); s = open(p).read()
        if s.count(old) != 1:
            print("NOT APPLIED (%d matches) in %s" % (s.count(old), f)); sys.exit(3)
        open(p, "w").write(s.replace(old, new))
    print("applied")
