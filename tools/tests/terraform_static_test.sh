#!/usr/bin/env bash
# =============================================================================
# tools/tests/terraform_static_test.sh -- text checks of terraform/ that need no
# Terraform, no Docker and no network
#
#   bash tools/tests/terraform_static_test.sh
#   TN_TERRAFORM_DIR=/path/to/terraform bash tools/tests/terraform_static_test.sh
#
# TN_TERRAFORM_DIR names the tree to check (default: terraform/ of this
# repository); it holds first-boot/, modules/host-plan/ and the cloud roots.
#   - every image tools/check-terraform.sh runs is pinned name:tag@sha256:<64
#     hex>, and every docker run in it runs one of those images;
#   - in each cloud root that exists (aws, gcp, azure; one that does not is
#     skipped with a note), every block of the types in PROTECTED below holds
#     prevent_destroy = true in its lifecycle block, and each type is there;
#   - the per-network redirect_queries_url defaults, wherever they live,
#     equal TESTNET_RPC_URL and MAINNET_RPC_URL of lib/common.sh;
#   - the Docker apt key fingerprint of the gateway's first boot equals
#     TN_DOCKER_APT_FINGERPRINT of setup-node.sh;
#   - the env file contract, both ways: each role renders, through
#     modules/host-plan, exactly the TN_FB_* keys its first-boot script takes
#     (the keys first-boot-lib.sh's fb_validate_env checks for that role, less
#     the test hooks its header lists), none twice;
#   - each host's user data scripts stay inside a gzip -9 budget;
#   - no .tf file opens port 22, 8545 or 43174, whatever the protocol, to
#     0.0.0.0/0, ::/0, *, Internet or Any (a text scan that fails when it
#     cannot tell);
#   - no file under the tree holds password, secret or token outside a
#     comment, but for the phrases in SECRET_ALLOW.
# Each rule is also run against small fixtures in a temporary directory, one
# that passes and one that fails, so the rules are proven before the cloud
# roots exist; and the whole test runs once more with TN_TERRAFORM_DIR set to
# each fixture tree.
#
# Maintainer tooling: not tracked by update-scripts.sh, no .sha256 sidecar.
# bash 3.2 safe.
# =============================================================================

set -u

# shellcheck source=tools/tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
eval "$(tn_test_source_common)"
T="$TN_TEST_TMP"
TF="${TN_TERRAFORM_DIR:-$TN_TEST_REPO/terraform}"
TF="${TF%/}"
CHECK_TF="$TN_TEST_REPO/tools/check-terraform.sh"

# The resources whose loss cannot be undone, per cloud: each must hold
# prevent_destroy = true inside its lifecycle block. blocks: * is every block
# of the type, a name is the one block of that name, external is every block
# whose address_type is not INTERNAL (the provider's default is EXTERNAL).
# except: block names (a pattern) left out, "-" for none.
#   cloud  type                           blocks     except     what
readonly PROTECTED="
aws    aws_ebs_volume                 *          -          the data disk
aws    aws_eip                        *          -          the static public IPs
aws    aws_instance                   validator  -          the validator VM
gcp    google_compute_disk            *          -          the data disk
gcp    google_compute_address         external   -          the static public IPs
gcp    google_compute_instance        validator  -          the validator VM
azure  azurerm_managed_disk           *          -          the data disk
azure  azurerm_public_ip              *          *bastion*  the static public IPs
azure  azurerm_linux_virtual_machine  validator  -          the validator VM
"
# *bastion*: the Azure Bastion host's address exists only while enable_bastion
# is on, and prevent_destroy on it would make turning the bastion off fail.

# gzip -9 budgets of each host's scripts, about 15 percent above their size
# when the budgets were set (lib + gateway 9,176 bytes, lib + validator 7,260).
# AWS takes 16,384 bytes of user data, which also carries the env file and, on
# the validator, the hubs file.
readonly GZ_BUDGET_GATEWAY=10550
readonly GZ_BUDGET_VALIDATOR=8350

# Phrases taken out of a line before the password/secret/token scan:
#   http_tokens                      AWS: the instance metadata setting that
#                                    requires IMDSv2 session tokens; it holds none
#   disable_password_authentication  Azure: the VM setting that turns password
#                                    login off; it holds no password
readonly SECRET_ALLOW="http_tokens disable_password_authentication"

# -----------------------------------------------------------------------------
# HCL as text
# -----------------------------------------------------------------------------

