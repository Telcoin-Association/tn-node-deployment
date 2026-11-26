#!/usr/bin/env bash
# =============================================================================
# tools/tests/first_boot_test.sh -- terraform/first-boot/, the scripts cloud-init
# runs on the first boot of a validator host and a worker-gateway host:
#
#   validator  a blank disk is formatted once, an ext4 disk is not, a foreign
#              filesystem stops the boot, a device that never appears times
#              out; swap that stays on stops it; the installer failing three
#              times stops it; a run after a fix formats nothing again and adds
#              no second fstab line; a missing trusted nodes file stops it;
#              setup-node.sh, firewall-setup.sh and the gateway scripts never run
#   gateway    every step in order with its exact arguments; setup-gateway.sh
#              exit 1 is tried again (and three of them stop the boot), exit 3
#              stops before the firewall, exit 0 without "ok":true stops; a
#              name that never resolves does not stop the boot; a Docker
#              signing key with another fingerprint writes no apt source; an
#              older node scripts release stops the boot before Docker
#   both       a release older than TN_FB_MIN_RELEASE, or none, stops the boot
#              at scripts-release; a bad env value or test hook is refused
#              before anything changes; a run stopped by a signal still leaves
#              the failed marker
#
#   bash tools/tests/run.sh tools/tests/first_boot_test.sh
#   docker run --rm --network none -v "$PWD:/w:ro" -w /w bash:3.2 bash tools/tests/run.sh tools/tests/first_boot_test.sh
#
# Every host command the scripts run (blkid, mkfs.ext4, mount, mountpoint,
# udevadm, swapoff, swapon, modprobe, systemctl, curl, sudo, apt-get, gpg,
# gpgconf, dpkg, docker, logger, id) is a PATH stub; all but id and logger log
# their arguments to $T/calls.log, one line per call, in order. A regular file
# under TN_FB_ROOT stands in for the data device and holds "<type> <uuid>", or
# nothing for a blank disk. The installer is a script the curl stub prints: it
# copies stand-ins of setup-node.sh, setup-gateway.sh, install-caddy.sh,
# firewall-setup.sh and check-node.sh, which log their arguments too, and a
# MANIFEST record into the login user's telcoin-node-scripts. TN_FB_WAIT_STEP=0 removes every sleep.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# =============================================================================
set -u
umask 022
# shellcheck source=tools/tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T="$TN_TEST_TMP"
FB="${TN_TEST_REPO}/terraform/first-boot"
export FBT_DIR="$T"
mkdir -p "$T/bin" "$T/scripts"

GOOD_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DEV=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol0123456789abcdef0
NEW_UUID=0f3c2a4e-1111-4222-8333-444455556666
OLD_UUID=7d1e2c3b-aaaa-4bbb-8ccc-ddddeeeeffff
HUBS=/etc/telcoin-first-boot/trusted-nodes.yaml
MIN_RELEASE=scripts-v2.3.0
# shellcheck disable=SC2016  # the installer command line as the sudo stub logs it, $1 included
INSTALL_LINE='sudo -u ubuntu -H bash -c set -o pipefail; curl --proto "=https" --tlsv1.2 -fsSL --url "$1" | bash -s -- --yes first-boot-installer https://install.telcoin.network'
INSTALL_CURL='curl --proto =https --tlsv1.2 -fsSL --url https://install.telcoin.network'

# --- stubs ----------------------------------------------------------------------
# stub NAME BODY -- a PATH stub that logs "NAME ARGS" to calls.log, then runs BODY.
stub() {
    # shellcheck disable=SC2016  # the stub's own logging line, expanded when it runs
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf '"'"'%%s\\n'"'"' "%s${*:+ $*}" >> "$FBT_DIR/calls.log"\n' "$1"
        printf '%s\n' "$2"
    } > "$T/bin/$1"
    chmod 0755 "$T/bin/$1"
}
# shellcheck disable=SC2016  # the bodies are code for the stubs, expanded when they run
{
stub blkid '
dev=""
for a in "$@"; do dev="$a"; done
c="$(cat "$dev" 2>/dev/null)" || exit 4
[ -n "$c" ] || exit 2
case " $* " in
    *" -s TYPE "*) printf "%s\n" "${c%% *}" ;;
    *" -s UUID "*) printf "%s\n" "${c#* }" ;;
