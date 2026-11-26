#!/usr/bin/env bash
# =============================================================================
# tools/tests/first_boot_test.sh -- terraform/first-boot/, the scripts cloud-init
# runs on the first boot of a validator host and a worker-gateway host:
#
#   validator  a blank disk is formatted once, an ext4 disk is not, a foreign
#              filesystem stops the boot, a device that never appears times
#              out; swap that stays on stops it; the installer failing three
#              times stops it; a run after a fix formats nothing again and adds
#              no second fstab line; an fstab without a final newline keeps
#              its last line; a missing trusted nodes file stops it;
#              setup-node.sh, firewall-setup.sh and the gateway scripts never run
#   gateway    every step in order with its exact arguments, each flag one the
#              real script's argument parser in this tree names; setup-gateway.sh
#              exit 1 is tried again (and three of them stop the boot), exit 3
#              stops before the firewall, exit 0 without "ok":true stops; a
#              name that never resolves does not stop the boot; a Docker
#              signing key with another fingerprint writes no apt source; an
#              older node scripts release stops the boot before Docker
#   both       a release older than TN_FB_MIN_RELEASE, none, or one the check
#              cannot read stops the boot at scripts-release, each named as
#              what it is; a bad env value or test hook is refused before
#              anything changes, and the plan's table of values (host-plan's
#              first_boot_rules.tftest.hcl) passes or stops the env step as the
#              plan takes or refuses each; a run stopped by a signal still
#              leaves the failed marker
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

echo "== validator: an fstab without a final newline"
fresh v-nonl
write_env validator
printf 'ext4 %s\n' "$OLD_UUID" > "$R$DEV"
printf 'LABEL=cloudimg-rootfs / ext4 discard,errors=remount-ro 0 1' > "$R/etc/fstab"
run_fb validator
succeeded "no final newline" validator
check "no final newline: the last line is kept, the entry on its own line" "LABEL=cloudimg-rootfs / ext4 discard,errors=remount-ro 0 1
UUID=${OLD_UUID} /var/lib/telcoin ext4 defaults,nofail 0 2" "$(cat "$R/etc/fstab")"
check "no final newline: the file ends with a newline" 1 "$(tail -c 1 "$R/etc/fstab" | od -An -c | grep -c '\\n')"
: > "$T/calls.log"
run_fb validator
succeeded "no final newline, second run" validator
check "no final newline, second run: nothing added" 2 "$(grep -c . "$R/etc/fstab")"

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
check "no hubs file: no command ran" "" "$CALLS"
check "no hubs file: fstab unchanged, no apt file" "LABEL=cloudimg-rootfs / ext4 discard,errors=remount-ro 0 1 no" \
    "$(cat "$R/etc/fstab") $([ -e "$R/etc/apt/apt.conf.d/50telcoin-first-boot" ] && echo yes || echo no)"
check_has "no hubs file: says nothing was changed" yes "$(grep -q 'Nothing was changed\.$' "$R/var/log/telcoin-first-boot.log" && echo yes || echo no)"

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
# A release= line in a form the check does not read (cut-release.sh's tag rule
# is wider) is named as it is, not as a missing line.
for rel in scripts-v2.3.01 ''; do
    fresh v-oddrel
    write_env validator
    : > "$R$DEV"
    printf '%s\n' "$rel" > "$T/release"
    run_fb validator
    failed_at "release=${rel}" validator scripts-release
    check_has "release=${rel}: names the line" \
        "reason=The node scripts the installer put on this host name a release this check cannot read (release=${rel} in /home/ubuntu/telcoin-node-scripts/MANIFEST); this deployment needs ${MIN_RELEASE} or newer. Once https://install.telcoin.network serves ${MIN_RELEASE} or newer, run this script again: sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-validator.sh" \
        "$(marker failed)"
done
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

