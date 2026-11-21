#!/usr/bin/env bash
# V-AWS harness, part 1: what `df -Pk` reports as the total size of an ext4 filesystem made the
# way the template's user data makes it (`mkfs.ext4 -q -E nodiscard`), for each data volume
# size in GiB given on the command line. Meant to run in the ubuntu:26.04 image (the AMI's
# release, so its e2fsprogs and /etc/mke2fs.conf):
#
#   docker run --rm -u "$(id -u):$(id -g)" -v <worktree>:<worktree>:ro -v <out>:<out> \
#     ubuntu:26.04 bash <worktree>/tasks/verify-req/V-AWS/ext4_df.sh <out> 300 350 500
#
# It formats sparse files under <out> (one new directory per run) and never mounts them, so
# it brackets the df total instead of reading it:
#   lower = free blocks after mkfs (everything mkfs marked used counted as overhead), and
#   upper = block count minus the inode tables and the journal (the two metadata items that
#           the kernel always subtracts in statfs; bitmaps, descriptors and the reserved GDT
#           blocks are left in, so this is an over-estimate).
# mke2fs 1.47 also records "Overhead clusters" in the superblock, which the kernel takes as
# s_overhead when it mounts, so statfs f_blocks = block count - overhead: that is "df". The
# script checks lower <= df <= upper. Output, one line per size:
# "<GiB> <df_kB> <lower_kB> <upper_kB> <block_count> <overhead> <inode_count> <journal_blocks>".
set -u

out="${1:?usage: ext4_df.sh OUTDIR GIB...}"
shift
run="${out}/ext4-run-$$-$(date +%s)"
if [[ -e "$run" ]]; then
    echo "ext4_df.sh: $run exists" >&2
    exit 2
fi
mkdir -p "$run" || exit 2

field() {
    # field NAME FILE -- the value of "NAME:" in a dumpe2fs -h listing
    awk -F: -v k="$1" '$1 == k { v = $2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }' "$2"
}

for gib in "$@"; do
    img="${run}/vol-${gib}.img"
    info="${run}/vol-${gib}.dumpe2fs"
    truncate -s "${gib}G" "$img" || exit 2
    mkfs.ext4 -q -E nodiscard "$img" || exit 2
    dumpe2fs -h "$img" > "$info" 2> /dev/null || exit 2
    blocks="$(field 'Block count' "$info")"
    free="$(field 'Free blocks' "$info")"
    inodes="$(field 'Inode count' "$info")"
    isize="$(field 'Inode size' "$info")"
    bsize="$(field 'Block size' "$info")"
    jblocks="$(field 'Total journal blocks' "$info")"
    overhead="$(field 'Overhead clusters' "$info")"
    for v in "$blocks" "$free" "$inodes" "$isize" "$bsize" "$jblocks" "$overhead"; do
        case "$v" in
            ''|*[!0-9]*) echo "ext4_df.sh: unexpected dumpe2fs field '$v' for ${gib} GiB" >&2; exit 2 ;;
        esac
    done
    itable=$(( inodes * isize / bsize ))
    lower=$(( free * bsize / 1024 ))
    upper=$(( (blocks - itable - jblocks) * bsize / 1024 ))
    dfk=$(( (blocks - overhead) * bsize / 1024 ))
    if [[ "$dfk" -lt "$lower" || "$dfk" -gt "$upper" ]]; then
        echo "ext4_df.sh: ${gib} GiB: df ${dfk} kB outside [${lower}, ${upper}]" >&2
        exit 2
    fi
    printf '%s %s %s %s %s %s %s %s\n' "$gib" "$dfk" "$lower" "$upper" "$blocks" "$overhead" "$inodes" "$jblocks"
    rm -f "$img"
done