esac
exit 0'
stub mkfs.ext4 '
dev=""
for a in "$@"; do dev="$a"; done
printf "ext4 0f3c2a4e-1111-4222-8333-444455556666\n" > "$dev"'
stub mount '
[ -f "$FBT_DIR/mount-fails" ] && exit 32
printf "%s\n" "$1" >> "$FBT_DIR/mounts"'
stub mountpoint '
[ "$1" = -q ] && shift
grep -qxF -- "$1" "$FBT_DIR/mounts" 2>/dev/null'
stub udevadm 'exit 0'
stub swapoff '[ -f "$FBT_DIR/swap-stuck" ] || rm -f "$FBT_DIR/swap-on"'
stub swapon '[ -f "$FBT_DIR/swap-on" ] && printf "/swap.img file 2G 0B -2\n"; exit 0'
stub modprobe 'exit 0'
stub systemctl '[ -f "$FBT_DIR/selfkill" ] && kill -TERM "$PPID"; exit 0'
stub dpkg '[ "$1" = --print-architecture ] && echo amd64; exit 0'
stub apt-get '[ -f "$FBT_DIR/apt-fails" ] && exit 100; exit 0'
stub docker '[ "$1" = info ] && [ -f "$FBT_DIR/docker-down" ] && exit 1; exit 0'
stub gpgconf 'exit 0'
# gpg: the key file holds "KEY <fingerprint>"; show-only prints that key's
# colon listing, --dearmor copies the file through.
stub gpg '
case " $* " in
    *" --dearmor "*) cat; exit 0 ;;
    *" --import "*)
        read -r _ f
        printf "pub:-:4096:1:8D81803C0EBFCD88:1487788800:::-:::scESA::::::23::0:\n"
        printf "fpr:::::::::%s:\n" "$f"
        exit 0 ;;
esac
exit 2'
# curl: Docker's key, or the installer: a script that copies the stand-ins into
# the login user's home with a MANIFEST whose release= is the file release (none
# when it is empty). installer-fails holds how many installer downloads fail.
stub curl '
u=""; o=""; prev=""
for a in "$@"; do
    case "$prev" in --url) u="$a" ;; -o) o="$a" ;; esac
    prev="$a"
done
case "$u" in
    https://download.docker.com/*/gpg)
        [ -f "$FBT_DIR/docker-key-fails" ] && exit 22
        printf "KEY %s\n" "$(cat "$FBT_DIR/docker-key-fpr")" > "$o"
        exit 0 ;;
esac
n="$(cat "$FBT_DIR/installer-fails" 2>/dev/null || echo 0)"
if [ "$n" -gt 0 ]; then
    echo $((n - 1)) > "$FBT_DIR/installer-fails"
    exit 22
