#!/usr/bin/env bash
# tools/tests/source_ref_test.sh -- source builds and binary updates take release
# tags only. tn_source_checkout_tag refuses branches, commit ids and other networks'
# tags before git runs, a tag re-pointed upstream, a dirty tree without --allow-dirty
# (testnet only), and on mainnet a tag whose signature cannot be checked; it fetches a
# tag origin added. update-node.sh refuses a branch or commit ref and a downgrade
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
co_refused() {  # co_refused NAME NETWORK TAG [ALLOW_DIRTY]
    local rc=0
    : > "$T/git.log"
    tn_source_checkout_tag "$T/src" "$2" "$3" "${4:-false}" >/dev/null 2>&1 || rc=$?
    check "$1: refused, git never ran" "1 no" "$rc $(ran_git)"
}
co_refused "branch main" testnet main
co_refused "commit id" testnet 5535ef1f0425973bd81ef3162f3d07219c3456d0
co_refused "hot-patch tag" testnet v0.16.0-adiri-hotfix
co_refused "mainnet tag on testnet" testnet v0.16.0
co_refused "testnet tag on mainnet" mainnet v0.16.0-adiri
co_refused "devnet" devnet v0.16.0-adiri
co_refused "--allow-dirty on mainnet" mainnet v1.0.0 true

rc=0; out="$(update_ref_refusal main testnet)" || rc=$?
check "update_ref_refusal: a branch is refused" "0 yes" "$rc $(has "$out" 'not a testnet release tag')"
rc=0; update_ref_refusal v0.16.0-adiri testnet >/dev/null || rc=$?
check_rc "update_ref_refusal: a release tag passes" 1 "$rc"
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

# --- rustup-init pinned by sha256 ------------------------------------------------------
: > "$T/setpriv.log"
rc=0; tn_rustup_ensure >/dev/null 2>&1 || rc=$?
check_rc "rustup-init with the wrong sha256: refused" 1 "$rc"
check "rustup-init with the wrong sha256: never run" no "$(has "$(cat "$T/setpriv.log")" 'rustup-init')"
check "rustup-init download: nothing left in staging" yes "$(stg_empty)"

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
check "checkouts leave nothing in staging" yes "$(stg_empty)"

# latest_source_ref: the newest release tag that did not move; a moved tag is flagged.
latest_source_ref "$SRC" >/dev/null 2>&1
check "latest_source_ref: newest unmoved tag, moved tag flagged" "v0.18.0-adiri true" "$LATEST_SOURCE_REF $SOURCE_TAG_MOVED"

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
G -C "$W" push -q origin refs/tags/v1.1.0 refs/tags/v1.2.0 2>/dev/null
H3="$(head_of)"
co "mainnet tag signed by a release key: checked out" mainnet v1.1.0 false 0 "$(commit_of v1.1.0)"
check "good signature reported" yes "$(has "$(cat "$T/co.out")" 'good signature')"
H4="$(head_of)"
co "mainnet tag signed by another key: refused" mainnet v1.2.0 false 1 "$H4"
co "mainnet unsigned tag with a release key present: refused" mainnet v1.0.0 false 1 "$H4"
check "signature checks leave nothing in staging" yes "$(stg_empty)"
: "$H0$H3"
finish
