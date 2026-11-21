status: done

# HW-T checkpoint (hardware_check_test.sh)

Sections: A expectations [done]; B test file [done]; C first run and findings [done]; D edge cases [done]; gates [done]; commit [done: 694b797]

## A. Expectations (written from spec 3.2/3.3 and the brief only)

Read before writing this: spec 0, 3.1-3.3; tools/tests/lib.sh; os_floor_test.sh; AGENTS.md
"Fixture tests"; lib/common.sh `tn_physical_cores` (while reading it the two adjacent helpers
`_tn_hw_disk_label` and `_tn_hw_cores_label` and the first line of `_tn_hw_role`'s header came
into view; nothing else of check_hardware/_tn_hw_role read); print_ok/print_warn/print_info
(prefixes `  [OK]  `, `  [WARN] `, `  ->  `); base (01664cc) step_preflight's call and json block.

Normalised output: ESC sequences stripped, prefix mapped to `OK: `, `WARN: `, `INFO: `.

Fixture: lscpu stub (CORE,SOCKET lines, 2 threads per core), TN_PROC_CPUINFO -> missing file,
sysctl/nproc/getconf stubs that fail unless given a value, TN_PROC_MEMINFO fixture,
df stub printing a header and `/dev/x TOTAL USED AVAIL CAP% MOUNT`.
Host "c3": 4 cores, MemTotal 16777216 kB (16 GiB), df total 341796875 kB (350e9 B), avail
332031250 kB (340e9 B), mount /mnt/data.

Every case: rc 0; single-core line `INFO: Prioritise single-core performance: EVM execution is
single-threaded, so a high clock speed matters more than extra cores.`; last line starts
`Hardware checks never block setup;`; order Detected < Comparing < node < rpc < validator <
recommended < single-core < last.

| id | call | expected |
|---|---|---|
| T1 | c3, `"" dir testnet` | `INFO: Comparing with the testnet hardware tiers.`; `OK: Full node (follower): meets minimum (2 cores (4 vCPU) / 8 GB / 350 GB)`; `OK: Public RPC node: meets minimum (4 cores (8 vCPU) / 16 GB / 350 GB)`; `OK: Validator (minimum): meets minimum (3 cores (6 vCPU) / 16 GB / 350 GB)`; `INFO: Validator (recommended): 4 cores (8 vCPU) / 16 GB / 500 GB NVMe — NVMe is not checked here.`; GAPS ""; no WARN; no logical note; SUMMARY `4 physical cores, 16 GB RAM, 350 GB disk on /mnt/data (340 GB free)` |
| M1 | c3, mainnet | `INFO: Comparing with the mainnet hardware tiers.`; `WARN: Full node (follower): below minimum — needs ≥ 2 TB disk (have 4 physical cores, 16 GB RAM, 350 GB disk)`; same for `Public RPC node`; `WARN: Validator (minimum): below minimum — needs ≥ 8 cores (16 vCPU), 32 GB RAM, 2 TB disk (have 4 physical cores, 16 GB RAM, 350 GB disk)`; `INFO: Validator (recommended): 16 cores (32 vCPU) / 64 GB ECC / 4 TB NVMe — ECC and NVMe are not checked here.`; GAPS `node,rpc,validator` |
| D1 | c3, devnet | `INFO: Comparing with the testnet hardware tiers (devnet uses them).`; T1's three OK lines and recommended line; GAPS "" |
| E1 | c3, `""` | `INFO: Comparing with the mainnet hardware tiers (no network given).`; M1 verdicts and mainnet recommended line; GAPS `node,rpc,validator` |
| U1 | c3, `foonet` | as E1 |
| A2 | c3, two arguments (set -u on) | as E1 |
| B1 | testnet, df total 324707031 | three OK, GAPS "" |
| B2 | testnet, df total 324707030 | three WARN starting `<label>: below minimum — needs ≥ 350 GB disk (have 4 physical cores, 16 GB RAM, `; GAPS `node,rpc,validator` |
| R1 | testnet, MemTotal 15938355 | three OK |
| R2 | testnet, MemTotal 15938354 | node OK; rpc/validator WARN `needs ≥ 16 GB RAM (have 4 physical cores, `…; GAPS `rpc,validator` |
| C2 | 2 cores, testnet | node OK; `WARN: Public RPC node: below minimum — needs ≥ 4 cores (8 vCPU) (have 2 physical cores, 16 GB RAM, 350 GB disk)`; `WARN: Validator (minimum): below minimum — needs ≥ 3 cores (6 vCPU) (have 2 physical cores, 16 GB RAM, 350 GB disk)`; GAPS `rpc,validator` |
| MV | 8 cores, 33554432 kB, 1953125000 kB, mainnet | `OK: Full node (follower): meets minimum (2 cores (4 vCPU) / 8 GB / 2 TB)`, `OK: Public RPC node: meets minimum (4 cores (8 vCPU) / 16 GB / 2 TB)`, `OK: Validator (minimum): meets minimum (8 cores (16 vCPU) / 32 GB / 2 TB)`; GAPS ""; SUMMARY starts `8 physical cores, 32 GB RAM, 2000 GB disk on ` |
| MR | 16 cores, 67108864 kB, 3906250000 kB, mainnet and testnet | three OK each, GAPS "", recommended line of the network unchanged |
| L8 | lscpu fails, no cpuinfo, sysctl fails, nproc 8, testnet | SUMMARY starts `8 logical CPUs, 16 GB RAM`; a note line (not Detected) containing `logical`, between Detected and Comparing; three OK |
| L2 | as L8 with nproc 2 | node OK; validator WARN `needs ≥ 3 cores (6 vCPU) (have 2 logical CPUs, 16 GB RAM, 350 GB disk)`; GAPS `rpc,validator` |
| LG | nproc fails, getconf 4 | SUMMARY starts `4 logical CPUs`; note printed |
| P0 | c3 testnet (physical) | no line other than Detected mentions `logical` |
| N1 | 4 cores, no meminfo, df fails, testnet | GAPS ""; no `needs ≥`; my reading: no `meets minimum` claim for a role with unmeasured values |
| N2 | 2 cores, no meminfo, df fails, testnet | GAPS `rpc,validator`; needs lines name cores only (no `GB RAM`/`disk` inside the needs part) |