fi
cat <<"EOF"
printf "installer %s\n" "$*" >> "$FBT_DIR/calls.log"
d="${TN_FB_ROOT}/home/${FBT_SUDO_USER}/telcoin-node-scripts"
mkdir -p "$d"
cp "$FBT_DIR"/scripts/*.sh "$d"/
rm -f "$d/MANIFEST"
[ -s "$FBT_DIR/release" ] && printf "format=1\nrelease=%s\nserial=3\n" "$(cat "$FBT_DIR/release")" > "$d/MANIFEST"
exit 0
EOF'
# sudo: drops -u USER -H (FBT_SUDO_USER keeps the user) and runs the rest.
stub sudo '
while [ $# -gt 0 ]; do
    case "$1" in
        -u) FBT_SUDO_USER="$2"; shift 2 ;;
        -H) shift ;;
        *) break ;;
    esac
done
export FBT_SUDO_USER
exec "$@"'
}
# shellcheck disable=SC2016  # code for the stubs, expanded when they run
{
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FBT_DIR/logger.log"\n' > "$T/bin/logger"
printf '#!/usr/bin/env bash\n[ "$1" = -u ] && [ "$2" = ubuntu ] && { echo 1000; exit 0; }\nexit 1\n' > "$T/bin/id"
}
chmod 0755 "$T/bin/logger" "$T/bin/id"

# The node scripts' stand-ins, installed by the fake installer.
# shellcheck disable=SC2016  # code for the stand-ins
{
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "setup-node.sh${*:+ $*}" >> "$FBT_DIR/calls.log"' > "$T/scripts/setup-node.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "check-node.sh${*:+ $*}" >> "$FBT_DIR/calls.log"' 'echo "check-node output"' > "$T/scripts/check-node.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "firewall-setup.sh${*:+ $*}" >> "$FBT_DIR/calls.log"' \
    'exit "$(cat "$FBT_DIR/fw-rc" 2>/dev/null || echo 0)"' > "$T/scripts/firewall-setup.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "install-caddy.sh${*:+ $*}" >> "$FBT_DIR/calls.log"' \
    'p=false; [ -f "$FBT_DIR/dns-ok" ] && p=true' \
    'printf "{\"domain\":\"gw.example.org\",\"public_ip\":\"203.0.113.7\",\"resolved_ip\":\"\",\"propagated\":%s,\"egress_ip\":\"\",\"local_ips\":[],\"note\":\"gw.example.org does not resolve yet\"}\n" "$p"' \
    > "$T/scripts/install-caddy.sh"
# setup-gateway.sh: each run takes its exit code from the first line of sg-rcs
# (default 0); sg-not-ok makes exit 0 come with "ok":false.
cat > "$T/scripts/setup-gateway.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "setup-gateway.sh${*:+ $*}" >> "$FBT_DIR/calls.log"
rc=0
if [ -s "$FBT_DIR/sg-rcs" ]; then
    rc="$(sed -n 1p "$FBT_DIR/sg-rcs")"
    sed -e 1d "$FBT_DIR/sg-rcs" > "$FBT_DIR/sg-rcs.next"
    cat "$FBT_DIR/sg-rcs.next" > "$FBT_DIR/sg-rcs"
fi
echo "human text on stderr" >&2
printf '{"event":"step","msg":"stand-in step"}\n'
if [ "$rc" = 0 ] && [ ! -f "$FBT_DIR/sg-not-ok" ]; then
    printf '{"event":"done","ok":true,"applied":["gateway:unit"],"network":"testnet","msg":"stand-in enabled"}\n'
else
    printf '{"event":"done","ok":false,"error":"stand-in failure %s","msg":"stand-in failure %s"}\n' "$rc" "$rc"
fi
exit "$rc"
STUB
}
export PATH="$T/bin:$PATH"

# --- fixtures -------------------------------------------------------------------
# fresh NAME -- a new host tree $T/NAME in R, and no stub state.
fresh() {
    R="$T/$1"
    rm -rf "$R"
    mkdir -p "$R/etc/telcoin-first-boot" "$R/var/log" "$R/proc" "$R/dev/disk/by-id" "$R/home/ubuntu"
    : > "$R/dev/console"
    : > "$R/proc/modules"
    printf 'LABEL=cloudimg-rootfs / ext4 discard,errors=remount-ro 0 1\n' > "$R/etc/fstab"
    printf 'ID=ubuntu\nVERSION_CODENAME=noble\n' > "$R/etc/os-release"
    rm -f "$T/calls.log" "$T/logger.log" "$T/mounts" "$T/swap-on" "$T/swap-stuck" "$T/installer-fails" \
        "$T/docker-key-fails" "$T/sg-rcs" "$T/sg-not-ok" "$T/dns-ok" "$T/fw-rc" "$T/apt-fails" "$T/docker-down" \
        "$T/selfkill"
    : > "$T/calls.log"
    printf '%s\n' "$GOOD_FPR" > "$T/docker-key-fpr"
    printf '%s\n' "$MIN_RELEASE" > "$T/release"
}

# write_env ROLE [KEY=VALUE...] -- R's env file: the role's keys, each KEY=VALUE
# replacing that key's value.
write_env() {
    local role="$1" kv k v o line
    shift
    local -a keys
    keys=("TN_FB_ROLE=${role}" "TN_FB_NETWORK=testnet" "TN_FB_CLOUD=aws" "TN_FB_LOGIN_USER=ubuntu"
        "TN_FB_INSTALLER_URL=https://install.telcoin.network" "TN_FB_MIN_RELEASE=${MIN_RELEASE}")
    if [ "$role" = validator ]; then
        keys+=("TN_FB_DATA_DEVICE=${DEV}" "TN_FB_TRUSTED_NODES=")
    else
        keys+=("TN_FB_UPSTREAM=10.42.1.10" "TN_FB_DOMAIN=gw.example.org" "TN_FB_PUBLIC_IP=203.0.113.7"
            "TN_FB_REDIRECT_QUERIES=https://rpc.example.org" "TN_FB_RATE_LIMIT_SUBMISSIONS=300"
            "TN_FB_SSH_FROM=198.51.100.0/24,10.42.0.0/16")
    fi
    : > "$R/etc/telcoin-first-boot/first-boot.env"
    for kv in "${keys[@]}"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        for o in "$@"; do
            [ "${o%%=*}" = "$k" ] && v="${o#*=}"
        done
        line="${k}='${v}'"
        printf '%s\n' "$line" >> "$R/etc/telcoin-first-boot/first-boot.env"
    done
}

# run_fb ROLE [VAR=VALUE...] -- run first-boot-ROLE.sh on R under this bash:
# OUT its output, RC its exit status, CALLS the call log with temp names fixed.
run_fb() {
    local role="$1"
    shift
    RC=0
    OUT="$(env TN_FB_ROOT="$R" TN_FB_WAIT_STEP=0 "$@" "$BASH" "${FB}/first-boot-${role}.sh" 2>&1)" || RC=$?
    CALLS="$(sed -e 's/docker-apt\.[A-Za-z0-9]*/docker-apt.TMP/g' "$T/calls.log")"
}

