#!/usr/bin/env python3
"""tasks/verify-fup/V5/mutate.py -- revert one behaviour's hunk at a time in a
copy of HEAD and confirm V5's harness fails there (a check that passes on the
tip fails on the mutant). From the repository root:

    python3 tasks/verify-fup/V5/mutate.py SCRATCH_DIR [NAME...]

Bash parts run under the host bash; pytest in python:3.10-slim; the page in
node:22-slim. Results go to tasks/verify-fup/V5/records/mutation.txt.
"""
import os, re, shutil, subprocess, sys

ROOT = os.getcwd()
D = "tasks/verify-fup/V5"
SCRATCH = os.path.abspath(sys.argv[1])
ONLY = set(sys.argv[2:])
FW, RM, HLP, PY, JS = "fw_v5_test.sh", "rm_v5_test.sh", "helper_v5_test.sh", "pytest", "node"

M = [
    ("fw-no-ct-state-new", "firewall-setup.sh", "ct state new udp dport", "udp dport", FW),
    ("fw-v6-no-64-mask", "firewall-setup.sh", "ip6 saddr & ffff:ffff:ffff:ffff:: limit", "ip6 saddr limit", FW),
    ("fw-priority-0", "firewall-setup.sh", "hook input priority -10;", "hook input priority 0;", FW),
    ("fw-no-delete-in-txn", "firewall-setup.sh", "table inet tn_p2p\ndelete table inet tn_p2p\ntable inet tn_p2p {", "table inet tn_p2p {", FW),
    ("fw-accept-verdict", "firewall-setup.sh", "burst ${burst} packets } drop\n        ct state new udp dport { ${dports} } update @tn_p2p_src6", "burst ${burst} packets } drop\n        ct state established accept\n        ct state new udp dport { ${dports} } update @tn_p2p_src6", FW),
    ("fw-no-sync-in-apply", "firewall-setup.sh", "    fw_snapshot_drop\n    fw_p2p_limit_sync \"$nodes\"\n", "    fw_snapshot_drop\n", FW),
    ("fw-sync-before-ufw", "firewall-setup.sh", "    fw_snapshot_drop\n    fw_p2p_limit_sync \"$nodes\"\n", "    fw_snapshot_drop\n", FW,
     ("    FW_APPLY_INFLIGHT=true\n    if ! fw_apply_rules", "    FW_APPLY_INFLIGHT=true\n    fw_p2p_limit_sync \"$nodes\"\n    if ! fw_apply_rules")),
    ("fw-no-env-validation", "firewall-setup.sh", "    fw_p2p_limit_load || return 1\n", "    fw_p2p_limit_load || true\n", FW),
    ("fw-count-ok-loose", "firewall-setup.sh", "[[ \"${1:-}\" =~ ^[1-9][0-9]{0,5}$ ]] && (( ${1} <= 100000 ))", "[[ \"${1:-}\" =~ ^[0-9]+$ ]]", FW),
    ("fw-no-nft-warning", "firewall-setup.sh", "print_warn \"nftables (nft) is not installed, so the P2P new-flow limit is not applied; P2P stays open to every source\"", ":", FW),
    ("fw-no-persist", "firewall-setup.sh", "        fw_p2p_limit_persist \"$prog\" || true\n", "", FW),
    ("fw-no-unpersist", "firewall-setup.sh", "    fw_p2p_limit_unpersist\n    command -v nft", "    command -v nft", FW),
    ("fw-enable-now", "firewall-setup.sh", "! systemctl enable \"$FW_P2P_LIMIT_SVC\"", "! systemctl enable --now \"$FW_P2P_LIMIT_SVC\"", FW),
    ("fw-file-mode-0644", "firewall-setup.sh", "tn_write_root_file \"$FW_P2P_LIMIT_FILE\" 0640", "tn_write_root_file \"$FW_P2P_LIMIT_FILE\" 0644", FW),
    ("fw-json-no-persistent", "firewall-setup.sh", ",\\\"reason\\\":null,\\\"persistent\\\":${persistent}}", ",\\\"reason\\\":null}", FW),
    ("fw-desired-anywhere", "firewall-setup.sh", "\"${p2p_src:-anywhere}\"", "\"anywhere\"", FW),
    ("fw-menu-no-sync", "firewall-setup.sh", "                fw_p2p_limit_sync \"$nodes\"\n", "                :\n", FW),
    ("fw-boot-ignores-unit", "firewall-setup.sh", "[[ -f \"$FW_P2P_LIMIT_FILE\" ]] && systemctl is-enabled", "[[ -f \"$FW_P2P_LIMIT_FILE\" ]] || systemctl is-enabled", FW),
    ("rm-no-teardown", "remove-node.sh", "    _rm_p2p_limit\n", "", RM),
    ("rm-no-table-delete", "remove-node.sh", "    if nft -f - >/dev/null 2>&1 <<< $'table inet tn_p2p\\ndelete table inet tn_p2p'; then", "    if true; then", RM),
    ("helper-no-p2p-arg", "ui/telcoin-ui-helper.sh", "        args+=( --p2p-from \"$p2p\" )\n", "", HLP),
    ("helper-no-slash-check", "ui/telcoin-ui-helper.sh", "    [[ \"$list\" != /* ]] || die", "    true || die", HLP),
    ("helper-no-engine-check", "ui/telcoin-ui-helper.sh", "        engine_has \"$FIREWALL_SCRIPT\" --p2p-from\n", "", HLP),
    ("server-no-dash", "ui/server.py", "argv.append(ssh_from or \"-\")", "argv.append(ssh_from)", PY),
    ("server-no-p2p-check", "ui/server.py", "    return fw_source_list(text, \"p2p_from\", \"P2P\")", "    return (text if isinstance(text, str) else None), None", PY),
    ("server-no-status-page", "ui/server.py", "            \"status_page\": status_page_link(slug),\n            \"title\": title_default,", "            \"title\": title_default,", PY),
    ("server-keeps-meta-cache", "ui/server.py", "    clear_meta_cache()      # the engine", "    pass  # the engine", PY),
    ("unit-no-limitcore", "ui/telcoin-ui.service", "LimitCORE=0\n", "", PY),
    ("page-adiri-link", "ui/static/index.html", "        ${statusPageLink(d)}\n", "        <a href=\"https://status.adiri.telcoin.network/\">status page</a>\n", PY),
    ("page-http-link", "ui/static/index.html", "if(!/^https:\\/\\/[^\\s\"'<>]+$/.test(url)) return '';", "if(!url) return '';", JS),
    ("page-no-boot-note", "ui/static/index.html", "(l.persistent===false ? ' (not restored at boot)' : '')", "''", JS),
]

