#!/usr/bin/env bash
# V2 driver for hooks_v2.sh: one path of update-node.sh (un), edit-config.sh (ec),
# remove-node.sh (rm) or setup-node.sh (sn) in a fresh process, with the steps
# around the hook stubbed and every call recorded in V2_LOG/calls.
#   bash hooks_drv.sh un|ec|rm|sn CASE
# Environment: V2_H (dir with the script copies, lib -> the library under test),
# V2_FX (TN_ROOT_PREFIX), V2_LOG, V2_JSON (1: --json mode), V2_NOSTUB (1: keep the
# library's own tn_host_baseline_* functions), and per-script controls below.
set -u
S="$1"
CASE="$2"
CALLS="$V2_LOG/calls"
TN_ROOT_PREFIX="$V2_FX"
export TN_UPDATE_LOCK_FILE="$V2_LOG/update.lock"
case "$S" in
    un) f=update-node.sh ;;
    ec) f=edit-config.sh ;;
    rm) f=remove-node.sh ;;
    sn) f=setup-node.sh ;;
esac
# shellcheck source=/dev/null
source "$V2_H/$f"
set +e
v2_call() { printf '%s\n' "$*" >> "$CALLS"; }
if [[ "${V2_NOSTUB:-0}" != 1 ]]; then
    # The hook targets: record, and send one warning through the printer the
    # script gave (in --json mode it must be an event before the done event).
    tn_host_baseline_refresh() { v2_call "REFRESH ${1:-}"; [[ -z "${1:-}" ]] || "$1" warn "V2-REFRESH-MARK"; return 0; }
    tn_host_baseline_remove() {
        v2_call "TEARDOWN fn=${1:-} unit=$([[ -f "$V2_FX/etc/systemd/system/telcoin.service" ]] && echo yes || echo no) conf=$([[ -d "$V2_FX/etc/telcoin" ]] && echo yes || echo no) data=$([[ -d "${V2_DD:-/nonexistent}" ]] && echo yes || echo no)"
        return 0
    }
    tn_host_baseline_install() { v2_call "INSTALL ${1:-}"; [[ -z "${1:-}" ]] || "$1" step "V2-INSTALL-MARK"; return "${V2_INSTALL_RC:-0}"; }
fi
confirm() { v2_call "confirm $*"; [[ "${V2_CONFIRM:-yes}" == yes ]]; }
if [[ "${V2_JSON:-0}" == 1 ]]; then
    JSON_MODE=true
    exec 3>&1 1>&2
fi

