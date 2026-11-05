#!/usr/bin/env bash
# Check 1: ./etc/release.sh parse TAG (no git, no network) for the four release tag shapes and
# the refused ones; IMAGE comes from init_env through drive.sh init (default environment).
set -u
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
parse() { (cd "$TN" && ./etc/release.sh parse "$1"); }
field() { sed -n "s/^$2=//p" "$OUT/$1.txt" | head -n 1; }

ok_tag() {
    local tag=$1 ch=$2 pkg=$3 alias=$4 pre=$5 feat=$6 n="parse-$1"
    expect "$n" 0 "CHANNEL=$ch" -- parse "$tag"
    expect "$n-pkg" 0 "PACKAGE=$pkg" -- parse "$tag"
    expect "$n-alias" 0 "ALIAS=$alias" -- parse "$tag"
    expect "$n-pre" 0 "PRERELEASE=$pre" -- parse "$tag"
    expect "$n-feat" 0 "FEATURES=$feat" -- parse "$tag"
    expect "init-$tag" 0 "IMAGE=ghcr.io/telcoin-association/$pkg " -- env -u RELEASE_REPO -u GITHUB_ACTIONS bash "$V8_DIR/drive.sh" init "$tag"
    printf '| `%s` | 0 | %s | %s | %s | %s | %s | %s |\n' "$tag" "$(field "$n" CHANNEL)" "$(field "$n" PACKAGE)" \
        "$(sed -n 's/.*IMAGE=\([^ ]*\).*/\1/p' "$OUT/init-$tag.txt")" "$(field "$n" ALIAS)" \
        "$(field "$n" PRERELEASE)" "$(field "$n" FEATURES)" >>"$OUT/matrix.md"
}
bad_tag() {
    local tag=$1 n
    n="parse-bad-$(printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_')"
    expect "$n" 2 "not a release tag" "PACKAGE=" -- parse "$tag"
    printf '| `%s` | 2 | refused: %s |||||\n' "$(printf '%s' "$tag" | tr '\n' '|')" "$(show "$n" | cut -c1-60)" >>"$OUT/matrix.md"
}

printf '| tag | rc | CHANNEL | PACKAGE | IMAGE | ALIAS | PRERELEASE | FEATURES |\n|---|---|---|---|---|---|---|---|\n' >"$OUT/matrix.md"
ok_tag v0.1.0 mainnet tn-mainnet latest false ""
ok_tag v0.1.0-rc1 mainnet tn-mainnet "" true ""
ok_tag v0.17.0-adiri adiri tn-testnet adiri true adiri
ok_tag v0.17.0-adiri-rc2 adiri tn-testnet "" true adiri
# rc-less mainnet ALIAS check must be exact: "ALIAS=" alone on the rc lines.
expect parse-rc1-alias-empty 0 "" "ALIAS=latest" -- parse v0.1.0-rc1
expect parse-adiri-rc2-alias-empty 0 "" "ALIAS=adiri" -- parse v0.17.0-adiri-rc2
for t in v0.1.0-mainnet v0.1.0-adiri-adiri V0.1.0 v01.0.0 v0.1.0-rc0 v0.1.0-rc1-adiri v0.1.0-testnet \
    "v0.1.0 " "$(printf 'v0.1.0\nx')" v0.1 ""; do
    bad_tag "$t"
done
cat "$OUT/matrix.md"
summary t1_matrix
