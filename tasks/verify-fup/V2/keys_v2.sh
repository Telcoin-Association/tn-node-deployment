#!/usr/bin/env bash
# =============================================================================
# V2 independent harness, KEYS package: edit-config.sh runs keytool verify before
# every credential write (passphrase change, reseal, --migrate-credential from
# the unit, a typed value and the plaintext file; the menu; main's flags), against
# a stub node image (docker: spec) and, as root, a stub node binary (binary: spec)
# whose keytool --help lists verify / omits it / exits 4 / cannot start (125, 127).
# A refusal is proven by unchanged bytes, inode and mtime of the credential, the
# plaintext file, the unit, .node-meta and the launch file, and by no writer call.
# The passphrase is grepped for in every argv, environment and /proc capture and in
# the output. Also: the shred note of remove-node.sh, once, with the destruction
# sentence. Run by run.sh under bash 5.3, bash:3.2 and ubuntu:24.04 (root).
#   V2_REPO=<repo root> bash tasks/verify-fup/V2/keys_v2.sh
# =============================================================================
set -u
V2_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
V2_REPO="${V2_REPO:-$(cd "$V2_DIR/../../.." && pwd)}"
export V2_REPO
# shellcheck source=/dev/null
. "$V2_REPO/tools/tests/lib.sh"
T="$TN_TEST_TMP"
BASE=""
BLOG=""
IS_ROOT=0
[[ "$(id -u)" == 0 ]] && IS_ROOT=1
ORIG_PATH="$PATH"
v2_cleanup() {
    PATH="$ORIG_PATH"
    tn_test_cleanup
    if [[ -n "$BASE" && "$BASE" != "$T"* && -d "$BASE" ]]; then rm -rf "${BASE:?}"; fi
    if [[ -n "$BLOG" && -d "$BLOG" ]]; then rm -rf "${BLOG:?}"; fi
    if [[ $IS_ROOT == 1 && -d /opt/v2bin ]]; then rm -rf /opt/v2bin; fi
}
trap v2_cleanup EXIT

REAL_ENV="$(command -v env)"
REAL_SHA="$(command -v sha256sum)"
REAL_STAT="$(command -v stat)"
REAL_CAT="$(command -v cat)"
REAL_TR="$(command -v tr)"

if [[ $IS_ROOT == 1 ]]; then
    BASE="$(mktemp -d /root/.v2k.XXXXXX)"
    chmod 0700 "$BASE"
    V2_SU=nobody
    V2_SG="$(id -gn nobody 2>/dev/null || echo nogroup)"
else
    BASE="$T/base"
    mkdir -p "$BASE"
    V2_SU="$(id -un)"
    V2_SG="$(id -gn)"
fi
export V2_SU V2_SG
FX="$BASE/fx"
CTL="$BASE/ctl"
LOG="$BASE/log"
BIN="$BASE/bin"
mkdir -p "$CTL" "$LOG" "$BIN"
export V2_FX="$FX" V2_CTL="$CTL" V2_LOG="$LOG"
export V2_EDIT="${V2_EDIT:-$V2_REPO/edit-config.sh}" V2_LIBDIR="${V2_LIBDIR:-$V2_REPO/lib}"
IMG="ghcr.io/telcoin/telcoin-network:v9.9.9"
DD="$FX/var/lib/telcoin"