# What setup-gateway.sh and firewall-setup.sh would refuse after the host has
# changed is refused here, before anything changes.
# env_refused KEY=VALUE... -- each value stops the gateway at the env step, no command run.
env_refused() {
    local kv
    for kv in "$@"; do
        fresh r-gw
        write_env gateway "$kv"
        run_fb gateway
        check "${kv}: refused before any change" "1 step=env " "$RC $(marker failed | grep '^step=') $CALLS"
    done
}
# env_taken KEY=VALUE... -- each value lets the gateway through.
env_taken() {
    local kv
    for kv in "$@"; do
        fresh g-taken
        write_env gateway "$kv"
        : > "$T/dns-ok"
        run_fb gateway
        check "${kv}: taken" "0 role=gateway" "$RC $(marker "done")"
    done
}
env_refused TN_FB_UPSTREAM=8.8.8.8 TN_FB_UPSTREAM=127.0.0.1 TN_FB_UPSTREAM=0.10.0.1 TN_FB_UPSTREAM=172.32.0.1 \
    TN_FB_UPSTREAM=100.128.0.1 TN_FB_UPSTREAM=192.169.0.1 TN_FB_UPSTREAM=010.42.1.10
env_taken TN_FB_UPSTREAM=172.16.0.1 TN_FB_UPSTREAM=172.31.255.254 TN_FB_UPSTREAM=192.168.7.7 \
    TN_FB_UPSTREAM=100.64.0.1 TN_FB_UPSTREAM=100.127.0.1 TN_FB_UPSTREAM=169.254.10.10
env_refused TN_FB_REDIRECT_QUERIES=http://10.42.1.10:8545 TN_FB_REDIRECT_QUERIES=http://10.42.1.10:43174/ \
    TN_FB_REDIRECT_QUERIES=http://localhost:8655 TN_FB_REDIRECT_QUERIES=http://LocalHost:8656/x \
    TN_FB_REDIRECT_QUERIES=http://127.0.0.1:9655 TN_FB_REDIRECT_QUERIES=http://0.0.0.0:8655 \
    TN_FB_REDIRECT_QUERIES=https://rpc.example.org:99999/ TN_FB_REDIRECT_QUERIES=https://rpc.example.org:0/ \
    TN_FB_REDIRECT_QUERIES=https://rpc.example.org:08545/ TN_FB_REDIRECT_QUERIES=https://rpc..example.org/ \
    TN_FB_REDIRECT_QUERIES=https://-rpc.example.org/ TN_FB_REDIRECT_QUERIES=https://rpc.example.org/a:b \
    TN_FB_REDIRECT_QUERIES=https://rpc.example.org/a@b TN_FB_REDIRECT_QUERIES=ftp://rpc.example.org/
env_taken TN_FB_REDIRECT_QUERIES=https://rpc.example.org:8545/ TN_FB_REDIRECT_QUERIES=http://10.42.1.10:8546 \
    TN_FB_REDIRECT_QUERIES=http://10.42.1.11:8545 TN_FB_REDIRECT_QUERIES=http://localhost:8545 \
    TN_FB_REDIRECT_QUERIES=https://rpc.example.org:65535/v1/rpc
env_refused TN_FB_SSH_FROM=0.0.0.0/0 TN_FB_SSH_FROM=0.0.0.0 TN_FB_SSH_FROM=10.0.0.0/7 TN_FB_SSH_FROM=10.0.0.0/33 \
    TN_FB_SSH_FROM=10.0.0.0/08 TN_FB_SSH_FROM=:: TN_FB_SSH_FROM=::/0 TN_FB_SSH_FROM=:::/999 \
    TN_FB_SSH_FROM=2001:db8::/7 TN_FB_SSH_FROM=2001:db8::/129 TN_FB_SSH_FROM=::ffff:198.51.100.7 \
    TN_FB_SSH_FROM=1:2:3 TN_FB_SSH_FROM=1::2::3 TN_FB_SSH_FROM=12345::1 TN_FB_SSH_FROM=1:2:3:4:5:6:7:8:9 \
    TN_FB_SSH_FROM=198.51.100.0/24,0.0.0.0/0