# count TEXT LINE -- how many lines of TEXT start with LINE.
count() {
    local n=0 l
    while IFS= read -r l; do
        case "$l" in "$2"*) n=$((n + 1)) ;; esac
    done <<< "$1"
    printf '%s' "$n"
}

marker() {
    grep -v '^time=' "$R/var/lib/telcoin-first-boot/$1" 2>/dev/null || true
}

# failed_at NAME ROLE STEP -- rc 1, the failed marker names STEP, the console
# line says so, and no done marker.
failed_at() {
    check_rc "$1: exit 1" 1 "$RC"
    check_has "$1: failed marker names the step" "step=$3" "$(marker failed)"
    check "$1: console line" "TELCOIN-FIRST-BOOT $2: FAILED at $3" "$(tail -n 1 "$R/dev/console")"
    check "$1: no done marker" no "$([ -e "$R/var/lib/telcoin-first-boot/done" ] && echo yes || echo no)"
}

# succeeded NAME ROLE -- rc 0, the done marker, the console line, no failed marker.
succeeded() {
    check_rc "$1: exit 0" 0 "$RC" || printf '%s\n' "$OUT" | sed 's/^/      | /'
    check "$1: done marker" "role=$2" "$(marker "done")"
    check "$1: console line" "TELCOIN-FIRST-BOOT $2: ok" "$(tail -n 1 "$R/dev/console")"
    check "$1: no failed marker" no "$([ -e "$R/var/lib/telcoin-first-boot/failed" ] && echo yes || echo no)"
}

# --- validator ------------------------------------------------------------------
echo "== validator: a blank disk"
fresh v-blank
write_env validator "TN_FB_TRUSTED_NODES=${HUBS}"
: > "$R$DEV"
printf 'nodes: []\n' > "$R$HUBS"
run_fb validator
succeeded "blank disk" validator
check "blank disk: the calls, in order" "swapoff -a
swapon --show --noheadings
udevadm settle
blkid -p $R$DEV
mkfs.ext4 -q -E nodiscard $R$DEV
blkid -p -s TYPE -o value $R$DEV
blkid -p -s UUID -o value $R$DEV
systemctl daemon-reload
mountpoint -q $R/var/lib/telcoin
mount $R/var/lib/telcoin
mountpoint -q $R/var/lib/telcoin
$INSTALL_LINE
$INSTALL_CURL
installer --yes" "$CALLS"
check "blank disk: fstab gains one line by UUID, nofail" "LABEL=cloudimg-rootfs / ext4 discard,errors=remount-ro 0 1
UUID=${NEW_UUID} /var/lib/telcoin ext4 defaults,nofail 0 2" "$(cat "$R/etc/fstab")"
check "blank disk: the dpkg lock timeout" 'DPkg::Lock::Timeout "900";' "$(cat "$R/etc/apt/apt.conf.d/50telcoin-first-boot" 2>&1)"
check "blank disk: the algif_aead line" "install algif_aead /bin/false" "$(cat "$R/etc/modprobe.d/telcoin-algif-aead.conf" 2>&1)"
check "blank disk: the node scripts are in the login user's home" yes \
    "$([ -f "$R/home/ubuntu/telcoin-node-scripts/setup-node.sh" ] && echo yes || echo no)"
check "blank disk: the console holds the one line" "TELCOIN-FIRST-BOOT validator: ok" "$(cat "$R/dev/console")"
check_has "blank disk: the journal gets the result" "-t telcoin-first-boot -- TELCOIN-FIRST-BOOT validator: ok" "$(cat "$T/logger.log")"
check_has "blank disk: the log file gets the result" "TELCOIN-FIRST-BOOT validator: ok" \
    "$(sed -e 's/^[^ ]* //' "$R/var/log/telcoin-first-boot.log")"
