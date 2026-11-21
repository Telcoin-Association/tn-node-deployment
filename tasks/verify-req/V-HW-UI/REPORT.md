# V-HW-UI: hardware check parity (shell, UI server, UI page)

Verifier V-HW-UI, worktree `tnd-req-v-hw-ui` at the integrated tip `1a3404b`. No tracked file was edited. The harness was written from spec sections 3.1-3.5 and 6 before I read the implementers' checkpoints or tests (I have not read them at all; I only ran the tests in H7).

Scratch directory (`$S` below): `/var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/v-hw-ui/`. `$W` is the worktree and `$V` is `$W/tasks/verify-req/V-HW-UI`.

## Summary

The three places agree. Over 55 fake hosts × 2 networks × 3 roles (330 rows), the shell and the server give the same verdict and the same failing dimensions on 318 rows. The 12 rows that differ come from two hosts that report a size of exactly 0 (MemTotal 0 kB, or a filesystem of 0 kB). That difference already existed at `01664cc`. The 24 constants match in four places: the library, the server, the spec 3.2 table and the spec 3.1 document tables. The pass floors are the same integers on both sides. The page prints the same tier figures and verdicts as the shell. The route never returns a 5xx and never echoes its input. `setup-node.sh` passes the network it chose in both the interactive path and the `--json` path. Every suite is green, and the mutants I planted are caught.

I found no High or Medium defect. There are 2 Low findings, both already present at `01664cc`, and 9 Info notes.

## Findings

