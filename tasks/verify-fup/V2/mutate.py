#!/usr/bin/env python3
"""V2 mutation run: revert or break one behaviour of KEYS / AUDIT / c4322d4 in a
temp copy of the tree, run the V2 harness file that guards it there, and report
whether the harness fails (it must). Run from the repository root:

    python3 -I tasks/verify-fup/V2/mutate.py [NAME ...]

Copies go to tasks/verify-fup/V2/work/mut/<NAME>/ (not committed). Harness files
named "host:" run under this host's bash as this user; "ubuntu:" run in
ubuntu:24.04 as root. The result table is printed and written to
tasks/verify-fup/V2/records/mutations.txt.
"""
import os, shutil, subprocess, sys

ROOT = os.getcwd()
D = os.path.join(ROOT, "tasks/verify-fup/V2")
WORK = os.path.join(D, "work/mut")

# name: (file, old, new, [harness runs], what the mutation breaks)
M = {
 "K1-change-noverify": ("edit-config.sh",
    '    if ! edit_keytool_verify "The new passphrase"; then\n',
    '    if false; then\n', ["host:keys_v2.sh"], "no verify before the passphrase change"),
 "K2-reseal-noverify": ("edit-config.sh",
    '    pcrs="$(edit_cred_pcrs "$key")"\n    edit_keytool_verify "The passphrase" || return 1\n',
    '    pcrs="$(edit_cred_pcrs "$key")"\n', ["host:keys_v2.sh"], "no verify before the reseal"),
 "K3-mig-unit-noverify": ("edit-config.sh",
    '        edit_keytool_verify "The passphrase" || return 1\n        tn_migrate_embedded_passphrase',
    '        tn_migrate_embedded_passphrase', ["host:keys_v2.sh"], "no verify before the move of a unit that holds it"),
 "K4-mig-file-noverify": ("edit-config.sh",
    '            edit_keytool_verify "The passphrase in ${conf}/bls-passphrase" "${conf}/bls-passphrase" || return 1\n',
    '            :\n', ["ubuntu:keys_v2.sh"], "no verify of the plaintext file before the move"),
 "K5-verify-failopen": ("edit-config.sh",
    '            edit_error "${what} does not open the BLS key in ${dd} (keytool verify, exit ${rc}); nothing was changed. Use the passphrase the key was created with."\n            return 1\n',
    '            return 0\n', ["host:keys_v2.sh"], "a failed verify lets the write go on"),
 "K6-no-redaction": ("edit-config.sh",
    '    [[ "$first" != *"$TN_KEYTOOL_PASS"* ]] || first=""\n',
    '', ["host:keys_v2.sh"], "keytool's first output line is shown even when it holds the passphrase"),
 "K7-keytoolpass-left": ("edit-config.sh",
    '    out=""\n    unset TN_KEYTOOL_PASS\n',
    '    out=""\n', ["host:keys_v2.sh"], "TN_KEYTOOL_PASS left set after the verify"),
 "K8-probe4-refuses-silently": ("edit-config.sh",
    '            edit_warn "Could not run the node binary of ${spec} to see whether it has keytool verify; skipped"\n',
    '', ["host:keys_v2.sh"], "the probe failure is not warned"),
 "K9-shred-sentence": ("remove-node.sh",
    '        print_info "Decommissioning a host that held a validator key means destroying or crypto-erasing its disk and deleting every snapshot and image taken from it; shred alone does not do that."\n',
    '', ["host:keys_v2.sh"], "the destruction sentence is gone"),
 "K10-shred-note-twice": ("remove-node.sh",
    '        _RM_SHRED_NOTED=true\n', '', ["host:keys_v2.sh"], "the note prints on every shred"),
 "A1-marker-after-init": ("lib/common.sh",
    '    if ! meta_set HOST_BASELINE true; then\n        _tn_hb_say warn "Could not record HOST_BASELINE=true in .node-meta; the host baseline was not made." "$fn"\n        return 1\n    fi\n    if ! _tn_hb_aide_db init "$fn"; then\n        meta_unset HOST_BASELINE >/dev/null 2>&1 || true\n',
    '    if ! _tn_hb_aide_db init "$fn"; then\n', ["ubuntu:audit_v2.sh"], "the marker is written after aide --init"),
 "A2-marker-kept-on-failed-init": ("lib/common.sh",
    '        meta_unset HOST_BASELINE >/dev/null 2>&1 || true\n        _tn_hb_say warn "The AIDE baseline was not made, so HOST_BASELINE stays unset." "$fn"\n',
    '        _tn_hb_say warn "The AIDE baseline was not made, so HOST_BASELINE stays unset." "$fn"\n', ["ubuntu:audit_v2.sh"], "a failed aide --init keeps the marker"),
 "A3-rules-mode-0644": ("lib/common.sh",
    'tn_write_root_file "${p}${TN_HB_AUDIT_RULES}" 0640', 'tn_write_root_file "${p}${TN_HB_AUDIT_RULES}" 0644',
    ["ubuntu:audit_v2.sh"], "rules file world-readable"),
 "A4-cred-not-excluded": ("lib/common.sh",
    '        "!${conf}/(.*/)?bls-passphrase(\\\\.cred)?(\\\\.new)?\\$" \\\n', '',
    ["ubuntu:audit_v2.sh", "ubuntu:real_v2.sh"], "the credential and the passphrase file are hashed by AIDE"),
 "A5-refresh-ignores-marker": ("lib/common.sh",
    '    [[ "$mark" == "true" ]] || return 0\n    if ! command -v aide', '    if ! command -v aide',
    ["host:audit_v2.sh"], "refresh runs without the marker"),
 "A6-remove-purges": ("lib/common.sh",
    '    _tn_hb_say log "Host baseline removed. The auditd and aide packages stay installed',
    '    apt-get purge -y auditd aide >/dev/null 2>&1 || true\n    _tn_hb_say log "Host baseline removed. The auditd and aide packages stay installed',
    ["ubuntu:audit_v2.sh"], "remove purges the packages"),
 "A7-refresh-rc-gt7-renamed": ("lib/common.sh",
    '    if (( rc > 7 )) || [[ ! -f "$new" || -L "$new" ]]; then', '    if [[ ! -f "$new" || -L "$new" ]]; then',
    ["ubuntu:audit_v2.sh"], "an aide error exit still replaces the database"),
 "A8-status-no-warn-rc": ("lib/common.sh",
    '    tn_host_baseline_status || warn=1\n', '    tn_host_baseline_status || true\n',
    ["ubuntu:audit_v2.sh"], "tn_host_audit ignores the baseline warnings"),
 "H1-json-docker-norefresh": ("update-node.sh",
    '        docker_record_meta "$new_image" "$new_ref"\n        update_baseline_refresh\n        json_emit',
    '        docker_record_meta "$new_image" "$new_ref"\n        json_emit', ["host:hooks_v2.sh"], "--json docker apply does not refresh"),
 "H2-source-refresh-on-fail": ("update-node.sh",
    '    # Health or binary-identity verify failed -- rollback\n',
    '    update_baseline_refresh\n    # Health or binary-identity verify failed -- rollback\n', ["host:hooks_v2.sh"], "a failed source verify refreshes"),
 "H3-set-norefresh": ("edit-config.sh",
    '        edit_baseline_refresh\n        edit_done true "$field" "$value" "applied and ${TARGET_SERVICE} healthy"',
    '        edit_done true "$field" "$value" "applied and ${TARGET_SERVICE} healthy"', ["host:hooks_v2.sh"], "--set does not refresh"),
 "H4-seam-c4322d4-revert": ("edit-config.sh",
    '        0) edit_ok "${2:-done}"; edit_baseline_refresh ;;', '        0) edit_ok "${2:-done}" ;;',
    ["host:hooks_v2.sh", "host:keys_v2.sh"], "c4322d4 reverted: a passphrase move does not refresh"),
 "H5-menu-refresh-when-down": ("edit-config.sh",
    '            print_error "Node failed to restart. Check logs:"\n            print_info "  sudo tail -30',
    '            edit_baseline_refresh\n            print_error "Node failed to restart. Check logs:"\n            print_info "  sudo tail -30',
    ["host:hooks_v2.sh"], "a menu restart that did not come back refreshes"),
 "H6-remove-no-teardown": ("remove-node.sh",
    '    if declare -F tn_host_baseline_remove >/dev/null 2>&1; then\n        tn_host_baseline_remove\n    fi\n', '',
    ["host:hooks_v2.sh"], "remove-node does not tear the baseline down"),
 "H7-teardown-after-stop": ("remove-node.sh",
    ['    if declare -F tn_host_baseline_remove >/dev/null 2>&1; then\n        tn_host_baseline_remove\n    fi\n    if [[ -z "$service_name" ]]; then',
     '    systemctl daemon-reload\n    print_ok "Service ${service_name} removed"\n'],
    ['    if [[ -z "$service_name" ]]; then',
     '    systemctl daemon-reload\n    tn_host_baseline_remove\n    print_ok "Service ${service_name} removed"\n'],
    ["host:hooks_v2.sh"], "teardown moved after the stop and the unit removal"),
 "H8-done-no-key": ("setup-node.sh",
    '\\"host_baseline\\":${hb},', '', ["host:hooks_v2.sh"], "finalize done event lacks host_baseline"),
 "H9-no-baseline-only": ("setup-node.sh",
    '    if [[ "$HOST_BASELINE" == "true" ]] && ! json_mode && tn_resolve_service >/dev/null 2>&1; then',
    '    if false; then', ["host:hooks_v2.sh"], "--host-baseline on an installed node runs the full setup"),
 "H10-unguarded-hook": ("edit-config.sh",
    '    if declare -F tn_host_baseline_refresh >/dev/null 2>&1; then\n        tn_host_baseline_refresh edit_wait_say\n    fi\n',
    '    tn_host_baseline_refresh edit_wait_say\n', ["host:hooks_v2.sh"], "the hook errors on a library without tn_host_baseline_*"),
}

