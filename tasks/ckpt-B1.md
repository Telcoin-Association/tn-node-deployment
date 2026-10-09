status: done
owner: implementer B1 (lib/common.sh only)

## Completed sections
- Section 1 (SC-1 stake status): DONE
- Section 2 (SC-2 observer safety net): DONE
- Section 3 (SC-3 hardware): DONE (COMMON_VERSION 1.3.9 -> 1.4.0, DEFAULT_DOCKER_IMAGE -> v0.15.0-adiri)
- Section 4 (harnesses + self-checks): DONE
- Drafts (README changelog + commit message): DONE (below)

## Public contracts (SC-1 / SC-2 / SC-3)
node_stake_status <address> [rpc_url=http://127.0.0.1:8545]
  stdout exactly one line, nothing else:
  "<status> <activation_epoch> <is_retired>" rc 0 | "none" rc 0 (revert: msg ~ [Rr]evert or "code":3)
  | "unknown" rc 1 (empty/malformed address) | "unknown" rc 2 (curl fail, empty body, non-revert error
  object, missing/0x/short/non-hex result). is_retired is 0|1.
node_is_staked_validator <address> [rpc_url]   no output; rc 0 status 1-4; rc 1 status 0/5/6 or none; rc 2 unknown
print_validator_onchain_status <address> "<result-line>" [is_retired 0|1]
  single label table + Next step text; rc 0 after a report (incl. "none" block), rc 1 + "Empty response"
  warn when the line is not decoded. Status 6+retired -> "Status: Retired"; 6 not retired ->
  "Status: Any (reserved status sentinel)"; other status + retired -> "Status: <label> (Retired)" plus
  two print_info lines about retirement.
check_validator_onchain_status <address> [rpc_url]   same header; rc 1 bad address or rc!=0 probe
  ("Empty response from contract ..." warn); else prints the report, rc 0.
tn_node_has_observer_flag <file>     rc 0 flag on a non-comment line as whole token; rc 1 otherwise/missing
tn_node_strip_observer_flag <file>   rc 0 stripped or already absent (idempotent); rc 1 not writable /
  mktemp failed / verification failed (file untouched). Caller owns backup, daemon-reload, restart.
tn_target_drops_observer <text...>   rc 0 when first x.y.z >= 0.15.0 or no x.y.z; rc 1 when < 0.15.0
check_hardware [legacy_arg] [data_dir=/]   always rc 0; sets TN_HW_SUMMARY, TN_HW_GAPS (node,rpc,validator)
HW_{NODE,RPC,VAL}_MIN_{CPU,RAM_GB,DISK_GB}, HW_VAL_REC_{CPU,RAM_GB,DISK_GB} replace VALIDATOR_MIN_*/OBSERVER_MIN_*

## Harnesses (scratchpad/B1; stubs on PATH: rm(guarded) systemctl docker ufw curl mktemp; hwbin: nproc df)
  for B in /bin/bash /opt/homebrew/bin/bash; do for t in h_stake.sh h_strip.sh h_hw.sh; do $B $t; done; done
  bash 3.2.57: h_stake 148/148, h_strip 102/102, h_hw 43/43
  bash 5.3.15: h_stake 148/148, h_strip 102/102, h_hw 43/43
  No stub calls to systemctl/docker/ufw; no refused rm. sort -V: macOS sort 2.3-Apple supports -V, no shim.
Self-checks: /bin/bash -n and homebrew bash -n lib/common.sh OK; shellcheck -x --severity=error on
  lib/common.sh setup-node.sh check-node.sh update-node.sh OK. All-severity shellcheck count on
  lib/common.sh 18 (HEAD: 19); only new one is TN_HW_GAPS "appears unused" (external interface).

## Notes / deviations
- Contract fact (tn-contracts ConsensusRegistry._retire): retiring sets currentStatus = Any (6) AND
  isRetired = true; getValidator answers for retired tombstones without reverting. So 6 + retired is the
  NORMAL retired case and keeps the old "Status: Retired" label (update-node.sh grep still matches).
- Only a JSON error OBJECT ("error": {...}) counts as an RPC error ("error":null next to a result is fine).
- Docker export command: `<image> telcoin keytool ...` (image binary is `telcoin`, as in setup-node keygen).
  Binary: ${BINARY_PATH:-telcoin-network}. Uses INSTALL_METHOD/DOCKER_IMAGE/BINARY_PATH when set.
  cast send uses ${CONSENSUS_REGISTRY} (lowercase; cast accepts it; checksum form verified with cast).
  display_node_info source 64 -> 68 lines, printed output 52 -> 50 lines.
- Strip: a bare `--observer` line without `\` that ends a continued command also drops the trailing `\`
  of the previous non-comment line (else the continuation swallows the next command; fixture d2 runtime).
- macOS /usr/bin/mktemp ignores TMPDIR -> harness mktemp stub. Leftover /var/folders temp files from the
  first run were deleted.
- awk verified with macOS onetrue awk 20200816 only (no mawk/gawk here). POSIX constructs only.
- Hardware: RAM in GiB (5 % slack, rounded display); disk in DECIMAL GB (5 % slack) since disks are sold
  in decimal TB. Unmeasurable dimension never counts as a gap (print_info "could not check ...").
- ui/server.py has its own hardware mirror + DEFAULT_DOCKER_IMAGE (v0.12.0-adiri); not B1's file.

## README changelog draft
### lib/common v1.4.0 — stake-status probe, --observer safety net, role-aware hardware check
`node_stake_status` is now the one `getValidator` probe. It prints a single
machine-readable line (`<status> <activation_epoch> <is_retired>`, `none` when the call
reverts because the address holds no ConsensusNFT, or `unknown`), and
`node_is_staked_validator` turns that into a yes / no / unknown exit code.
`check_validator_onchain_status` prints the same report as before through
`print_validator_onchain_status`, with two fixes: a rate limit or other non-revert RPC
error no longer reads as "No validator record found", and status 6 is shown as the `Any`
sentinel it is. A retired validator (the contract parks it at `Any` with `isRetired` set)
still prints `Status: Retired`; any other status with `isRetired` set gets `(Retired)`.

The staking steps printed after key generation now match the live `stake(bytes,(bytes))`
signature: export the calldata on the node with `keytool export-staking-args --calldata`,
send it with `cast send` from the machine that holds the validator wallet, then call
`activate()`.

Releases after v0.15.0-adiri reject `--observer`. `tn_node_strip_observer_flag` removes it
from a start wrapper or legacy docker unit and leaves comments, `--instance` and every
`--http` line alone. It writes the file back only after the edited copy passes those
checks. `tn_target_drops_observer` says whether a target tag, image or version is new
enough for the strip.

`check_hardware` now reports against the per-role tiers from the telcoin-network hardware
page (full node 2 cores / 8 GB, public RPC 4 / 16 GB, validator 8 / 32 GB, all on 2 TB)
instead of one flat baseline. It measures total disk size rather than free space, allows
5 % slack so a 16 GB box or a formatted 2 TB disk passes, warns at 90 % disk use, copes
with a missing `nproc` or GNU-only `df` options, and never stops setup. The fallback
docker image is now v0.15.0-adiri.

## Commit message draft
feat(lib/common): stake-status probe, --observer safety net, role-aware hardware check

node_stake_status is the single getValidator probe (status, activation epoch,
isRetired, or none/unknown); non-revert RPC errors no longer read as "no record".
print_validator_onchain_status holds the one label table: status 6 is the Any
sentinel, a retired validator still prints "Status: Retired".
tn_node_strip_observer_flag removes --observer with verification (post-v0.15.0).
check_hardware reports per-role tiers (node/rpc/validator) on total disk with 5 %
slack, sets TN_HW_SUMMARY/TN_HW_GAPS, and never fails. Staking steps now use
keytool export-staking-args; fallback image v0.15.0-adiri; COMMON_VERSION 1.4.0.