# tf_lex FILE... -- each HCL file as "FILE:LINE<TAB>TEXT" lines: comments (#,
# //, /* */) and heredoc bodies dropped, a break after every { and before
# every } outside a string, and one line per argument where a comma joins
# several (a = 1, b = 2). Text in quotes is kept whole.
tf_lex() {
    awk '
        function emit(s) {
            sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
            if (s != "") print FILENAME ":" FNR "\t" s
        }
        function arg_follows(r) {
            return r ~ /^,[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*=[^=>]/ ||
                r ~ /^,[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*=$/
        }
        FNR == 1 { hd = ""; incom = 0 }
        hd != "" {
            t = $0; gsub(/[[:space:]]/, "", t)
            if (t == hd) hd = ""
            next
        }
        {
            line = $0; n = length(line); out = ""; instr = 0; i = 1
            while (i <= n) {
                c = substr(line, i, 1); c2 = substr(line, i, 2)
                if (incom) {
                    if (c2 == "*/") { incom = 0; i += 2 } else i++
                    continue
                }
                if (instr) {
                    if (c == "\\") { out = out c2; i += 2; continue }
                    if (c == "\"") instr = 0
                    out = out c; i++; continue
                }
                if (c == "\"") { instr = 1; out = out c; i++; continue }
                if (c == "#" || c2 == "//") break
                if (c2 == "/*") { incom = 1; i += 2; continue }
                if (c2 == "<<") {
                    rest = substr(line, i + 2); sub(/^-/, "", rest); sub(/[[:space:]]+$/, "", rest)
                    if (rest ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { hd = rest; out = out "\"\""; break }
                }
                if (c == "{") { emit(out "{"); out = ""; i++; continue }
                if (c == "}") { emit(out); out = "}"; i++; continue }
                if (c == "," && arg_follows(substr(line, i))) { emit(out); out = ""; i++; continue }
                out = out c; i++
            }
            emit(out)
        }
    ' "$@"
}

# tf_scan LEXED -- walk the blocks of tf_lex output. LEXED is read twice: the
# first pass learns which locals and variables hold an open source. Prints:
#   R|LOC|TYPE|NAME|PROTECTED|ADDRESS_TYPE  each top-level resource; PROTECTED is
#                                           1 when its lifecycle block holds
#                                           prevent_destroy = true
#   U|LOC|NETWORK|URL                       an entry of a public_rpc_url map or of
#                                           the default of variable
#                                           redirect_queries_url (NETWORK any for a
#                                           single non-empty string)
#   O|LOC|TEXT                              an inbound allow rule open to the
#                                           world on 22, 8545 or 43174, or on ports
#                                           it does not write out; an ssh variable
#                                           whose default is open
# A rule is the block that holds its source: a rule resource, an inline
# ingress or security_rule block, or an object of a locals or variable map;
# its ports are its own, or those of its allow blocks. A port is known when it
# is written out, is a local whose value is written out, or is each.value of a
# for_each that is; anything else (a variable, an attribute) is unknown, and an
# open rule with an unknown port fails. A rule with neither a port nor a
# protocol is a rule only inside a security group, firewall, security rule or
# network ACL resource; there, and wherever a protocol has no ports, it opens
# every port.
tf_scan() {
    awk '
        BEGIN { np = split("22 8545 43174", SP, " ") }
        function unq(v) { sub(/^[[:space:]]*"/, "", v); sub(/"[[:space:],]*$/, "", v); return v }
        function opentok(v,   t) {
            while (match(v, /"[^"]*"/)) {
                t = substr(v, RSTART + 1, RLENGTH - 2)
                if (tolower(t) ~ /^(0\.0\.0\.0\/0|::\/0|\*|internet|any)$/) return t
                v = substr(v, RSTART + RLENGTH)
            }
            return ""
        }
        function openref(v,   r) {
            while (match(v, /(local|var)\.[A-Za-z_][A-Za-z0-9_-]*/)) {
                r = substr(v, RSTART, RLENGTH)
                if (r in bound) return r
                v = substr(v, RSTART + RLENGTH)
            }
            return ""
        }
        function bal(v,   o, c) { gsub(/"[^"]*"/, "", v); o = gsub(/\[|\(/, "&", v); c = gsub(/\]|\)/, "&", v); return o - c }
        # resolve V -- the port ranges V stands for: the ones written in it and
        # those of the locals it names. Sets unk when V names anything else,
        # eachref when it names each.*.
        function resolve(v,   w, r, out) {
            unk = 0; eachref = 0; out = ""
            w = v; gsub(/"[^"]*"/, " ", w)
            while (match(w, /[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_-]*)+/)) {
                r = substr(w, RSTART, RLENGTH); w = substr(w, RSTART + RLENGTH)
                if (r ~ /^each\./) eachref = 1
                else if (r in lp) out = out lp[r]
                else unk = 1
            }
            return ranges(v) out
        }
        function first(rs, end,   a, r) { split(rs, a, " "); split(a[1], r, "-"); return r[end] + 0 }
        # ranges V -- " LO-HI" for each port or port range written in V; "*"
        # and -1 are every port.
        function ranges(v,   out, m, a, j) {
            out = ""
            gsub("[^-0-9A-Za-z_.:/*]", " ", v)
            m = split(v, a, " ")
            for (j = 1; j <= m; j++) {
                if (a[j] == "*" || a[j] == "-1") out = out " 0-65535"
                else if (a[j] ~ /^[0-9]+$/) out = out " " a[j] "-" a[j]
                else if (a[j] ~ /^[0-9]+-[0-9]+$/) out = out " " a[j]
            }
            return out
        }
        function open_block(n, h,   q) {
            hdr[n] = h; rtype[n] = ""; rname[n] = ""; vname[n] = ""; rloc[n] = loc
            if (n == 1 && h ~ /^resource[[:space:]]+"[^"]*"[[:space:]]+"[^"]*"$/) {
                split(h, q, "\""); rtype[n] = q[2]; rname[n] = q[4]
            }
            if (n == 1 && h ~ /^variable[[:space:]]+"[^"]*"$/) { split(h, q, "\""); vname[n] = q[2] }
            prot[n] = 0; atype[n] = ""; src[n] = ""; sloc[n] = ""
            hasport[n] = 0; pr[n] = ""; nl[n] = 0; ne[n] = 0; fromp[n] = ""; top[n] = ""
            hasproto[n] = 0; icmp[n] = 0; allproto[n] = 0; fe[n] = ""; feu[n] = 0; dn[n] = 0; achild[n] = 0; dchild[n] = 0
            lkey[n] = ""; lbal[n] = 0
            eg[n] = (h ~ /^egress[[:space:]]*(=.*)?$/ || h ~ /^dynamic[[:space:]]+"egress"$/)
            if (n > 1 && (h == "allow" || h ~ /^dynamic[[:space:]]+"allow"$/)) achild[n - 1] = 1
            if (n > 1 && (h == "deny" || h ~ /^dynamic[[:space:]]+"deny"$/)) dchild[n - 1] = 1
        }
        function close_block(n,   p, a1, a2, u, e) {
            if (icmp[n]) {
                hasport[n] = 1
            } else {
                if (fromp[n] != "" || top[n] != "") {
                    a1 = (fromp[n] == "") ? " 0-0" : resolve(fromp[n]); u = unk; e = eachref
                    a2 = (top[n] == "") ? " 65535-65535" : resolve(top[n]); u += unk; e += eachref
                    if (u) nl[n] = 1
                    else if (e) ne[n] = 1
                    else if (a1 == "" || a2 == "") nl[n] = 1
                    else pr[n] = pr[n] " " first(a1, 1) "-" first(a2, 2)
                }
                # -1 (AWS) and all (GCP) are every protocol on every port,
                # whatever ports the rule names.
                if ((hasproto[n] && !hasport[n]) || allproto[n]) { hasport[n] = 1; pr[n] = pr[n] " 0-65535" }
            }
            if (n == 1 && rtype[1] != "") print "R|" rloc[1] "|" rtype[1] "|" rname[1] "|" prot[1] "|" atype[1]
            if (src[n] != "") judge(n)
            p = n - 1
            if (p >= 1 && (hdr[n] ~ /^(allow|deny|content)$/ || hdr[n] ~ /^dynamic[[:space:]]+"(allow|deny)"$/)) {
                hasport[p] += hasport[n]; pr[p] = pr[p] pr[n]; nl[p] += nl[n]; ne[p] += ne[n]; hasproto[p] += hasproto[n]
            }
        }
        function judge(n,   i, fw, rs, m, a, r, j, k) {
            if (n == 1 && rtype[1] == "") return
            fw = (hasport[n] || hasproto[n])
            for (i = 1; i <= n; i++) {
                if (rtype[i] ~ /security_group|firewall|security_rule|network_acl/) fw = 1
                if (rtype[i] ~ /egress/ || eg[i] || dn[i]) return
            }
            if (!fw || (dchild[n] && !achild[n])) return
            rs = pr[n]
            if (!hasport[n]) rs = " 0-65535"
            if (nl[n]) { say(n, "ports it does not write out"); return }
            if (ne[n]) {
                for (i = n; i >= 1; i--) if (fe[i] != "" || feu[i]) break
                if (i < 1 || feu[i]) { say(n, "ports it does not write out"); return }
                rs = rs fe[i]
            }
            m = split(rs, a, " ")
            for (j = 1; j <= m; j++) {
                split(a[j], r, "-")
                for (k = 1; k <= np; k++)
                    if (r[1] + 0 <= SP[k] + 0 && SP[k] + 0 <= r[2] + 0) { say(n, "port " SP[k]); return }
            }
        }
        function say(n, what,   i, d, h) {
            d = ""
            for (i = 1; i <= n; i++) { h = hdr[i]; sub(/[[:space:]]*=[[:space:]]*\[?$/, "", h); d = d (i > 1 ? " > " : "") h }
            print "O|" sloc[n] "|" d ": " what " open to \"" src[n] "\""
        }
        function arg(n, k, v,   lk, t) {
            lk = tolower(k)
            if (pass == 1) {
                if (n == 1 && hdr[1] == "locals" && opentok(v) != "") bound["local." k] = 1
                if (n == 1 && hdr[1] == "locals" && (t = ranges(v)) != "") lp["local." k] = lp["local." k] t
                if (n == 1 && vname[1] != "" && lk == "default" && opentok(v) != "") bound["var." vname[1]] = 1
                return
            }
            if (n == 2 && rtype[1] != "" && hdr[2] == "lifecycle" && lk == "prevent_destroy" && v ~ /^true[[:space:]]*$/) prot[1] = 1
            if (n == 1 && rtype[1] != "" && lk == "address_type") atype[1] = toupper(unq(v))
            if ((lk == "testnet" || lk == "mainnet") && (hdr[n] ~ /^public_rpc_url[[:space:]]*=$/ ||
                (n == 2 && vname[1] == "redirect_queries_url" && hdr[2] ~ /^default[[:space:]]*=$/)))
                print "U|" loc "|" lk "|" unq(v)
            if (n == 1 && vname[1] == "redirect_queries_url" && lk == "default" && v !~ /^(""|null)[[:space:]]*$/)
                print "U|" loc "|any|" unq(v)
            if (n == 1 && tolower(vname[1]) ~ /ssh/ && lk == "default" && (t = opentok(v)) != "")
                print "O|" loc "|variable \"" vname[1] "\": defaults to \"" t "\""
            if (lk ~ /^source_port/) return
            if (lk == "from_port") { fromp[n] = v; hasport[n] = 1; return }
            if (lk == "to_port") { top[n] = v; hasport[n] = 1; return }
            if (lk ~ /^ports?$/ || lk ~ /_ports?$/ || lk ~ /port_ranges?$/) {
                hasport[n] = 1; pr[n] = pr[n] resolve(v)
                if (unk) nl[n] = 1
                if (eachref) ne[n] = 1
                return
            }
            if (lk == "protocol" || lk == "ip_protocol") {
                hasproto[n] = 1
                if (tolower(unq(v)) ~ /^(icmp|icmpv6|1|58)$/) icmp[n] = 1
                if (tolower(unq(v)) ~ /^(-1|all)$/) allproto[n] = 1
                return
            }
            t = tolower(v)
            if ((lk == "direction" && t ~ /egress|outbound/) || (lk == "type" && t ~ /egress/) || (lk == "egress" && t ~ /^true/)) eg[n] = 1
            if ((lk == "access" || lk == "action" || lk == "rule_action") && t ~ /deny/) dn[n] = 1
            if (lk ~ /^destination/ || lk ~ /^(description|name|condition|error_message|priority|access|direction|type|action|rule_action|egress)$/) return
            if (lk == "for_each") { fe[n] = fe[n] resolve(v); if (unk || eachref) feu[n] = 1 }
            t = opentok(v)
            if (t == "") t = openref(v)
            if (t != "" && src[n] == "") { src[n] = t; sloc[n] = loc }
        }
        FNR == 1 { pass++; d = 0; cur = "" }
        {
            tab = index($0, "\t"); loc = substr($0, 1, tab - 1); text = substr($0, tab + 1)
            f = loc; sub(/:[0-9]+$/, "", f)
            if (f != cur) { cur = f; d = 0 }
            if (substr(text, 1, 1) == "}") {
                if (d > 0) { if (pass == 2) close_block(d); d-- }
                text = substr(text, 2); sub(/^[[:space:]]+/, "", text)
            }
            if (text ~ /[{]$/) {
                h = substr(text, 1, length(text) - 1); sub(/[[:space:]]+$/, "", h)
                d++; open_block(d, h)
                next
            }
            if (text == "" || d == 0) next
            k = ""; v = text; isarg = 0
            if (match(text, /^[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*=/) || match(text, /^"[^"]*"[[:space:]]*=/)) {
                k = substr(text, 1, RLENGTH - 1); v = substr(text, RLENGTH + 1)
                if (v !~ /^[=>]/) isarg = 1
            }
            if (isarg) {
                sub(/[[:space:]]+$/, "", k); gsub(/"/, "", k); sub(/^[[:space:]]+/, "", v)
                lkey[d] = ""; b = bal(v)
                if (b > 0) { lkey[d] = k; lbal[d] = b }
            } else {
                k = lkey[d]; v = text
                if (k != "") { lbal[d] += bal(v); if (lbal[d] <= 0) lkey[d] = "" }
            }
            arg(d, k, v)
        }
    ' "$1" "$1"
}

# tf_records TREE FILE... -- tf_scan of the named .tf files, given relative to
# TREE (so each LOC reads aws/validator.tf:12).
tf_records() {
    local tree="$1" lx
    shift
    [[ $# -gt 0 ]] || return 0
    lx="$(mktemp "$T/lex.XXXXXX")" || return 1
    (cd "$tree" && tf_lex "$@") > "$lx"
    tf_scan "$lx"
    rm -f "$lx"
}

# tf_dirs TREE -- each directory under TREE that holds .tf files, relative to
# TREE; the .terraform working directories are left out.
tf_dirs() {
    (cd "$1" && find . -name .terraform -prune -o -name '*.tf' -type f -print) |
        sed -e 's|/[^/]*$||' -e 's|^\./||' -e 's|^\.$||' | sort -u
}

# tf_files TREE DIR -- the .tf files of TREE/DIR, relative to TREE, one per line.
tf_files() {
    local f
    for f in "$1/${2:+$2/}"*.tf; do
        [[ -f "$f" ]] && printf '%s\n' "${2:+$2/}${f##*/}"
    done
}

# tree_records TREE TAG -- the TAG records of every module under TREE, one
# module (one set of locals) at a time, without the tag.
tree_records() {
    local tree="$1" tag="$2" dir files f
    while IFS= read -r dir; do
        files=()
        while IFS= read -r f; do files+=("$f"); done < <(tf_files "$tree" "$dir")
        [[ ${#files[@]} -gt 0 ]] || continue
        tf_records "$tree" "${files[@]}" | sed -n "s/^${tag}|//p"
    done < <(tf_dirs "$tree")
}

# -----------------------------------------------------------------------------
# The rules. Each prints what breaks it, one line each, and nothing when it holds.
# -----------------------------------------------------------------------------

# image_pins SCRIPT -- the *_IMAGE assignments of SCRIPT not pinned as
# name:tag@sha256:<64 hex>, and every docker run that runs no *_IMAGE variable.
image_pins() {
    local re='^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9_][A-Za-z0-9._-]*@sha256:[0-9a-f]{64}$' name val
    while IFS='|' read -r name val; do
        [[ "$val" =~ $re ]] || printf '%s=%s is not name:tag@sha256:<64 hex>\n' "$name" "$val"
    done < <(image_vars "$1")
    awk '
        /^[[:space:]]*#/ { next }
        { cmd = (cont ? cmd " " : "") $0; cont = ($0 ~ /\\$/) }
        cont { next }
        cmd ~ /docker[[:space:]]+run/ && cmd !~ /"\$[{]?[A-Z_]*_IMAGE[}]?"/ {
            gsub(/[[:space:]]+/, " ", cmd); sub(/^ /, "", cmd)
            print "docker run without a pinned image variable: " cmd
        }
        { cmd = "" }
    ' "$1"
}

# image_vars SCRIPT -- "NAME|VALUE" for each *_IMAGE="..." assignment of SCRIPT.
image_vars() {
    sed -n 's/^[[:space:]]*\(readonly[[:space:]][[:space:]]*\)\{0,1\}\([A-Z_]*_IMAGE\)="\([^"]*\)".*/\2|\3/p' "$1"
}

# protected TREE CLOUD -- the PROTECTED rows of CLOUD that TREE/CLOUD breaks.
protected() {
    local tree="$1" cloud="$2" recs="" files=() f c type blocks except what n tag loc rtype name prot atype
    while IFS= read -r f; do files+=("$f"); done < <(tf_files "$tree" "$cloud")
    [[ ${#files[@]} -eq 0 ]] || recs="$(tf_records "$tree" "${files[@]}" | grep '^R|')"
    while read -r c type blocks except what; do
        [[ "$c" == "$cloud" ]] || continue
        n=0
        while IFS='|' read -r tag loc rtype name prot atype; do
            [[ "$tag" == R && "$rtype" == "$type" ]] || continue
            case "$blocks" in
                '*') ;;
                external) [[ "$atype" == INTERNAL ]] && continue ;;
                *) [[ "$name" == "$blocks" ]] || continue ;;
            esac
            # shellcheck disable=SC2254  # except is a pattern
            case "$name" in $except) continue ;; esac
            n=$((n + 1))
            [[ "$prot" == 1 ]] || printf '%s: %s.%s (%s) has no prevent_destroy = true in its lifecycle block\n' \
                "$loc" "$type" "$name" "$what"
        done <<< "$recs"
        if [[ $n -eq 0 && "$blocks" == '*' ]]; then
            printf '%s: no %s block (%s)\n' "$cloud" "$type" "$what"
        elif [[ $n -eq 0 ]]; then
            printf '%s: no %s block %s (%s)\n' "$cloud" "$type" "$blocks" "$what"
        fi
    done <<< "$PROTECTED"
}

# rpc_defaults TREE -- each per-network default under TREE that is not the
# lib/common.sh URL of its network; both networks must have one.
rpc_defaults() {
    local recs loc net url nt=0 nm=0
    recs="$(tree_records "$1" U)"
    while IFS='|' read -r loc net url; do
        case "$net" in
            testnet)
                nt=$((nt + 1))
                [[ "$url" == "$TESTNET_RPC_URL" ]] || printf '%s: testnet default %s is not TESTNET_RPC_URL (%s)\n' "$loc" "$url" "$TESTNET_RPC_URL" ;;
            mainnet)
                nm=$((nm + 1))
                [[ "$url" == "$MAINNET_RPC_URL" ]] || printf '%s: mainnet default %s is not MAINNET_RPC_URL (%s)\n' "$loc" "$url" "$MAINNET_RPC_URL" ;;
            any) printf '%s: redirect_queries_url defaults to %s on both networks\n' "$loc" "$url" ;;
        esac
    done <<< "$recs"
    [[ $nt -gt 0 ]] || echo "no testnet default of the public RPC URL"
    [[ $nm -gt 0 ]] || echo "no mainnet default of the public RPC URL"
}

# fingerprint FILE... -- the TN_DOCKER_APT_FINGERPRINT values FILE... assign.
fingerprint() {
    sed -n 's/^readonly TN_DOCKER_APT_FINGERPRINT="\([^"]*\)".*/\1/p' "$@" | sort -u
}

# gz_bytes FILE... -- the size of FILE... concatenated, after gzip -9.
gz_bytes() {
    cat "$@" | gzip -9 | wc -c | tr -d '[:space:]'
}

# in_list WORD LIST -- WORD is a line of LIST.
in_list() {
    grep -qxF -- "$1" <<< "$2"
}

# fb_hooks LIB -- the test hooks the "Test hooks" part of LIB's header lists.
fb_hooks() {
    awk '
        /^# Test hooks/ { on = 1; next }
        on && (/^#$/ || /^# [^ ]/ || !/^#/) { exit }
        on && /^#[[:space:]]+TN_FB_[A-Z0-9_]+/ { sub(/^#[[:space:]]+/, ""); sub(/[^A-Z0-9_].*/, ""); print }
    ' "$1" | sort -u
}

# fb_keys SCRIPT LIB -- the FB_KEYS list SCRIPT sets, or else LIB's, one per line.
fb_keys() {
    local f
    for f in "$1" "$2"; do
        if grep -q '^readonly FB_KEYS=' "$f"; then
            sed -n 's/^readonly FB_KEYS="\([^"]*\)".*/\1/p' "$f" | tr ' ' '\n' | grep . | sort -u
            return
        fi
    done
}

# fb_checked LIB -- "ROLE KEY" for each TN_FB_* key fb_validate_env checks:
# ROLE is shared outside its case "$FB_ROLE", else the role of the branch.
fb_checked() {
    awk '
        /^fb_validate_env\(\)[[:space:]]*[{]/ { on = 1; role = "shared"; next }
        on && /^[}]/ { exit }
        !on { next }
        {
            line = $0; sub(/^[[:space:]]*#.*/, "", line); sub(/[[:space:]]#.*/, "", line)
            t = " " line " "
            if (!rc && line ~ /case[[:space:]]+"\$FB_ROLE"[[:space:]]+in/) { rc = 1; nest = 1; next }
            if (rc) {
                if (t ~ /[[:space:];]case[[:space:]]/) nest++
                if (nest == 1 && line ~ /^[[:space:]]*[a-z][a-z0-9_-]*[)][[:space:]]*$/) {
                    role = line; gsub(/[[:space:])]/, "", role); next
                }
                if (t ~ /[[:space:];]esac[[:space:];]/) { nest--; if (nest == 0) { rc = 0; role = "shared"; next } }
            }
            while (match(line, /TN_FB_[A-Z0-9_]+/)) {
                print role, substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$1" | sort -u
}

# fb_reads SCRIPT -- the TN_FB_* names SCRIPT uses outside comments.
fb_reads() {
    sed -e 's/^[[:space:]]*#.*//' -e 's/[[:space:]]#.*//' "$1" | grep -oE 'TN_FB_[A-Z0-9_]+' | sort -u
}

# hp_renders HOST_PLAN -- "LOCAL KEY" for each key the env pair lists of
# HOST_PLAN's locals name, in order; KEY is @shared where local.shared_env
# stands in a list.
hp_renders() {
    local f
    for f in "$1"/*.tf; do
        [[ -f "$f" ]] || continue
        awk '
            /^locals[[:space:]]*[{]/ { inl = 1; next }
            inl && /^[}]/ { inl = 0; cur = ""; next }
            inl && /^  [A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { cur = $1 }
            inl && (cur == "shared_env" || cur == "validator_env_pairs" || cur == "gateway_env_pairs") {
                line = $0; sub(/#.*/, "", line)
                while (match(line, /"TN_FB_[A-Z0-9_]+"|local\.shared_env/)) {
                    t = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
                    if (t == "local.shared_env") print cur, "@shared"; else print cur, substr(t, 2, length(t) - 2)
                }
            }
        ' "$f"
    done
}

# rendered ROLE RENDERS -- the keys host-plan renders for ROLE, one per line,
# a key given twice listed twice.
rendered() {
    local l k
    while read -r l k; do
        [[ "$l" == "${1}_env_pairs" ]] || continue
        if [[ "$k" == @shared ]]; then
            awk '$1 == "shared_env" { print $2 }' <<< "$2"
        else
            printf '%s\n' "$k"
        fi
    done <<< "$2"
}

# env_contract TREE -- every break of the env file contract between
# TREE/modules/host-plan and the first-boot scripts of TREE/first-boot.
env_contract() {
    local fb="$1/first-boot" hp="$1/modules/host-plan" lib hooks checked renders role script keys acc rend k all="" union=""
    lib="$fb/first-boot-lib.sh"
    hooks="$(fb_hooks "$lib")"
    checked="$(fb_checked "$lib")"
    renders="$(hp_renders "$hp")"
    [[ -n "$checked" ]] || echo "first-boot-lib.sh: fb_validate_env checks no TN_FB_ key"
    [[ -n "$renders" ]] || echo "host-plan: no shared_env, validator_env_pairs or gateway_env_pairs local"
    for role in validator gateway; do
        script="$fb/first-boot-${role}.sh"
        keys="$(fb_keys "$script" "$lib")"
        all="${all}${keys}
"
        acc="$(awk -v r="$role" '$1 == "shared" || $1 == r { print $2 }' <<< "$checked" | sort -u)"
        union="${union}${acc}
"
        rend="$(rendered "$role" "$renders")"
        for k in $acc; do
            in_list "$k" "$keys" || echo "${role}: fb_validate_env checks ${k}, which FB_KEYS leaves out"
            in_list "$k" "$rend" || echo "${role}: first-boot-${role}.sh takes ${k}; host-plan does not render it"
        done
        for k in $(fb_reads "$script"); do
            in_list "$k" "$hooks" || in_list "$k" "$acc" \
                || echo "${role}: first-boot-${role}.sh reads ${k}, which the ${role} role does not take"
        done
        for k in $(sort -u <<< "$rend"); do
            in_list "$k" "$acc" || echo "${role}: host-plan renders ${k}; first-boot-${role}.sh does not take it"
        done
        for k in $(sort <<< "$rend" | uniq -d); do
            echo "${role}: host-plan renders ${k} twice"
        done
    done
    for k in $(sort -u <<< "$all"); do
        in_list "$k" "$union" || echo "FB_KEYS holds ${k}, which no role checks"
    done
}

# open_rules TREE -- every .tf rule under TREE open to the world on 22, 8545
# or 43174 (see tf_scan).
open_rules() {
    tree_records "$1" O | sed 's/|/: /'
}

# secret_words TREE -- each line under TREE that holds password, secret or token
# (in any case) outside a comment, once the SECRET_ALLOW phrases are taken out.
# Markdown is prose about the tree, not part of it; .terraform is a working
# directory.
secret_words() {
    local tree="$1" f mode
    while IFS= read -r f; do
        case "$f" in
            *.md) continue ;;
            *.tf|*.hcl|*.tfvars|*.tfvars.example) mode=hcl ;;
            *.tftpl) mode=none ;;
            *) mode="hash" ;;
        esac
        awk -v mode="$mode" -v allow="$SECRET_ALLOW" -v name="${f#./}" '
            BEGIN { na = split(allow, A, " ") }
            FNR == 1 { inc = 0 }
            {
                s = $0
                if (mode == "hcl") {
                    out = ""
                    while (s != "") {
                        if (inc) {
                            i = index(s, "*/")
                            if (i == 0) { s = ""; break }
                            s = substr(s, i + 2); inc = 0; continue
                        }
                        i = 0
                        if (substr(s, 1, 2) == "/*") i = 1
                        else if (match(s, /[[:space:]]\/\*/)) i = RSTART + 1
                        if (i == 0) { out = out s; s = ""; break }
                        out = out substr(s, 1, i - 1); s = substr(s, i + 2); inc = 1
                    }
                    s = out
                    sub(/^[[:space:]]*\/\/.*/, "", s); sub(/[[:space:]]\/\/.*/, "", s)
                }
                if (mode != "none") { sub(/^[[:space:]]*#.*/, "", s); sub(/[[:space:]]#.*/, "", s) }
                t = tolower(s)
                for (j = 1; j <= na; j++) gsub(A[j], "", t)
                if (t ~ /password|secret|token/) { l = $0; sub(/^[[:space:]]+/, "", l); print name ":" FNR ": " l }
            }
        ' "$tree/${f#./}"
    done < <(cd "$tree" && find . -name .terraform -prune -o -type f -print | sort)
}

# -----------------------------------------------------------------------------
# The tree
# -----------------------------------------------------------------------------

show="${TF#"$TN_TEST_REPO"/}"

check "check-terraform.sh: every image is name:tag@sha256:<64 hex> and every docker run runs one" "" \
    "$(image_pins "$CHECK_TF")"
check "check-terraform.sh: pins terraform, tflint and checkov" \
    "hashicorp/terraform terraform-linters/tflint bridgecrew/checkov" \
    "$(vars="$(image_vars "$CHECK_TF")"
    for i in hashicorp/terraform terraform-linters/tflint bridgecrew/checkov; do
        grep -q "|\([^|]*/\)\{0,1\}${i}:" <<< "$vars" && printf '%s ' "$i"
    done | sed 's/ $//')"

for cloud in aws gcp azure; do
    if [[ -d "$TF/$cloud" ]]; then
        check "${cloud}: the data disk, static public IPs and validator VM hold prevent_destroy = true" "" \
            "$(protected "$TF" "$cloud")"
    else
        skip "${cloud}: the data disk, static public IPs and validator VM hold prevent_destroy = true" \
            "${show}/${cloud} does not exist yet"
    fi
done

check "the per-network public RPC defaults equal TESTNET_RPC_URL and MAINNET_RPC_URL" "" "$(rpc_defaults "$TF")"

setup_fpr="$(fingerprint "$TN_TEST_REPO/setup-node.sh")"
re40='^[0-9A-F]{40}$'
check "setup-node.sh: TN_DOCKER_APT_FINGERPRINT is 40 hex digits" "yes" \
    "$([[ "$setup_fpr" =~ $re40 ]] && echo yes || echo "no: $setup_fpr")"
check "first boot: the Docker apt key fingerprint equals setup-node.sh's" "$setup_fpr" \
    "$(fingerprint "$TF/first-boot/first-boot-gateway.sh" "$TF/first-boot/first-boot-lib.sh")"

check "env file: each role's keys are the ones host-plan renders for it, none twice" "" "$(env_contract "$TF")"

for role in gateway validator; do
    if [[ "$role" == gateway ]]; then budget="$GZ_BUDGET_GATEWAY"; else budget="$GZ_BUDGET_VALIDATOR"; fi
    n="$(gz_bytes "$TF/first-boot/first-boot-lib.sh" "$TF/first-boot/first-boot-${role}.sh")"
    check "first-boot-lib.sh + first-boot-${role}.sh: gzip -9 ${n} bytes, under ${budget}" "yes" \
        "$([[ "$n" -gt 0 && "$n" -lt "$budget" ]] && echo yes || echo no)"
done

check "no .tf rule opens 22, 8545 or 43174 to the world" "" "$(open_rules "$TF")"
check "no password, secret or token outside comments under ${show}" "" "$(secret_words "$TF")"

# -----------------------------------------------------------------------------
# The rules on fixtures: one tree that keeps every rule, one that breaks each.
# The nested runs at the end set _TN_TF_STATIC_NESTED and skip this part.
# -----------------------------------------------------------------------------

if [[ -n "${_TN_TF_STATIC_NESTED:-}" ]]; then
    finish
fi

OK="$T/fx/ok"
BAD="$T/fx/bad"
mkdir -p "$OK/aws" "$OK/gcp" "$OK/azure" "$OK/aws/.terraform" "$BAD/aws" "$BAD/gcp" "$BAD/azure"
cp -R "$TF/first-boot" "$TF/modules" "$OK/"
cp -R "$TF/first-boot" "$TF/modules" "$BAD/"

cat > "$OK/aws/main.tf" <<'EOF'
# Nothing here is secret.
locals {
  anywhere = "0.0.0.0/0"
  ingress = {
    p2p_primary = { cidr = "0.0.0.0/0", port = 49590, proto = "udp" }
    web         = { cidr = local.anywhere, port = 443, proto = "tcp" }
  }
}

variable "admin_ssh_cidrs" {
  type    = list(string)
  default = []
  validation {
    condition     = !contains(var.admin_ssh_cidrs, "0.0.0.0/0")
    error_message = "admin_ssh_cidrs must not hold 0.0.0.0/0."
  }
}

variable "redirect_queries_url" {
  type    = string
  default = ""
}

resource "aws_ebs_volume" "data" {
  size = 500
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip" "validator" {
  domain = "vpc"
  lifecycle { prevent_destroy = true }
}

resource "aws_eip" "gateway" {
  domain = "vpc"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_instance" "validator" {
  user_data_base64 = base64gzip("${local.anywhere}")
  metadata_options {
    http_tokens = "required"
  }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [ami, user_data_base64]
  }
}

/* The gateway is disposable,
   so it carries no lifecycle block. */
resource "aws_instance" "gateway" {
  count     = var.rpc_domain != "" ? 1 : 0
  user_data = <<-EOT
    { unbalanced
  EOT
}

resource "aws_vpc_security_group_ingress_rule" "p2p" {
  for_each    = toset(["49590", "49594"])
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = each.value
  to_port     = each.value
  ip_protocol = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each    = toset(var.admin_ssh_cidrs)
  cidr_ipv4   = each.value
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "rpc" {
  cidr_ipv4   = "${aws_network_interface.gateway.private_ip}/32"
  from_port   = 8545
  to_port     = 8545
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ping" {
  cidr_ipv6   = "::/0"
  from_port   = -1
  to_port     = -1
  ip_protocol = "icmpv6"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_route" "internet" {
  destination_cidr_block = "0.0.0.0/0"
}

resource "aws_route_table" "main" {
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_security_group" "web" {
  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
  }
  egress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }
}

locals {
  p2p_ports = [49590, 49594]
  rpc_port  = 8545
}

resource "aws_vpc_security_group_ingress_rule" "p2p_from_local" {
  for_each    = toset(local.p2p_ports)
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = each.value
  to_port     = each.value
  ip_protocol = "udp"
}

resource "aws_vpc_security_group_ingress_rule" "rpc_from_local" {
  cidr_ipv4   = "10.42.1.20/32"
  from_port   = local.rpc_port
  to_port     = local.rpc_port
  ip_protocol = "tcp"
}
EOF

cat > "$OK/gcp/main.tf" <<EOF
variable "redirect_queries_url" {
  type = map(string)
  default = {
    testnet = "${TESTNET_RPC_URL}"
    mainnet = "${MAINNET_RPC_URL}"
  }
}

resource "google_compute_disk" "data" {
  type = "hyperdisk-balanced"
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_address" "validator_public" {
  address_type = "EXTERNAL"
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_address" "gateway_public" {
  lifecycle {
    prevent_destroy = true
  }
}

# A fixed private address is no public one.
resource "google_compute_address" "validator_private" {
  address_type = "INTERNAL"
}

resource "google_compute_instance" "validator" {
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata["user-data"]]
  }
}