# ---- stubs and recording wrappers --------------------------------------------
for c in cat chmod chown cp grep mktemp mv rm sed sha256sum stat awk head tail tr wc env id \
         getent flock setpriv runuser cmp date install shred ln dirname basename sort cut sleep; do
    real="$(command -v "$c" 2>/dev/null)" || real=""
    [[ -n "$real" && "$real" == /* ]] || continue
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s/argv.log"\n"%s" >> "%s/env.log"\nexec "%s" "$@"\n' \
        "$c" "$LOG" "$REAL_ENV" "$LOG" "$real" > "$BIN/$c"
    chmod 0755 "$BIN/$c"
done
# The process-group capture: cmdline and environ of every process in this run's
# process group while a stub runs (what `ps` and /proc would show then).
cat > "$BIN/v2-pscap" <<STUB
#!/bin/sh
pg="\$(sed -n 's/^[0-9]* ([^)]*) . [0-9]* \([0-9]*\).*/\1/p' /proc/\$\$/stat 2>/dev/null)"
for p in /proc/[0-9]*; do
    g="\$(sed -n 's/^[0-9]* ([^)]*) . [0-9]* \([0-9]*\).*/\1/p' "\$p/stat" 2>/dev/null)"
    [ -n "\$g" ] && [ "\$g" = "\$pg" ] || continue
    "$REAL_TR" '\0' ' ' < "\$p/cmdline" 2>/dev/null >> "$LOG/ps.log"; echo >> "$LOG/ps.log"
    "$REAL_TR" '\0' '\n' < "\$p/environ" 2>/dev/null >> "$LOG/psenv.log"
done
exit 0
STUB
chmod 0755 "$BIN/v2-pscap"
# docker: the node image. keytool --help per CTL/help; keytool verify reads the
# passphrase from stdin and compares it with CTL/expected (CTL/verify: ok|runfail).
# A wrong passphrase gets an error line that holds it, as a careless CLI might.
cat > "$BIN/docker" <<STUB
#!/bin/sh
printf '%s\n' "docker \$*" >> "$LOG/argv.log"
"$REAL_ENV" >> "$LOG/env.log"
"$BIN/v2-pscap"
help="\$("$REAL_CAT" "$CTL/help" 2>/dev/null)"
case "\$*" in
    *" keytool --help"*)
        case "\$help" in
            verify) printf 'Key management\n\nUsage: telcoin keytool <COMMAND>\n\nCommands:\n  generate  Generate keys\n  verify    Check that the passphrase opens the BLS key\n  help      Print this message\n\nOptions:\n  -h, --help  Print help\n'; exit 0 ;;
            noverify) printf 'Key management\n\nUsage: telcoin keytool <COMMAND>\n\nCommands:\n  generate  Generate keys (verify with export-staking-args)\n  help      Print this message\n\nOptions:\n  -h, --help  Print help\n'; exit 0 ;;
            exit4) exit 4 ;;
            nostart) echo "docker: Error response from daemon: no such image" >&2; exit 125 ;;
            notfound) exit 127 ;;
        esac
        exit 0 ;;
    *" keytool verify"*)
        v="\$("$REAL_CAT" "$CTL/verify" 2>/dev/null)"
        IFS= read -r got || got=""
        [ "\$v" = runfail ] && { echo "docker: Error response from daemon: OCI runtime create failed" >&2; exit 125; }
        [ "\$v" = runecho ] && { echo "docker: invalid reference format: \$got"; exit 125; }
        exp="\$("$REAL_CAT" "$CTL/expected" 2>/dev/null)"
        if [ "\$got" = "\$exp" ]; then echo "BLS key opens"; exit 0; fi
        echo "Error: the passphrase \$got does not decrypt node-keys/bls.key"
        exit 1 ;;
esac
exit 0
STUB
chmod 0755 "$BIN/docker"
cat > "$BIN/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "systemctl \$*" >> "$LOG/argv.log"
case "\$1" in is-active) exit "\$("$REAL_CAT" "$CTL/active" 2>/dev/null || echo 3)" ;; esac
exit 0
STUB
chmod 0755 "$BIN/systemctl"
# systemd-creds: decrypt prints CTL/credval (or fails when absent); encrypt is a write.
cat > "$BIN/systemd-creds" <<STUB
#!/bin/sh
printf '%s\n' "systemd-creds \$*" >> "$LOG/argv.log"
"$REAL_ENV" >> "$LOG/env.log"
case "\$1" in
    decrypt) [ -f "$CTL/credval" ] || exit 1; "$REAL_CAT" "$CTL/credval"; exit 0 ;;
    encrypt) echo "WRITE systemd-creds encrypt" >> "$LOG/argv.log"; "$REAL_CAT" > /dev/null; exit 0 ;;
    has-tpm2) exit 1 ;;
esac
exit 0
STUB
chmod 0755 "$BIN/systemd-creds"
mkdir -p "$LOG/h"
grep -v '^main "\$@"$' "$V2_EDIT" > "$LOG/h/edit-config.sh"
ln -s "$V2_LIBDIR" "$LOG/h/lib"
export PATH="$BIN:$PATH"