for s in setup-node.sh firewall-setup.sh setup-gateway.sh install-caddy.sh check-node.sh; do
    check_lacks "blank disk: ${s} never runs" "$s" "$CALLS"
done
check_lacks "blank disk: no passphrase anywhere" "passphrase" "$OUT$(cat "$R/var/log/telcoin-first-boot.log")"

echo "== validator: an ext4 disk"
fresh v-ext4
write_env validator
printf 'ext4 %s\n' "$OLD_UUID" > "$R$DEV"
run_fb validator
succeeded "ext4 disk" validator
check "ext4 disk: not formatted" 0 "$(count "$CALLS" mkfs)"
check "ext4 disk: the data is kept" "ext4 ${OLD_UUID}" "$(cat "$R$DEV")"
check_has "ext4 disk: fstab names its UUID" "UUID=${OLD_UUID} /var/lib/telcoin ext4 defaults,nofail 0 2" "$(cat "$R/etc/fstab")"

echo "== validator: a foreign filesystem"
fresh v-xfs
write_env validator
printf 'xfs %s\n' "$OLD_UUID" > "$R$DEV"
run_fb validator
failed_at "xfs disk" validator data-disk
check "xfs disk: not formatted" 0 "$(count "$CALLS" mkfs)"
check "xfs disk: fstab unchanged" "LABEL=cloudimg-rootfs / ext4 discard,errors=remount-ro 0 1" "$(cat "$R/etc/fstab")"
check "xfs disk: nothing mounted, no installer" "0 0" "$(count "$CALLS" "mount ") $(count "$CALLS" sudo)"
check_has "xfs disk: the reason" "reason=The data disk holds no ext4 filesystem (found: xfs); it was left untouched." "$(marker failed)"

echo "== validator: a device that never appears"
fresh v-nodev
write_env validator
run_fb validator TN_FB_DEVICE_TIMEOUT=10
failed_at "no device" validator data-disk
check_has "no device: the reason" "reason=The data device ${DEV} did not appear within 10 s; check that the data disk is attached to this instance." "$(marker failed)"
check "no device: no disk command ran" "0 0 0" "$(count "$CALLS" udevadm) $(count "$CALLS" blkid) $(count "$CALLS" mkfs)"

echo "== validator: swap that stays on"
fresh v-swap
write_env validator
: > "$R$DEV"
: > "$T/swap-on"
: > "$T/swap-stuck"
run_fb validator
failed_at "swap on" validator swap
check "swap on: the disk is never touched" "0 0" "$(count "$CALLS" blkid) $(count "$CALLS" mkfs)"

echo "== validator: the installer fails three times"
fresh v-inst
write_env validator
: > "$R$DEV"
echo 3 > "$T/installer-fails"
run_fb validator
failed_at "installer x3" validator node-scripts
check "installer x3: three attempts, none ran" "3 0" "$(count "$CALLS" "$INSTALL_CURL") $(count "$CALLS" installer)"
check_has "installer x3: the reason" "reason=The node scripts installer failed three times." "$(marker failed)"

echo "== validator: a run after the fix, and one more"
# R and the stub state are kept: the disk was formatted and mounted by the run above.
: > "$T/calls.log"
run_fb validator
succeeded "rerun" validator
check "rerun: not formatted again" 0 "$(count "$CALLS" mkfs)"
check "rerun: not mounted again" 0 "$(count "$CALLS" "mount ")"
check "rerun: the installer ran" 1 "$(count "$CALLS" installer)"
: > "$T/calls.log"
run_fb validator
succeeded "third run" validator
check "third run: one fstab line for the disk" 1 "$(count "$(cat "$R/etc/fstab")" "UUID=${NEW_UUID} ")"
check "third run: the console shows each run" "TELCOIN-FIRST-BOOT validator: FAILED at node-scripts
TELCOIN-FIRST-BOOT validator: ok
TELCOIN-FIRST-BOOT validator: ok" "$(cat "$R/dev/console")"

echo "== validator: a trusted nodes file that is not there"
fresh v-hubs
write_env validator "TN_FB_TRUSTED_NODES=${HUBS}"
: > "$R$DEV"
run_fb validator
failed_at "no hubs file" validator trusted-nodes
check "no hubs file: no installer" 0 "$(count "$CALLS" sudo)"

