status: done

# HW-UI-SRV checkpoint

Round 1 (done): commit ed952f8 (server, contract tests, mirror test, gates).

Round 2 (fix round: verifier F1, F2, F4, F6): commit 86d5804 on top of ed952f8.
- [x] F1 server: MEMINFO_PATH constant; _mem_total_kb via _positive_int (None unless > 0);
      _hw_disk numbers all None when total is 0 kB
- [x] F4 server: cpu >= min_cpu (no slack); HW_PASS_PCT comment says RAM and disk only
- [x] F2 server: _counted_physical_cores split out of physical_cores (physical_cores still
      returns counted-or-logical for system_info); hardware gains cpu_kind
- [x] F6 ui/dev/serve.py legacy drops hardware network, cpu_kind, validator_recommended.ecc
      (NET_HARDWARE); smoke: legacy/fresh/public all 200, legacy has none of the three
- [x] tests: HardwareTiersTest +4 (memtotal zero, filesystem zero, exact cores, cpu_kind),
      PhysicalCoresTest +1 (cpu_kind per source); each caught its mutant on a scratch copy
- [x] gates: pytest -q ui 305 passed / 1 failed (mirror, old lib names in this worktree);
      TN_HW_MIRROR_LIB=main checkout lib/common.sh: 306 passed; py_compile server.py +
      dev/serve.py OK; check-network-hits clean (153)
- [x] commit 86d5804 (ui/server.py, ui/test_server_contract.py, ui/dev/serve.py)
