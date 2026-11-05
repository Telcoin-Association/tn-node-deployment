#!/usr/bin/env bash
# =============================================================================
# tasks/verify-r2/V7-IMG/t_order.sh -- IMG checks 4 (call order) and 5 (--json)
# of the V7 spec. setup-node, update-node and edit-config run with a docker
# stand-in on PATH (lib.sh: every call logged, a canned --version per digest)
# and the real tn_docker_holds_digest and tn_docker_image_network_ok; only what
# touches the host or the network is stubbed (root, locks, apt, the release
# lookup, the pending-state and .node-meta writers, which log to the same file).
# For each path: a testnet image built without adiri (or a mainnet image built
# with it) is refused after resolve -> pull -> digest check -> --version run,
# and nothing that starts a container or writes .node-meta / pending state
# follows; a good image goes on, and those writes come after the --version run.
# Under --json: stdout is JSON lines only, ending with an error event and then
# the done event (ok false), nothing after it.
#
#   bash tasks/verify-r2/V7-IMG/t_order.sh
#
# Verifier harness (round 2, V7-IMG). bash 3.2 safe.
# =============================================================================
# shellcheck source=tasks/verify-r2/V7-IMG/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
mkdir -p "$T/sn" "$T/un" "$T/ec" "$T/root/etc/telcoin" "$T/data"
for s in setup-node update-node edit-config; do
    d="$T/sn"; [[ "$s" == update-node ]] && d="$T/un"; [[ "$s" == edit-config ]] && d="$T/ec"
    grep -v '^main "\$@"$' "$V7_REPO/${s}.sh" > "$d/${s}.sh"
    ln -s "$V7_REPO/lib" "$d/lib"
done
export TN_ROOT_PREFIX="$T/root" T GT GM D64
v7_docker_stub "$T/bin"
PATH="$T/bin:$PATH"
D_TOK="$(v7_digest 21)"; D_TBAD="$(v7_digest 22)"; D_MOK="$(v7_digest 23)"; D_MBAD="$(v7_digest 24)"; D_OLD="$(v7_digest 25)"
v7_canned "$D_TOK" "$(v7_version 'Build Features: adiri,faucet')"
v7_canned "$D_TBAD" "$(v7_version 'Build Features: ')"
v7_canned "$D_MOK" "$(v7_version 'Build Features: ')"
v7_canned "$D_MBAD" "$(v7_version 'Build Features: adiri')"
export D_TOK D_TBAD D_MOK D_MBAD D_OLD
VERSION_RUN='^run .*--entrypoint /usr/local/bin/telcoin .* --version$'
# after_check -- the log lines after the --version run that start or record something.
after_check() {
    awk -v re="$VERSION_RUN" 'f && /^(run --rm [^-]|swap|meta|pending|restart|keygen)/ { print } $0 ~ re { f = 1 }' "$V7_DLOG"
}
meta() { printf '%s\n' "$@" > "$T/root/etc/telcoin/.node-meta"; }

# ---------------------------------------------------------------------------------
# setup-node: main --json --phase=keygen, and the interactive _preflight_docker
SN_STUBS='json_require_root() { :; }; setup_take_lock() { :; }; setup_release_lock() { :; }
  check_root() { :; }; detect_distro() { :; }; setup_write_restart_guards() { :; }; check_cve_2026_31431() { :; }
  check_hardware() { :; }; check_ports() { :; }; check_internet() { :; }; tn_os_floor_check() { return 0; }; tn_systemd_version() { echo 257; }
  install_package() { :; }; _setup_docker_apt() { :; }; _setup_docker_live_restore() { :; }
  json_check_keygen_inputs() { :; }; tn_docker_release_tag_for() { return 1; }; tn_ref_min_check() { return 0; }
  tn_mainnet_enabled() { return 0; }; tn_docker_network_ok() { return 0; }
  tn_docker_image_for_tag() { echo "resolve $1 $2" >> "$V7_DLOG"; printf "%s@sha256:%s\n" "$(tn_docker_repo_for "$1")" "$RESOLVED"; }
  latest_docker_image() { echo "resolve $1 latest" >> "$V7_DLOG"; printf "%s@sha256:%s\n" "$(tn_docker_repo_for "$1")" "$RESOLVED"; }
  setup_passphrase_method() { echo "meta passphrase" >> "$V7_DLOG"; }
  write_node_meta() { echo "meta $*" >> "$V7_DLOG"; }
  step_config() { echo "step_config" >> "$V7_DLOG"; }
  step_create_infrastructure() { echo "infra" >> "$V7_DLOG"; }
  step_generate_keys() { echo "keygen" >> "$V7_DLOG"; docker run --rm "$DOCKER_IMAGE" telcoin keytool; write_node_meta "DOCKER_IMAGE=$DOCKER_IMAGE"; }'