env_taken TN_FB_SSH_FROM=198.51.100.7 TN_FB_SSH_FROM=2001:db8::/32 TN_FB_SSH_FROM=fe80::1 \
    TN_FB_SSH_FROM=1:2:3:4:5:6:7:8/128 TN_FB_SSH_FROM=::1 TN_FB_SSH_FROM=10.0.0.0/8,2001:db8:0:1::/64
env_refused TN_FB_INSTALLER_URL=https://install..telcoin.network TN_FB_INSTALLER_URL=https://install.telcoin.network:70000
fresh r-gw
write_env gateway TN_FB_REDIRECT_QUERIES=http://10.42.1.10:8545
run_fb gateway
check_has "a redirect URL that loops: says why" \
    "reason=TN_FB_REDIRECT_QUERIES in /etc/telcoin-first-boot/first-boot.env points at the validator's own RPC or readiness port, or at this host's gateway, and setup-gateway.sh refuses that: give a node that answers queries (it is 'http://10.42.1.10:8545')." \
    "$(marker failed)"
fresh r-gw
write_env gateway TN_FB_SSH_FROM=0.0.0.0/0
run_fb gateway
check_has "an SSH source that is anywhere: says why" \
    "reason=TN_FB_SSH_FROM in /etc/telcoin-first-boot/first-boot.env must be a comma list of addresses or CIDRs of /8 or narrower, none of them 0.0.0.0 or :: (it is '0.0.0.0/0')." \
    "$(marker failed)"

fresh r-noenv
rm -f "$R/etc/telcoin-first-boot/first-boot.env"
run_fb gateway
refused "no env file" gateway

