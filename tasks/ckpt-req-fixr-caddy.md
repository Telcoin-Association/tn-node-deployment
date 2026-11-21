status: done

# FIXR-CADDY checkpoint

Worktree /home/drtnarg/coding/telcoin/tnd-req-fixr-caddy, branch req/fixr-caddy, base 1a3404b.
Owned: install-caddy.sh (caddy_mainnet_gate + header), tools/tests/caddy_test.sh (gate block).
Commit: 2030273.

## Sections
- [x] VC-2 (reason for a network that cannot be told) -- install-caddy.sh edited
- [x] VC-3 (public RPC chain check before the fallback stake read) -- install-caddy.sh edited
- [x] tests -- caddy_test.sh: tn_rpc_call stub in the gate block (+ restore), new marked block
      "mainnet gate: the network read from the genesis, the public RPC's chain". Host 189/0
      (base 161). Against 1a3404b install-caddy.sh (scratch base-tree): 11 failures (the
      fix-pinning checks). Verifier h_entry.sh caddy: 2/2 on both trees, no check flips; the
      "genesis 487 key -" rows now print "(487) is neither 731 nor 2017".
- [x] gates -- 7 install-caddy fixtures green on host, ubuntu:26.04, bash:3.2; caddy_test 181/0/1
      skipped in both containers; whole suite 84 files 0 failed host + ubuntu:26.04;
      check-bash32 clean (214); shellcheck errors 0, warnings 0/0 install-caddy, 13/13 caddy_test;
      network-hits clean (153); perl-interp clean; caddy_gateway_smoke 47/0.

## Decisions
- VC-2: reuse tn_detect_network's stderr reason (true in every case, also NETWORK= empty),
  stripped through its "tn_detect_network: " prefix; fallback to the old wording if absent.
  Two calls (the second only on failure) -- a merged 2>&1 capture could fail open.
- VC-3: _tn_rpc_chain_is "$MAINNET_RPC_URL" "$MAINNET_CHAIN_ID" before the fallback read; on
  failure hint "; <url> does not answer with chain <id>, so the stake was not read there" (the
  quorum guard's wording).