export SN_STUBS
sn_json() {  # NAME NETWORK RESOLVED-DIGEST EXPECTED-RC ARGS...
    local name="$1" net="$2" res="$3" want="$4" rc=0
    shift 4
    : > "$V7_DLOG"
    ( set +e
      # shellcheck source=/dev/null
      source "$T/sn/setup-node.sh" >/dev/null 2>&1
      set +e
      eval "$SN_STUBS"
      RESOLVED="$res"
      main --json --phase=keygen --network "$net" --install-method docker "$@" \
          --address 0x0123456789012345678901234567890123456789 --data-dir "$T/data"
    ) > "$T/json.out" 2> "$T/err" || rc=$?
    check_rc "setup --json $name: rc" "$want" "$rc"
}
sn_json "testnet tag, image without adiri" testnet "$D_TBAD" 1 --release-tag v0.17.0-adiri
check "setup --json testnet bad: order resolve, pull, digest check, --version" yes \
    "$(v7_yes v7_log_order '^resolve testnet v0.17.0-adiri' "^pull ${GT}@sha256:${D_TBAD}$" '^image inspect .*RepoDigests' "$VERSION_RUN")"
check "setup --json testnet bad: nothing started or recorded" "" "$(after_check)"
check "setup --json testnet bad: no meta write at all" "0" "$(grep -c '^meta' "$V7_DLOG")"
check "setup --json testnet bad: JSON only, error then done ok:false" "1 error done false" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2-5)"
printf 'info  setup --json testnet bad: events %s\n' "$(v7_events "$T/json.out")"
check "setup --json testnet bad: done names the refusal" "1" "$(tail -n 1 "$T/json.out" | grep -c 'it is not a testnet image')"
sn_json "testnet tag, adiri image" testnet "$D_TOK" 0 --release-tag v0.17.0-adiri
check "setup --json testnet ok: --version before meta, keygen run and DOCKER_IMAGE" yes \
    "$(v7_yes v7_log_order "$VERSION_RUN" '^meta passphrase' '^keygen' "^run --rm ${GT}@sha256:${D_TOK} telcoin keytool" '^meta DOCKER_IMAGE=')"
check "setup --json testnet ok: JSON only, done ok:true last" "1 done true" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2,4,5)"
sn_json "testnet --docker-image without adiri" testnet "" 1 --docker-image "${GT}@sha256:${D_TBAD}"
check "setup --json --docker-image bad: pull then --version, nothing after" "yes " \
    "$(v7_yes v7_log_order "^pull ${GT}@sha256:${D_TBAD}$" "$VERSION_RUN") $(after_check)"
check "setup --json --docker-image bad: error then done" "1 error done false" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2-5)"
sn_json "newest release (no tag), image without adiri" testnet "$D_TBAD" 1
check "setup --json newest bad: resolve latest, pull, --version, nothing after" "yes " \
    "$(v7_yes v7_log_order '^resolve testnet latest' '^pull ' "$VERSION_RUN") $(after_check)"
sn_json "mainnet tag, image with adiri" mainnet "$D_MBAD" 1 --release-tag v1.0.0
check "setup --json mainnet bad: refused after --version, nothing after" "yes " \
    "$(v7_yes v7_log_order '^resolve mainnet v1.0.0' "^pull ${GM}@sha256:${D_MBAD}$" "$VERSION_RUN") $(after_check)"
check "setup --json mainnet bad: error then done" "1 error done false" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2-5)"
sn_json "mainnet tag, image without features" mainnet "$D_MOK" 0 --release-tag v1.0.0
check "setup --json mainnet ok: done ok:true" "1 done true" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2,4,5)"
V7_RUN_RC=125 sn_json "docker run fails" testnet "$D_TOK" 1 --release-tag v0.17.0-adiri
check "setup --json run failure: refused, nothing after" "yes " "$(v7_yes v7_log_order "$VERSION_RUN") $(after_check)"
check "setup --json run failure: error then done" "1 error done false" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2-5)"
V7_HOLD=0 sn_json "digest not held after the pull" testnet "$D_TOK" 1 --release-tag v0.17.0-adiri
check "setup --json digest mismatch: no --version run" "0" "$(grep -cE "$VERSION_RUN" "$V7_DLOG")"
V7_PULL_RC=1 sn_json "pull fails" testnet "$D_TOK" 1 --release-tag v0.17.0-adiri
check "setup --json pull fails: no --version run, error then done" "0 1 error done false" \
    "$(grep -cE "$VERSION_RUN" "$V7_DLOG") $(v7_json_tail "$T/json.out" | cut -d' ' -f2-5)"

