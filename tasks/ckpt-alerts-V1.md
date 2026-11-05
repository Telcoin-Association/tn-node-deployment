status: done

Package V1 (issue #60, branch private-alerts). Spec: tasks/spec-alerts-V1.md; shared: tasks/spec-alerts-shared.md.
V1 does V0-V4, V6, V7 (code and tests). V5 (docs) is V1d.

## Sections
- [x] V0 tree state
- [x] V1 gates
- [x] V2 systemd verify/security
- [x] V3 AGENTS-rule sweep
- [x] V4 runner mutants
- [x] V6 implementer checkpoints
- [x] V7 findings list

## Findings

No E findings. Ordered W then N; the owning package in brackets.

W1 lib/alerts.sh:703-716 (`_alerts_enable_undo`) + :973 (`alerts_disable` meta_set false) [A1b]: a failed fresh enable on a
host with no ENABLE_ALERTS line ends with a new `ENABLE_ALERTS=false` line in /etc/telcoin/.node-meta (the undo
runs alerts_disable, which always `meta_set ENABLE_ALERTS false`; the put-back only runs for a non-false value).
setup-alerts.sh then exits 1 ("nothing changed") without `sa_baseline_refresh` (setup-alerts.sh:584-591, the final `return 1` of sa_enable_run), so on a
HOST_BASELINE=true host AIDE (TnNode = p+u+g+ftype+n+s+l+sha256+sha512 over /etc/telcoin) reports .node-meta
changed. Shown by reading the code and by alerts_test.sh:685, which asserts this very outcome ("enable all-fail:
ENABLE_ALERTS=false" from an absent key). pending->false->pending is two needless writes with identical content (no
AIDE hit). Fix (preferred): give alerts_disable a mode that skips its meta write (e.g. third arg `keep-meta`) and let
the undo restore the start state exactly: `meta_set ENABLE_ALERTS "$prev"` when the key was present,
`meta_unset ENABLE_ALERTS` when it was absent (read presence with `meta_get` rc 1 vs 0 before the enable); update
alerts_test.sh:685 to expect no line. Alternative: call sa_baseline_refresh on the rc-1 path of sa_enable_run.

W2 lib/alerts.sh:1025-1030 (`alerts_status`) [A1b]: without root, .node-meta (root 0600) cannot be read, so
`addon_meta_get ENABLE_ALERTS false` returns the default and a host with private alerts ON reports
"Private alerts: off" (plus "timer active ...") and `--json --status` says `"enabled":"false"`; with on=0 the
timer-down and stale-run issues are not counted either. check-node.sh is usually run without sudo, so this is the
common case. Shown: fixture with ENABLE_ALERTS=true in a mode-000 .node-meta, timer unit present, non-root:
output "Private alerts: off / timer active, next run ...". Fix: when node_meta_path exists but is not readable,
report "Private alerts: unknown (run with sudo to read .node-meta)" and take `on` from
`systemctl is-enabled --quiet telcoin-heartbeat.timer` (or set ALERTS_ST_ENABLED="" -> JSON null).

W3 tools/tests/heartbeat_test.sh [A1a] surviving runner mutants (each one line in a scratch copy, 167/167 pass):
  - M04 lib/tn-heartbeat.sh:585 `if [[ $age -lt $grace ]]` -> `-le` (RPC starting grace): the test checks 70 s
    and 130 s only. Add: unit active 120 s ago, RPC refused -> down (and 119 s -> up).
  - M21 lib/tn-heartbeat.sh:485 drop `header_since="$mono"` in the restart branch: no test shows a node restart
    restarting the stall window. Add: header stuck for 170 s, restart (new SVC_AET), 60 s later still up (stall
    counts from the restart), not "consensus stalled ... for 230s".
  - M23 lib/tn-heartbeat.sh:646 `unknown` mode clearing inactive_since: no test with tn_nodeMode failing between
    two CvvInactive runs. Add: CvvInactive, then tn_nodeMode unreadable (rpc file removed), then CvvInactive at
    900 s from the first -> down; inactive_since unchanged across the unknown run.
  - M63 lib/tn-heartbeat.sh:646 `Observer` no longer clearing inactive_since: the test has no Observer run at
    all (neither the `Observer block N` up message nor the reset). A member that leaves the committee and comes
    back CvvInactive would be measured from its old window. Add: CvvInactive, then Observer (inactive_since
    empty, up "Observer block 1234567 epoch 42"), then CvvInactive again -> window from that run.

N1 setup-alerts.sh:647-649 [A2]: an already-enabled node ignores --interval/--stall-after/--inactive-after
(alerts_refresh keeps the stored values) and says so with a warn ("... are not applied; to change them, run
--disable and then --enable"). Fine as is (warned); the request-variable refresh (ALERTS_TIMING_REQ read by
alerts_refresh) would be a small follow-up. --label is applied on that path (no-targets refresh) but silently
ignored when targets are given (alerts_set_targets does not rewrite alerts.env).

N2 heartbeat_test.sh further survivors (low impact or equivalent): M44 the negative-age clamp in `_hb_age`
(lib/tn-heartbeat.sh:417; /proc/uptime never runs behind CLOCK_MONOTONIC); M60 the runner's own
`unset TN_BLS_PASSPHRASE` (:749; the unit's UnsetEnvironment= covers it; a test could export it and have the curl
stub log `${TN_BLS_PASSPHRASE+set}`); M65 hb_url_host's character filter (a host with `%` or `!` would make the
push record fail its regex and be left out of the state); M66 the temp state file outside the state dir (not
observable in a fixture: mv still works, only atomicity is lost); M69 `inres` without the `{` test (equivalent:
valid JSON cannot put a key directly in an array); M25b stale `push_N` of a removed target survives (drop
lib/tn-heartbeat.sh:909 `_hb_state_clear`; alerts_test reads only as many slots as the targets file has, so
harmless); M39 header digits not followed by `,` `}` or blank (e.g. `"number":12.5`) would read as 12 (serde never
emits that); M37 the symlink `rm` before `mv -f` in hb_state_save is an equivalent mutant (rename replaces the link).

