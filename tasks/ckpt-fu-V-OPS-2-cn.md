status: done

# V-OPS-2-cn checkpoint (check-node.sh 1.2.0, c7a9690)

Harness: /private/tmp/claude-501/-Users-grant-coding-telcoin-tn-node-deployment/eddb430f-f0dc-43fe-9180-65cd421b1e88/scratchpad/vops2-tests/cn/
Driver: `bash t_cn.sh <bash-binary> [case-regex]` (shims/, mkfx.py, work-<tag>/fx/<case>/plain.txt),
ws/t_ws.sh <bash>, t_sig.sh <bash>, live-run*/ (live read-only).
Paths: TN_ROOT_PREFIX tree + path-rewritten lib/common.sh copy (DEFAULT_INSTALL_DIR and the unit
path in tn_node_launch_target prefixed); check-node.sh copied verbatim.

## Sections
- [x] read check-node.sh + library functions
- [x] harness: shims + fixtures
- [x] network / chain id / --network-rpc / other-chain WARN
- [x] authority id + committee header check
- [x] epoch section
- [x] worker count + per-worker probes
- [x] macOS /bin/bash run, df/meminfo
- [x] wss probe timing (ws/t_ws.sh 6/6 both bashes; t_sig.sh 3/3 both)
- [x] stale block + http.api/ws.api warnings
- [x] usage errors, exit code, pre-L1 library (+ L1 1.5.0 lib)
- [x] VALIDATOR_ADDRESS mismatch (gaps reproduced)
- [x] live cast comparison (all values match; b3 == b5)
- [x] implementer checkpoint + tests: t_b.sh 493/493 both bashes; t_ws.sh 7/7 both
- [x] prose

## Results
t_cn.sh: 68 cases, 428 assertions; 423 pass / 5 fail under /bin/bash 3.2.57 and bash 5.3.15
(the 5 fails are F1 and F2 below, reproduced on purpose).

## Findings
- F1 warn: reputation never shown (live sub_dag key is reputation_scores; python reads reputation_score;
  implementer shim encodes the singular key). Pre-existing since 1.1.55.
- F2 warn: VALIDATOR_ADDRESS mismatch WARN only inside report_epoch_committee after its early returns:
  missing with local RPC down + --no-network, and when the network epoch read fails; in the latter the
  unknown-membership rule then raises ERROR "registry has this node as Active" from the .node-meta
  address while the node's own address has no record.
- F3 note: wrong-chain run says "Skipping on-chain validator status (network RPC unreachable)".
- F4 note: `all` in --http.api is eth,net,web3,rpc on v0.15.0 (binary help); fix text "remove all".
- F5 note: "committee N" in the Network line counts authors of the latest commit (live 4 vs 5).
- F6 note: old library: "Authority ID unknown (no tn_info answer)" though tn_info was not asked.
- F7 note (prose): workers ERROR, Observer-in-committee WARN and meta-mismatch WARN give no next step.