sn_int() {  # NAME NETWORK RESOLVED-DIGEST EXPECTED ("rc BINARY_PATH") CODE
    local rc=0
    : > "$V7_DLOG"
    rm -f "$T/bp"
    ( set +e
      # shellcheck source=/dev/null
      source "$T/sn/setup-node.sh" >/dev/null 2>&1
      set +e
      eval "$SN_STUBS"
      setup_fail() { printf '%s\n' "$*" >&2; exit 1; }
      # The image prompt loops on stdin EOF while nothing is usable (it ignores
      # read's status): stop after three prompts instead of spinning.
      V7_READS=0
      read() { V7_READS=$((V7_READS + 1)); [ "$V7_READS" -le 3 ] || { echo "V7: prompt loop" >&2; exit 9; }; builtin read "$@"; }
      RESOLVED="$3" NETWORK="$2" JSON_MODE=false
      eval "$5"
      printf '%s' "$BINARY_PATH" > "$T/bp"
    ) > "$T/int.out" 2> "$T/err" || rc=$?
    check "setup interactive $1" "$4" "$rc $(cat "$T/bp" 2>/dev/null)"
}
sn_int "--release-tag, image without adiri: refused" testnet "$D_TBAD" "1 " "RELEASE_TAG=v0.17.0-adiri DOCKER_IMAGE=; _preflight_docker"
check "setup interactive bad: order and nothing after" "yes " "$(v7_yes v7_log_order '^resolve ' '^pull ' '^image inspect' "$VERSION_RUN") $(after_check)"
sn_int "--release-tag, adiri image: goes on" testnet "$D_TOK" "0 docker" "RELEASE_TAG=v0.17.0-adiri DOCKER_IMAGE=; _preflight_docker"
sn_int "typed tag at the prompt, image without adiri: refused" testnet "$D_TBAD" "1 " "RELEASE_TAG= DOCKER_IMAGE=; _preflight_docker <<< 'v0.17.0-adiri'"
check "setup interactive typed: resolve, pull, --version" yes "$(v7_yes v7_log_order '^resolve testnet v0.17.0-adiri' '^pull ' "$VERSION_RUN")"
sn_int "Enter at the prompt (newest), mainnet image with adiri: refused" mainnet "$D_MBAD" "1 " "RELEASE_TAG= DOCKER_IMAGE=; _preflight_docker <<< ''"
# (step_preflight end to end is the --json run above: the interactive one prompts for the data dir.)

# ---------------------------------------------------------------------------------
# update-node: main --json --prepare --ref, and the interactive prepare_docker_update
UN_STUBS='json_require_root() { :; }; detect_node() { :; }; update_lock() { return 0; }; update_legacy_refusal() { return 0; }
  update_migrate_ownership() { return 0; }; detect_install_method() { echo docker; }; check_root() { :; }
  update_floor_check() { return 0; }; tn_release_update_lock() { :; }
  detect_current_docker_image() { printf "%s@sha256:%s\n" "$(tn_docker_repo_for "$(_tn_guard_network)")" "$D_OLD"; }
  tn_docker_image_for_tag() { echo "resolve $1 $2" >> "$V7_DLOG"; printf "%s@sha256:%s\n" "$(tn_docker_repo_for "$1")" "$RESOLVED"; }
  build_log_file() { mktemp "$T/pull.XXXXXX"; }
  write_pending_state() { echo "pending $(cat | tr "\n" " ")" >> "$V7_DLOG"; }
  storage_migration_begin() { :; }; confirm() { return 0; }'
export UN_STUBS
un_json() {  # NAME NETWORK RESOLVED REF EXPECTED-RC
    local rc=0
    : > "$V7_DLOG"
    meta "NETWORK=$2" "INSTALL_METHOD=docker"
    ( set +e
      # shellcheck source=/dev/null
      source "$T/un/update-node.sh" >/dev/null 2>&1
      set +e
      eval "$UN_STUBS"
      RESOLVED="$3"
      main --json --prepare --ref "$4"
    ) > "$T/json.out" 2> "$T/err" || rc=$?
    check_rc "update --json $1: rc" "$5" "$rc"
}
un_json "testnet tag, image without adiri" testnet "$D_TBAD" v0.17.0-adiri 1
check "update --json testnet bad: order resolve, pull, digest check, --version" yes \
    "$(v7_yes v7_log_order '^resolve testnet v0.17.0-adiri' "^pull ${GT}@sha256:${D_TBAD}$" '^image inspect .*RepoDigests' "$VERSION_RUN")"