resource "google_compute_firewall" "p2p" {
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "udp"
    ports    = ["49590", "49594"]
  }
  allow {
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "iap_ssh" {
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "deny_rpc" {
  source_ranges = ["0.0.0.0/0"]
  deny {
    protocol = "tcp"
    ports    = ["8545", "43174"]
  }
}

resource "google_compute_firewall" "egress" {
  direction          = "EGRESS"
  destination_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "all"
  }
}
EOF

cat > "$OK/azure/main.tf" <<'EOF'
resource "azurerm_managed_disk" "data" {
  storage_account_type = "PremiumV2_LRS"
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_public_ip" "validator" {
  allocation_method = "Static"
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_public_ip" "gateway" {
  allocation_method = "Static"
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_public_ip" "bastion" {
  count             = var.enable_bastion ? 1 : 0
  allocation_method = "Static"
}

resource "azurerm_linux_virtual_machine" "validator" {
  disable_password_authentication = true
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [custom_data]
  }
}

resource "azurerm_network_security_rule" "p2p" {
  priority                   = 100
  direction                  = "Inbound"
  access                     = "Allow"
  protocol                   = "Udp"
  source_port_range          = "*"
  destination_port_ranges    = ["49590", "49594"]
  source_address_prefix      = "*"
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "web" {
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "443"
  source_address_prefix      = "Internet"
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "rpc_from_gateway" {
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_ranges    = ["8545", "43174"]
  source_address_prefix      = "10.42.1.20/32"
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "deny_rpc" {
  priority                   = 4000
  access                     = "Deny"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_ranges    = ["8545", "43174"]
  source_address_prefix      = "*"
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "out" {
  direction                  = "Outbound"
  access                     = "Allow"
  protocol                   = "*"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
}
EOF

printf '# Operators: no password reaches the state.\nThe token and the secret are never stored.\n' > "$OK/README.md"
printf 'binary provider data: token secret password\n' > "$OK/aws/.terraform/provider"
printf '#!/bin/sh\n# no secret here\necho "${#x}" # the token count\n' > "$OK/aws/helper.sh"

cat > "$BAD/aws/main.tf" <<'EOF'
resource "aws_ebs_volume" "data" {
  size = 500
  # lifecycle { prevent_destroy = true }
}

resource "aws_eip" "validator" {
  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_eip" "gateway" {
  tags = {
    note = "prevent_destroy = true"
  }
}

resource "aws_instance" "gateway" {
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh_world" {
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 22
  to_port     = 22
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "wide" {
  cidr_ipv6   = "::/0"
  from_port   = 1024
  to_port     = 65535
  ip_protocol = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "all_traffic" {
  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "unwritten" {
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = var.rpc_port
  to_port     = var.rpc_port
  ip_protocol = "tcp"
}

resource "aws_security_group" "inline" {
  ingress {
    cidr_blocks = [
      "10.0.0.0/8",
      "0.0.0.0/0",
    ]
    from_port = 43174
    to_port   = 43174
    protocol  = "tcp"
  }
}

locals {
  rules = {
    rpc = { cidr = "0.0.0.0/0", port = 8545 }
  }
}

variable "admin_ssh_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "redirect_queries_url" {
  type    = string
  default = "https://rpc.example.org"
}

locals {
  admin_ports = [22]
}

resource "aws_vpc_security_group_ingress_rule" "ssh_from_local" {
  for_each    = toset(local.admin_ports)
  cidr_ipv4   = "0.0.0.0/0"
  from_port   = each.value
  to_port     = each.value
  ip_protocol = "tcp"
}

resource "aws_security_group" "legacy" {
  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }
}
EOF

cat > "$BAD/gcp/main.tf" <<EOF
variable "redirect_queries_url" {
  type = map(string)
  default = {
    testnet = "${TESTNET_RPC_URL}"
    mainnet = "https://rpc.example.net"
  }
}

resource "google_compute_disk" "data" {
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_address" "validator_public" {
  region = "us-central1"
}

resource "google_compute_instance" "validator" {
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_firewall" "all_tcp" {
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
  }
}

resource "google_compute_firewall" "range" {
  source_ranges = ["10.0.0.0/8", "::/0"]
  allow {
    protocol = "tcp"
    ports    = ["8000-9000"]
  }
}

resource "google_compute_firewall" "everything" {
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "all"
  }
}
EOF

cat > "$BAD/azure/main.tf" <<'EOF'
resource "azurerm_managed_disk" "data" {
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_public_ip" "validator" {
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_public_ip" "gateway" {
  allocation_method = "Static"
}

resource "azurerm_linux_virtual_machine" "validator" {
  admin_password = "x"
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_network_security_rule" "ssh" {
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "22"
  source_address_prefix      = "*"
  destination_address_prefix = "*"
}

resource "azurerm_network_security_rule" "any_port" {
  access                     = "Allow"
  protocol                   = "Tcp"
  source_port_range          = "*"
  destination_port_range     = "*"
  source_address_prefixes    = ["Internet"]
  destination_address_prefix = "*"
}

resource "azurerm_network_security_group" "inline" {
  security_rule {
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["43174"]
    source_address_prefix      = "0.0.0.0/0"
    destination_address_prefix = "*"
  }
}
EOF

printf 'framework:\n  - terraform\napi_token: abc\n' > "$BAD/settings.yaml"
printf '#!/bin/sh\nSECRET=abc # set here\n' > "$BAD/aws/helper.sh"

for cloud in aws gcp azure; do
    check "fixture ok: ${cloud} protected resources pass" "" "$(protected "$OK" "$cloud")"
done
check "fixture bad: aws protected resources" "aws/main.tf:1: aws_ebs_volume.data (the data disk) has no prevent_destroy = true in its lifecycle block
aws/main.tf:6: aws_eip.validator (the static public IPs) has no prevent_destroy = true in its lifecycle block
aws/main.tf:12: aws_eip.gateway (the static public IPs) has no prevent_destroy = true in its lifecycle block
aws: no aws_instance block validator (the validator VM)" "$(protected "$BAD" aws)"
check "fixture bad: gcp protected resources (an address with no address_type is external)" \
    "gcp/main.tf:15: google_compute_address.validator_public (the static public IPs) has no prevent_destroy = true in its lifecycle block" \
    "$(protected "$BAD" gcp)"
check "fixture bad: azure protected resources" \
    "azure/main.tf:13: azurerm_public_ip.gateway (the static public IPs) has no prevent_destroy = true in its lifecycle block" \
    "$(protected "$BAD" azure)"
mkdir -p "$T/fx/empty/gcp"
check "fixture: a root without its types fails on each" "gcp: no google_compute_disk block (the data disk)
gcp: no google_compute_address block external (the static public IPs)
gcp: no google_compute_instance block validator (the validator VM)" "$(protected "$T/fx/empty" gcp)"

check "fixture ok: no rule open to the world on 22, 8545 or 43174" "" "$(open_rules "$OK")"
check "fixture bad: each open rule is found" 'aws/main.tf:25: resource "aws_vpc_security_group_ingress_rule" "ssh_world": port 22 open to "0.0.0.0/0"
aws/main.tf:32: resource "aws_vpc_security_group_ingress_rule" "wide": port 8545 open to "::/0"
aws/main.tf:39: resource "aws_vpc_security_group_ingress_rule" "all_traffic": port 22 open to "0.0.0.0/0"
aws/main.tf:44: resource "aws_vpc_security_group_ingress_rule" "unwritten": ports it does not write out open to "0.0.0.0/0"
aws/main.tf:54: resource "aws_security_group" "inline" > ingress: port 43174 open to "0.0.0.0/0"
aws/main.tf:64: locals > rules > rpc: port 8545 open to "0.0.0.0/0"
aws/main.tf:70: variable "admin_ssh_cidrs": defaults to "0.0.0.0/0"
aws/main.tf:84: resource "aws_vpc_security_group_ingress_rule" "ssh_from_local": port 22 open to "0.0.0.0/0"
aws/main.tf:92: resource "aws_security_group" "legacy" > ingress: port 22 open to "0.0.0.0/0"
azure/main.tf:29: resource "azurerm_network_security_rule" "ssh": port 22 open to "*"
azure/main.tf:38: resource "azurerm_network_security_rule" "any_port": port 22 open to "Internet"
azure/main.tf:48: resource "azurerm_network_security_group" "inline" > security_rule: port 43174 open to "0.0.0.0/0"
gcp/main.tf:26: resource "google_compute_firewall" "all_tcp": port 22 open to "0.0.0.0/0"
gcp/main.tf:33: resource "google_compute_firewall" "range": port 8545 open to "::/0"
gcp/main.tf:41: resource "google_compute_firewall" "everything": port 22 open to "0.0.0.0/0"' "$(open_rules "$BAD")"

check "fixture ok: the public RPC defaults pass (empty, a per-network map, host-plan's)" "" "$(rpc_defaults "$OK")"
check "fixture bad: a single default and a wrong mainnet URL are found" "aws/main.tf:75: redirect_queries_url defaults to https://rpc.example.org on both networks
gcp/main.tf:5: mainnet default https://rpc.example.net is not MAINNET_RPC_URL (${MAINNET_RPC_URL})" "$(rpc_defaults "$BAD")"
rm -rf "$T/fx/none"
mkdir -p "$T/fx/none/modules/host-plan"
printf 'locals {\n  x = 1\n}\n' > "$T/fx/none/modules/host-plan/main.tf"
check "fixture: no default at all is found" "no testnet default of the public RPC URL
no mainnet default of the public RPC URL" "$(rpc_defaults "$T/fx/none")"

check "fixture ok: no password, secret or token outside comments (README.md and .terraform/ skipped)" "" \
    "$(secret_words "$OK")"
check "fixture bad: each password, secret or token outside comments is found" "aws/helper.sh:2: SECRET=abc # set here
azure/main.tf:18: admin_password = \"x\"
settings.yaml:3: api_token: abc" "$(secret_words "$BAD")"

mkdir -p "$T/fx/pins"
cat > "$T/fx/pins/check.sh" <<'EOF'
readonly TF_IMAGE="hashicorp/terraform:1.17.2"
readonly LINT_IMAGE="ghcr.io/x/y:v1@sha256:abc"
GOOD_IMAGE="bridgecrew/checkov:3.4.11@sha256:68da9ede242807850ab346b533dc1e4d2b00e15a9e6b4b595654d39c7f2e2566"
# docker run --rm alpine:3.20 true
docker run --rm alpine:3.20 true
docker run --rm \
    -v "$PWD:/w" "$GOOD_IMAGE" --version
docker run --rm "${GOOD_IMAGE}" --version
EOF
check "fixture: an image without a digest and a docker run without a pinned image are found" \
    "TF_IMAGE=hashicorp/terraform:1.17.2 is not name:tag@sha256:<64 hex>
LINT_IMAGE=ghcr.io/x/y:v1@sha256:abc is not name:tag@sha256:<64 hex>
docker run without a pinned image variable: docker run --rm alpine:3.20 true" "$(image_pins "$T/fx/pins/check.sh")"

printf 'readonly TN_DOCKER_APT_FINGERPRINT="0000000000000000000000000000000000000000"\n' > "$T/fx/fpr.sh"
check "fixture: a different fingerprint is told apart" "no" \
    "$([[ "$(fingerprint "$T/fx/fpr.sh")" == "$setup_fpr" ]] && echo yes || echo no)"

check "fixture: a gzip budget below the size fails" "no" \
    "$([[ "$(gz_bytes "$TF/first-boot/first-boot-lib.sh")" -lt 1000 ]] && echo yes || echo no)"

# The env file contract on a small library, two role scripts and a host-plan
# whose keys match; then one break at a time.
EC="$T/fx/contract"
mkdir -p "$EC/first-boot" "$EC/modules/host-plan"
cat > "$EC/first-boot/first-boot-lib.sh" <<'EOF'
# Test hooks (the fixture tests set them; cloud-init does not):
#   TN_FB_ROOT       prefix of every path
#   TN_FB_WAIT_STEP  seconds a wait sleeps
# Each is checked.
readonly FB_KEYS="TN_FB_ROLE TN_FB_NETWORK TN_FB_DATA_DEVICE TN_FB_UPSTREAM"
fb_validate_env() {
    [ "$TN_FB_ROLE" = "$FB_ROLE" ] || fb_bad
    case "$TN_FB_NETWORK" in
        testnet|mainnet) ;;
        *) fb_bad ;;
    esac
    case "$FB_ROLE" in
        validator)
            case "$TN_FB_DATA_DEVICE" in
                /dev/?*) ;;
                *) fb_bad ;;
            esac
            ;;
        gateway)
            [ -n "$TN_FB_UPSTREAM" ] || fb_bad
            ;;
    esac
}
EOF
printf '#!/usr/bin/env bash\n# TN_FB_UPSTREAM is the gateway'"'"'s.\necho "$TN_FB_DATA_DEVICE" "${TN_FB_WAIT_STEP:-5}"\n' \
    > "$EC/first-boot/first-boot-validator.sh"