def mkcopy(name):
    dst = os.path.join(WORK, name)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(os.path.join(dst, "tools/tests"))
    shutil.copytree(os.path.join(ROOT, "lib"), os.path.join(dst, "lib"), symlinks=True)
    for f in os.listdir(ROOT):
        if f.endswith(".sh") and os.path.isfile(os.path.join(ROOT, f)):
            shutil.copy2(os.path.join(ROOT, f), os.path.join(dst, f))
    shutil.copy2(os.path.join(ROOT, "tools/tests/lib.sh"), os.path.join(dst, "tools/tests/lib.sh"))
    return dst

def run(dst, spec):
    env_, f = spec.split(":", 1)
    rel = os.path.relpath(dst, ROOT)
    old = "tasks/verify-fup/V2/work/old/lib"
    if env_ == "host":
        e = dict(os.environ, V2_REPO=dst, V2_QUICK="1", V2_OLDLIB=os.path.join(ROOT, old))
        p = subprocess.run(["bash", os.path.join(D, f)], env=e, capture_output=True, text=True, timeout=1500)
    else:
        p = subprocess.run(["docker", "run", "--rm", "-e", "V2_REPO=/w/" + rel, "-e", "V2_QUICK=1",
                            "-e", "V2_OLDLIB=/w/" + old, "-v", ROOT + ":/w", "-w", "/w", "ubuntu:24.04",
                            "bash", "tasks/verify-fup/V2/" + f], capture_output=True, text=True, timeout=1500)
    out = p.stdout + p.stderr
    fails = [l for l in out.splitlines() if l.startswith("FAIL")]
    last = [l for l in out.splitlines() if "checks," in l]
    return p.returncode, fails, (last[-1] if last else out.splitlines()[-1:])