check "update --json testnet bad: no pending state" "" "$(after_check)$(grep '^pending' "$V7_DLOG")"
check "update --json testnet bad: JSON only, error then done ok:false" "1 error done false" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2-5)"
printf 'info  update --json testnet bad: events %s\n' "$(v7_events "$T/json.out")"
un_json "testnet tag, adiri image" testnet "$D_TOK" v0.17.0-adiri 0
check "update --json testnet ok: pending written after --version" yes "$(v7_yes v7_log_order "$VERSION_RUN" '^pending PHASE=pull_complete')"
check "update --json testnet ok: done ok:true last" "1 done true" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2,4,5)"
un_json "mainnet tag, image with adiri" mainnet "$D_MBAD" v1.0.0 1
check "update --json mainnet bad: refused after --version, no pending" "yes " "$(v7_yes v7_log_order "^pull ${GM}@sha256:${D_MBAD}$" "$VERSION_RUN") $(grep '^pending' "$V7_DLOG")"
check "update --json mainnet bad: error then done" "1 error done false" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2-5)"
un_json "mainnet tag, image without features" mainnet "$D_MOK" v1.0.0 0
un_json "testnet digest without adiri" testnet "" "${GT}@sha256:${D_TBAD}" 1
check "update --json testnet digest bad: pull, --version, no pending" "yes " "$(v7_yes v7_log_order "^pull ${GT}@sha256:${D_TBAD}$" "$VERSION_RUN") $(grep '^pending' "$V7_DLOG")"
V7_RUN_RC=125 un_json "docker run fails" testnet "$D_TOK" v0.17.0-adiri 1
check "update --json run failure: no pending, error then done" " 1 error done false" "$(grep '^pending' "$V7_DLOG") $(v7_json_tail "$T/json.out" | cut -d' ' -f2-5)"
un_json "old package digest refused before any pull" testnet "" "${GL}@sha256:${D_TOK}" 1
check "update --json old package: no docker call" "0" "$(wc -l < "$V7_DLOG" | tr -d ' ')"
check "update --json old package: error then done" "1 error done false" "$(v7_json_tail "$T/json.out" | cut -d' ' -f2-5)"
un_int() {  # NAME NETWORK RESOLVED REF EXPECTED-RC
    local rc=0
    : > "$V7_DLOG"
    meta "NETWORK=$2" "INSTALL_METHOD=docker"
    ( set +e
      # shellcheck source=/dev/null
      source "$T/un/update-node.sh" >/dev/null 2>&1
      set +e
      eval "$UN_STUBS"
      RESOLVED="$3" JSON_MODE=false
      prepare_docker_update "$4"
    ) > "$T/int.out" 2> "$T/err" || rc=$?
    check_rc "update interactive $1" "$5" "$rc"
}
un_int "testnet tag, image without adiri refused" testnet "$D_TBAD" v0.17.0-adiri 1
check "update interactive bad: order, no pending" "yes " "$(v7_yes v7_log_order '^resolve ' '^pull ' '^image inspect' "$VERSION_RUN") $(grep '^pending' "$V7_DLOG")"
un_int "testnet tag, adiri image" testnet "$D_TOK" v0.17.0-adiri 0
check "update interactive ok: pending after --version" yes "$(v7_yes v7_log_order "$VERSION_RUN" '^pending ')"

# ---------------------------------------------------------------------------------
# edit-config: --set docker_image (plain and --json) and the image menu
EC_STUBS='edit_require_root() { :; }; resolve_target() { TARGET_SERVICE=telcoin; TARGET_LAUNCH_FILE="$T/start.sh"; return 0; }
  edit_lock() { return 0; }; edit_unlock() { :; }; menu_lock() { return 0; }; backup_edit_targets() { return 0; }
  edit_reset_backups() { :; }; edit_restore_backups() { return 0; }; edit_drop_backups() { :; }; edit_report_backups() { :; }
  edit_launch_unambiguous() { return 0; }; edit_floor_check() { return 0; }; edit_baseline_refresh() { :; }
  read_launch_line() { printf "ExecStart=/usr/bin/docker run --rm --name telcoin %s node\n" "$CURRENT"; }
  launch_docker_image() { printf "%s\n" "$CURRENT"; }
  swap_docker_image() { echo "swap $1" >> "$V7_DLOG"; SWAPPED=1; return 0; }
  edit_any_changed() { [[ -n "${SWAPPED:-}" ]]; }
  edit_record_image() { echo "meta $*" >> "$V7_DLOG"; }
  edit_restart() { echo "restart" >> "$V7_DLOG"; return 0; }; apply_changes() { echo "restart" >> "$V7_DLOG"; }
  tn_docker_network_ok() { return 0; }
  tn_docker_image_for_tag() { echo "resolve $1 $2" >> "$V7_DLOG"; printf "%s@sha256:%s\n" "$(tn_docker_repo_for "$1")" "$RESOLVED"; }'