printf '#!/usr/bin/env bash\necho "$TN_FB_UPSTREAM" "$TN_FB_NETWORK"\n' > "$EC/first-boot/first-boot-gateway.sh"
cat > "$EC/modules/host-plan/main.tf" <<'EOF'
locals {
  shared_env = [
    ["TN_FB_NETWORK", var.network],
  ]
  validator_env_pairs = concat([["TN_FB_ROLE", "validator"]], local.shared_env, [
    ["TN_FB_DATA_DEVICE", var.data_device],
  ])
  gateway_env_pairs = concat([["TN_FB_ROLE", "gateway"]], local.shared_env, [
    ["TN_FB_UPSTREAM", var.validator_private_ip],
  ])
}
EOF
cp -R "$EC" "$T/fx/contract.orig"

# contract_with FILE SED -- env_contract after SED edits FILE (relative to the
# fixture), the fixture restored afterwards.
contract_with() {
    sed "$2" "$T/fx/contract.orig/$1" > "$EC/$1"
    env_contract "$EC"
    cp "$T/fx/contract.orig/$1" "$EC/$1"
}
check "fixture: matching keys keep the contract" "" "$(env_contract "$EC")"
check "fixture: a key the gateway takes and host-plan leaves out" \
    "gateway: first-boot-gateway.sh takes TN_FB_UPSTREAM; host-plan does not render it" \
    "$(contract_with modules/host-plan/main.tf '/"TN_FB_UPSTREAM"/d')"