# ---- passphrases (unique strings, grepped for everywhere) ----------------------
P_NEW="V2-new-Passphrase-77x"
P_OTHER="V2-key-OtherPass-55x"
P_CRED="V2-cred-Passphrase-31x"
P_TYPED="V2-typed-Passphrase-42x"
P_UNIT="V2-unit-Passphrase-19x"
P_FILE="V2-file-Passphrase-63x"
ALLP="$P_NEW $P_OTHER $P_CRED $P_TYPED $P_UNIT $P_FILE"

# fx KIND -- the node tree: cred (credential, no plaintext), plain (root-only file),
# typed (stdin method, no file), unit (a docker unit that holds the passphrase).
fx() {
    if [[ -d "$FX" ]]; then rm -rf "${FX:?}"; fi
    mkdir -p "$FX/etc/telcoin" "$FX/etc/systemd/system" "$FX/usr/local/libexec/telcoin" "$DD/node-keys" "$FX/backups"
    chmod 0755 "$FX" "$FX/etc" "$FX/etc/telcoin" "$FX/etc/systemd" "$FX/etc/systemd/system" "$FX/usr" \
        "$FX/usr/local" "$FX/usr/local/libexec" "$FX/usr/local/libexec/telcoin" "$FX/var" "$FX/var/lib"
    chmod 0700 "$DD" "$FX/backups"
    [[ $IS_ROOT == 0 ]] || chown -R "$V2_SU:$V2_SG" "$DD"
    local method=stdin
    [[ "$1" != cred ]] || method=credential
    printf 'NETWORK=testnet\nOWNERSHIP_LAYOUT=2\nINSTALL_METHOD=docker\nDATA_DIR=%s\nPASSPHRASE_METHOD=%s\nCREDENTIAL_KEY=host\n' \
        "$DD" "$method" > "$FX/etc/telcoin/.node-meta"
    chmod 0600 "$FX/etc/telcoin/.node-meta"
    rm -f "${CTL:?}/credval"
    case "$1" in
        cred)
            printf 'V2-ENCRYPTED-BLOB\n' > "$FX/etc/telcoin/bls-passphrase.cred"
            chmod 0600 "$FX/etc/telcoin/bls-passphrase.cred"
            printf '%s\n' "$P_CRED" > "$CTL/credval"
            ;;
        plain)
            printf '%s\n' "$P_FILE" > "$FX/etc/telcoin/bls-passphrase"
            chmod 0600 "$FX/etc/telcoin/bls-passphrase"
            ;;
    esac
    if [[ "$1" == unit ]]; then
        printf '[Service]\nEnvironment="TN_BLS_PASSPHRASE=%s"\nExecStart=/usr/bin/docker run --rm --name telcoin -e TN_BLS_PASSPHRASE %s telcoin node --http --datadir /home/nonroot\n' \
            "$P_UNIT" "$IMG" > "$FX/etc/systemd/system/telcoin.service"
        V2_LAUNCH="$FX/etc/systemd/system/telcoin.service"
    else
        printf '[Service]\nLoadCredentialEncrypted=bls-passphrase:/etc/telcoin/bls-passphrase.cred\nExecStart=/usr/local/libexec/telcoin/tn-start-docker\n' \
            > "$FX/etc/systemd/system/telcoin.service"
        printf '#!/bin/bash\nexec docker run --rm --name telcoin --network host %s telcoin node --http --datadir /home/nonroot\n' "$IMG" \
            > "$FX/usr/local/libexec/telcoin/tn-start-docker"
        chmod 0755 "$FX/usr/local/libexec/telcoin/tn-start-docker"
        V2_LAUNCH="$FX/usr/local/libexec/telcoin/tn-start-docker"
    fi
    chmod 0644 "$FX/etc/systemd/system/telcoin.service"
    export V2_LAUNCH
}
# fp -- fingerprint of every file a refused action must leave alone.
fp() {
    local f
    for f in "$FX/etc/telcoin/bls-passphrase.cred" "$FX/etc/telcoin/bls-passphrase" "$FX/etc/telcoin/.node-meta" \
             "$FX/etc/systemd/system/telcoin.service" "$FX/usr/local/libexec/telcoin/tn-start-docker"; do
        if [[ -e "$f" ]]; then
            printf '%s %s %s\n' "${f#"$FX"}" "$("$REAL_SHA" < "$f" | cut -c1-16)" "$("$REAL_STAT" -c '%i %s %Y %a %u' "$f")"
        else
            printf '%s absent\n' "${f#"$FX"}"
        fi
    done
    ls -A "$FX/etc/telcoin" "$FX/backups" 2>/dev/null | tr '\n' ' '
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
# leaks TEXT -- the passphrases TEXT contains (none: empty).
leaks() {
    local p hit=""
    for p in $ALLP; do
        case "$1" in *"$p"*) hit="${hit} ${p}" ;; esac
    done
    printf '%s' "$hit"
}