# --- the plan's table -----------------------------------------------------------
# The values of terraform/modules/host-plan/tests/first_boot_rules.tftest.hcl, in
# its order, as env values (TN_FB_SSH_FROM ends with the plan's vpc_cidr): the
# plan takes what first boot takes, so a host it builds does not stop at its env
# file. Change a row in both tables or in neither. taken: the env step passes
# (the run then stops at swap, held on here); refused: it stops at env;
# plan-refuses: first boot takes it, the plan refuses it on purpose (that file
# says why).
# plan_table -- each "KEY VERDICT VALUE" line of stdin through the gateway's env step.
plan_table() {
    local key verdict val want
    while read -r key verdict val; do
        want="1 step=swap"
        [ "$verdict" != refused ] || want="1 step=env"
        fresh r-table
        write_env gateway "${key}=${val}"
        : > "$T/swap-on"
        : > "$T/swap-stuck"
        run_fb gateway < /dev/null
        check "table: ${key}=${val} ${verdict}" "$want" "$RC $(marker failed | grep '^step=')"
    done
}
plan_table <<'EOF'
TN_FB_INSTALLER_URL taken https://install.example.org:65535/a
TN_FB_INSTALLER_URL taken https://install.example.org/v2/latest_1.sh
TN_FB_INSTALLER_URL refused https://install.example.org/v2:latest
TN_FB_INSTALLER_URL refused https://install..telcoin.network
TN_FB_INSTALLER_URL refused https://install.telcoin.network:70000
TN_FB_INSTALLER_URL refused http://install.telcoin.network
TN_FB_REDIRECT_QUERIES taken https://rpc.example.org:8545/
TN_FB_REDIRECT_QUERIES taken http://10.42.1.10:8546
TN_FB_REDIRECT_QUERIES taken http://10.42.1.11:8545
TN_FB_REDIRECT_QUERIES taken http://localhost:8545
TN_FB_REDIRECT_QUERIES taken https://rpc.example.org:65535/v1/rpc
TN_FB_REDIRECT_QUERIES taken http://rpc.example.org:8545/v1/a_b-c.d
TN_FB_REDIRECT_QUERIES refused https://rpc.example.org:99999/
TN_FB_REDIRECT_QUERIES refused https://rpc.example.org:65536/
TN_FB_REDIRECT_QUERIES refused https://rpc.example.org:0/
TN_FB_REDIRECT_QUERIES refused https://rpc.example.org:08545/
TN_FB_REDIRECT_QUERIES refused https://rpc..example.org/
TN_FB_REDIRECT_QUERIES refused https://rpc.-x.example.org/
TN_FB_REDIRECT_QUERIES refused https://-rpc.example.org/
TN_FB_REDIRECT_QUERIES refused http://rpc.example.org:8545/v1:a@b,c
TN_FB_REDIRECT_QUERIES refused https://rpc.example.org/a@b
TN_FB_REDIRECT_QUERIES refused ftp://rpc.example.org/
TN_FB_REDIRECT_QUERIES refused http://10.42.1.10:8545
TN_FB_REDIRECT_QUERIES refused http://10.42.1.10:43174/
TN_FB_REDIRECT_QUERIES refused http://localhost:8655
TN_FB_REDIRECT_QUERIES refused http://LocalHost:8656/x
TN_FB_REDIRECT_QUERIES refused http://127.0.0.1:9655
TN_FB_REDIRECT_QUERIES refused http://0.0.0.0:8655
TN_FB_DOMAIN taken rpc.example.org
TN_FB_DOMAIN taken rpc.example.xn--p1ai
TN_FB_DOMAIN taken a.b1
TN_FB_DOMAIN taken x.y-z
TN_FB_DOMAIN refused rpc.example.123
TN_FB_DOMAIN refused 10.42.1.20
TN_FB_DOMAIN refused localhost
TN_FB_DOMAIN refused rpc..example.org
TN_FB_DOMAIN refused -rpc.example.org
TN_FB_DOMAIN refused rpc.example.org.
TN_FB_SSH_FROM taken 198.51.100.7/32,10.42.0.0/16
TN_FB_SSH_FROM taken 198.51.100.0/24,10.42.0.0/16
TN_FB_SSH_FROM taken 10.0.0.0/8,10.42.0.0/16
TN_FB_SSH_FROM taken 198.51.100.7/24,10.42.0.0/16
TN_FB_SSH_FROM taken 2001:db8::/32,10.42.0.0/16
TN_FB_SSH_FROM taken 1:2:3:4:5:6:7:8/128,10.42.0.0/16
TN_FB_SSH_FROM refused 0.0.0.0/0,10.42.0.0/16
TN_FB_SSH_FROM refused 0.0.0.0/8,10.42.0.0/16
TN_FB_SSH_FROM refused 128.0.0.0/1,10.42.0.0/16
TN_FB_SSH_FROM refused 10.0.0.0/7,10.42.0.0/16
TN_FB_SSH_FROM refused 10.0.0.0/33,10.42.0.0/16
TN_FB_SSH_FROM refused 10.0.0.0/08,10.42.0.0/16
TN_FB_SSH_FROM refused 010.0.0.0/8,10.42.0.0/16
TN_FB_SSH_FROM refused ::/0,10.42.0.0/16
TN_FB_SSH_FROM refused ::/8,10.42.0.0/16
TN_FB_SSH_FROM refused 2001:db8::/7,10.42.0.0/16
TN_FB_SSH_FROM refused 2001:db8::/129,10.42.0.0/16
TN_FB_SSH_FROM refused ::ffff:198.51.100.7/128,10.42.0.0/16
TN_FB_SSH_FROM refused 1::2::3/64,10.42.0.0/16
TN_FB_SSH_FROM refused 10.042.0.0/16
TN_FB_MIN_RELEASE taken scripts-v0.0.0
TN_FB_MIN_RELEASE taken scripts-v2.10.0
TN_FB_MIN_RELEASE taken scripts-v9999.9999.9999
TN_FB_MIN_RELEASE refused scripts-v2.03.0
TN_FB_MIN_RELEASE refused scripts-v10000.0.0
TN_FB_MIN_RELEASE refused scripts-v2.3
TN_FB_MIN_RELEASE refused scripts-v2.3.0-rc1
TN_FB_MIN_RELEASE refused v2.3.0
TN_FB_DOMAIN plan-refuses RPC.Example.org
TN_FB_SSH_FROM plan-refuses 198.51.100.7,10.42.0.0/16
TN_FB_UPSTREAM plan-refuses 169.254.10.10
EOF

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

