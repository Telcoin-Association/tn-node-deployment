status: complete
completed sections: setup-node.sh, check-node.sh, firewall-setup.sh, final report

## setup-node.sh
- SHOULD-FIX 1419 vs 1346/801: gate is `systemctl is-active`, not the start answer; interactive re-run keeping keys over a running unit + decline start -> rpc-enable restarts node. Fix: NODE_STARTED flag set in the start branch.
- SHOULD-FIX(verify) 1690/1692 + 695, server.py:2837 -> helper:673: UI sends `--rpc-public true` when rpc_public truthy (index.html:2837 toggles it); was ignored, now error+exit at keygen. Fix on UI side (send false until it forwards --rpc-domain) or accept.
- NOTE 1406: ${DATA_DIR}/node-info.yaml vs install-caddy tn_resolve_data_dir (install-caddy.sh:681-684) with custom --data-dir -> permanent pending, follow-up can't fix.
- NOTE 1464: "cert on first request" wrong (no on_demand; Caddy obtains at load). 1055 pre-existing comment names config-caddy.sh as WS_PORT consumer (install-caddy write_rpc_block is).
- a met, b met, c met, d met, e met except declined-start gate on re-run, f met
## check-node.sh
- NOTE 600-614: 0600 root .node-meta, non-root run -> pending node shown as "not configured (private node)".
- all reqs met
## firewall-setup.sh
- no findings; req met
## process
- no *.sha256 / update-scripts bump / changelog in git status -> CI stale sidecar
