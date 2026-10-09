status: done
completed:
- item 1 (check-node.sh report_public_rpc unreadable .node-meta -> unknown)
- item 2 (caddy_serves_public_edge marker anchored to line 1)
- item 3 (reset hint uses ${SCRIPT_DIR}/install-caddy.sh)
- item 4 (helper comment reworded)
- self-check: bash -n (3.2 + 5.3) and shellcheck -x --severity=error clean on both