Constants: exactly 24 `readonly HW_(TESTNET|MAINNET)_…=N` statements with the values of the
3.2 table (UI regex), the same values at run time, and no `HW_NODE_`/`HW_RPC_`/`HW_VAL_` name in
lib/common.sh; the comment block directly above the first HW constant does not say adiri.

Static (setup-node.sh step_preflight): `select_network` line and `check_internet` line precede
the one `check_hardware` call; the call is exactly `check_hardware "node" "$DATA_DIR" "$NETWORK"`;
the `json_event log "hardware: ${TN_HW_SUMMARY:-unknown}"` block follows it; `mkdir -p
"$DATA_DIR"` precedes it; setup-node.sh calls check_hardware once.

## B. Test file

tools/tests/hardware_check_test.sh written to the A table (182 checks after C's fixes).

## C. First run (host, bash 5, tree 7d12626 + new file): 182 checks, 14 failures, then 0

- C-1 (my reading wrong, test fixed): the "(have ...)" part of a below-minimum line lists
  the measured values of the short dimensions only (`needs ≥ 2 TB disk (have 350 GB disk)`),
  not all three. The spec's only example (c3 on mainnet validator) has all three short, so it
  fits both readings; base 01664cc `_tn_hw_role` already builds `have` per short dimension.
  13 of the 14 failures were this.
- C-2 (my arithmetic wrong, test fixed): 324707030 kB = 332.49999872 GB, so the rounded
  `(have 332 GB disk)`, not 333.
- Everything else matched as written in A, including N1's "no meets claim" (the code prints
  `<label>: could not check RAM, disk; minimum is ...` via print_info).
- No code finding yet.

## D. Edge cases (after reading check_hardware/_tn_hw_role at 7d12626): 300 checks, 0 failures (host)

Added: real c3 MemTotal 16365288 kB (shown 16 GB, passes); 1 core (singular "1 physical
core", gaps node,rpc,validator); no CPU source at all ("unknown CPUs", "could not check CPU",
no logical note, no gap); nothing measurable on mainnet; mainnet with df failing (WARN on
CPU+RAM plus "could not check disk", gaps validator); zeros (lscpu header only, MemTotal 0,
df total 0) and garbage (nproc "8x" skipped for getconf, MemTotal abc, df capacity "-");
huge host (1024 cores, 4 TiB, 1 PB: no overflow); device and mount with spaces; mount with
quote/backslash/control dropped; disk 95 % used warning (not a gap); data dir not created yet
(df gets the nearest parent), data dir with a space (one df argument); zero-argument call
(df /, mainnet tiers); network spellings Testnet, "testnet ", "*", "-n" (mainnet tiers);
lscpu and sysctl truly absent from PATH (minimal PATH, nproc 8: logical note); constants
readonly. Every case runs under set -euo pipefail in a subshell, as setup-node.sh runs it.

Findings: no code defect. Notes: 20-digit MemTotal wraps in bash arithmetic (not
realistic, not tested); "(no network given)" also shows for a given-but-unknown network
(spec wording); a logical count is compared with the physical-core minimum (lenient, spec).
JSON mode sets NETWORK (json_set_network) before json_phase_keygen -> step_preflight, so the
moved call gets the network there too.

## D2. Harness fix (my test, not the code)

hw() first ran its subshell as `( ... ) || sub=$?`: bash ignores set -e inside a compound
command on the left of ||, so the "as setup-node.sh runs it" claim held only for -u and
pipefail. Now a plain statement then `sub=$?`. Probe (scratch copy with _tn_hw_cpu_text
forced to fail): 241 of 300 checks fail with `rc died(1)`, so an errexit abort is caught.
Final file: 300 checks, 0 failures on host bash 5, ubuntu:26.04, bash:3.2.

## Gates (in progress)
- file alone: host 300/0, ubuntu:26.04 300/0, bash:3.2 300/0 (final file)
- check-bash32 (file, and all 211 tracked .sh): clean; shellcheck error/warning: clean
- check-network-hits: clean (153 annotated); check-perl-interp: clean (211 files)
- whole suite (final file, tree 7d12626 + new file): host 82 files / 0 failed; ubuntu:26.04 82 files / 0 failed
- committed 694b797 (tools/tests/hardware_check_test.sh only, no attribution lines)