N3 lib/tn-heartbeat.sh:174-183 [A1a]: a healthchecks URL holding a `#fragment` is accepted; its down push goes to
`<url>#frag/fail`, which curl sends as the success ping. Refuse `#` for healthchecks like `?`.

N5 lib/alerts.sh:814 and :934 [A1b]: OnBootSec=120 is in the past on a running host, and systemd elapses such a
timer as soon as it is activated (systemd.timer(5)), so `systemctl enable --now` after the enable's test and
`systemctl restart` in alerts_refresh each send one extra heartbeat at once. Harmless (a duplicate up), worth one
line in the docs or a comment; no change needed.

N6 tools/tests/check_node_hardening_test.sh:212-238 [A3a]: check_alerts is tested against a stand-in
alerts_status only. The real quiet line was confirmed here by hand (real library, empty fixture:
"Private alerts: off (enable them with setup-alerts.sh)", rc 0) and alerts_test.sh:788 asserts it in the library.

N4 `git diff hardening-followups` is not this round's diff: hardening-followups moved 4 commits (2966e54..a2162b6)
after private-alerts branched at 4a2cf6e; merge or rebase before the PR so it shows only the alerts files.

## Gates

V0: HEAD = 4a2cf6e (base), no agent commit on private-alerts. No `*.sha256` touched before V1.
`git diff hardening-followups --stat` also lists .github/CODEOWNERS, observability/config.alloy(.sha256),
tasks/spec-r2-*, tools/tests/ci_pins_test.sh, tasks/todo.md: those are 4 commits that landed on
hardening-followups after private-alerts branched (2966e54..a2162b6), not this round. The round's own
diff is `git diff HEAD`: 13 tracked code/test files + 8 new files (setup-alerts.sh, lib/alerts.sh,
lib/tn-heartbeat.sh, 4 tests, vm.d/P0-alerts.sh). The orchestrator should rebase/merge before the PR.

