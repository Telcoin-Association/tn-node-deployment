#!/usr/bin/env bash
# tools/tests/source_ref_test.sh -- source builds and binary updates take release
# tags only. tn_source_checkout_tag refuses branches, commit ids and other networks'
# tags before git runs, a tag re-pointed upstream, a dirty tree without --allow-dirty
# (testnet only), and on mainnet a tag whose signature cannot be checked (a signer
# whose key is not shipped among them: _tn_tag_sig_check rc 4 naming its key id, so
# testnet builds it with a warning); it fetches a tag origin added. update-node.sh refuses a branch or commit ref and a downgrade
# (with "downgrade" and "storage_downgrade" in the --json done event) before any git.
# tn_rustup_ensure never runs a rustup-init whose sha256 is not the pinned one (curl
# shim). tn_source_build runs rustup and cargo through tn_as_build_user with an empty
# environment (setpriv shim; recording stubs in the build account's cargo bin).
# tn_stage_binary checks --version and leaves nothing behind on a refusal.
#
# A copy of update-node.sh without its last line is sourced at the top level. A local
# bare repository stands in for origin; a git wrapper drops GIT_ALLOW_PROTOCOL so the
# file transport works (the scripts allow https only). Signed-tag checks use throwaway
# GPG keys. Tools this host lacks (git, gpg) turn their cases into SKIPs.
# Maintainer tooling (not updater-tracked). bash 3.2 safe.
# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
T="$TN_TEST_TMP"
mkdir -p "$T/h" "$T/root/etc/telcoin" "$T/bin" "$T/stg" "$T/keys" "$T/bh/.cargo/bin" "$T/bsrc"
chmod 0700 "$T/stg"
grep -v '^main "\$@"$' "$TN_TEST_REPO/update-node.sh" > "$T/h/update-node.sh"
ln -s "$TN_TEST_REPO/lib" "$T/h/lib"
TN_ROOT_PREFIX="$T/root"
TN_RELEASE_STAGING_DIR="$T/stg"
TN_RELEASE_KEYS_DIR="$T/keys"
TN_BUILD_HOME="$T/bh"
tn_test_timeout_standin "$TN_BUILD_HOME/.cargo/bin"
if [[ "$(id -u)" == "0" ]]; then
    if ! id -u tnbuildtest >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin tnbuildtest >/dev/null 2>&1 || true
    fi
    TN_BUILD_USER=tnbuildtest
else
    TN_BUILD_USER="$(id -un)"
fi
export TN_RELEASE_STAGING_DIR TN_RELEASE_KEYS_DIR
tn_test_pre_common
# shellcheck source=/dev/null
source "$T/h/update-node.sh"
tn_test_post_common
META="$T/root/etc/telcoin/.node-meta"
printf 'NETWORK=testnet\n' > "$META"
SERVICE_NAME=telcoin JSON_MODE=false

