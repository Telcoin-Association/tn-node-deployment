#!/usr/bin/env bash
# =============================================================================
# terraform/first-boot/first-boot-validator.sh -- first boot of the validator
# host a Terraform root under terraform/ creates
#
# cloud-init runs this once, as root, from /usr/local/libexec/telcoin-first-boot.
# It leaves a ready host, not a running node: the operator generates the keys
# from a Session Manager or IAP shell with the commands the deployment prints,
# so no passphrase or key ever passes through user data, metadata or Terraform.
# This script never runs setup-node.sh or firewall-setup.sh.
#
# Steps, in order (first-boot-lib.sh has the env file, the log and the markers):
#   env             check /etc/telcoin-first-boot/first-boot.env
#   apt-lock        apt waits up to 15 minutes for the dpkg lock
#   cve-2026-31431  the algif_aead modprobe line; unload the module if loaded
#   swap            swap off
#   data-disk       wait up to 10 minutes for TN_FB_DATA_DEVICE; format it only
#                   when it carries no signature at all, refuse anything but
#                   ext4, mount it by UUID (nofail) at /var/lib/telcoin
#   trusted-nodes   TN_FB_TRUSTED_NODES, when set, is a readable file
#   node-scripts    the published installer, as TN_FB_LOGIN_USER, three tries
#   scripts-release the installed release is TN_FB_MIN_RELEASE or newer
#
# USAGE:
#   sudo bash /usr/local/libexec/telcoin-first-boot/first-boot-validator.sh
#   Run it again after a fix: it starts at the top and formats nothing that
#   already holds a filesystem.
#
# Exit status: 0 the host is ready (/var/lib/telcoin-first-boot/done); 1 a step
# failed (/var/lib/telcoin-first-boot/failed names it and says why).
# =============================================================================

set -euo pipefail

FB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=terraform/first-boot/first-boot-lib.sh
. "${FB_DIR}/first-boot-lib.sh"

readonly FB_DATA_DIR=/var/lib/telcoin

# fbv_data_disk -- the data disk at /var/lib/telcoin. setup-node.sh takes the
# mount point as it is (root-owned, holding only lost+found) and hands it to
# the node's service user.
fbv_data_disk() {
    local dev limit waited=0 probe=0 fstype uuid mnt fstab re='^[0-9A-Fa-f-]+$'
    fb_step data-disk "the data disk ${TN_FB_DATA_DEVICE} at ${FB_DATA_DIR}"
    dev="${FB_ROOT}${TN_FB_DATA_DEVICE}"
    limit="${TN_FB_DEVICE_TIMEOUT:-600}"
    # The disk can attach after the instance starts.
    until fb_is_block "$dev"; do
        [ "$waited" -lt "$limit" ] \
            || fb_fail "The data device ${TN_FB_DATA_DEVICE} did not appear within ${limit} s; check that the data disk is attached to this instance."
        fb_sleep 5
        waited=$((waited + 5))
    done
    udevadm settle || fb_fail "udevadm settle failed."

    # Format it only when it carries no signature at all (blkid -p exits 2 when
    # it finds none): a disk that already holds a filesystem keeps its data. A
    # new cloud disk holds nothing to discard.
    blkid -p "$dev" > /dev/null 2>&1 || probe=$?
    case "$probe" in
        0) fb_log "The data disk already carries a filesystem; it is not formatted." ;;
        2) fb_log "The data disk is blank; formatting it as ext4."
           mkfs.ext4 -q -E nodiscard "$dev" || fb_fail "mkfs.ext4 failed on ${TN_FB_DATA_DEVICE}." ;;
        *) fb_fail "blkid could not probe the data disk (exit ${probe})." ;;
    esac
    fstype="$(blkid -p -s TYPE -o value "$dev" 2> /dev/null)" || fstype=""
    if [ "$fstype" != ext4 ]; then
        fb_fail "The data disk holds no ext4 filesystem (found: ${fstype:-none}); it was left untouched."
    fi
    uuid="$(blkid -p -s UUID -o value "$dev" 2> /dev/null)" || uuid=""
    [[ "$uuid" =~ $re ]] || fb_fail "The filesystem on the data disk has no usable UUID (found: ${uuid:-none})."

    # By UUID, because device names can change between boots; nofail keeps a
    # boot without the disk out of emergency mode.
    mnt="${FB_ROOT}${FB_DATA_DIR}"
    fstab="${FB_ROOT}/etc/fstab"
    mkdir -p "$mnt" || fb_fail "Could not create ${FB_DATA_DIR}."
    if ! grep -q "^UUID=${uuid} " "$fstab" 2> /dev/null; then
        printf 'UUID=%s %s ext4 defaults,nofail 0 2\n' "$uuid" "$FB_DATA_DIR" >> "$fstab" \
            || fb_fail "Could not add the data disk to /etc/fstab."
    fi
    systemctl daemon-reload || fb_fail "systemctl daemon-reload failed."
    mountpoint -q "$mnt" || mount "$mnt" || fb_fail "mount ${FB_DATA_DIR} failed."
    mountpoint -q "$mnt" || fb_fail "The data disk did not mount at ${FB_DATA_DIR}."
}

# fbv_trusted_nodes -- the hubs file the printed key generation names.
fbv_trusted_nodes() {
    local f
    fb_step trusted-nodes "the trusted nodes file ${TN_FB_TRUSTED_NODES:-(none given)}"
    if [ -z "$TN_FB_TRUSTED_NODES" ]; then
        fb_log "No trusted nodes file was given; copy it to this host before key generation and name its path there."
        return 0
    fi
    f="${FB_ROOT}${TN_FB_TRUSTED_NODES}"
    if [ ! -f "$f" ] || [ ! -r "$f" ] || [ ! -s "$f" ]; then
        fb_fail "The trusted nodes file ${TN_FB_TRUSTED_NODES} is missing, unreadable or empty."
    fi
}

main() {
    fb_init validator
    fb_apt_lock_timeout
    fb_cve_2026_31431
    fb_swap_off
    fbv_data_disk
    fbv_trusted_nodes
    fb_install_node_scripts setup-node.sh
    fb_done "The host is ready: the data disk is mounted at ${FB_DATA_DIR} and the node scripts are in ${FB_SCRIPTS_DIR#"$FB_ROOT"}. Next: the key generation and firewall commands that terraform output next_steps prints, run on this host."
}

main "$@"