echo "== gateway: the command lines against the real scripts' parsers"
# The stand-ins take any argument, so this holds the lines asserted above to the
# argument parsers of the scripts in this tree: a flag renamed or dropped there
# fails here. install-caddy.sh and firewall-setup.sh skip an argument they do not
# know, so nothing at boot would say why. check-node.sh is run with no flags.
# parser_arms SCRIPT FUNC -- each pattern of the case arms in FUNC() of SCRIPT,
# one a line: an arm --a|--b) gives --a and --b.
parser_arms() {
    awk -v fn="$2() {" '$0 == fn { f = 1; next } f && /^}/ { exit }
        f && match($0, /^[[:space:]]*[^[:space:]()#|]+([|][^[:space:]()#|]+)*[)]/) {
            s = substr($0, RSTART, RLENGTH - 1); gsub(/[[:space:]]/, "", s)
            n = split(s, a, "|"); for (i = 1; i <= n; i++) print a[i] }' "${TN_TEST_REPO}/$1"
}
# takes SCRIPT FUNC LINE -- each --flag of LINE is an arm of FUNC's parser; a
# --flag=value needs a --flag=* arm.
takes() {
    local arms w want
    arms="$(parser_arms "$1" "$2")"
    for w in $3; do
        case "$w" in
            --*=*) want="${w%%=*}=*" ;;
            --*) want="$w" ;;
            *) continue ;;
        esac
        check "${1} takes ${want}" yes "$(grep -qxF -- "$want" <<< "$arms" && echo yes || echo no)"
    done
}
takes setup-gateway.sh sg_parse_args "$GW_SG"
takes install-caddy.sh main "$GW_DNS"
takes firewall-setup.sh main "$GW_FW"
for v in standalone caddy testnet mainnet; do
    check "setup-gateway.sh takes the value ${v}" yes \
        "$(parser_arms setup-gateway.sh sg_set_value | grep -qxF -- "$v" && echo yes || echo no)"
done
check "install-caddy.sh has the phase gateway-check-dns" yes \
    "$(parser_arms install-caddy.sh main | grep -qxF gateway-check-dns && echo yes || echo no)"
check "check-node.sh is run with no flags" "check-node.sh" "$(grep '^check-node\.sh' <<< "$CALLS")"

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
# The wait ends on the clock, not after a number of checks: 3 s with a check a
# second is three checks or so (whole seconds on the clock make it 2 to 5).
fresh g-dns
write_env gateway
run_fb gateway TN_FB_DNS_TIMEOUT=3 TN_FB_WAIT_STEP=1
succeeded "dns timeout" gateway
n="$(count "$CALLS" "$GW_DNS")"
check "dns timeout: checks until 3 s are up (${n} checks)" yes "$([ "$n" -ge 2 ] && [ "$n" -le 5 ] && echo yes || echo no)"
check "dns timeout: then setup-gateway.sh and the firewall" "$GW_DNS
$GW_SG
$GW_FW" "$(grep -E '^(install-caddy|setup-gateway|firewall-setup)\.sh' <<< "$CALLS" | uniq)"
check_has "dns timeout: a warning in the log" yes \
    "$(grep -q 'Warning: gw.example.org did not reach 203.0.113.7 within 3 s (gw.example.org does not resolve yet)' "$R/var/log/telcoin-first-boot.log" && echo yes || echo no)"
fresh g-dns0
write_env gateway
run_fb gateway TN_FB_DNS_TIMEOUT=0
check "dns timeout 0: one check" 1 "$(count "$CALLS" "$GW_DNS")"

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