names = sys.argv[1:] or list(M)
lines = []
BASE = {}
def baseline(spec):
    if spec not in BASE:
        dst = mkcopy("baseline-" + spec.replace(":", "-"))
        rc, fails, last = run(dst, spec)
        BASE[spec] = set(fails)
        lines.append(f"{'baseline':30s} {spec:20s} rc={rc} {last} | {len(fails)} FAIL lines (the finding checks)")
        print(lines[-1], flush=True)
        shutil.rmtree(dst)
    return BASE[spec]
for n in names:
    f, old, new, runs, what = M[n]
    dst = mkcopy(n)
    path = os.path.join(dst, f)
    s = open(path).read()
    olds = old if isinstance(old, list) else [old]
    news = new if isinstance(new, list) else [new]
    bad = [o for o in olds if s.count(o) != 1]
    if bad:
        lines.append(f"{n:30s} NOT APPLIED (pattern not found once) [{what}]")
        print(lines[-1], flush=True)
        continue
    for o, nw in zip(olds, news):
        s = s.replace(o, nw)
    open(path, "w").write(s)
    for spec in runs:
        base = baseline(spec)
        rc, fails, last = run(dst, spec)
        new_fails = [x for x in fails if x not in base]
        killed = "KILLED" if new_fails else "SURVIVED"
        first = new_fails[0][6:100] if new_fails else ""
        lines.append(f"{n:30s} {spec:20s} {killed:8s} rc={rc} {last} | first FAIL: {first} [{what}]")
        print(lines[-1], flush=True)
    shutil.rmtree(dst)
open(os.path.join(D, "records/mutations.txt"), "a").write("\n".join(lines) + "\n")