echo "== validator: the installer serves an older release"
fresh v-old
write_env validator
: > "$R$DEV"
printf 'scripts-v2.2.0\n' > "$T/release"
run_fb validator
failed_at "older release" validator scripts-release
check_has "older release: names both releases and the command" \
    "reason=The installer put the node scripts scripts-v2.2.0 on this host; this deployment needs ${MIN_RELEASE} or newer. Once https://install.telcoin.network serves ${MIN_RELEASE} or newer, run this script again: sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-validator.sh" \
    "$(marker failed)"
for rel in scripts-v2.2.9 scripts-v1.99.99 scripts-v02.3.0 scripts-v2.3 v2.3.0; do
    fresh v-old
    write_env validator
    : > "$R$DEV"
    printf '%s\n' "$rel" > "$T/release"
    run_fb validator
    check "release ${rel}: stops at scripts-release" "1 step=scripts-release" "$RC $(marker failed | grep '^step=')"
done
fresh v-norel
write_env validator
: > "$R$DEV"
: > "$T/release"
run_fb validator
failed_at "no release record" validator scripts-release
check_has "no release record: says so" \
    "reason=The node scripts the installer put on this host name no release (no release= line in /home/ubuntu/telcoin-node-scripts/MANIFEST); this deployment needs ${MIN_RELEASE} or newer. Once https://install.telcoin.network serves ${MIN_RELEASE} or newer, run this script again: sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-validator.sh" \
    "$(marker failed)"
for rel in scripts-v2.3.0 scripts-v2.3.1 scripts-v2.10.0 scripts-v3.0.0; do
    fresh v-new
    write_env validator
    : > "$R$DEV"
    printf '%s\n' "$rel" > "$T/release"
    run_fb validator
    check "release ${rel}: the host is ready" "0 role=validator" "$RC $(marker "done")"
done
fresh v-new
write_env validator TN_FB_MIN_RELEASE=scripts-v2.9.1
: > "$R$DEV"
printf 'scripts-v2.10.0\n' > "$T/release"
run_fb validator
check "2.10.0 is newer than 2.9.1 (by number, not by text)" "0 role=validator" "$RC $(marker "done")"

echo "== validator: stopped by a signal"
fresh v-term
write_env validator
: > "$R$DEV"
: > "$T/selfkill"
run_fb validator
failed_at "TERM" validator data-disk
check_has "TERM: the reason" \
    "reason=The script ended unexpectedly (exit 143); the lines above in /var/log/telcoin-first-boot.log show where." "$(marker failed)"
check "TERM: nothing after the signal" 0 "$(count "$CALLS" "mount ")"

# --- refusals before any change -------------------------------------------------
# refused NAME ROLE -- the run stopped at the env step and changed nothing.
refused() {
    failed_at "$1" "$2" env
    check "$1: no command ran" "" "$CALLS"
    check "$1: no apt or modprobe file" "no no" \
        "$([ -e "$R/etc/apt/apt.conf.d/50telcoin-first-boot" ] && echo yes || echo no) $([ -e "$R/etc/modprobe.d/telcoin-algif-aead.conf" ] && echo yes || echo no)"
    check_has "$1: says nothing was changed" yes "$(grep -q 'Nothing was changed\.$' "$R/var/log/telcoin-first-boot.log" && echo yes || echo no)"
}

echo "== refusals"
fresh r-char
write_env validator
printf "TN_FB_DATA_DEVICE='/dev/sdb;reboot'\n" >> "$R/etc/telcoin-first-boot/first-boot.env"
: > "$R$DEV"
run_fb validator
refused "a value with a shell character" validator
check_has "a value with a shell character: names the line" \
    "reason=Line 9 of /etc/telcoin-first-boot/first-boot.env is not a KEY='value' line whose value holds only letters, digits and . _ : / , @ -." "$(marker failed)"

fresh r-net
write_env validator TN_FB_NETWORK=devnet
: > "$R$DEV"
run_fb validator
refused "a network other than testnet and mainnet" validator
check_has "a network other than testnet and mainnet: names the key" \
    "reason=TN_FB_NETWORK in /etc/telcoin-first-boot/first-boot.env must be testnet or mainnet (it is 'devnet')." "$(marker failed)"

fresh r-twice
write_env validator
printf "TN_FB_NETWORK='mainnet'\n" >> "$R/etc/telcoin-first-boot/first-boot.env"
: > "$R$DEV"
run_fb validator
refused "a key given twice" validator

fresh r-role
write_env gateway
run_fb validator
refused "the gateway's env on the validator" validator