REAL_GIT="$(command -v git 2>/dev/null || true)"
cat > "$T/bin/git" <<SHIM
#!/bin/sh
printf '%s\n' "\$*" >> "$T/git.log"
unset GIT_ALLOW_PROTOCOL
exec "${REAL_GIT:-/nonexistent/git}" "\$@"
SHIM
# setpriv: drop the options and run the command after --, as this account.
cat > "$T/bin/setpriv" <<SHIM
#!/bin/sh
printf '%s\n' "\$*" >> "$T/setpriv.log"
while [ \$# -gt 0 ] && [ "\$1" != "--" ]; do shift; done
shift
exec "\$@"
SHIM
# curl: write junk to the -o file (a rustup-init that is not the pinned one).
cat > "$T/bin/curl" <<SHIM
#!/bin/sh
out=""
while [ \$# -gt 0 ]; do
    if [ "\$1" = "-o" ]; then out="\$2"; shift; fi
    shift
done
[ -n "\$out" ] && printf 'not rustup-init\n' > "\$out"
printf '%s\n' "\$out" >> "$T/curl.log"
exit 0
SHIM
chmod 0755 "$T/bin/git" "$T/bin/setpriv" "$T/bin/curl"
PATH="$T/bin:$PATH"
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
ran_git() { [[ -s "$T/git.log" ]] && echo yes || echo no; }
stg_empty() { [[ -z "$(ls -A "$T/stg" 2>/dev/null)" ]] && echo yes || echo no; }

# --- refusals before git runs ----------------------------------------------------------
co_refused() {  # co_refused NAME NETWORK TAG [ALLOW_DIRTY] [RC, default 3: not a release tag]
    local rc=0
    : > "$T/git.log"
    tn_source_checkout_tag "$T/src" "$2" "$3" "${4:-false}" >/dev/null 2>&1 || rc=$?
    check "$1: refused, git never ran" "${5:-3} no" "$rc $(ran_git)"
}
co_refused "branch main" testnet main
co_refused "commit id" testnet 5535ef1f0425973bd81ef3162f3d07219c3456d0
co_refused "hot-patch tag" testnet v0.16.0-adiri-hotfix
co_refused "mainnet tag on testnet" testnet v0.16.0
co_refused "testnet tag on mainnet" mainnet v0.16.0-adiri
co_refused "devnet" devnet v0.16.0-adiri
co_refused "--allow-dirty on mainnet" mainnet v1.0.0 true 1
co_refused "a release candidate on mainnet" mainnet v1.0.0-rc1
co_refused "a testnet release candidate on mainnet" mainnet v1.0.0-adiri-rc1
co_refused "rc0 is not a release candidate" testnet v0.17.0-adiri-rc0
co_refused "rc01 is not a release candidate" testnet v0.17.0-adiri-rc01
co_refused "an rc without -adiri on testnet" testnet v0.17.0-rc1
co_refused "rc before -adiri" testnet v0.17.0-rc1-adiri

# --- the tag grammar and its order ------------------------------------------------------
tok() { local rc=0; tn_release_tag_ok "$1" "$2" || rc=$?; printf '%s' "$rc"; }
fin() { local rc=0; tn_release_tag_final "$1" "$2" || rc=$?; printf '%s' "$rc"; }
check "grammar: testnet final" 0 "$(tok testnet v0.17.0-adiri)"
check "grammar: testnet rc1" 0 "$(tok testnet v0.17.0-adiri-rc1)"
check "grammar: testnet rc12" 0 "$(tok testnet v0.17.0-adiri-rc12)"
check "grammar: testnet rc0 refused" 1 "$(tok testnet v0.17.0-adiri-rc0)"
check "grammar: testnet -rc without a number refused" 1 "$(tok testnet v0.17.0-adiri-rc)"
check "grammar: mainnet final" 0 "$(tok mainnet v1.0.0)"
check "grammar: mainnet rc refused" 1 "$(tok mainnet v1.0.0-rc1)"
check "grammar: devnet rc refused" 1 "$(tok devnet v1.0.0-adiri-rc1)"
check "final: a testnet final is one" 0 "$(fin testnet v0.17.0-adiri)"
check "final: a testnet rc is not" 1 "$(fin testnet v0.17.0-adiri-rc1)"
check "final: a mainnet final is one" 0 "$(fin mainnet v1.0.0)"
check "final: not a release tag at all" 1 "$(fin testnet main)"
newer() { local rc=0; tn_release_tag_newer "$1" "$2" || rc=$?; printf '%s' "$rc"; }
check "order: rc2 is newer than rc1" 0 "$(newer v0.17.0-adiri-rc2 v0.17.0-adiri-rc1)"
check "order: rc10 is newer than rc9" 0 "$(newer v0.17.0-adiri-rc10 v0.17.0-adiri-rc9)"
check "order: a final is newer than its rc" 0 "$(newer v0.17.0-adiri v0.17.0-adiri-rc3)"
check "order: an rc is older than its final" 1 "$(newer v0.17.0-adiri-rc3 v0.17.0-adiri)"
check "order: an rc of a higher version is newer than a lower final" 0 "$(newer v0.18.0-adiri-rc1 v0.17.9-adiri)"
check "order: 0.10.0 is newer than 0.9.0" 0 "$(newer v0.10.0-adiri v0.9.0-adiri)"
check "order: the same tag is not newer" 1 "$(newer v0.17.0-adiri v0.17.0-adiri)"
check "order: not a tag form" 2 "$(newer main v0.17.0-adiri)"
check "order: keys" "000000000 000000017 000000000 000000002|000000000 000000017 000000000 999999999" \
    "$(tn_release_tag_key v0.17.0-adiri-rc2)|$(tn_release_tag_key v0.17.0-adiri)"
check "order: a sorted list, oldest first, each once" \
    "v0.9.0-adiri v0.17.0-adiri-rc1 v0.17.0-adiri-rc2 v0.17.0-adiri-rc10 v0.17.0-adiri v0.18.0-adiri-rc1" \
    "$(printf '%s\n' v0.17.0-adiri v0.17.0-adiri-rc10 main v0.18.0-adiri-rc1 v0.9.0-adiri v0.17.0-adiri-rc2 v0.17.0-adiri-rc1 v0.17.0-adiri | tn_release_tags_sort | tr '\n' ' ' | sed 's/ $//')"

rc=0; out="$(update_ref_refusal main testnet)" || rc=$?
check "update_ref_refusal: a branch is refused" "0 yes" "$rc $(has "$out" 'not a testnet release tag')"
rc=0; update_ref_refusal v0.16.0-adiri testnet >/dev/null || rc=$?
check_rc "update_ref_refusal: a release tag passes" 1 "$rc"
rc=0; update_ref_refusal v0.17.0-adiri-rc1 testnet >/dev/null || rc=$?
check_rc "update_ref_refusal: a named testnet release candidate passes" 1 "$rc"
rc=0; out="$(update_ref_refusal v1.0.0-rc1 mainnet)" || rc=$?
check "update_ref_refusal: a mainnet release candidate is refused, naming the grammar" "0 yes" "$rc $(has "$out" 'release candidates are testnet only')"
rc=0; update_ref_refusal --help >/dev/null || rc=$?
check_rc "update_ref_refusal: a leading dash is refused" 0 "$rc"

# update-node --json prepare: refusals end before any git, with the reason.
JSON_MODE=true
json_emit() { printf '%s\n' "$1" >> "$T/json.log"; }
jprep() {  # jprep NAME FN REF
    local rc=0
    : > "$T/git.log"; : > "$T/json.log"
    "$2" "$3" >/dev/null 2>&1 || rc=$?
    check "$1: rc 1, git never ran" "1 no" "$rc $(ran_git)"
}
jprep "json source prepare of main" json_prepare_source main
check "json source prepare of main: says why" yes "$(has "$(cat "$T/json.log")" 'not a testnet release tag')"
jprep "json source prepare of a commit id" json_prepare_source 5535ef1f0425973bd81ef3162f3d07219c3456d0
jprep "json release prepare of main" json_prepare_release main
installed_source_ref() { printf 'v0.16.0-adiri\n'; }
jprep "json source prepare of an older release" json_prepare_source v0.15.0-adiri
check "downgrade across the storage floor: done event" yes \
    "$(grep -q '"ok":false,"phase":"prepare","downgrade":true,"storage_downgrade":true' "$T/json.log" && echo yes || echo no)"
JSON_MODE=false

dg() {  # dg NAME RUNNING TARGET EXPECTED-RC
    local rc=0
    update_downgrade_check "$2" "$3" >/dev/null 2>&1 || rc=$?
    check_rc "$1" "$4" "$rc"
}
dg "upgrade passes" v0.16.0-adiri v0.17.0-adiri 0
dg "same release passes" v0.16.0-adiri v0.16.0-adiri 0
dg "unknown running release passes" "" v0.1.0-adiri 0
out="$(update_downgrade_check "" v0.17.0-adiri 2>&1)"
check "unknown running release: a warning says the downgrade check cannot be made" yes \
    "$(printf '%s' "$out" | grep -q 'running release is not recorded.*cannot be checked' && echo yes || echo no)"
out="$(update_downgrade_check v0.16.0-adiri v0.17.0-adiri 2>&1)"
check "known running release: no such warning" "" "$out"
dg "older release refused" v0.17.0-adiri v0.16.0-adiri 1
dg "rc2 over rc1 passes" v0.17.0-adiri-rc1 v0.17.0-adiri-rc2 0
dg "rc10 over rc9 passes" v0.17.0-adiri-rc9 v0.17.0-adiri-rc10 0
dg "final over its rc passes" v0.17.0-adiri-rc2 v0.17.0-adiri 0
dg "rc over its final refused" v0.17.0-adiri v0.17.0-adiri-rc2 1
dg "rc1 over rc2 refused" v0.17.0-adiri-rc2 v0.17.0-adiri-rc1 1
dg "rc of a higher version over a lower final passes" v0.17.0-adiri v0.18.0-adiri-rc1 0
dg "a final below a running rc refused" v0.18.0-adiri-rc1 v0.17.0-adiri 1
dg "a running marker without a tag form compares as its final" "0.17.0" v0.17.0-adiri-rc1 1
ALLOW_DOWNGRADE=true
dg "--allow-downgrade, interactive testnet: passes" v0.17.0-adiri v0.16.0-adiri 0
printf 'NETWORK=mainnet\n' > "$META"
dg "--allow-downgrade on mainnet: refused" v1.1.0 v1.0.0 1
printf 'NETWORK=testnet\n' > "$META"
JSON_MODE=true
: > "$T/json.log"
dg "--allow-downgrade in --json: refused" v0.17.0-adiri v0.16.0-adiri 1
JSON_MODE=false
ALLOW_DOWNGRADE=false
unset -f installed_source_ref

# tn_ref_min_check judges release tags by tn_release_tag_ok: mainnet tags have no
# suffix, testnet ones end in -adiri; anything else only warns (rc 2).
mc() {  # mc NAME REF NETWORK EXPECTED-RC
    local rc=0
    tn_ref_min_check "$2" "$3" > /dev/null || rc=$?
    check_rc "$1" "$4" "$rc"
}
mc "floor: testnet release tag at the floor" v0.13.0-adiri testnet 0
mc "floor: testnet release tag below the floor" v0.12.0-adiri testnet 1
mc "floor: testnet release candidate at the floor" v0.13.0-adiri-rc1 testnet 0
mc "floor: testnet release candidate below the floor" v0.12.0-adiri-rc1 testnet 1
mc "floor: testnet hot-patch tag only warns" v0.16.0-adiri-hotfix testnet 2
mc "floor: a mainnet-form tag on testnet only warns" v0.16.0 testnet 2
mc "floor: a -telcoin tag on testnet only warns" v0.16.0-telcoin testnet 2
mc "floor: an image by its release tag" "${GAR_IMAGE_BASE}:v0.16.0-adiri" testnet 0
mc "floor: an image by digest only warns" "${GAR_IMAGE_BASE}@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" testnet 2
check "mainnet release tags carry no suffix" "" "$NETWORK_TAG_SUFFIX_MAINNET"

# --- rustup-init pinned by sha256 ------------------------------------------------------
: > "$T/setpriv.log"
rc=0; tn_rustup_ensure >/dev/null 2>&1 || rc=$?
check_rc "rustup-init with the wrong sha256: refused" 1 "$rc"
check "rustup-init with the wrong sha256: never run" no "$(has "$(cat "$T/setpriv.log")" 'rustup-init')"
check "rustup-init download: nothing left in staging" yes "$(stg_empty)"
mkdir -p "$T/stg-open"
chmod 0755 "$T/stg-open"
rc=0; TN_RELEASE_STAGING_DIR="$T/stg-open" tn_rustup_ensure > /dev/null 2> "$T/err" || rc=$?
check "rustup-init: an unusable staging directory is refused with the reason" "1 yes" \
    "$rc $(grep -q 'staging directory.*not a root-owned 0700 directory' "$T/err" && echo yes || echo no)"

# --- the build runs as the build account with an empty environment ---------------------
if id -u "$TN_BUILD_USER" >/dev/null 2>&1 && [[ "$(id -u "$TN_BUILD_USER")" != "0" ]]; then
    for s in rustup cargo; do
        cat > "$T/bh/.cargo/bin/$s" <<STUB
#!/bin/sh
printf '%s\n' "\$*" > "\$HOME/$s.argv"
env > "\$HOME/$s.env"
exit 0
STUB
        chmod 0755 "$T/bh/.cargo/bin/$s"
    done
    printf '[toolchain]\nchannel = "1.94"\n' > "$T/bsrc/rust-toolchain.toml"
    export TN_BLS_PASSPHRASE=leak TN_SECRET_TEST=1
    rc=0; tn_source_build "$T/bsrc" testnet >/dev/null 2>&1 || rc=$?
    unset TN_BLS_PASSPHRASE TN_SECRET_TEST
    check_rc "testnet build: rc 0" 0 "$rc"
    check "toolchain from rust-toolchain.toml" "toolchain install --profile minimal 1.94" "$(cat "$T/bh/rustup.argv" 2>/dev/null)"
    check "cargo: locked release build with adiri" "build --release --locked -p telcoin-network --bin telcoin-network --features adiri" "$(cat "$T/bh/cargo.argv" 2>/dev/null)"
    check_has "cargo env: HOME is the build home" "HOME=$T/bh" "$(cat "$T/bh/cargo.env" 2>/dev/null)"
    check_has "cargo env: its own target dir" "CARGO_TARGET_DIR=$T/bh/target" "$(cat "$T/bh/cargo.env" 2>/dev/null)"
    check "cargo env: nothing of the caller's TN_* variables" no "$(grep -q '^TN_' "$T/bh/cargo.env" 2>/dev/null && echo yes || echo no)"
    check "cargo env: no TN_BLS_PASSPHRASE" no "$(grep -q 'TN_BLS' "$T/bh/cargo.env" 2>/dev/null && echo yes || echo no)"
    rm -f "$T/bh/cargo.argv"
    rc=0; tn_source_build "$T/bsrc" mainnet >/dev/null 2>&1 || rc=$?
    check "mainnet build: no features" "0 build --release --locked -p telcoin-network --bin telcoin-network" "$rc $(cat "$T/bh/cargo.argv" 2>/dev/null)"
    rm -f "$T/bh/cargo.argv"
    printf '[toolchain]\nchannel = "-x"\n' > "$T/bsrc/rust-toolchain.toml"
    rc=0; tn_source_build "$T/bsrc" testnet >/dev/null 2>&1 || rc=$?
    check "a toolchain name like an option: refused, cargo never ran" "1 no" "$rc $([[ -e "$T/bh/cargo.argv" ]] && echo yes || echo no)"
    rc=0; tn_source_build "$T/bsrc" devnet >/dev/null 2>&1 || rc=$?
    check_rc "devnet: no source build" 1 "$rc"

    # tn_stage_binary: --version runs as the build account; a mainnet check of an adiri
    # build refuses and leaves staging empty.
    printf '#!/bin/sh\nprintf "telcoin-network-cli Version: 0.1.0\\nBuild Features: adiri\\n"\n' > "$T/built"
    chmod 0755 "$T/built"
    rc=0; staged="$(tn_stage_binary "$T/built" testnet "" 2>/dev/null)" || rc=$?
    check "stage: testnet adiri build staged" "0 yes" "$rc $(has "$staged" "$T/stg/bin.")"
    check "stage: version kept beside it" "Build Features: adiri" "$(tail -n 1 "${staged%/*}/version" 2>/dev/null)"
    tn_staged_cleanup "$staged"
    check "stage: tn_staged_cleanup empties staging" yes "$(stg_empty)"
    rc=0; tn_stage_binary "$T/built" mainnet "" >/dev/null 2>&1 || rc=$?
    check "stage: adiri build refused on mainnet, staging empty" "1 yes" "$rc $(stg_empty)"
    rc=0; tn_stage_binary "$T/built" testnet v0.17.0-adiri >/dev/null 2>&1 || rc=$?
    check "stage: release whose --version names another version refused" "1 yes" "$rc $(stg_empty)"
else
    skip "build account environment" "no non-root build account on this host"
fi

# --- checkouts against a local origin --------------------------------------------------
if [[ -z "$REAL_GIT" ]]; then
    skip "source checkouts" "git absent"
    finish
fi
O="$T/origin.git"; W="$T/work"; SRC="$T/src"
G() { "$REAL_GIT" -c user.email=t@example.invalid -c user.name=t -c advice.detachedHead=false "$@"; }
G init -q --bare "$O"
G clone -q "$O" "$W" 2>/dev/null
printf 'one\n' > "$W/f"; G -C "$W" add f; G -C "$W" commit -qm one
G -C "$W" tag -a v0.16.0-adiri -m r16
printf 'two\n' > "$W/f"; G -C "$W" commit -qam two
G -C "$W" tag -a v0.17.0-adiri -m r17
G -C "$W" tag -a v1.0.0 -m m1
G -C "$W" push -q origin HEAD:refs/heads/main --tags 2>/dev/null
G --git-dir="$O" symbolic-ref HEAD refs/heads/main
G clone -q "$O" "$SRC" 2>/dev/null
head_of() { G -C "$SRC" rev-parse HEAD 2>/dev/null; }
commit_of() { G -C "$W" rev-parse "$1^{commit}" 2>/dev/null; }

co() {  # co NAME NETWORK TAG ALLOW_DIRTY EXPECTED-RC EXPECTED-HEAD
    local rc=0
    tn_source_checkout_tag "$SRC" "$2" "$3" "$4" > "$T/co.out" 2>&1 || rc=$?
    check "$1" "$5 $6" "$rc $(head_of)"
}
H0="$(head_of)"
co "testnet tag, no release key: checked out with a warning" testnet v0.16.0-adiri false 0 "$(commit_of v0.16.0-adiri)"
check "no release key: the warning says so" yes "$(has "$(cat "$T/co.out")" 'not verified')"
H1="$(head_of)"
co "mainnet tag, no release key: refused" mainnet v1.0.0 false 1 "$H1"
printf 'x\n' > "$SRC/untracked"
co "untracked file: refused" testnet v0.17.0-adiri false 1 "$H1"
check "untracked file: kept" yes "$([[ -e "$SRC/untracked" ]] && echo yes || echo no)"
co "untracked file, --allow-dirty: discarded and checked out" testnet v0.17.0-adiri true 0 "$(commit_of v0.17.0-adiri)"
check "--allow-dirty: the file is gone" no "$([[ -e "$SRC/untracked" ]] && echo yes || echo no)"
# origin re-points v0.17.0-adiri; the checkout's own tag stays where it was.
G -C "$W" tag -f -a v0.17.0-adiri -m moved v0.16.0-adiri^{commit} >/dev/null 2>&1
G -C "$W" push -q -f origin refs/tags/v0.17.0-adiri 2>/dev/null
G -C "$SRC" checkout -q --detach v0.16.0-adiri 2>/dev/null
H2="$(head_of)"
co "tag re-pointed upstream: refused" testnet v0.17.0-adiri false 1 "$H2"
check "re-pointed: the message names it" yes "$(has "$(cat "$T/co.out")" 're-pointed upstream')"
check "re-pointed: local tag not moved" "$(G -C "$SRC" rev-parse 'refs/tags/v0.17.0-adiri^{commit}')" "$(G -C "$SRC" rev-parse 'refs/remotes/origin/main')"
# A tag origin added after the clone is fetched.
printf 'three\n' > "$W/f"; G -C "$W" commit -qam three
G -C "$W" tag -a v0.18.0-adiri -m r18
G -C "$W" push -q origin HEAD:refs/heads/main refs/tags/v0.18.0-adiri 2>/dev/null
co "new tag on origin: fetched and checked out" testnet v0.18.0-adiri false 0 "$(commit_of v0.18.0-adiri)"
# A release candidate newer than every final: checked out when named.
printf 'four\n' > "$W/f"; G -C "$W" commit -qam four
G -C "$W" tag -a v0.19.0-adiri-rc1 -m r19rc1
G -C "$W" push -q origin HEAD:refs/heads/main refs/tags/v0.19.0-adiri-rc1 2>/dev/null
co "a named release candidate: checked out" testnet v0.19.0-adiri-rc1 false 0 "$(commit_of v0.19.0-adiri-rc1)"
check "checkouts leave nothing in staging" yes "$(stg_empty)"

# latest_source_ref: the newest final release tag that did not move (a newer
# release candidate is not offered); a moved tag is flagged.
latest_source_ref "$SRC" >/dev/null 2>&1
check "latest_source_ref: newest unmoved tag, moved tag flagged" "v0.18.0-adiri true" "$LATEST_SOURCE_REF $SOURCE_TAG_MOVED"

# --- the source picker offers release tags only ---------------------------------------
P="$T/pick"
G init -q "$P"
printf 'p\n' > "$P/f"; G -C "$P" add f; G -C "$P" commit -qm p
for t in v0.12.0-adiri v0.16.0-adiri v0.17.0-adiri-rc1 v0.17.0-adiri v0.18.0-adiri-hotfix v0.18.0-adiri-rc2 v1.0.0 v1.1.0-telcoin v2.0.0-rc1; do
    G -C "$P" tag "$t"
done
G -C "$P" branch feature 2>/dev/null
pick() {  # pick NETWORK INPUT -> "<rc> <answer>"
    local rc=0 o
    o="$(printf '%b' "$2" | pick_source_version "$1" "$P" 2>"$T/pick.err")" || rc=$?
    printf '%s %s' "$rc" "$o"
}
check "picker, testnet default: the newest testnet release" "0 v0.17.0-adiri" "$(pick testnet '\n')"
check_lacks "picker: main is not offered" "main (latest" "$(cat "$T/pick.err")"
check_lacks "picker: no branch or commit option" "branch / tag / commit" "$(cat "$T/pick.err")"
check "picker, mainnet default: the newest vX.Y.Z tag (no suffix)" "0 v1.0.0" "$(pick mainnet '\n')"
check "picker, another release tag typed" "0 v0.16.0-adiri" "$(pick testnet '2\nv0.16.0-adiri\n')"
check "picker, a newer release candidate is not the default" "0 v0.17.0-adiri" "$(pick testnet '\n')"
check "picker, a release candidate typed on testnet" "0 v0.18.0-adiri-rc2" "$(pick testnet '2\nv0.18.0-adiri-rc2\n')"
check "picker, a release candidate typed on mainnet: refused" "1 " "$(pick mainnet '2\nv2.0.0-rc1\n')"
check "picker, main typed: refused" "1 " "$(pick testnet '2\nmain\n')"
check "picker, a branch typed: refused" "1 " "$(pick testnet '2\nfeature\n')"
check "picker, a mainnet tag typed on testnet: refused" "1 " "$(pick testnet '2\nv1.0.0\n')"
check "picker, cancel" "1 " "$(pick testnet '3\n')"
check "picker, devnet: no source releases" "1 " "$(pick devnet '\n')"

# --- signed tags (throwaway keys) ------------------------------------------------------
if ! command -v gpg >/dev/null 2>&1; then
    skip "signed tags" "gpg absent"
    finish
fi
GH="$T/gnupg"
mkdir -m 0700 "$GH"
K() { GNUPGHOME="$GH" gpg --batch --no-tty --quiet --pinentry-mode loopback --passphrase '' "$@"; }
K --quick-gen-key 'Release A <a@example.invalid>' ed25519 sign 1y 2>/dev/null
K --quick-gen-key 'Other B <b@example.invalid>' ed25519 sign 1y 2>/dev/null
FA="$(K --with-colons --list-keys a@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
FB="$(K --with-colons --list-keys b@example.invalid 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')"
if [[ -z "$FA" || -z "$FB" ]]; then
    skip "signed tags" "gpg could not make the throwaway keys"
    finish
fi
K --armor --export "$FA" > "$T/keys/a.asc"
GNUPGHOME="$GH" G -C "$W" -c gpg.program=gpg -c "user.signingkey=$FA" tag -s v1.1.0 -m signed-a 2>/dev/null
GNUPGHOME="$GH" G -C "$W" -c gpg.program=gpg -c "user.signingkey=$FB" tag -s v1.2.0 -m signed-b 2>/dev/null
GNUPGHOME="$GH" G -C "$W" -c gpg.program=gpg -c "user.signingkey=$FB" tag -s v0.21.0-adiri -m signed-b 2>/dev/null
G -C "$W" push -q origin refs/tags/v1.1.0 refs/tags/v1.2.0 refs/tags/v0.21.0-adiri 2>/dev/null
IDB="${FB#????????????????????????}"
H3="$(head_of)"
co "mainnet tag signed by a release key: checked out" mainnet v1.1.0 false 0 "$(commit_of v1.1.0)"
check "good signature reported" yes "$(has "$(cat "$T/co.out")" 'good signature')"
H4="$(head_of)"
co "mainnet tag signed by another key: refused" mainnet v1.2.0 false 1 "$H4"
check "mainnet, another key: cannot be verified, the key named" yes \
    "$(has "$(cat "$T/co.out")" "Tag v1.2.0 cannot be verified: the tag is signed by key ${IDB}, which is not in")"
rc=0; out="$(_tn_tag_sig_check "$SRC" v1.2.0)" || rc=$?
check "tag by a key that is not shipped: rc 4 (cannot be told), its key id named" \
    "4 the tag is signed by key ${IDB}, which is not in ${T}/keys" "$rc $out"
co "testnet tag signed by a key that is not shipped: checked out with a warning" testnet v0.21.0-adiri false 0 "$(commit_of v0.21.0-adiri)"
check "testnet, another key: the warning names the key" yes \
    "$(has "$(cat "$T/co.out")" "Tag v0.21.0-adiri is not verified (the tag is signed by key ${IDB}, which is not in")"
H4="$(head_of)"
co "mainnet unsigned tag with a release key present: refused" mainnet v1.0.0 false 1 "$H4"
check "signature checks leave nothing in staging" yes "$(stg_empty)"
: "$H0$H3"
finish
