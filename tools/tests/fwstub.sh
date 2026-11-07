#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tools/tests/fwstub.sh -- PATH stubs for the firewall and sshd fixture tests.
#
#   fw_stub_install BIN_DIR    write ufw, sshd, systemctl, nft and tn-p2p-allow-sync
#                              stubs into BIN_DIR
#
# ufw keeps its state in files under $TN_ROOT_PREFIX, like the real one:
# etc/ufw/user.rules (one normalized rule per line), etc/ufw/ufw.conf
# (ENABLED=yes|no) and etc/default/ufw (DEFAULT_INPUT_POLICY). Every call is
# appended to $UFW_LOG. UFW_FAIL_AT=N makes call N fail; UFW_FAIL_FROM=N makes
# every call from N on fail. `status` prints a ufw-like table.
#
# sshd: `-t` exits $SSHD_T_RC (default 0); `-T` prints the effective value of
# every keyword the fixture sets, first value wins, reading
# etc/ssh/sshd_config.d/*.conf in name order and then etc/ssh/sshd_config, the
# way sshd does when sshd_config starts with the Include line. $SSHD_PORT_LINE
# replaces the "port 22" line. systemctl appends to $SYSTEMCTL_LOG; with
# TN_ROOT_PREFIX set it also keeps the enabled units in
# $TN_ROOT_PREFIX/.systemctl.enabled (`enable U`, `disable [--now] U`), and
# `is-enabled U` answers from it (rc 0 "enabled", rc 1 "disabled"). `show ...`
# prints $SYSTEMCTL_SHOW as it is, whatever unit and properties it names
# (nothing when it is unset or empty).
#
# nft keeps table inet tn_p2p in $TN_ROOT_PREFIX/.nft.table (the table block of
# the last program it applied; absent when there is no table) and table inet
# tn_p2p_allow in $TN_ROOT_PREFIX/.nft.allow (below). Every call appends
# "nft ARGV" to $NFT_LOG (default /dev/null) and, for -f, the program read, each
# line prefixed with "| ". `-f -` or `-f FILE` applies the program as one
# transaction: a program holding `table inet tn_p2p {` leaves exactly that block,
# one that only deletes the table leaves none, and the state file is replaced in
# one rename. `-c` checks only. NFT_FAIL=1 makes every write fail with nothing
# changed; NFT_LIST_FAIL=1 makes `list` fail. NFT_HOLD=1 makes a write wait,
# after reading the program and before applying it, until
# $TN_ROOT_PREFIX/.nft.release exists (it writes its pid to .nft.held first).
# `list tables [FAMILY]` prints `table ip filter` and each table present;
# `list table inet tn_p2p` prints the block, or fails as nft does when it is
# absent.
#
# A program that names table inet tn_p2p_allow is applied to it statement by
# statement, as nft does: `table inet tn_p2p_allow { ... }` declares sets (type
# ipv4_addr or ipv6_addr, optionally flags interval), named counters and chains
# with their rules (udp or tcp dport or sport, ip or ip6 saddr or daddr,
# counter, accept, drop); `flush table` drops every rule; `flush set`,
# `add element` and `delete element` change one set; `delete table` drops the
# table. An argv command that names inet tn_p2p_allow, such as
# `nft delete table inet tn_p2p_allow`, is that program on one line (the stub
# takes no other argv write). As in nft, a missing table, set or element, a CIDR
# in a set without flags interval or an address of the other family fails the
# whole transaction with nothing changed, and `-c` checks a program against the
# table without changing it; syntax the stub does not model fails with
# "nft stub: unsupported", and layout is not checked (nft also wants a newline
# or `;` after a nested block's closing brace). Overlapping intervals in one
# set are not modelled either: the stub keeps both elements where nft refuses
# the transaction ("conflicting intervals specified"). .nft.allow holds one
# tab-separated record per line:
# `table inet tn_p2p_allow`, `counter NAME`, `set NAME TYPE FLAGS`,
# `elem SET VALUE JSON`, `chain NAME TYPE HOOK PRIO POLICY`, `rule CHAIN TEXT
# JSON`; a full-length prefix is kept as the plain address, IPv6 in lower case.
# `list table inet tn_p2p_allow`, `list set inet tn_p2p_allow SET`,
# `list counter inet tn_p2p_allow NAME` and `list counters` print what nft
# 1.0.9 prints, except that a set lists its elements on one line and in the
# order they were added (nft sorts an interval set). With -j they print nft's
# JSON on one line, {"nftables": [metainfo, ...]}: the table, its counters
# (packets and bytes 0), its sets (elem: a string per address,
# {"prefix": {"addr": A, "len": N}} per CIDR), its chains, then their rules.
# `-j list tables [FAMILY]` lists the tables the same way. A missing table, set
# or counter fails as nft does.
#
# tn-p2p-allow-sync is a #!/bin/sh stand-in for the P2P committee allowlist sync
# tool; copy it to TN_P2P_ALLOW_BIN, or into a release tarball, to run it there.
# With REC set, every call writes its arguments one per line to $REC.argv, its
# environment to $REC.env and, with TN_P2P_STUB_STDIN=1, its standard input to
# $REC.stdin (else that file is left empty and nothing is read), replacing what
# the last call wrote, and appends its arguments on one line to $REC.log.
# Without REC only --version runs; anything else exits 2. --version prints the
# five lines of a release (tn-p2p-allow-sync $TN_P2P_STUB_VERSION, default 0.1.0,
# then commit, target, snapshot-versions 1, config-version 1), or
# $TN_P2P_STUB_VERSION_TEXT whenever that is set, and exits
# $TN_P2P_STUB_RC_VERSION (default 0). Every other call is keyed by its command:
# SYNC, CHECK, STATUS, STATUS_JSON (status --json), RENDER or CAPTURE_FLOOR; an
# unknown or missing command exits $TN_P2P_STUB_RC_USAGE (default 2). It prints
# $TN_P2P_STUB_OUT_<KEY> when that is set, else $TN_P2P_STUB_OUT, on stdout
# (nothing when empty), and exits $TN_P2P_STUB_RC_<KEY>, else $TN_P2P_STUB_RC,
# else 0. A sync that exits neither 1 (refused) nor 4 (busy) writes
# $TN_P2P_STUB_STATUS, when set, as the status file of --state-dir (default
# $TN_ROOT_PREFIX/var/lib/telcoin-p2p-allow), and exits 2 when that directory is
# missing, as the tool does.
# Not updater-tracked. bash 3.2 safe.
# =============================================================================