def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)

def tree(name):
    t = os.path.join(SCRATCH, name)
    shutil.rmtree(t, ignore_errors=True)
    os.makedirs(t)
    a = subprocess.Popen(["git", "archive", "HEAD"], stdout=subprocess.PIPE, cwd=ROOT)
    subprocess.run(["tar", "-x", "-C", t], stdin=a.stdout, check=True)
    a.wait()
    return t

def run(test, t):
    env = dict(os.environ, V5_SRC=t)
    if test == PY:
        r = sh(["docker", "run", "--rm", "-v", ROOT + ":/w", "-v", SCRATCH + ":/m", "-w", "/w", "-e", "PYTHONDONTWRITEBYTECODE=1", "-e",
                "V5_SRC=/m/" + os.path.basename(t), "python:3.10-slim", "sh", "-c",
                "pip install -q --require-hashes -r ui/requirements.txt -r ui/tests/requirements-dev.txt >/dev/null 2>&1 "
                "&& python -m pytest -q -p no:cacheprovider --tb=no -rf " + D + " 2>&1 | grep -v 'tn-ui]'"])
        return set(re.findall(r"^((?:SUB)?FAILED(?:\([^)]*\))? \S+)", r.stdout, re.M)), r.stdout.strip().splitlines()[-1:] 
    if test == JS:
        r = sh(["docker", "run", "--rm", "-v", ROOT + ":/w", "-v", SCRATCH + ":/m", "-w", "/w", "node:22-slim",
                "node", D + "/render_v5.js", "/m/" + os.path.basename(t)])
    else:
        r = sh(["bash", os.path.join(D, test)], env=env)
    out = r.stdout + r.stderr
    return set(re.findall(r"^FAIL\s+(.+)$", out, re.M)), [l for l in out.splitlines() if "checks," in l][-1:]

base = {}
lines = []
for m in M:
    name, f, old, new, test = m[:5]
    extra = m[5] if len(m) > 5 else None
    if ONLY and name not in ONLY:
        continue
    if test not in base:
        base[test] = run(test, tree("base-" + test.replace(".", "-")))[0]
        lines.append("baseline %-18s FAILs at tip: %d %s" % (test, len(base[test]), sorted(base[test])))
    t = tree(name)
    p = os.path.join(t, f)
    text = open(p, encoding="utf-8").read()
    if text.count(old) < 1:
        lines.append("%-26s NOT APPLIED (old text not found)" % name)
        continue
    text = text.replace(old, new)
    if extra:
        assert text.count(extra[0]) == 1, name
        text = text.replace(extra[0], extra[1])
    open(p, "w", encoding="utf-8").write(text)
    fails, summary = run(test, t)
    new_fails = sorted(fails - base[test])
    lines.append("%-26s %-6s %s  new FAILs: %s" % (name, "KILLED" if new_fails else "SURVIVED", test,
                                                   "; ".join(new_fails)[:300]))
    shutil.rmtree(t, ignore_errors=True)
    print(lines[-1], flush=True)
open(os.path.join(D, "records", os.environ.get("V5_MUT_OUT", "mutation.txt")), "w").write("\n".join(lines) + "\n")