rc=0
case "$S:$CASE" in
    un:*)
        # update-node: the apply functions with their steps stubbed.
        STORAGE_MIGRATION=false
        read_pending_state() {
            if [[ "$V2_METHOD" == docker ]]; then
                printf 'INSTALL_METHOD=docker\nOLD_IMAGE=img:old\nNEW_IMAGE=img:new\nPULLED_IMAGE_ID=sha256:abc\nOLD_REF=v1\nNEW_REF=v2\n'
            else
                printf 'INSTALL_METHOD=%s\nBUILT_BINARY=%s\nOLD_REF=v1\nNEW_REF=v2\nNEW_VERSION=2.0\nBUILT_HASH=%s\n' "$V2_METHOD" "$V2_BUILT" "$V2_BUILT_HASH"
            fi
        }
        storage_migration_begin() { STORAGE_MIGRATION="${V2_SM:-false}"; return 0; }
        validator_downtime_warning_if_applicable() { return 0; }
        docker_launch_file() { printf '%s\n' "$V2_FX/launch"; }
        apply_root_dir_refusal() { return 1; }
        update_swap_precheck() { return 0; }
        backup_unit_file() { return 0; }
        update_epoch_wait() { v2_call "epoch-wait"; [[ "${V2_EPOCH:-ok}" == ok ]]; }
        wait_for_service_stopped() { v2_call "stop"; return 0; }
        update_swap_image() { return 0; }
        storage_migration_mark_started() { :; }
        start_service() { v2_call "start"; return 0; }
        verify_health_after_restart() {
            local n
            n="$(cat "$V2_LOG/vh" 2>/dev/null || echo 0)"
            printf '%s\n' "$((n + 1))" > "$V2_LOG/vh"
            if [[ "$n" == 0 ]]; then [[ "${V2_VERIFY:-ok}" == ok ]]; else [[ "${V2_RBHEALTH:-ok}" == ok ]]; fi
        }
        verify_running_image_id() { return 0; }
        verify_consensus_participation() { return 0; }
        verify_installed_binary_hash() { return 0; }
        clear_pending_state() { v2_call "clear-pending"; }
        docker_record_meta() { v2_call "record-meta $*"; }
        record_installed_ref() { v2_call "record-ref $*"; }
        restore_unit_file() { v2_call "restore"; return 0; }
        update_vote_note() { :; }
        update_vote_field() { :; }
        storage_migration_verify_failed() { v2_call "one-way-verify-failed"; }
        installed_source_ref() { echo v1; }
        backup_installed_binary() { BIN_BK_PATH="$V2_LOG/bk"; return 0; }
        tn_install_root_binary() { cp -- "$1" "$2"; }
        launch_backup_all() { return 1; }
        observer_strip_needed() { return 1; }
        update_rerender_launch() { :; }
        tn_staged_cleanup() { :; }
        restore_installed_binary() { v2_call "restore-binary"; return 0; }
        launch_restore_all() { return 0; }
        binary_restore_hint() { echo hint; }
        launch_restore_hint() { echo hint; }
        unit_restore_hint() { echo hint; }
        case "$CASE" in
            docker) apply_docker_update || rc=$? ;;
            source) apply_source_update || rc=$? ;;
            json_docker) json_apply_docker || rc=$? ;;
            json_source) json_apply_source || rc=$? ;;
        esac
        ;;
    ec:*)
        TARGET_SERVICE=telcoin
        TARGET_SERVICE_FILE="$V2_FX/etc/systemd/system/telcoin.service"
        TARGET_LAUNCH_FILE="$TARGET_SERVICE_FILE"
        resolve_target() { return 0; }
        edit_lock() { EDIT_LOCK_HELD=true; return 0; }
        menu_lock() { EDIT_LOCK_HELD=true; return 0; }
        edit_require_root() { :; }
        edit_field_known() { return 0; }
        set_field() { v2_call "set_field $*"; return 0; }
        edit_any_changed() { return 0; }
        edit_report_backups() { :; }
        edit_restore_backups() { v2_call "restore-backups"; return 0; }
        edit_epoch_wait() { v2_call "epoch-wait"; [[ "${V2_EPOCH:-ok}" == ok ]]; }
        case "$CASE" in
            set) EDIT_SET_PAIR="metrics=127.0.0.1:9101"; run_set || rc=$? ;;
            menu) EDIT_BK_FILES=(); apply_changes < /dev/null || rc=$? ;;
            menu_bk) EDIT_BK_FILES=(x); apply_changes < /dev/null || rc=$? ;;
            restart_node) restart_node < /dev/null || rc=$? ;;
            cred) edit_cred_report "$V2_CRED_RC" "moved" || rc=$? ;;
        esac
        ;;
    rm:*)
        rm_take_lock() { return 0; }
        case "$CASE" in
            stop) stop_and_disable_service telcoin || rc=$? ;;
            stop_empty) stop_and_disable_service "" || rc=$? ;;
            json_service|json_data|json_keys) json_remove observer "${CASE#json_}" || rc=$? ;;
            menu) detect_node_installs >/dev/null 2>&1; remove_all_nodes < /dev/null || rc=$? ;;
            leftovers) remove_leftovers || rc=$? ;;
        esac
        ;;
    sn:*)
        check_root() { :; }
        case "$CASE" in
            step) HOST_BASELINE="${V2_HB:-true}"; step_host_baseline || rc=$?; v2_call "STATE ${HOST_BASELINE_STATE:-} lock=${SETUP_LOCK_HELD}" ;;
            finalize)
                HOST_BASELINE="${V2_HB:-true}"
                json_refuse_installed() { :; }
                finalize_install_inputs() { :; }
                PRIMARY_LISTENER_MULTIADDR=/ip4/127.0.0.1/udp/49590/quic-v1
                WORKER_LISTENER_MULTIADDR=/ip4/127.0.0.1/udp/49595/quic-v1
                finalize_node_extra_flags() { :; }
                step_write_config() { v2_call "write-config"; }
                step_create_service() { v2_call "create-service"; }
                public_rpc_json() { printf '{"enabled":false}'; }
                PUBLIC_RPC_DOMAIN=""
                json_phase_finalize || rc=$?
                ;;
            main_only)
                step_welcome() { v2_call "FULL-SETUP step_welcome"; exit 9; }
                setup_read_passphrase() { v2_call "FULL-SETUP setup_read_passphrase"; exit 9; }
                main --host-baseline || rc=$?
                ;;
        esac
        ;;
esac
printf '%s\n' "$rc" > "$V2_LOG/rc"
exit 0