fw_stub_install() {
    local bin="$1"
    mkdir -p "$bin"
    cat > "$bin/ufw" <<'STUB'
#!/usr/bin/env bash
R="${TN_ROOT_PREFIX:?}"
n=0
[ -f "$R/.ufw.n" ] && n="$(cat "$R/.ufw.n")"
n=$((n + 1))
echo "$n" > "$R/.ufw.n"
printf '%s\n' "$*" >> "${UFW_LOG:?}"
if [ -n "${UFW_FAIL_AT:-}" ] && [ "$n" -eq "$UFW_FAIL_AT" ]; then exit 1; fi
if [ -n "${UFW_FAIL_FROM:-}" ] && [ "$n" -ge "$UFW_FAIL_FROM" ]; then exit 1; fi
mkdir -p "$R/etc/ufw" "$R/etc/default"
rules="$R/etc/ufw/user.rules"
touch "$rules"
case "$*" in
    status*)
        if grep -q '^ENABLED=yes' "$R/etc/ufw/ufw.conf" 2>/dev/null; then
            echo "Status: active"
            echo ""
            while IFS= read -r r; do
                case "$r" in
                    "allow from "*)
                        set -- $r
                        printf '%s/%s ALLOW %s\n' "$7" "$9" "$3" ;;
                    "allow "*) printf '%s ALLOW Anywhere\n' "${r#allow }" ;;
                esac
            done < "$rules"
        else
            echo "Status: inactive"
        fi ;;
    "--force reset") : > "$rules"; echo "ENABLED=no" > "$R/etc/ufw/ufw.conf" ;;
    "--force enable") echo "ENABLED=yes" > "$R/etc/ufw/ufw.conf" ;;
    "--force disable"|disable) echo "ENABLED=no" > "$R/etc/ufw/ufw.conf" ;;
    "default deny incoming") echo 'DEFAULT_INPUT_POLICY="DROP"' > "$R/etc/default/ufw" ;;
    "default allow outgoing") : ;;
    "delete "*)
        # ${*#...} would strip each word, not the joined line: join first.
        r="$*"
        r="${r#delete }"
        grep -vxF -- "$r" "$rules" > "$rules.tmp"; mv "$rules.tmp" "$rules" ;;
    allow*|limit*)
        grep -qxF -- "$*" "$rules" || printf '%s\n' "$*" >> "$rules" ;;
esac
exit 0
STUB
    cat > "$bin/sshd" <<'STUB'