check "fixture: a key host-plan renders and the validator does not take" \
    "validator: host-plan renders TN_FB_DOMAIN; first-boot-validator.sh does not take it" \
    "$(contract_with modules/host-plan/main.tf '/"TN_FB_DATA_DEVICE"/a\
    ["TN_FB_DOMAIN", var.rpc_domain],
')"
check "fixture: a key rendered twice for one role" "gateway: host-plan renders TN_FB_NETWORK twice" \
    "$(contract_with modules/host-plan/main.tf '/"TN_FB_UPSTREAM"/a\
    ["TN_FB_NETWORK", var.network],
')"
check "fixture: a role script that reads another role's key" \
    "validator: first-boot-validator.sh reads TN_FB_UPSTREAM, which the validator role does not take" \
    "$(contract_with first-boot/first-boot-validator.sh '$a\
echo "$TN_FB_UPSTREAM"
')"
check "fixture: a checked key that FB_KEYS leaves out" \
    "gateway: fb_validate_env checks TN_FB_UPSTREAM, which FB_KEYS leaves out" \
    "$(contract_with first-boot/first-boot-lib.sh '/^readonly FB_KEYS=/s/ TN_FB_UPSTREAM"/"/')"
check "fixture: an FB_KEYS key that no role checks" "FB_KEYS holds TN_FB_SPARE, which no role checks" \
    "$(contract_with first-boot/first-boot-lib.sh '/^readonly FB_KEYS=/s/"$/ TN_FB_SPARE"/')"