export EC_STUBS
ec() {  # NAME NETWORK RESOLVED EXPECTED-RC MODE(json|plain|menu) VALUE
    local rc=0 cur
    : > "$V7_DLOG"
    meta "NETWORK=$2" "INSTALL_METHOD=docker"
    if [[ "$2" == mainnet ]]; then cur="${GM}@sha256:${D_OLD}"; else cur="${GT}@sha256:${D_OLD}"; fi
    ( set +e
      # shellcheck source=/dev/null
      source "$T/ec/edit-config.sh" >/dev/null 2>&1
      set +e
      eval "$EC_STUBS"
      RESOLVED="$3" CURRENT="$cur"
      case "$5" in
          json) main --json --set "docker_image=$6" ;;
          plain) JSON_MODE=false; EDIT_SET_PAIR="docker_image=$6"; run_set ;;
          menu) JSON_MODE=false; printf '%s\n\n\n' "$6" | edit_docker_image ;;
      esac
    ) > "$T/ec.out" 2> "$T/err" || rc=$?
    check_rc "edit $5 $1: rc" "$4" "$rc"
}
ec "testnet tag, image without adiri" testnet "$D_TBAD" 1 json v0.17.0-adiri
check "edit --json testnet bad: order resolve, pull, digest check, --version" yes \
    "$(v7_yes v7_log_order '^resolve testnet v0.17.0-adiri' "^pull ${GT}@sha256:${D_TBAD}$" '^image inspect .*RepoDigests' "$VERSION_RUN")"
check "edit --json testnet bad: no swap, meta or restart" "" "$(after_check)"
check "edit --json testnet bad: JSON only, error then done ok:false" "1 error done false" "$(v7_json_tail "$T/ec.out" | cut -d' ' -f2-5)"
printf 'info  edit --json testnet bad: events %s\n' "$(v7_events "$T/ec.out")"
ec "testnet tag, adiri image" testnet "$D_TOK" 0 json v0.17.0-adiri
check "edit --json testnet ok: swap, meta, restart after --version" yes "$(v7_yes v7_log_order "$VERSION_RUN" '^swap ' '^meta ' '^restart')"
check "edit --json testnet ok: done ok:true last" "1 done true" "$(v7_json_tail "$T/ec.out" | cut -d' ' -f2,4,5)"
ec "mainnet tag, image with adiri" mainnet "$D_MBAD" 1 json v1.0.0
check "edit --json mainnet bad: nothing after --version, error then done" "yes  1 error done false" \
    "$(v7_yes v7_log_order "$VERSION_RUN") $(after_check) $(v7_json_tail "$T/ec.out" | cut -d' ' -f2-5)"
V7_RUN_RC=125 ec "docker run fails" testnet "$D_TOK" 1 json v0.17.0-adiri
check "edit --json run failure: nothing after, error then done" " 1 error done false" "$(after_check) $(v7_json_tail "$T/ec.out" | cut -d' ' -f2-5)"
ec "testnet tag, image without adiri" testnet "$D_TBAD" 1 plain v0.17.0-adiri
check "edit --set testnet bad: nothing after --version" "yes " "$(v7_yes v7_log_order "$VERSION_RUN") $(after_check)"
ec "testnet digest without adiri" testnet "" 0 menu "${GT}@sha256:${D_TBAD}"
check "edit menu testnet bad: pull, --version, no swap/meta/restart" "yes " "$(v7_yes v7_log_order "^pull ${GT}@sha256:${D_TBAD}$" "$VERSION_RUN") $(after_check)"
ec "testnet tag, adiri image" testnet "$D_TOK" 0 menu v0.17.0-adiri
check "edit menu testnet ok: swap, meta, restart after --version" yes "$(v7_yes v7_log_order "$VERSION_RUN" '^swap ' '^meta ' '^restart')"
ec "mainnet tag, image with adiri" mainnet "$D_MBAD" 0 menu v1.0.0
check "edit menu mainnet bad: nothing after --version" "yes " "$(v7_yes v7_log_order "$VERSION_RUN") $(after_check)"
finish