#!/usr/bin/env bash
R="${TN_ROOT_PREFIX:?}"
case "$1" in
    -t) exit "${SSHD_T_RC:-0}" ;;
    -T)
        echo "${SSHD_PORT_LINE:-port 22}"
        files=""
        for f in "$R"/etc/ssh/sshd_config.d/*.conf; do [ -f "$f" ] && files="$files $f"; done
        # shellcheck disable=SC2086
        cat $files "$R/etc/ssh/sshd_config" 2>/dev/null \
            | awk 'NF >= 2 && $1 !~ /^#/ && tolower($1) != "include" && tolower($1) != "port" {
                       k = tolower($1); if (!(k in seen)) { seen[k] = 1; print k, $2 } }'
        ;;
esac
exit 0
STUB
    cat > "$bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG:-/dev/null}"
if [ "${1:-}" = show ]; then
    [ -z "${SYSTEMCTL_SHOW:-}" ] || printf '%s\n' "$SYSTEMCTL_SHOW"
    exit 0
fi
[ -n "${TN_ROOT_PREFIX:-}" ] || exit 0
en="$TN_ROOT_PREFIX/.systemctl.enabled"
case "${1:-}" in
    enable)
        shift
        for u in "$@"; do
            grep -qxF -- "$u" "$en" 2>/dev/null || printf '%s\n' "$u" >> "$en"
        done ;;
    disable)
        shift
        [ "${1:-}" = --now ] && shift
        for u in "$@"; do
            if [ -f "$en" ]; then grep -vxF -- "$u" "$en" > "$en.tmp"; mv "$en.tmp" "$en"; fi
        done ;;
    is-enabled)
        shift
        [ "${1:-}" = --quiet ] && shift
        if grep -qxF -- "${1:-}" "$en" 2>/dev/null; then echo enabled; exit 0; fi
        echo disabled
        exit 1 ;;
esac
exit 0
STUB
    cat > "$bin/nft" <<'STUB'
#!/usr/bin/env bash
R="${TN_ROOT_PREFIX:?}"
log="${NFT_LOG:-/dev/null}"
st="$R/.nft.table"
sa="$R/.nft.allow"
printf 'nft %s\n' "$*" >> "$log"
meta='{"metainfo": {"version": "1.0.9", "release_name": "Old Doc Yak #3", "json_schema_version": 1}}'
# the program (the input file) applied to the records in $old: the new records
# on stdout, none when the table is gone; rc 1 and nothing printed when nft
# would refuse the transaction.
apply_awk='
function fail(m) { print m > "/dev/stderr"; failed = 1; exit 1 }
function missing() { fail("Error: Could not process rule: No such file or directory") }
function nosuch() { fail("Error: No such file or directory") }
function lex(s,    i, c, w, j) {
    i = 1
    while (i <= length(s)) {
        c = substr(s, i, 1)
        if (c == " " || c == "\t" || c == "\r") { i++; continue }
        if (c == "#") break
        if (c == "{" || c == "}" || c == ";" || c == ",") { tk[++n] = c; i++; continue }
        if (c == "\"") {
            j = index(substr(s, i + 1), "\"")
            if (!j) fail("Error: syntax error, unterminated string")
            tk[++n] = substr(s, i, j + 1)
            i += j + 1
            continue
        }
        w = ""
        while (i <= length(s) && !index(" \t\r{};,#\"", substr(s, i, 1))) { w = w substr(s, i, 1); i++ }
        tk[++n] = w
    }
    tk[++n] = "\n"
}
function sep() { while (p <= n && (tk[p] == "\n" || tk[p] == ";")) p++ }
function word(   w) {
    w = tk[p]
    if (p > n || w == "\n" || w == ";" || w == "{" || w == "}" || w == ",")
        fail("Error: syntax error, unexpected " ((p > n || w == "\n") ? "end of line" : w))
    p++
    return w
}
function expect(w) {
    if (p > n || tk[p] != w) fail("Error: syntax error, expected " w)
    p++
}
function ours(f, t) { return f == "inet" && t == "tn_p2p_allow" }
# a statement for another table: skip it, its blocks included
function skip(   d) {
    for (d = 0; p <= n; p++) {
        if (tk[p] == "{") d++
        else if (tk[p] == "}") d--
        else if (!d && (tk[p] == "\n" || tk[p] == ";")) return
    }
}
function findset(s,   i) {
    for (i = 1; i <= ns; i++) if (sn[i] == s) return i
    return 0
}
function findctr(c,   i) {
    for (i = 1; i <= nc; i++) if (cn[i] == c) return i
    return 0
}
function findchain(c,   i) {
    for (i = 1; i <= nh; i++) if (hn[i] == c) return i
    return 0
}
function findelem(s, v,   k) {
    for (k = 1; k <= ne; k++) if (!ed[k] && es[k] == s && et[k] == v) return k
    return 0
}
# nft compares addresses, not text: a full-length prefix is the address itself
function addr(v, full,   k, b) {
    v = tolower(v)
    if (full == 32 && v !~ /^[0-9.]+(\/[0-9]+)?$/) fail(FAMILY)
    if (full == 128 && (!index(v, ":") || v !~ /^[0-9a-f:.]+(\/[0-9]+)?$/)) fail(FAMILY)
    k = index(v, "/")
    if (!k) return v
    b = substr(v, k + 1) + 0
    if (b > full) fail("Error: prefix length " b " is out of range")
    if (b == full) return substr(v, 1, k - 1)
    return substr(v, 1, k - 1) "/" b
}
function val(v, full) {
    if (v == "" || v == "\n" || v == ";" || v == "{" || v == "}" || v == ",") fail("Error: syntax error, a value is missing")
    if (substr(v, 1, 1) == "@") return v
    if (full) return addr(v, full)
    if (v !~ /^[0-9]+$/) fail("nft stub: unsupported value " v)
    return v + 0
}
function vjson(v,   k) {
    if (v ~ /^[0-9]+$/) return v
    k = index(v, "/")
    if (k) return "{\"prefix\": {\"addr\": \"" substr(v, 1, k - 1) "\", \"len\": " substr(v, k + 1) "}}"
    return "\"" v "\""
}
function rule(c,   i, t, f, full, nv, v, vt, vj, tx, js, d, rn) {
    rn = 0
    d = 0
    while (p <= n) {
        t = tk[p]
        if (!d && (t == "\n" || t == ";" || t == "}")) break
        if (t == "{") d++
        else if (t == "}") d--
        if (t != "\n") rw[++rn] = t
        p++
    }
    rw[rn + 1] = ""; rw[rn + 2] = ""; rw[rn + 3] = ""
    tx = ""; js = ""; i = 1
    while (i <= rn) {
        t = rw[i]
        if (t == "udp" || t == "tcp" || t == "ip" || t == "ip6") {
            f = rw[i + 1]
            full = 0
            if (t == "ip") full = 32
            if (t == "ip6") full = 128
            if (full && f != "saddr" && f != "daddr") fail("nft stub: unsupported match " t " " f)
            if (!full && f != "dport" && f != "sport") fail("nft stub: unsupported match " t " " f)
            i += 2
            nv = 0; vt = ""; vj = ""
            if (rw[i] == "{") {
                for (i++; i <= rn && rw[i] != "}"; i++) {
                    if (rw[i] == ",") continue
                    v = val(rw[i], full)
                    nv++
                    vt = vt (nv > 1 ? ", " : "") v
                    vj = vj (nv > 1 ? ", " : "") vjson(v)
                }
                if (rw[i] != "}" || !nv) fail("Error: syntax error, bad anonymous set")
                i++
                # nft lists a one-element anonymous set as the value itself
                if (nv > 1) { vt = "{ " vt " }"; vj = "{\"set\": [" vj "]}" }
            } else {
                v = val(rw[i], full)
                i++
                vt = v; vj = vjson(v)
            }
            tx = tx (tx == "" ? "" : " ") t " " f " " vt
            js = js (js == "" ? "" : ", ") "{\"match\": {\"op\": \"==\", \"left\": {\"payload\": {\"protocol\": \"" t "\", \"field\": \"" f "\"}}, \"right\": " vj "}}"
        } else if (t == "counter" && rw[i + 1] == "name") {
            v = rw[i + 2]
            gsub(/"/, "", v)
            if (v == "") fail("Error: syntax error, a counter name is missing")
            tx = tx (tx == "" ? "" : " ") "counter name \"" v "\""
            js = js (js == "" ? "" : ", ") "{\"counter\": \"" v "\"}"
            i += 3
        } else if (t == "counter") {
            tx = tx (tx == "" ? "" : " ") "counter packets 0 bytes 0"
            js = js (js == "" ? "" : ", ") "{\"counter\": {\"packets\": 0, \"bytes\": 0}}"
            i++
        } else if (t == "accept" || t == "drop") {
            tx = tx (tx == "" ? "" : " ") t
            js = js (js == "" ? "" : ", ") "{\"" t "\": null}"
            i++
        } else fail("nft stub: unsupported in a rule: " t)
    }
    rc[++nr] = c; rt[nr] = tx; rj[nr] = js
}
function setdecl(s,   k, ty, fl, i) {
    expect("{")
    ty = ""; fl = ""
    while (1) {
        sep()
        if (p > n) fail("Error: syntax error, unterminated set block")
        k = tk[p++]
        if (k == "}") break
        if (k == "type") ty = word()
        else if (k == "flags") {
            fl = word()
            while (tk[p] == ",") { p++; fl = fl "," word() }
        } else fail("nft stub: unsupported in set " s ": " k)
    }
    if (ty != "ipv4_addr" && ty != "ipv6_addr") fail("nft stub: unsupported set type " ty)
    if (fl != "" && fl != "interval") fail("nft stub: unsupported set flags " fl)
    i = findset(s)
    if (!i) { sn[++ns] = s; sy[ns] = ty; sf[ns] = fl }
    else if (sy[i] != ty || sf[i] != fl) fail("Error: Could not process rule: File exists")
}
function ctrdecl(c) {
    if (tk[p] == "{") {
        for (p++; p <= n && tk[p] != "}"; p++) continue
        if (p > n) fail("Error: syntax error, unterminated counter block")
        p++
    }
    if (!findctr(c)) cn[++nc] = c
}
function chaindecl(c,   i, k, ty, hook, pr) {
    expect("{")
    i = findchain(c)
    if (!i) { i = ++nh; hn[i] = c; hy[i] = ""; hk[i] = ""; hp[i] = ""; hq[i] = "" }
    while (1) {
        sep()
        if (p > n) fail("Error: syntax error, unterminated chain block")
        k = tk[p]
        if (k == "}") { p++; return }
        if (k == "type") {
            p++
            ty = word(); expect("hook"); hook = word(); expect("priority"); pr = word()
            if (pr !~ /^-?[0-9]+$/) fail("nft stub: unsupported priority " pr)
            if (hy[i] != "" && (hy[i] != ty || hk[i] != hook || hp[i] != pr)) fail("Error: Chain of type \"" ty "\" is not supported, perhaps kernel support is missing?")
            hy[i] = ty; hk[i] = hook; hp[i] = pr
            if (hq[i] == "") hq[i] = "accept"
        } else if (k == "policy") {
            p++
            hq[i] = word()
        } else rule(c)
    }
}
function elements(i, a,   v, k, nv, full) {
    expect("{")
    nv = 0
    full = 128
    if (sy[i] == "ipv4_addr") full = 32
    while (1) {
        while (p <= n && (tk[p] == "\n" || tk[p] == ",")) p++
        if (p > n) fail("Error: syntax error, unterminated element list")
        if (tk[p] == "}") { p++; break }
        v = addr(word(), full)
        if (index(v, "/") && sf[i] != "interval") fail("Error: You must add \047flags interval\047 to your set declaration if you want to add prefix elements")
        k = findelem(sn[i], v)
        nv++
        if (a == "add" && !k) { es[++ne] = sn[i]; et[ne] = v; ej[ne] = vjson(v); ed[ne] = 0 }
        if (a == "delete") {
            if (!k) missing()
            ed[k] = 1
        }
    }
    if (!nv) fail("Error: syntax error, empty element list")
}
function tablebody(   k) {
    expect("{")
    while (1) {
        sep()
        if (p > n) fail("Error: syntax error, unterminated table block")
        k = tk[p++]
        if (k == "}") return
        if (k == "set") setdecl(word())
        else if (k == "counter") ctrdecl(word())
        else if (k == "chain") chaindecl(word())
        else fail("nft stub: unsupported in a table block: " k)
    }
}
function stmt(   a, o, f, t, s, i, k) {
    a = tk[p]
    if (a == "table") { o = "table"; a = "add" }
    else if (a == "add" || a == "delete" || a == "flush") { p++; o = tk[p] }
    else fail("nft stub: unsupported statement " a)
    p++
    if (o == "table") {
        f = word(); t = word()
        if (!ours(f, t)) { skip(); return }
        if (a == "add") {
            present = 1
            if (tk[p] == "{") tablebody()
            return
        }
        if (!present) missing()
        if (a == "delete") { present = 0; nc = 0; ns = 0; ne = 0; nh = 0 }
        nr = 0
        return
    }
    if ((o == "set" && a == "flush") || (o == "element" && a != "flush")) {
        f = word(); t = word(); s = word()
        if (!ours(f, t)) { skip(); return }
        i = 0
        if (present) i = findset(s)
        if (!i) nosuch()
        if (o == "element") { elements(i, a); return }
        for (k = 1; k <= ne; k++) if (es[k] == s) ed[k] = 1
        return
    }
    fail("nft stub: unsupported statement " a " " o)
}
BEGIN {
    FAMILY = "Error: Could not resolve hostname: Address family for hostname not supported"
    n = 0; p = 1; failed = 0; present = 0; nc = 0; ns = 0; ne = 0; nh = 0; nr = 0
    while ((getline l < old) > 0) {
        m = split(l, rec, "\t")
        if (rec[1] == "table") present = 1
        else if (rec[1] == "counter") cn[++nc] = rec[2]
        else if (rec[1] == "set") { sn[++ns] = rec[2]; sy[ns] = rec[3]; sf[ns] = (m >= 4 ? rec[4] : "") }
        else if (rec[1] == "elem") { es[++ne] = rec[2]; et[ne] = rec[3]; ej[ne] = rec[4]; ed[ne] = 0 }
        else if (rec[1] == "chain") { hn[++nh] = rec[2]; hy[nh] = rec[3]; hk[nh] = rec[4]; hp[nh] = rec[5]; hq[nh] = rec[6] }
        else if (rec[1] == "rule") { rc[++nr] = rec[2]; rt[nr] = rec[3]; rj[nr] = rec[4] }
    }
}
{ lex($0) }
END {
    if (failed) exit 1
    while (1) {
        sep()
        if (p > n) break
        stmt()
    }
    if (!present) exit 0
    print "table\tinet\ttn_p2p_allow"
    for (i = 1; i <= nc; i++) print "counter\t" cn[i]
    for (i = 1; i <= ns; i++) print "set\t" sn[i] "\t" sy[i] "\t" sf[i]
    for (k = 1; k <= ne; k++) if (!ed[k]) print "elem\t" es[k] "\t" et[k] "\t" ej[k]
    for (i = 1; i <= nh; i++) print "chain\t" hn[i] "\t" hy[i] "\t" hk[i] "\t" hp[i] "\t" hq[i]
    for (i = 1; i <= nr; i++) print "rule\t" rc[i] "\t" rt[i] "\t" rj[i]
}
'
# the records of .nft.allow listed as nft lists them: WHAT is table, set,
# counter or counters, NAME the set or counter, JSON 1 for -j. Handles count
# in listing order, as a fresh load numbers them.
render_awk='
BEGIN { FS = "\t"; T = "\"table\": \"tn_p2p_allow\"" }
$1 == "counter" { cn[++nc] = $2 }
$1 == "set" { sn[++ns] = $2; sy[ns] = $3; sf[ns] = $4 }
$1 == "elem" { es[++ne] = $2; et[ne] = $3; ej[ne] = $4 }
$1 == "chain" { hn[++nh] = $2; hy[nh] = $3; hk[nh] = $4; hp[nh] = $5; hq[nh] = $6 }
$1 == "rule" { rc[++nr] = $2; rt[nr] = $3; rj[nr] = $4 }
function want(kind, nm) { return what == "table" || (what == kind && nm == name) || (what == "counters" && kind == "counter") }
# nft separates the objects of a table listing with a blank line
function gap() { return (shown++ && what == "table") ? "\n" : "" }
END {
    h = 0; shown = 0; js = ""; tx = ""
    if (what == "table") js = ", {\"table\": {\"family\": \"inet\", \"name\": \"tn_p2p_allow\", \"handle\": 3}}"
    for (i = 1; i <= nc; i++) {
        h++
        if (!want("counter", cn[i])) continue
        js = js ", {\"counter\": {\"family\": \"inet\", \"name\": \"" cn[i] "\", " T ", \"handle\": " h ", \"packets\": 0, \"bytes\": 0}}"
        tx = tx gap() "\tcounter " cn[i] " {\n\t\tpackets 0 bytes 0\n\t}\n"
    }
    for (i = 1; i <= ns; i++) {
        h++
        if (!want("set", sn[i])) continue
        ev = ""; evj = ""
        for (k = 1; k <= ne; k++) {
            if (es[k] != sn[i]) continue
            ev = ev (ev == "" ? "" : ", ") et[k]
            evj = evj (evj == "" ? "" : ", ") ej[k]
        }
        j = "{\"set\": {\"family\": \"inet\", \"name\": \"" sn[i] "\", " T ", \"type\": \"" sy[i] "\", \"handle\": " h
        t = "\tset " sn[i] " {\n\t\ttype " sy[i] "\n"
        if (sf[i] != "") { j = j ", \"flags\": [\"" sf[i] "\"]"; t = t "\t\tflags " sf[i] "\n" }
        if (ev != "") { j = j ", \"elem\": [" evj "]"; t = t "\t\telements = { " ev " }\n" }
        js = js ", " j "}}"
        tx = tx gap() t "\t}\n"
    }
    if (what == "table") {
        for (i = 1; i <= nh; i++) {
            h++
            j = "{\"chain\": {\"family\": \"inet\", " T ", \"name\": \"" hn[i] "\", \"handle\": " h
            t = "\tchain " hn[i] " {\n"
            if (hy[i] != "") {
                j = j ", \"type\": \"" hy[i] "\", \"hook\": \"" hk[i] "\", \"prio\": " hp[i] ", \"policy\": \"" hq[i] "\""
                t = t "\t\ttype " hy[i] " hook " hk[i] " priority " hp[i] "; policy " hq[i] ";\n"
            }
            for (k = 1; k <= nr; k++) if (rc[k] == hn[i]) t = t "\t\t" rt[k] "\n"
            js = js ", " j "}}"
            tx = tx gap() t "\t}\n"
        }
        for (i = 1; i <= nh; i++) {
            for (k = 1; k <= nr; k++) {
                if (rc[k] != hn[i]) continue
                h++
                js = js ", {\"rule\": {\"family\": \"inet\", " T ", \"chain\": \"" hn[i] "\", \"handle\": " h ", \"expr\": [" rj[k] "]}}"
            }
        }
    }
    if ((what == "set" || what == "counter") && !shown) {
        print "Error: No such file or directory" > "/dev/stderr"
        exit 1
    }
    if (json == "1") print "{\"nftables\": [" meta js "]}"
    else if (shown || what == "table") printf "%s", "table inet tn_p2p_allow {\n" tx "}\n"
}
'
allow_apply() {
    printf '%s\n' "$prog" > "$sa.prog.$$"
    awk -v old="$sa" "$apply_awk" "$sa.prog.$$"
    rc=$?
    rm -f "$sa.prog.$$"
    return "$rc"
}
allow_list() {
    j=0
    [ "$json" = true ] && j=1
    awk -v what="$1" -v name="$2" -v json="$j" -v meta="$meta" "$render_awk" "$sa"
}
nft_tables() {
    echo "ip filter 1"
    [ -f "$st" ] && echo "inet tn_p2p 2"
    [ -f "$sa" ] && echo "inet tn_p2p_allow 3"
    return 0
}
nft_list() {
    [ -n "${NFT_LIST_FAIL:-}" ] && { echo "Error: Operation not permitted" >&2; exit 1; }
    if [ "${1:-}" = tables ]; then
        objs=""
        while read -r fam name handle; do
            [ -z "${2:-}" ] || [ "$2" = "$fam" ] || continue
            if [ "$json" = true ]; then
                objs="$objs, {\"table\": {\"family\": \"$fam\", \"name\": \"$name\", \"handle\": $handle}}"
            else
                echo "table $fam $name"
            fi
        done <<EOF
$(nft_tables)
EOF
        [ "$json" = true ] && printf '{"nftables": [%s%s]}\n' "$meta" "$objs"
        exit 0
    fi
    case "${1:-} ${2:-} ${3:-}" in
        "table inet tn_p2p")
            [ "$json" = true ] && { echo "nft stub: unsupported list -j $*" >&2; exit 1; }
            [ -f "$st" ] && { cat "$st"; exit 0; }
            echo "Error: No such file or directory" >&2
            exit 1 ;;
        "table inet tn_p2p_allow"|"set inet tn_p2p_allow"|"counter inet tn_p2p_allow")
            [ -f "$sa" ] || { echo "Error: No such file or directory" >&2; exit 1; }
            allow_list "$1" "${4:-}"
            exit ;;
        "counters  ")
            [ -f "$sa" ] && { allow_list counters ""; exit; }
            [ "$json" = true ] && printf '{"nftables": [%s]}\n' "$meta"
            exit 0 ;;
    esac
    echo "nft stub: unsupported list $*" >&2
    exit 1
}
check=false
json=false
file=""
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--check) check=true; shift ;;
        -j|--json) json=true; shift ;;
        -f|--file) file="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
        list) shift; nft_list "$@" ;;
        add|delete|flush)
            case " $* " in *" inet tn_p2p_allow "*) break ;; esac
            echo "nft stub: unsupported argument $1" >&2
            exit 1 ;;
        *) echo "nft stub: unsupported argument $1" >&2; exit 1 ;;
    esac
done
[ "$json" = false ] || { echo "nft stub: unsupported -j with a write" >&2; exit 1; }
if [ $# -gt 0 ]; then
    [ -z "$file" ] || { echo "nft stub: unsupported -f with a command" >&2; exit 1; }
    prog="$*"
else
    [ -n "$file" ] || { echo "nft stub: nothing to do" >&2; exit 1; }
    if [ "$file" = "-" ]; then
        prog="$(cat)"
    else
        prog="$(cat "$file")" || exit 1
    fi
    printf '%s\n' "$prog" | sed 's/^/| /' >> "$log"
fi
if [ -n "${NFT_FAIL:-}" ]; then
    echo "Error: Could not process rule: Operation not supported" >&2
    exit 1
fi
allow=false
case "$prog" in *tn_p2p_allow*) allow=true ;; esac
if [ "$check" = true ]; then
    if [ "$allow" = true ]; then allow_apply > /dev/null || exit 1; fi
    exit 0
fi
if [ -n "${NFT_HOLD:-}" ]; then
    echo "$$" > "$R/.nft.held"
    while [ ! -e "$R/.nft.release" ]; do sleep 0.1; done
fi
if [ "$allow" = true ]; then
    allow_apply > "$sa.tmp.$$" || { rm -f "$sa.tmp.$$"; exit 1; }
    if [ -s "$sa.tmp.$$" ]; then mv "$sa.tmp.$$" "$sa"; else rm -f "$sa.tmp.$$" "$sa"; fi
fi
block="$(printf '%s\n' "$prog" | awk '/^table inet tn_p2p \{/ { on = 1 } on { print }')"
if [ -n "$block" ]; then
    printf '%s\n' "$block" > "$st.tmp" && mv "$st.tmp" "$st"
elif printf '%s\n' "$prog" | grep -qx 'delete table inet tn_p2p'; then
    rm -f "$st"
fi
exit 0
STUB
    cat > "$bin/tn-p2p-allow-sync" <<'STUB'
#!/bin/sh
# tn-p2p-allow-sync stand-in (tools/tests/fwstub.sh): records each call, answers
# from the TN_P2P_STUB_* knobs.
state="${TN_ROOT_PREFIX:-}/var/lib/telcoin-p2p-allow"
key="" json=false next=""
for a in "$@"; do
    if [ -n "$next" ]; then
        [ "$next" = state ] && state="$a"
        next=""
        continue
    fi
    case "$a" in
        --state-dir) next=state ;;
        --state-dir=*) state="${a#--state-dir=}" ;;
        --nft) next=skip ;;
        --json) json=true ;;
        --version) [ -n "$key" ] || key=VERSION ;;
        -*) ;;
        *)
            if [ -z "$key" ]; then
                case "$a" in
                    sync) key=SYNC ;;
                    check) key=CHECK ;;
                    status) key=STATUS ;;
                    render) key=RENDER ;;
                    capture-floor) key=CAPTURE_FLOOR ;;
                    *) key=USAGE ;;
                esac
            fi
            ;;
    esac
done
[ -n "$key" ] || key=USAGE
if [ "$key" = STATUS ] && [ "$json" = true ]; then
    key=STATUS_JSON
fi
if [ -n "${REC:-}" ]; then
    : > "$REC.argv"
    for a in "$@"; do printf '%s\n' "$a" >> "$REC.argv"; done
    if [ "${TN_P2P_STUB_STDIN:-}" = 1 ]; then cat > "$REC.stdin"; else : > "$REC.stdin"; fi
    env > "$REC.env"
    printf '%s\n' "$*" >> "$REC.log"
elif [ "$key" != VERSION ]; then
    echo "tn-p2p-allow-sync stub: REC is not set" >&2
    exit 2
fi
if [ "$key" = VERSION ]; then
    if [ -n "${TN_P2P_STUB_VERSION_TEXT+x}" ]; then
        [ -z "$TN_P2P_STUB_VERSION_TEXT" ] || printf '%s\n' "$TN_P2P_STUB_VERSION_TEXT"
    else
        printf 'tn-p2p-allow-sync %s\n' "${TN_P2P_STUB_VERSION:-0.1.0}"
        printf 'commit 0123456789abcdef0123456789abcdef01234567\n'
        printf 'target x86_64-unknown-linux-musl\nsnapshot-versions 1\nconfig-version 1\n'
    fi
    exit "${TN_P2P_STUB_RC_VERSION:-0}"
fi
if [ "$key" = USAGE ]; then
    echo "tn-p2p-allow-sync stub: unknown command: $*" >&2
    exit "${TN_P2P_STUB_RC_USAGE:-2}"
fi
# key is one of the fixed names above, so the knob names are safe to expand.
rc=0 out=""
eval "rc=\${TN_P2P_STUB_RC_${key}:-\${TN_P2P_STUB_RC:-0}}"
eval "out=\${TN_P2P_STUB_OUT_${key}-\${TN_P2P_STUB_OUT-}}"
if [ "$key" = SYNC ] && [ -n "${TN_P2P_STUB_STATUS+x}" ] && [ "$rc" != 1 ] && [ "$rc" != 4 ]; then
    if [ ! -d "$state" ]; then
        echo "tn-p2p-allow-sync stub: state directory $state is missing" >&2
        exit 2
    fi
    printf '%s\n' "$TN_P2P_STUB_STATUS" > "$state/status"
fi
[ -z "$out" ] || printf '%s\n' "$out"
exit "$rc"
STUB
    chmod +x "$bin/ufw" "$bin/sshd" "$bin/systemctl" "$bin/nft" "$bin/tn-p2p-allow-sync"
}