fresh r-minrel
write_env validator TN_FB_MIN_RELEASE=2.3.0
: > "$R$DEV"
run_fb validator
refused "a minimum release that is not scripts-vX.Y.Z" validator
check_has "a minimum release that is not scripts-vX.Y.Z: names the key" \
    "reason=TN_FB_MIN_RELEASE in /etc/telcoin-first-boot/first-boot.env must be a node scripts release, scripts-vMAJOR.MINOR.PATCH (it is '2.3.0')." "$(marker failed)"

fresh r-nominrel
write_env gateway
grep -v '^TN_FB_MIN_RELEASE=' "$R/etc/telcoin-first-boot/first-boot.env" > "$T/env.tmp"
cat "$T/env.tmp" > "$R/etc/telcoin-first-boot/first-boot.env"
run_fb gateway
refused "no minimum release" gateway

fresh r-hook
write_env validator
: > "$R$DEV"
run_fb validator TN_FB_DEVICE_TIMEOUT=10m
refused "a test hook that is not a number" validator

fresh r-upstream
write_env gateway TN_FB_UPSTREAM=10.42.1.300
run_fb gateway
refused "an upstream that is not an IPv4 address" gateway

fresh r-ssh
write_env gateway "TN_FB_SSH_FROM=198.51.100.0/24,,10.42.0.0/16"
run_fb gateway
refused "an SSH list with an empty entry" gateway

fresh r-noenv
rm -f "$R/etc/telcoin-first-boot/first-boot.env"
run_fb gateway
refused "no env file" gateway

# --- gateway --------------------------------------------------------------------
GW_DNS='install-caddy.sh --json --phase=gateway-check-dns --gateway-domain gw.example.org --public-ip 203.0.113.7'
GW_SG='setup-gateway.sh --enable --mode standalone --network testnet --upstream 10.42.1.10 --front caddy --domain gw.example.org --redirect-queries https://rpc.example.org --rate-limit-submissions 300 --json'
GW_FW='firewall-setup.sh --enable --ssh-from 198.51.100.0/24,10.42.0.0/16'

echo "== gateway: every step"
fresh g-ok
write_env gateway
printf 'algif_aead 16384 0 - Live 0x0000000000000000\n' > "$R/proc/modules"
: > "$T/dns-ok"
run_fb gateway
succeeded "gateway" gateway
check "gateway: the calls, in order, with their arguments" "modprobe -r algif_aead
swapoff -a
swapon --show --noheadings
$INSTALL_LINE
$INSTALL_CURL
installer --yes
dpkg --print-architecture
curl --proto =https --tlsv1.2 -fsSL --max-time 60 --max-filesize 1048576 -o $R/var/lib/telcoin-first-boot/docker-apt.TMP/key --url https://download.docker.com/linux/ubuntu/gpg
gpg --batch --no-tty --with-colons --import-options show-only --import
gpg --batch --no-tty --dearmor
gpgconf --kill all
apt-get -q update
apt-get -y -q install docker-ce docker-ce-cli containerd.io
systemctl enable --now docker
docker info
$GW_DNS
$GW_SG
$GW_FW
check-node.sh" "$CALLS"
check "gateway: Docker's apt source" \
    "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
    "$(cat "$R/etc/apt/sources.list.d/docker.list" 2>&1)"
check "gateway: Docker's keyring" "KEY ${GOOD_FPR}" "$(cat "$R/etc/apt/keyrings/docker.gpg" 2>&1)"
check "gateway: the apt files are 0644" "644 644" \
    "$(stat -c %a "$R/etc/apt/sources.list.d/docker.list" 2>&1) $(stat -c %a "$R/etc/apt/keyrings/docker.gpg" 2>&1)"
check "gateway: no temp dir is left" "" "$(cd "$R/var/lib/telcoin-first-boot" && ls -d docker-apt.* 2>/dev/null)"
check "gateway: the state dir is 0700" 700 "$(stat -c %a "$R/var/lib/telcoin-first-boot")"
check_has "gateway: check-node's output is in the log" "check-node output" "$(cat "$R/var/log/telcoin-first-boot.log")"
check_has "gateway: setup-gateway's events are in the log" \
    '{"event":"done","ok":true,"applied":["gateway:unit"],"network":"testnet","msg":"stand-in enabled"}' \
    "$(cat "$R/var/log/telcoin-first-boot.log")"
check_lacks "gateway: no data disk step" "blkid" "$CALLS"

