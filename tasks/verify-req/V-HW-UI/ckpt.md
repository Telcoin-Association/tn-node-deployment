status: done (H1-H7 done; REPORT.md Write refused -> full text returned in the hand-back)

V-HW-UI checkpoint (verifier; worktree at 1a3404b; edits no tracked file)
Scratch: /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-hw-ui/
  pydeps/ = ui requirements + pytest (pip --target, py3.10 container, uid-owned); run1/ = H1 run.

Sections:
- [x] H1 parity table -- harness hosts.tsv, h1_shell.sh, h1_server.py, h1_compare.py.
      55 hosts x {testnet,mainnet} x 3 roles = 330 rows; 12 differ: memzero (MemTotal 0 kB)
      and diskzero (fs total 0 kB): shell "could not check", server "below (ram|disk)".
      Tier set: devnet both testnet; adiri shell=mainnet "(no network given)" vs server testnet;
      none shell=mainnet vs server testnet (intended). Shell verdicts identical in bash 5,
      bash:3.2, ubuntu:26.04. rc 0 and TN_HW_GAPS consistent in all 285 shell runs.
      Logical-only (nproc N): both compare N with the tier (same verdicts); shell says
      "N logical CPUs" + note; server cpu=N, cpu_physical=N, cpu_threads=N, nothing marks it
      logical (page check in H4). Missing data dir: both measure the nearest parent.
      Huge values: verdicts agree; shell display overflows (-8796093022207 GB RAM at int64 max,
      -9223372036 GB disk at 2^53 kB) -- Info. "partial" host: "needs >= 8 GB RAM (have 8 GB RAM)"
      rounding (check if pre-existing at 01664cc).
- [x] H2 constants -- h2_constants.py + h2_floors.sh: 24/24 equal across lib, server, spec 3.2,
      spec 3.1; floors identical (RAM 8/16/32/64, disk 350/500/2000/4000) and _tn_hw_role
      passes at floor, warns at floor-1. Old names: only hit is the description string of
      hardware_check_test.sh:499 (a check that they are absent) -- no name left.
- [x] H3 route parameter validation -- h3_params.py, new and 01664cc server: 27 query strings,
      all 200, network only testnet/mainnet, nothing reflected; " mainnet ", "+mainnet+", NBSP,
      tab, trailing LF all read as mainnet (network_rule strips Unicode whitespace) -- Info;
      MAINNET/devnet/adiri/10kB/quotes/<>/LF-mid/NUL/bad UTF-8 -> testnet; duplicate -> first.
      Key sets vs 01664cc: hardware +network, validator_recommended +ecc, nothing removed.
      Auth: same as /api/setup/defaults (401 no/wrong token, 421 foreign Host, 403 public;
      cross-site GET 200 on both, as at 01664cc -- GET routes never had CSRF, by design).
- [x] H4 page rendering -- h4_extract.py + h4_page.js (node:22-slim), 3079 checks, 18 fail:
      12 verdict + 4 detected-GB = memzero/diskzero (same as H1, PRE-EXISTING at 01664cc:
      run-old shows old shell unknown / old server below); 2 = partial replies a server never
      sends (validator_recommended {} -> "undefined GB RAM"; tier minima null -> "null GB RAM")
      -- Info. Request line, tier rows, info row, single-core sentence (last, once), ECC only on
      mainnet, hostile values escaped, new page/old server, old page/new server: all pass.
      Tier figures and recommended figures equal the shell's for all 55 hosts.
      Logical-only host: page "Detected 8 cores (8 threads)", no note; shell "8 logical CPUs" +
      note. Pre-existing at 01664cc (same fallback, same page text) -- Low.
      Old page/new server: "(3 cores / 16 GB RAM / 350 GB disk)", detected disk in GiB (343 GB)
      vs a 350 GB tier -- Info (stale tab only).
- [x] H5 wizard flow, dev server -- h5_flow.js (node) on renderSetup/goStep/setSetupNetwork/
      stepNetwork/loadSetupDefaults: shipped wizard: every preflight request ?network=testnet
      (open: 2 requests, the second from loadSetupDefaults' re-render -- pre-existing); testnet
      card click no-op; back to step 1 re-fetches testnet. Mainnet card shipped: class
      "rcard disabled", no data-net, so no click handler. Copy with SETUP_MAINNET_ENABLED=true:
      click -> state.setup.network=mainnet, back to step 1 -> ?network=mainnet. 0 mismatches.
      Note: with mainnet enabled, step 1 shows mainnet tiers only if the operator goes back.
      h5_devserve.sh: ui/dev/serve.py fresh + legacy, ?network= testnet/mainnet/none: all 200;
      legacy rewrites hardware.cpu to 16 (threads) while tiers were computed on 8 and keeps
      network + ecc, so "legacy" no longer mimics an older server for the preflight -- Info
      (6.2 item confirmed, not broken).
- [x] H6 setup-node.sh wiring -- h6_preflight.sh runs step_preflight (stubs for root/lock/
      ports/internet, STOP at tn_os_floor_check): --json testnet/adiri/devnet/mainnet and
      interactive testnet/mainnet all compare with the chosen network's tiers; NETWORK is set
      by json_set_network in run_json_mode before json_phase_keygen -> step_preflight (finalize
      has no step_preflight); adiri -> NETWORK=testnet, so the library's adiri->mainnet mapping
      is never reached from setup-node.sh. fd3 log lines "hardware: ..." and "WARNING: hardware
      below the minimum for: node,rpc,validator (setup continues)" present; page styles
      /warning:/i as warn (index.html:2460). Order: mkdir DATA_DIR (45) < select_network (72) <
      check_internet (75) < check_hardware (77). Only caller of check_hardware: setup-node.sh:450.
      The three parsing tests are unedited since 01664cc.
- [x] H7 suites and mutation checks -- pytest ui (python:3.10-slim, ro, no bytecode/cache):
      312 passed, 1277 subtests. hardware_check_test.sh: 300 checks 0 failed host; exit 0 in
      ubuntu:26.04 and bash:3.2. helper_test 557/0, install_ui_test 1/0 on host (non-root: rest
      skipped; 13/0 as root in ubuntu:26.04), open_ui_test 9/0. Mutants (scratch copies):
      M1 lib HW_TESTNET_VAL_MIN_CPU 3->4: hardware_check_test 13 FAIL + test_hw_mirror FAIL;
      M2 server mainnet validator RAM 32->31: test_hw_mirror + HardwareTiersTest FAIL (shell
      test green, as expected); M3 server disk floor binary: 5 HardwareTiersTest FAIL. My
      harness: M1 56 differing rows, M2 41 (baseline 12). Own files: shebangs, shellcheck
      error+warning clean, bash -n 5 and 3.2, check-bash32 clean, py ast ok, node --check ok.
- [x] REPORT.md -- Write refused by the harness; full text returned in the final answer for the orchestrator to save

Candidate findings so far:
- F? Low: MemTotal 0 / fs total 0: server "below", shell "could not check".
- F? Low: logical-only CPU count presented as cores by server/page (check H4).
- F? (H6) adiri as NETWORK -> shell mainnet tiers.
- Info: shell display overflow for absurd values.