| Gate | Result |
|---|---|
| `bash tools/tests/run.sh` (bash 5.3.9, host) | 65 files, 1 failed: release_scripts_test.sh ("not committed to git: lib/alerts.sh", expected) |
| `bash:3.2` container run.sh | 65 files, 0 failed (release_scripts SKIP: no git) |
| `ubuntu:24.04` container run.sh (root) | 65 files, 0 failed (release_scripts SKIP) |
| new tests (bash5/3.2/ubuntu) | heartbeat 167/167/167; alerts 241 (3 skip non-root)/241 (1 skip)/241 (1 skip, no systemd-analyze); setup_alerts 176/173 (3 skip no python3)/173; setup_node_alerts 48 all |
| changed tests | remove 474, remove_addons 34, updater_manifest 192 (alerts rows + hint un-skipped), addon_gates 67, addon_oldlib 53, host_baseline 223/232/232, check_node_hardening 30/45/50: all 0 failures |
| `bash -n` bash 5 + bash 3.2 on 20 changed/new *.sh | clean |
| `tools/check-bash32.sh` on each | clean |
| `shellcheck -x --severity=error` (0.11.0) | clean |
| shellcheck warning (advisory) | new files: only SC2034 on cross-file globals in lib/alerts.sh (ALERTS_VERSION, ALERTS_APPLIED, ALERTS_ST_*); changed files: no new warnings vs HEAD |
| `check-perl-interp.sh` on every tracked *.sh + 8 new | clean, 153 files |
| passphrase_print_test.sh | 4/4; NOTE it scans `git ls-files` so the untracked new files were not in its tree scan: ran its `passphrase_print_lint` function directly on the three new files: clean |
| root_write_pipe_test.sh | 2/2 (glob scan includes new files) |
| check-network-hits.sh | clean, 146 annotated hits, 27 files |
| ci_pins_test.sh | 53/53 |
| V2 `systemd-analyze verify` (ubuntu:24.04, systemd 255.4) | service, timer and the DATA_DIR=/srv/tn-data variant: rc 0, no output |
| V2 `systemd-analyze security --offline=yes` service | exposure 1.5 OK |
| V3 sweep | no require_testnet/is_testnet in the 3 new files; lib/common.sh diff = the 3-line guarded source block only; tn_testnet_addons_present byte-identical to HEAD; every push curl takes the URL via `-K <(printf ...)` (RPC and health use `--url` with the local, non-secret address); no echo/printf of a URL, token, SA_RAW, ALERTS_VALID or old targets except into `/dev/null`-bound validators and process substitutions; no root write outside the primitives (the only `mv` is the runner's own state file); no `systemctl stop/restart` of the node (only the heartbeat timer/service); first `VAR=` match for _file_version: setup-alerts.sh:52 `readonly SCRIPT_VERSION="2.1.0"`, lib/alerts.sh:47, lib/tn-heartbeat.sh:61; three SCRIPTS rows right after setup-observability; not in TESTNET_ADDONS_BUNDLE; no hb_/ALERTS_ name collision with the library |
| V3 real-curl smoke (curl 8.18, python listener) | kuma GET with query and ping, webhook exact JSON, healthchecks POST and /fail, UA, refused/tls, exit 1 + `<4>every target failed`, real `systemctl show` not-found reason |
| V4 mutants of lib/tn-heartbeat.sh vs heartbeat_test.sh | 59 one-line mutants (scratch copies; test copy with RUNNER from HB_RUNNER): 46 killed, 13 survived (W3: M04 M21 M23 M63; N2: M25/M25b M37 M39 M44 M60 M65 M66 M69). Lists: scratchpad V1/mut/results.txt and results2.txt |
| gen-checksums.sh | 43 sidecars; changed: check-node, lib/common, remove-node, setup-node, update-scripts; new: setup-alerts, lib/alerts, lib/tn-heartbeat. Restored with `git checkout -- '*.sha256'` and the three new ones deleted; `git status --short -- '*.sha256'` empty after |

## Claims not confirmed

Read last (V6), after V0-V4. Confirmed independently: A1a's real-curl smoke (re-run here with curl 8.18 against a
python listener: kuma GET `?status=up&msg=...&ping=N`, webhook POST with the exact JSON, healthchecks POST to `<url>`
and `<url>/fail`, UA `tn-heartbeat/2.1.0`, `refused`/`tls` push failures, exit 1 and `<4>every target failed`,
`service <x> not found` from a real `systemctl show`); A1b's systemd-analyze verify (re-run on systemd 255: clean,
exposure 1.5); every test count the checkpoints give (heartbeat 167, alerts 241, setup_alerts 176/173,
setup_node_alerts 48, remove 474, remove_addons 34, updater_manifest 192, addon_gates 67, addon_oldlib 53,
lib_skew 146/110); the quiet status line through the real library (`Private alerts: off (enable them with
setup-alerts.sh)`, rc 0); the A2/A3b/A3a open items now resolved in code (pending put back, `.tn.*` shredded by
alerts_disable, quiet status, setup-alerts maps alerts_set_targets rc 2 to exit 3).

Not confirmed:
- A1b: tools/tests/vm.d/P0-alerts.sh never passed end to end anywhere (Docker gives no LoadCredential= dir). Read
  closely: its assumptions about setup-alerts.sh hold in the code (`--json` done on stdout via fd 3, exit 0 for
  enable/disable, `--targets-stdin` from a pipe, `--interval 30` -> stall 180 / inactive 900, the launch file found
  as /usr/local/libexec/telcoin/tn-start through INSTALL_METHOD=binary, http to 127.0.0.1 allowed, token
  `vmtest1` 7 chars). Unproven until the CI VM job: that `systemctl show` works for the DynamicUser under
  ProtectSystem=strict / ProtectProc=invisible / RestrictAddressFamilies (the "service telcoin inactive (dead)"
  assertion is the only proof), and that curl resolves and connects inside the sandbox. Small flake window: a
  timer-started run (OnBootSec is in the past, so `enable --now` fires one at once) can overlap the explicit
  `systemctl start` after `systemctl stop telcoin`.
- A1a: "ten deliberate runner bugs each fail the test": the named kinds do fail here too, but 4 other one-line
  mutants survive (W3) and 3 more are low-impact (N2).
- A2: the smoke against the real library in ubuntu ("no systemctl call" on the no-unit refusal) was not re-run.
- A3a: its two mutation checks (export TN_SETUP_PASS, change the summary line) were not re-run.
- release_scripts_test.sh: 41 local failures; the only non-fixture error is "not committed to git: lib/alerts.sh"
  and every failing case is a prepare or reads the MANIFEST a prepare makes, so they look like one cascade. Not
  re-run with the files committed (no commits allowed here): the orchestrator re-runs it after W5.