# The whole test against each fixture tree, through TN_TERRAFORM_DIR.
_TN_TF_STATIC_NESTED=1 TN_TERRAFORM_DIR="$OK" "${BASH:-bash}" "$TN_TEST_DIR/terraform_static_test.sh" > "$T/nested-ok" 2>&1
rc=$?
check_rc "TN_TERRAFORM_DIR at the passing tree: exit 0" 0 "$rc"
check "TN_TERRAFORM_DIR at the passing tree: no root skipped" "0" "$(grep -c '^SKIP' "$T/nested-ok")"
[[ "$rc" -eq 0 ]] || sed 's/^/      /' "$T/nested-ok"
_TN_TF_STATIC_NESTED=1 TN_TERRAFORM_DIR="$BAD" "${BASH:-bash}" "$TN_TEST_DIR/terraform_static_test.sh" > "$T/nested-bad" 2>&1
check_rc "TN_TERRAFORM_DIR at the failing tree: exit 1" 1 "$?"
check "TN_TERRAFORM_DIR at the failing tree: the rules that fail" "FAIL  aws: the data disk, static public IPs and validator VM hold prevent_destroy = true
FAIL  gcp: the data disk, static public IPs and validator VM hold prevent_destroy = true
FAIL  azure: the data disk, static public IPs and validator VM hold prevent_destroy = true
FAIL  the per-network public RPC defaults equal TESTNET_RPC_URL and MAINNET_RPC_URL
FAIL  no .tf rule opens 22, 8545 or 43174 to the world
FAIL  no password, secret or token outside comments under ${BAD}" "$(grep '^FAIL' "$T/nested-bad")"

finish