| id | sev | one line |
|---|---|---|
| F1 | Low (pre-existing) | A measured 0 (MemTotal 0 kB, a filesystem total of 0 kB): the shell says "could not check", the server and page say "below minimum" and show "0 GB RAM". |
| F2 | Low (pre-existing) | Only the logical CPU count is known: the page says "Detected 8 cores (8 threads)" with no note; the shell says "8 logical CPUs" and explains the comparison. |
| F3 | Info | `check_hardware ... adiri` uses the mainnet tiers ("(no network given)"); every other reader treats adiri as testnet. setup-node.sh never passes `adiri`. |
| F4 | Info | The server gives the CPU check 5 % slack (`cpu*100 >= min*95`) and the shell gives none. The results are the same for every tier under 20 cores (all of today's); a 20-core tier would split them. |
| F5 | Info | `?network=` with surrounding whitespace (space, `+`, NBSP, tab, trailing LF) is read as mainnet. The reply stays canonical and nothing is echoed. |
| F6 | Info (6.2 confirmed) | The `legacy` scenario of `ui/dev/serve.py` keeps `network` and `ecc` and rewrites `hardware.cpu` without recomputing the tiers. Nothing breaks, but it no longer looks like an older server. |
| F7 | Info (pre-existing) | The shell's display overflows on absurd values (`-8796093022207 GB RAM`, `-9223372036 GB disk`), and rounding gives "needs ≥ 8 GB RAM (have 8 GB RAM)". Verdicts are unaffected. |
| F8 | Info | The page prints `undefined GB RAM` or `null GB RAM` for partial objects (`validator_recommended: {}`, null tier minima). No server sends these. |
| F9 | Info | With mainnet enabled (a copy with `SETUP_MAINNET_ENABLED=true`), step 1 shows the mainnet tiers only if the operator goes back to it. |
| F10 | Info (pre-existing) | The UI preflight measures `/var/lib/telcoin`; setup measures the data dir chosen in step 4, which may be a separate mount under it. |
| F11 | Info (pre-existing) | Opening the wizard sends two preflight requests: `loadSetupDefaults` re-renders step 1. |

### F1: a measured zero is "below" on the server and "could not check" in the shell (Low, already at 01664cc)

- Expected: the same verdict on both sides for the same host (spec 3.4: "Disk floor in decimal GB, the shell's formula"; the shell treats anything not matching `^[1-9][0-9]*$` as unmeasured).
- Got: host `memzero` (`MemTotal: 0 kB`) reads `unknown` in the shell and `below(ram)` on the server, for all 3 roles on both networks. The page shows `Full node (follower): below minimum — ram (...)` and `Detected 32 cores (64 threads) / 0 GB RAM / ...`. Host `diskzero` (a filesystem total of 0) behaves the same way with `disk`. Together these are the 12 differing rows of the parity table. The same run against the `01664cc` library and server (`$S/run-old`) gives the same split, so this round did not introduce it.
- Realism: MemTotal 0 does not happen on Linux. A filesystem total of 0 can happen when the nearest existing parent of the data dir sits on a pseudo or autofs mount.
- Reproduction: `cd $V && TMPDIR=$S bash h1_shell.sh hosts.tsv $S/run-x && docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1 -v $W:$W:ro -v $S:$S python:3.10-slim sh -c "cd /tmp && PYTHONPATH=$S/pydeps python3 $V/h1_server.py $W/ui $V/hosts.tsv $S/run-x" && python3 -I h1_compare.py $S/run-x`
- Suggested fix: on the server, follow the shell's rule. `_mem_total_kb` returns None unless the value is > 0, and `_hw_disk` leaves `total_kb` None when `du.total` is 0. Add a `HardwareTiersTest` case for each.

### F2: a logical-only CPU count is presented as cores (Low, already at 01664cc)

- Expected (brief H1/H4): when only the logical count is known, the shell compares it with the physical-core tier and says so. The question was what the server and page do.
- Got: both sides compare the logical count with the tier, so the verdicts match (hosts `log3`, `log4`, `log8`, `log16`). The shell prints `Detected: 8 logical CPUs, ...` plus `Physical cores could not be counted, so the tiers below are compared with logical CPUs; ...`. The server's `physical_cores()` falls back to `logical_cpus()` and returns `cpu: 8`, `cpu_physical: 8`, `cpu_threads: 8`, with nothing marking the count as logical. The page then says `Detected 8 cores (8 threads)` with no note. On a 4-core host with hyperthreading whose cores cannot be counted, the page claims 8 cores and passes the mainnet validator CPU minimum. The shell passes it too, but it says why. `01664cc` behaves the same way.
- Reproduction: the H1 commands above (section 4 of `h1_compare.py` prints the CPU kind), then `python3 -I $V/h4_extract.py $W/ui/static/index.html $S/h4/new.js` and `docker run --rm -u "$(id -u):$(id -g)" -v $W:$W:ro -v $S:$S node:22-slim node $V/h4_page.js $S/h4/new.js $S/h4/old.js $S/run-x` (prints the `log*` lines).
- Suggested fix: have `hardware_profile` add `"cpu_kind": "physical" | "logical"`, or have `physical_cores` report the kind. The page then writes `8 logical CPUs` and a short note under the tier rows, the same sentence the shell prints.

### F3: the library maps `adiri` to the mainnet tiers (Info)

- Got: `check_hardware node DIR adiri` → `Comparing with the mainnet hardware tiers (no network given).` `network_rule`, `json_set_network` and the page's `setupNetwork()` all read adiri as testnet. The behaviour follows spec 3.2 ("anything else → mainnet") and 6.1. It cannot be reached from `setup-node.sh`: `NETWORK` is always canonical there (`json_set_network` turns adiri into testnet; `select_network` only sets testnet or mainnet), which `h6_preflight.sh` shows for `--json adiri`.
- Suggested fix (optional): add `adiri` to the testnet branch of the `case`, with a `# network-gated:` annotation, so a future caller that passes a raw `.node-meta` value gets the testnet tiers.

### F4: the server's CPU slack (Info)

- Got: `ui/server.py:5279` passes the CPU at `cpu * 100 >= min_cpu * 95`. The shell (`lib/common.sh:2316`) uses a plain `cpu -lt min_cpu`. For integers the two agree whenever `min_cpu < 20`. Today's largest checked tier is 8 cores, and the 16-core recommendation is never checked. With a 20-core tier, a 19-core host passes on the server and fails in the shell (`python3 -c "print(19*100 >= 20*95)"` → True).
- Suggested fix: compare CPU without slack on the server (`cpu >= min_cpu`). The slack exists for RAM and disk, where capacity reads slightly under the size printed on the box.

### F5: whitespace around `?network=` (Info)

- Got: `%20mainnet%20`, `+mainnet+`, `%C2%A0mainnet`, `mainnet%09` and `mainnet%0A` all get `network: "mainnet"` (`network_rule` calls `str.strip()`, which also strips Unicode whitespace). `MAINNET`, a NUL, invalid UTF-8, angle brackets, quotes, 10 kB values, `main%0Anet` and JSON all get testnet. A duplicated parameter uses its first value. The status is always 200, the `network` field is only ever testnet or mainnet, and the hostile input appears nowhere in the body. `/api/setup/defaults` follows the same rule. No fix needed.

### F6: `ui/dev/serve.py` legacy mode (Info, confirms the 6.2 item)

- Got (`h5_devserve.sh`): the `fresh` and `legacy` scenarios return 200 for `?network=` testnet, mainnet and none, so the new shape does not break the dev server. In `legacy`, `hardware.cpu` becomes 16 (threads) while the tiers were computed from 8 cores, and `network` and `ecc` stay in the reply, so the page shows "Compared with the ... tiers" and ECC, which an older server would not send.
- Suggested fix: in the `legacy` branch of `overlay`, also pop `hardware["network"]` and `hardware["validator_recommended"]["ecc"]`.

### F7: shell display on absurd values, and rounding (Info, already at 01664cc)

- Got: `MemTotal 9223372036854775807` displays as `-8796093022207 GB RAM`, and a disk of 2^53 kB as `-9223372036 GB disk` (`ram_kb + 524288` and `disk_kb * 1024` overflow in bash). A 20-digit value wraps to an arbitrary positive number. The verdicts still pass, and the server, using Python integers, agrees. `7969176 kB` gives `needs ≥ 8 GB RAM (have 8 GB RAM)`, because the "have" figure is rounded while the floor carries 5 % slack. All of this matches `01664cc` line for line.
- Suggested fix: none needed. Optionally print the "have" RAM with one decimal.

### F8: page output for partial objects (Info)

- Got: `validator_recommended: {}` → `Recommended to validate: ? cores / undefined GB RAM / ? GB disk.` Tier minima of null → `(? cores / null GB RAM / ? GB disk)`. No server version sends these, and the 01664cc page had the same raw `${...ram_gb}`.
- Suggested fix: use `${r.ram_gb ?? '?'}` and `${t.min_ram_gb ?? '?'}`.

### F9: once mainnet is enabled, step 1 shows the mainnet tiers only after going back (Info)

- Got (`h5_flow.js`, a copy with `SETUP_MAINNET_ENABLED = true`): clicking the mainnet card sets `state.setup.network = 'mainnet'`. The next preflight request carries `?network=mainnet` only when the operator goes back to step 1. An operator who goes forward from step 2 never sees the mainnet verdict in the wizard, only in the setup log (the shell's `WARNING:` line). As shipped, the mainnet card is `<div class="rcard disabled">` with no `data-net`, so no click handler is attached. Spec 3.5 accepts this.
- Suggested fix (when mainnet is enabled): re-fetch the preflight in `setSetupNetwork`, or show the hardware verdict on the Review step.

### F10: the UI measures the default data dir (Info, already at 01664cc; from reading the code)

- `hardware_profile` measures `_hw_disk(DEFAULT_DATA_DIR)` (`/var/lib/telcoin`). The page sends no data dir, and step 4 lets the operator pick a path under `/var/lib/telcoin` and suggests mounting a separate drive there. Setup's `check_hardware` measures that `DATA_DIR`. On a host where the drive is mounted below `/var/lib/telcoin`, the preflight can report `below minimum — disk` while the setup log reports a pass. I did not run this case.

### F11: two preflight requests when the wizard opens (Info, already at 01664cc)

- `renderSetup` → `stepPreflight`, then `loadSetupDefaults` → `renderSetup` → `stepPreflight` again (`h5_flow.js` log: two `?network=testnet` requests before any click). Both carry the same network.

## Parity table (H1)

Verdicts: P = pass, B(x) = below minimum on the dimensions x (c cpu, r ram, d disk), ? = could not measure. Each cell is written once when the shell and the server agree, and as `sh … / srv …` when they do not. The full 330-row listing is `$S/run-final/parity.txt` (`h1_compare.py --table`).

| host | testnet node / rpc / validator | mainnet node / rpc / validator | same |
|---|---|---|---|
| tnval (c3-highcpu-8: 4 cores/8 threads, 16365288 kB, 360000000 kB) | P / P / P | B(d) / B(d) / B(crd) | yes |
| tnval-raw (same, disk 367001600 kB = 350 GiB) | P / P / P | B(d) / B(d) / B(crd) | yes |
| big | P / P / P | P / P / P | yes |
| c1 | B(c) / B(c) / B(c) | B(c) / B(c) / B(c) | yes |
| c2 | P / B(c) / B(c) | P / B(c) / B(c) | yes |
| c3 | P / B(c) / P | P / B(c) / B(c) | yes |
| c4 | P / P / P | P / P / B(c) | yes |
| c7 | P / P / P | P / P / B(c) | yes |
| c8 | P / P / P | P / P / P | yes |
| c15 | P / P / P | P / P / P | yes |
| c16 | P / P / P | P / P / P | yes |
| c16-2s (2 sockets, core ids repeat) | P / P / P | P / P / P | yes |
| r8 (7969177) | P / B(r) / B(r) | P / B(r) / B(r) | yes |
| r8m1 (7969176) | B(r) / B(r) / B(r) | B(r) / B(r) / B(r) | yes |
| r16 (15938355) | P / P / P | P / P / B(r) | yes |
| r16m1 (15938354) | P / B(r) / B(r) | P / B(r) / B(r) | yes |
| r32 (31876710) | P / P / P | P / P / P | yes |
| r32m1 (31876709) | P / P / P | P / P / B(r) | yes |
| r64 / r64m1 | P / P / P | P / P / P | yes |
| d350 (324707031) | P / P / P | B(d) / B(d) / B(d) | yes |
| d350m1 (324707030) | B(d) / B(d) / B(d) | B(d) / B(d) / B(d) | yes |
| d500 / d500m1 | P / P / P | B(d) / B(d) / B(d) | yes |
| d2000 (1855468750) | P / P / P | P / P / P | yes |
| d2000m1 (1855468749) | P / P / P | B(d) / B(d) / B(d) | yes |
| d4000 / d4000m1 | P / P / P | P / P / P | yes |
| cpuinfo4 (no lscpu) | P / P / P | P / P / B(c) | yes |
| cpuinfo16 (no lscpu, 2 sockets) | P / P / P | P / P / P | yes |
| sysctl3 | P / B(c) / P | P / B(c) / B(c) | yes |
| sysctl8 | P / P / P | P / P / P | yes |
| log3 (logical only) | P / B(c) / P | P / B(c) / B(c) | yes |
| log4 | P / P / P | P / P / B(c) | yes |
| log8 | P / P / P | P / P / P | yes |
| log16 | P / P / P | P / P / P | yes |
| rawsock (empty socket ids) | P / B(c) / B(c) | P / B(c) / B(c) | yes |
| rawcore (lines without core id) | P / B(c) / B(c) | P / B(c) / B(c) | yes |
| cpunone | ? / ? / ? | ? / ? / ? | yes |
| memnone (unreadable) | ? / ? / ? | ? / ? / ? | yes |
| memzero | sh ? / srv B(r) (×3) | sh ? / srv B(r) (×3) | **no** (F1) |
| memnokey / memjunk | ? / ? / ? | ? / ? / ? | yes |
| disknone (unstattable) | ? / ? / ? | ? / ? / ? | yes |
| diskzero | sh ? / srv B(d) (×3) | sh ? / srv B(d) (×3) | **no** (F1) |
| dirmissing (data dir not created yet) | P / P / P | B(d) / B(d) / B(crd) | yes |
| allnone | ? / ? / ? | ? / ? / ? | yes |
| mixed (2 cores, RAM and disk just under) | B(d) / B(crd) / B(crd) | B(d) / B(crd) / B(crd) | yes |
| partial (CPU unknown, RAM under 8 GB) | B(r) / B(r) / B(r) | B(r) / B(r) / B(r) | yes |
| hugecpu, hugecpu63, hugemem, hugemem63, hugedisk, hugedisk53 | P / P / P | P / P / P | yes |

**Rows: 330; differing: 12 (memzero × 6, diskzero × 6).**

Tier set applied:

| network value | shell | server |
|---|---|---|
| testnet | testnet | testnet |
| mainnet | mainnet | mainnet |
| devnet | testnet ("(devnet uses them)") | testnet |
| adiri | mainnet ("(no network given)") (F3) | testnet |
| none | mainnet ("(no network given)") | testnet (intended difference, confirmed) |

Also proved in H1:
- Shell rc is 0 in all 275 runs, and `TN_HW_GAPS` always equals the roles the role lines call below.
- The shell's verdicts are byte-identical under host bash 5, `bash:3.2` and `ubuntu:26.04`.
- For `dirmissing`, both sides measure the same nearest existing parent (the df argument equals the `disk_usage` argument).
- The route's `hardware` equals the direct `hardware_profile(net)` for all 275 host/network pairs.

## Proved (with the commands)

- **H1** (above): `bash h1_shell.sh hosts.tsv $S/run-final`, then `h1_server.py` in `python:3.10-slim` (deps from `ui/requirements.txt` + `ui/tests/requirements-dev.txt` installed with `pip --target $S/pydeps`), then `h1_compare.py $S/run-final --table`. The shell harness was also run in `bash:3.2` and `ubuntu:26.04` (`docker run --rm -u uid:gid -e TMPDIR=$S -v $W:$W:ro -v $S:$S -w $V <img> bash h1_shell.sh ...`).
- **H2**: `h2_constants.py $W $W/tasks/spec-req-shared.md` (in the container). All 24 names are equal in lib (by the spec 3.2 regex; 24 `HW_*=` assignments in total), the server, spec 3.2 and spec 3.1, including vCPU = 2 × cores and ECC only on mainnet. The server labels equal the shell's role labels. `bash h2_floors.sh $W <FLOORS line>` confirms the server's floors equal the shell formula: RAM 8/16/32/64 GB → 7969177/15938355/31876710/63753420 kB; disk 350/500/2000/4000 GB → 324707031/463867187/1855468750/3710937500 kB. `_tn_hw_role` passes at each floor and warns one kB under it. `git grep -nE 'HW_(NODE|RPC|VAL)_' -- ':!tasks/'` finds only the description string of the absence check at `tools/tests/hardware_check_test.sh:499`, so no old name is left.
- **H3**: `h3_params.py $W/ui $S/h3-new.json` and against the `01664cc` module (`git -C <main checkout> archive 01664cc ui lib setup-node.sh tools | tar -x -C $S/old01664cc`): 27 query strings, 0 bad cases (see F5). Key sets compared with `01664cc`: `hardware` gains `network`, `validator_recommended` gains `ecc`, and nothing else changes at the top level, in `hardware`, `disk` or a tier. Auth matches the neighbouring `/api/setup/defaults`: 401 without the token or with a wrong one, 421 for a foreign Host, 403 with the public header. A cross-site GET returns 200 on both routes, and did at `01664cc` too, because GET routes carry no CSRF check by design (`_is_write_request`). Nothing new here.
- **H4**: `h4_extract.py` copies `esc`, `cap`, `setupNetwork`, `hwCores`, `hwDiskLabel`, `hwTierRows`, `hwInfoRow` and `stepPreflight` verbatim from the new page and the `01664cc` page. `h4_page.js` (in `node:22-slim`) ran 3079 checks with 18 failures: 16 are F1 and 2 are F8. Passing checks:
  - The request line is `/api/setup/preflight?network=testnet|mainnet` (`encodeURIComponent(setupNetwork())`).
  - Each tier row reads exactly `<label>: <verdict> (<n> cores (<2n> vCPU) / <g> GB RAM / <disk label> disk)`.
  - The info row contains `Compared with the <net> hardware tiers.` and `Recommended to validate: ...` with `GB ECC RAM` on mainnet only, and ends with the single-core sentence, verbatim and exactly once.
  - No `undefined`, `NaN` or `null` appears on any real reply.
  - Hostile `network`, label, path, gap and recommendation values are HTML-escaped.
  - New page with the old (01664cc) server: no "Compared with", no ECC, the single-core sentence present, 3 tier rows.
  - Old page with the new server: the request has no `network` (so testnet), 3 tier rows, no undefined. Its rows read `(3 cores / 16 GB RAM / 350 GB disk)`, and its detected disk is binary (343 GB against a 350 GB tier). That only matters in a stale tab.
  - Wording parity: for every host and both networks, the page's tier figures equal the shell's `meets minimum (...)` / `minimum is ...` spec. Every shell "needs" item appears among the page's figures. The recommended figures, and the detected RAM and disk GB, are equal (huge-value hosts excluded).
- **H5**: `h5_flow.js` (see F9 and F11). As shipped, every preflight request carries `network=testnet`. Clicking the testnet card changes nothing, and going back to step 1 re-fetches. The mainnet card has no `data-net`. `h5_devserve.sh`: see F6.
- **H6**: `h6_preflight.sh $S/run1` runs `step_preflight` for real, with stubs for root, the lock, ports, packages and `check_internet`, stopping at `tn_os_floor_check`:
  - In `--json` mode with testnet, adiri, devnet and mainnet, and interactively with testnet and mainnet, the "Comparing with" line names the chosen network's tiers.
  - On fd 3, `{"event":"log","msg":"hardware: ..."}` is always present, and `WARNING: hardware below the minimum for: node,rpc,validator (setup continues)` appears on mainnet. The page styles `/warning:/i` log lines as `warn` (`index.html:2460`).
  - In `--json` mode, `NETWORK` comes from `json_set_network` in `run_json_mode`, before `json_phase_keygen` → `step_preflight`. The finalize phase does not run `step_preflight`.
  - Order inside the function: `mkdir -p "$DATA_DIR"` (line 45) < `select_network` (72) < `check_internet` (75) < `check_hardware "node" "$DATA_DIR" "$NETWORK"` (77). This is the only caller of `check_hardware`.
  - The step_preflight parsing sections of the three tests that parse this function are unchanged since `01664cc`. `network_detect_test.sh` was edited, but only its chain-id lines, in `1a3404b`.
- **H7**:
  - `python -m pytest -q -p no:cacheprovider ui` in `python:3.10-slim` (worktree read-only, `PYTHONDONTWRITEBYTECODE=1`): **312 passed, 1277 subtests passed**.
  - `tools/tests/hardware_check_test.sh`: 300 checks, 0 failed on the host; exit 0 in `ubuntu:26.04` and in `bash:3.2`.
  - `ui/tests/helper_test.sh`: 557 checks, 0 failed.
  - `install_ui_test.sh`: 1 check, 0 failed on the host. As non-root the root cases are skipped; as root in `ubuntu:26.04` it ran 13 checks, 0 failed.
  - `open_ui_test.sh`: 9 checks, 0 failed.
  - Mutants, each on its own `git archive HEAD` copy:

    | mutant | caught by |
    |---|---|
    | M1: lib `HW_TESTNET_VAL_MIN_CPU` 3→4 | `hardware_check_test.sh` (13 FAIL) and `ui/test_hw_mirror.py` (FAIL) |
    | M2: server mainnet validator RAM 32→31 | `test_hw_mirror.py` and `HardwareTiersTest::test_both_tier_sets_and_their_numbers` (the shell test stays green, as it should) |
    | M3: server disk floor in binary GB | 5 `HardwareTiersTest` cases, including `test_disk_floor_is_decimal_gb_at_the_350_gb_boundary` |

    My own harness catches M1 (56 differing rows) and M2 (41), against a baseline of 12.
  - Own files: every `*.sh` has a shebang; `shellcheck --severity=error` and `--severity=warning` are clean; `bash -n` passes under bash 5 and `bash:3.2`; `tools/check-bash32.sh` is clean (4 files). The Python files parse, and `node --check` passes for both JS files.
  - `df -Pk` total equals `shutil.disk_usage().total // 1024` on this host for `/`, `/var/tmp` and `/home`.

## Not proved

- **Real machines.** Every host is a fixture: stubbed `lscpu`, `nproc`, `sysctl`, `getconf` and `df`, and fixture `/proc/meminfo` and `/proc/cpuinfo` for both sides. I did not check that `df -Pk` and `statvfs` agree on every filesystem type, beyond the spot check on this host. The macOS `sysctl` path was only simulated.
- **The page in a browser.** I ran the extracted functions in node against a stub DOM, so layout and CSS were not checked, and neither was a real `tnFetch`.
- **F10.** Read in the code; I did not run a host with the data dir mounted below `/var/lib/telcoin`.
- **The route's slow probes.** `systemctl`, `docker info`, the GitHub probe and `host_has_tpm` were stubbed, so timing and timeouts were not exercised.
- **The documents.** The wave-3 docs are not written yet. H2 compared the code with the spec 3.1 tables, which are their source.

## Harness (`tasks/verify-req/V-HW-UI/`)

| file | what it does |
|---|---|
| `hosts.tsv` | the 55 fake hosts |
| `h1_shell.sh` | H1 shell side; writes the fixtures both sides read |
| `h1_server.py` | H1 server side; direct call and route, for the new or the 01664cc module |
| `h1_compare.py` | the parity table and the list of differing rows |
| `h2_constants.py` | the 24 constants, compared four ways |
| `h2_floors.sh` | the shell's floors against the server's integers |
| `h3_params.py` | route parameter validation and auth |
| `h4_extract.py` | copies the page code out for node (H4 and H5) |
| `h4_page.js` | page rendering and wording parity with the shell |
| `h5_flow.js` | the wizard's network as the preflight request carries it |
| `h5_devserve.sh` | `ui/dev/serve.py` with the new reply |
| `h6_preflight.sh` | runs `step_preflight` in `--json` and interactive modes |
| `ckpt.md` | checkpoint |