# run_case NAME CASE HELP VERIFY EXPECTED KEEP STDIN [ACTIVE] -- one action in the driver.
run_case() {
    local name="$1" case="$2" help="$3" verify="$4" exp="$5" keep="$6" input="$7"
    rm -f "${LOG:?}"/*.log "${LOG:?}/calls" "${LOG:?}/rc" "${LOG:?}/out"
    printf '%s\n' "$help" > "$CTL/help"
    printf '%s\n' "$verify" > "$CTL/verify"
    printf '%s\n' "$exp" > "$CTL/expected"
    printf '%s\n' "$keep" > "$CTL/keep"
    printf '%s\n' "${8:-3}" > "$CTL/active"
    printf '%s\n' "${V2_DOWN_RC:-0}" > "$CTL/down_rc"
    FP_BEFORE="$(fp)"
    printf '%b' "$input" | bash "$V2_DIR/keys_drv.sh" "$case" > "$LOG/out" 2>&1
    DRV_RC=$?
    FP_AFTER="$(fp)"
    RC="$("$REAL_CAT" "$LOG/rc" 2>/dev/null || echo none)"
    OUT="$("$REAL_CAT" "$LOG/out" 2>/dev/null)"
    CALLS="$("$REAL_CAT" "$LOG/calls" 2>/dev/null)"
    ARGV="$("$REAL_CAT" "$LOG/argv.log" 2>/dev/null)"
    ALLCAP="$("$REAL_CAT" "$LOG/argv.log" "$LOG/env.log" "$LOG/ps.log" "$LOG/psenv.log" 2>/dev/null)"
    NAME="$name"
}
# expect_common HELP VERIFY -- the checks every case gets.
expect_common() {
    local help="$1" verify="$2"
    check "$NAME: no passphrase in any argv, environment or /proc capture" "" "$(leaks "$ALLCAP")"
    check "$NAME: no passphrase in the output" "" "$(leaks "$OUT")"
    check_has "$NAME: TN_KEYTOOL_PASS unset and TN_CRED_PASS empty afterwards" "POST pass=empty keytoolpass=unset exported=no" "$CALLS"
    if [[ "$help" == verify ]]; then
        check "$NAME: keytool verify ran with the passphrase on stdin" yes \
            "$(has "$ARGV" "-i --user ${UIDGID} -e HOME=/home/nonroot -v ${DD}:/home/nonroot ${IMG} telcoin -q --datadir /home/nonroot --bls-passphrase-source stdin keytool verify")"
    else
        check "$NAME: keytool verify not run" no "$(has "$ARGV" "keytool verify")"
    fi
}
# expect_refused -- nothing written, nothing downstream.
expect_refused() {
    check "$NAME: credential, plaintext, unit, .node-meta, launch file unchanged (bytes, inode, mtime)" "$FP_BEFORE" "$FP_AFTER"
    check "$NAME: no writer and no downstream call" "" "$(printf '%s\n' "$CALLS" | grep -E '^(W|D) ' || true)"
    check "$NAME: no write tool ran" "" "$(printf '%s\n' "$ARGV" | grep -E '^(WRITE|shred|mv|cp|install|chmod|chown|ln) ' || true)"
    check "$NAME: no restart or stop" "" "$(printf '%s\n' "$ARGV" | grep -E '^systemctl (restart|stop|start)' || true)"
}
# expect_proceeds DOWN[:empty] -- the downstream writer DOWN ran once with the kept
# passphrase in TN_CRED_PASS (":empty": DOWN reads the plaintext file itself, so
# TN_CRED_PASS must be empty), TN_KEYTOOL_PASS unset.
expect_proceeds() {
    local d="${1%%:*}" st=match
    [[ "$1" != *:empty ]] || st=empty
    check "$NAME: $d called once" 1 "$(printf '%s\n' "$CALLS" | grep -c "^D $d " || true)"
    check_has "$NAME: $d got TN_CRED_PASS=${st}, TN_KEYTOOL_PASS unset" "D-pass $d pass=${st} keytoolpass=unset exported=no" "$CALLS"
}
expect_msg() {
    local help="$1" verify="$2"
    case "$help:$verify" in
        verify:ok) check "$NAME: verify success logged" yes "$(has "$OUT" "keytool verify: the passphrase opens the BLS key in ${DD}")" ;;
        verify:wrong) check "$NAME: refusal names the mismatch" yes "$(has "$OUT" "does not open the BLS key in ${DD} (keytool verify, exit 1); nothing was changed")" ;;
        verify:runfail|verify:runecho) check "$NAME: refusal says verify could not run" yes "$(has "$OUT" "keytool verify could not run (exit 125")" ;;
        noverify:*) check "$NAME: skip log line" yes "$(has "$OUT" "keytool verify is not in this release; skipped")" ;;
        *) check "$NAME: probe failure warned" yes "$(has "$OUT" "Could not run the node binary of docker:${IMG} to see whether it has keytool verify; skipped")" ;;
    esac
}

if [[ $IS_ROOT == 1 ]]; then
    UIDGID="$(id -u nobody):$(getent group "$V2_SG" 2>/dev/null | cut -d: -f3)"
    [[ "$UIDGID" != *: ]] || UIDGID="$(id -u nobody):$(id -g nobody)"
else
    UIDGID="$(id -u):$(getent group "$V2_SG" 2>/dev/null | cut -d: -f3)"
    [[ "$UIDGID" != *: ]] || UIDGID="$(id -u):$(id -g)"
fi

MODES="verify:ok verify:wrong verify:runfail verify:runecho noverify:- exit4:- nostart:- notfound:-"
[[ "${V2_QUICK:-0}" != 1 ]] || MODES="verify:ok verify:wrong verify:runecho noverify:- exit4:-"
# matrix LABEL CASE FXKIND KEEP STDIN DOWN -- every probe/verify mode for one action.
matrix() {
    local label="$1" case="$2" kind="$3" keep="$4" input="$5" down="$6" m help verify exp
    for m in $MODES; do
        help="${m%%:*}"
        verify="${m#*:}"
        exp="$keep"
        [[ "$verify" != wrong ]] || exp="$P_OTHER"
        fx "$kind"
        run_case "$label [$m]" "$case" "$help" "$verify" "$exp" "$keep" "$input"
        expect_common "$help" "$verify"
        expect_msg "$help" "$verify"
        if [[ "$help" == verify && "$verify" != ok ]]; then
            expect_refused
            if [[ "$case" == change || "$case" == menu ]]; then
                if [[ "$kind" == cred && "$keep" == "$P_NEW" ]]; then
                    check "$NAME: says the passphrase is unchanged" yes "$(has "$OUT" "Passphrase unchanged.")"
                fi
            elif [[ "$case" != main_* ]]; then
                check_rc "$NAME: rc 1" 1 "$RC"
            fi
        else
            expect_proceeds "$down"
        fi
    done
}

echo "== KEYS: docker: spec, every action x every probe/verify mode (user $(id -un))"
matrix "change" change cred "$P_NEW" "${P_NEW}\n${P_NEW}\n" _tn_cred_switch
matrix "reseal (decrypted value)" reseal cred "$P_CRED" "" _tn_cred_switch
# reseal when the credential no longer decrypts: the typed value is checked.
for m in verify:ok verify:wrong noverify:-; do
    help="${m%%:*}"; verify="${m#*:}"; exp="$P_TYPED"; [[ "$verify" != wrong ]] || exp="$P_OTHER"
    fx cred; rm -f "${CTL:?}/credval"
    run_case "reseal (typed, cred does not decrypt) [$m]" reseal_typed "$help" "$verify" "$exp" "$P_TYPED" "${P_TYPED}\n"
    expect_common "$help" "$verify"; expect_msg "$help" "$verify"
    if [[ "$verify" == wrong ]]; then expect_refused; else expect_proceeds _tn_cred_switch; fi
done
matrix "migrate (unit holds it)" mig_unit unit "$P_UNIT" "" tn_migrate_embedded_passphrase
matrix "migrate (typed)" mig_typed typed "$P_TYPED" "${P_TYPED}\n" tn_migrate_credential
if [[ $IS_ROOT == 1 ]]; then
    matrix "migrate (plaintext file)" mig_file plain "$P_FILE" "" tn_migrate_credential:empty
    matrix "menu: change" menu cred "$P_NEW" "1\n${P_NEW}\n${P_NEW}\n" _tn_cred_switch
    matrix "menu: reseal" menu cred "$P_CRED" "2\n" _tn_cred_switch
    matrix "menu: move the plaintext file" menu plain "$P_FILE" "2\n" tn_migrate_credential:empty
    matrix "menu: legacy unit move" menu unit "$P_UNIT" "" tn_migrate_embedded_passphrase
    matrix "main --json --migrate-credential (plaintext)" main_mig_json plain "$P_FILE" "" tn_migrate_credential:empty
    matrix "main --reseal" main_reseal cred "$P_CRED" "" _tn_cred_switch
    # --json: stdout is JSON events only and ends with done.
    fx plain
    run_case "main --json refused" main_mig_json verify wrong "$P_OTHER" "$P_FILE" ""
    check "main --json refused: done ok false" yes "$(has "$OUT" '{"event":"done","ok":false')"
    check_rc "main --json refused: exit 1" 1 "$RC"
else
    skip "migrate (plaintext file) matrix" "_tn_cred_plain_ok needs a root-owned file"
    skip "menu matrices" "the menu cases need root-owned fixture files"
    skip "main --migrate-credential / --reseal" "resolve_target needs a root-owned launch chain"
    # As a user the plaintext file is not root-owned: the check is skipped and the
    # real migration refuses it (nothing written).
    fx plain
    V2_DOWN=real; export V2_DOWN
    run_case "migrate (plaintext not root-owned, real migration)" mig_file verify ok "$P_FILE" "$P_FILE" ""
    unset V2_DOWN
    check "$NAME: verify skipped (file not root-owned)" no "$(has "$ARGV" "keytool verify")"
    check "$NAME: the real migration refused it" yes "$(has "$OUT" "is missing or not a root-owned file")"
    check "$NAME: the real migration was reached" yes "$(has "$CALLS" "REAL tn_migrate_credential edit_wait_say")"
    check "$NAME: files unchanged" "$FP_BEFORE" "$FP_AFTER"
    check "$NAME: no writer call" "" "$(printf '%s\n' "$CALLS" | grep -E '^W ' || true)"
fi

# The rollback reports after a verified action are those of the release before.
for drc in 2 3; do
    V2_DOWN_RC=$drc
    fx cred
    run_case "reseal verified, downstream rc ${drc}" reseal verify ok "$P_CRED" "$P_CRED" ""
    if [[ $drc == 2 ]]; then
        check "$NAME: rollback report" yes "$(has "$OUT" "telcoin did not come back with the new passphrase delivery; its previous files are back and it runs on them")"
    else
        check "$NAME: failed rollback report" yes "$(has "$OUT" "telcoin did not come back on its previous files either")"
    fi
    check_rc "$NAME: rc ${drc}" "$drc" "$RC"
    check "$NAME: no baseline refresh after a rollback" no "$(has "$CALLS" "R tn_host_baseline_refresh")"
done
unset V2_DOWN_RC
fx cred
run_case "reseal verified, downstream rc 0" reseal verify ok "$P_CRED" "$P_CRED" ""
check "$NAME: baseline refresh after the move (c4322d4)" yes "$(has "$CALLS" "R tn_host_baseline_refresh edit_wait_say")"
fx cred
run_case "reseal refused by verify" reseal verify wrong "$P_OTHER" "$P_CRED" ""
check "$NAME: no baseline refresh after a refused verify" no "$(has "$CALLS" "R tn_host_baseline_refresh")"

# ---- binary: spec (root, real setpriv) ----------------------------------------
if [[ $IS_ROOT == 1 ]] && command -v setpriv >/dev/null 2>&1; then
    if ! setpriv --reuid "$(id -u nobody)" --regid "$(id -g nobody)" --clear-groups --no-new-privs -- true 2>/dev/null; then
        V2_SETPRIV_BROKEN=1
        echo "NOTE: this setpriv cannot drop to the service user (busybox); the binary: spec cases show what edit-config does then"
    fi
    # The service user runs the stub binary through env and the recording
    # wrappers in BIN: it needs search access to them and write access to LOG
    # (a disposable container; the fixture prefix stays root-owned).
    chmod 0711 /root "$BASE"; chmod 0755 "$BIN"; chmod 0777 "$LOG"; umask 0000
    BLOG="$(mktemp -d /tmp/v2b.XXXXXX)"; chmod 0777 "$BLOG"
    mkdir -p /opt/v2bin; chmod 0755 /opt/v2bin
    cat > /opt/v2bin/telcoin-network <<STUB
#!/bin/sh
printf '%s\n' "node-binary \$*" >> "$BLOG/argv.log"
"$REAL_ENV" >> "$BLOG/env.log"
help="\$(cat "$BLOG/help" 2>/dev/null)"
case "\$*" in
    *"keytool --help"*)
        [ "\$help" = verify ] && { printf 'Commands:\n  generate  Generate keys\n  verify    Check the passphrase\n'; exit 0; }
        printf 'Commands:\n  generate  Generate keys\n'; exit 0 ;;
    *"keytool verify"*)
        IFS= read -r got || got=""
        [ "\$got" = "\$(cat "$BLOG/expected")" ] && exit 0
        echo "Error: wrong passphrase"; exit 1 ;;
esac
exit 0
STUB
    chmod 0755 /opt/v2bin/telcoin-network
    for m in verify:ok verify:wrong noverify:-; do
        help="${m%%:*}"; verify="${m#*:}"; exp="$P_NEW"; [[ "$verify" != wrong ]] || exp="$P_OTHER"
        fx cred
        printf '#!/bin/bash\nexec /opt/v2bin/telcoin-network node --http --datadir %s\n' "$DD" > "$FX/usr/local/libexec/telcoin/tn-start-docker"
        printf '%s\n' "$help" > "$BLOG/help"; printf '%s\n' "$exp" > "$BLOG/expected"; chmod 0644 "$BLOG/help" "$BLOG/expected"
        : > "$BLOG/argv.log"; : > "$BLOG/env.log"; chmod 0666 "$BLOG/argv.log" "$BLOG/env.log"
        run_case "binary spec: change [$m]" change "$help" "$verify" "$exp" "$P_NEW" "${P_NEW}\n${P_NEW}\n"
        BARGV="$(cat "$BLOG/argv.log")"
        if [[ "${V2_DEBUG:-0}" == 1 ]]; then printf '%s\n' "$OUT" | sed 's/^/    | /'; printf 'BARGV: %s\n' "$BARGV"; fi
        check "$NAME: no passphrase in the binary's argv or environment" "" "$(leaks "$BARGV $(cat "$BLOG/env.log") $ALLCAP")"
        check "$NAME: no passphrase in the output" "" "$(leaks "$OUT")"
        check_has "$NAME: TN_KEYTOOL_PASS unset afterwards" "POST pass=empty keytoolpass=unset exported=no" "$CALLS"
        if [[ "$help" == verify ]]; then
            check "$NAME: binary ran keytool verify" yes "$(has "$BARGV" "node-binary -q --datadir ${DD} --bls-passphrase-source stdin keytool verify")"
            check "$NAME: setpriv dropped to the service user" yes "$(has "$ARGV" "setpriv --reuid $(id -u nobody)")"
        else
            check "$NAME: verify not run" no "$(has "$BARGV" "keytool verify")"
        fi
        if [[ "$verify" == wrong ]]; then
            expect_refused
            check "$NAME: refusal" yes "$(has "$OUT" "The new passphrase does not open the BLS key in ${DD}")"
        else
            expect_proceeds _tn_cred_switch
        fi
    done
    umask 0022
else
    skip "binary: spec matrix" "needs root and setpriv (ubuntu:24.04)"
fi

# ---- differential: after the verify, the same downstream calls and reports as
# 0a9db45 (the release before this round: no verify at all) --------------------
OLDEDIT="${V2_OLDLIB:+${V2_OLDLIB%/lib}/edit-config.sh}"
if [[ -n "$OLDEDIT" && -f "$OLDEDIT" ]]; then
    mkdir -p "$LOG/h-old"
    "$REAL_CAT" "$OLDEDIT" | sed '/^main "\$@"$/d' > "$LOG/h-old/edit-config.sh"
    ln -s "$V2_OLDLIB" "$LOG/h-old/lib"
    # diffcase LABEL CASE KIND KEEP STDIN HELP DOWN_RC
    diffcase() {
        local a b ra rb
        V2_DOWN_RC="$7"
        fx "$3"; run_case "$1 (tip, $6)" "$2" "$6" ok "$4" "$4" "$5"
        a="$(printf '%s\n' "$CALLS" | grep -E '^D(-pass)? ')"; ra="$RC"
        A_OUT="$(printf '%s\n' "$OUT" | grep -E 'did not come back|now runs from|is sealed again|new passphrase is stored|nothing was changed' | grep -v 'keytool verify')"
        fx "$3"; V2_HDIR="$LOG/h-old" run_case "$1 (0a9db45)" "$2" "$6" ok "$4" "$4" "$5"
        b="$(printf '%s\n' "$CALLS" | grep -E '^D(-pass)? ')"; rb="$RC"
        B_OUT="$(printf '%s\n' "$OUT" | grep -E 'did not come back|now runs from|is sealed again|new passphrase is stored|nothing was changed')"
        check "differential $1, downstream rc $7, keytool $6: same downstream calls as 0a9db45" "$b" "$a"
        check "differential $1, downstream rc $7, keytool $6: same rc as 0a9db45" "$rb" "$ra"
        check "differential $1, downstream rc $7, keytool $6: same report as 0a9db45" "$B_OUT" "$A_OUT"
        unset V2_DOWN_RC
    }
    export V2_HDIR
    for h in verify noverify; do
        for drc in 0 2 3; do
            diffcase "change" change cred "$P_NEW" "${P_NEW}\n${P_NEW}\n" "$h" "$drc"
            diffcase "reseal" reseal cred "$P_CRED" "" "$h" "$drc"
            diffcase "migrate (unit)" mig_unit unit "$P_UNIT" "" "$h" "$drc"
            diffcase "migrate (typed)" mig_typed typed "$P_TYPED" "${P_TYPED}\n" "$h" "$drc"
        done
    done
    unset V2_HDIR
else
    skip "differential against 0a9db45" "V2_OLDLIB not given"
fi

# ---- remove-node.sh: the shred note -------------------------------------------
echo "== KEYS: remove-node shred note"
mkdir -p "$T/rm/h" "$T/rm/d"
grep -v '^main "\$@"$' "$V2_REPO/remove-node.sh" > "$T/rm/h/remove-node.sh"
ln -s "$V2_LIBDIR" "$T/rm/h/lib"
cat > "$T/rm/drv.sh" <<'DRV'
set -u
TN_ROOT_PREFIX="$1/fx"
source "$1/h/remove-node.sh"
set +e
printf 'a\n' > "$1/d/f1"; printf 'b\n' > "$1/d/f2"; mkdir -p "$1/d/t"; printf 'c\n' > "$1/d/t/f3"
_rm_shred "$1/d/f1"
_rm_shred "$1/d/f2"
_rm_shred_tree "$1/d/t"
DRV
chmod 0700 "$T/rm/d"
out="$(bash "$T/rm/drv.sh" "$T/rm" 2>&1)"
if command -v shred >/dev/null 2>&1; then
    check "shred note: printed once in a run of three shreds" 1 "$(printf '%s\n' "$out" | grep -c 'best effort on SSDs' || true)"
    check "shred note: destruction sentence printed once" 1 "$(printf '%s\n' "$out" | grep -c 'Decommissioning a host that held a validator key means destroying or crypto-erasing its disk and deleting every snapshot and image taken from it; shred alone does not do that.' || true)"
    check "shred note: files gone" "" "$(ls -A "$T/rm/d" | grep -v '^t$' || true)"
else
    skip "shred note" "no shred here"
fi
finish