echo "== gateway: setup-gateway.sh exit 1, then 0"
fresh g-retry
write_env gateway
: > "$T/dns-ok"
printf '1\n0\n' > "$T/sg-rcs"
run_fb gateway
succeeded "retry" gateway
check "retry: two runs of setup-gateway.sh, then the firewall" "$GW_SG
$GW_SG
$GW_FW
check-node.sh" "$(grep -E '^(setup-gateway|firewall-setup|check-node)\.sh' <<< "$CALLS")"

echo "== gateway: setup-gateway.sh exit 1 three times"
fresh g-retry3
write_env gateway
: > "$T/dns-ok"
printf '1\n1\n1\n' > "$T/sg-rcs"
run_fb gateway
failed_at "exit 1 x3" gateway gateway
check "exit 1 x3: three runs, no firewall" "3 0" "$(count "$CALLS" setup-gateway.sh) $(count "$CALLS" firewall-setup.sh)"
check_has "exit 1 x3: the reason carries the script's message" \
    "reason=setup-gateway.sh refused or put everything back three times (exit 1): stand-in failure 1." "$(marker failed)"

echo "== gateway: setup-gateway.sh exit 3"
fresh g-exit3
write_env gateway
: > "$T/dns-ok"
printf '3\n' > "$T/sg-rcs"
run_fb gateway
failed_at "exit 3" gateway gateway
check "exit 3: one run, no firewall, no check-node" "1 0 0" \
    "$(count "$CALLS" setup-gateway.sh) $(count "$CALLS" firewall-setup.sh) $(count "$CALLS" check-node.sh)"

echo "== gateway: setup-gateway.sh exit 0 without ok:true"
fresh g-notok
write_env gateway
: > "$T/dns-ok"
: > "$T/sg-not-ok"
run_fb gateway
failed_at "exit 0 not ok" gateway gateway
check "exit 0 not ok: no firewall" 0 "$(count "$CALLS" firewall-setup.sh)"

echo "== gateway: the name never resolves"
fresh g-dns
write_env gateway
run_fb gateway TN_FB_DNS_TIMEOUT=90
succeeded "dns timeout" gateway
check "dns timeout: three checks, then setup-gateway.sh" "$GW_DNS
$GW_DNS
$GW_DNS
$GW_SG
$GW_FW" "$(grep -E '^(install-caddy|setup-gateway|firewall-setup)\.sh' <<< "$CALLS")"
check_has "dns timeout: a warning in the log" yes \
    "$(grep -q 'Warning: gw.example.org did not reach 203.0.113.7 within 90 s (gw.example.org does not resolve yet)' "$R/var/log/telcoin-first-boot.log" && echo yes || echo no)"

echo "== gateway: the installer serves an older release"
fresh g-old
write_env gateway
: > "$T/dns-ok"
printf 'scripts-v2.2.0\n' > "$T/release"
run_fb gateway
failed_at "gateway older release" gateway scripts-release
check_has "gateway older release: names both releases and the command" \
    "reason=The installer put the node scripts scripts-v2.2.0 on this host; this deployment needs ${MIN_RELEASE} or newer. Once https://install.telcoin.network serves ${MIN_RELEASE} or newer, run this script again: sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-gateway.sh" \
    "$(marker failed)"
check "gateway older release: no Docker, no DNS wait, no gateway" "0 0 0 0 0" \
    "$(count "$CALLS" apt-get) $(count "$CALLS" docker) $(count "$CALLS" gpg) $(count "$CALLS" install-caddy.sh) $(count "$CALLS" setup-gateway.sh)"
check "gateway older release: no apt source" no "$([ -e "$R/etc/apt/sources.list.d/docker.list" ] && echo yes || echo no)"

echo "== gateway: a Docker key with another fingerprint"
fresh g-fpr
write_env gateway
printf '0000000000000000000000000000000000000000\n' > "$T/docker-key-fpr"
run_fb gateway
failed_at "bad fingerprint" gateway docker
check "bad fingerprint: no apt source, no keyring" "no no" \
    "$([ -e "$R/etc/apt/sources.list.d/docker.list" ] && echo yes || echo no) $([ -e "$R/etc/apt/keyrings/docker.gpg" ] && echo yes || echo no)"
check "bad fingerprint: no apt-get, no setup-gateway.sh" "0 0" "$(count "$CALLS" apt-get) $(count "$CALLS" setup-gateway.sh)"
check "bad fingerprint: no temp dir is left" "" "$(cd "$R/var/lib/telcoin-first-boot" && ls -d docker-apt.* 2>/dev/null)"

finish
