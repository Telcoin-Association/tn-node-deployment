status: done

# DOC-R checkpoint (README.md only; worktree tnd-req-doc-r, branch req/doc-r)

Sections:
- [x] pass 1: chain configs come from the pinned tag -- a9f82e9
- [x] pass 2: hardware requirements per network -- 88f82de
- [x] pass 3: the mainnet chain id is 731 -- c546d82
- [x] self-check

Changelog order (agreed with the coordinator 2026-11-21): newest first by commit, each pass
only adding lines. 17 new entries (16 versioned + aws/node.yaml), lines 2120-2214.

Self-check results:
- grep -c '26\.04' README.md = 9 (unchanged)
- newest entry per script = tip version: lib/common.sh 2.2.5, setup-node 2.1.4, edit-config 2.2.2,
  check-node 2.2.1, update-node 2.1.2, install-caddy 2.2.1, telcoin-ui 2.1.3
- stale-pattern grep above ## Changelog (line 2114): no hits
- 487|0x1e7 above: none; below: the new entries (2121, 2122, 2159, 2160, 2164, 2168, 2171,
  2172) and the old lib/common v1.6.0 line, now 3559 (was 3394), byte-identical
- the only hunk at or below the old changelog line is an insertion (old 2049,0)
- headings: unchanged apart from the 17 new entry headings
