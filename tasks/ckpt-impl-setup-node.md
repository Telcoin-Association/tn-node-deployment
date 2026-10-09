status: complete (report returned to orchestrator)
completed: 1, 2, 3, 4, 5, 6, self-check
notes:
- 1 domain input: header 10-29, globals 55-67, step_config 537-551, prompt_public_rpc 594-662 (dashboard.<your-node-domain> wording), normalize_rpc_domain 664, validate_rpc_domain 674, init_public_rpc_flags 687-709, arg parse 1682-1696, init calls 1651 (json) / 1716 (interactive)
- 2 .node-meta: PUBLIC_RPC_DOMAIN=${PUBLIC_RPC_DOMAIN:-} at 1320 (heredoc, after WS_PORT), comment 1304
- 3 step_public_rpc 1373-1466 (public_rpc_cmd, public_rpc_pending); main 1724; json finalize 1640-1644 gated on domain
- 4 summary block 1491-1512
- 5 wrappers exec "$@"; UI sends --rpc-public false -> no-op; JSON done unchanged
- 6 SCRIPT_VERSION 1.1.0 (36)
- self-check: bash -n brew+3.2 OK; shellcheck --severity=error clean; default-severity identical to HEAD; harness tests in /tmp/tnh.* (validate, main flags, prompt, step_public_rpc 8 paths, json finalize)
