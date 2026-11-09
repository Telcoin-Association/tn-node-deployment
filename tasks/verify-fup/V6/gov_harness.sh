#!/usr/bin/env bash
# V6 GOV harness: compares the workflow security surface between two commits
# (default 3b760cc, the pre-GOV base, and HEAD) and checks the required display
# names. Needs git, python3 with pyyaml. Usage: bash gov_harness.sh [BASE] [TIP]
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$here/../../.." && pwd)"
BASE="${1:-3b760cc}"
TIP="${2:-HEAD}"
T="$(mktemp -d)"
trap 'rm -rf "${T:?}"' EXIT
mkdir -p "$T/base" "$T/tip"
git -C "$REPO" archive "$BASE" .github | tar -x -C "$T/base"
git -C "$REPO" archive "$TIP" .github | tar -x -C "$T/tip"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/     /'; fi; }

# Text extracts that keep comments (pins carry their tag in a comment).
for side in base tip; do
    for f in ci.yml integration.yml publish-installer.yml; do
        w="$T/$side/.github/workflows/$f"
        grep -nE '^[[:space:]-]*uses:' "$w" | sed 's/^[0-9]*://; s/^[[:space:]-]*//' > "$T/$side.$f.uses"
        grep -E 'persist-credentials' "$w" | sed 's/^[[:space:]-]*//' > "$T/$side.$f.persist"
    done
done
for f in ci.yml integration.yml publish-installer.yml; do
    if diff "$T/base.$f.uses" "$T/tip.$f.uses" > "$T/d"; then ok "$f: every uses: pin identical ($(wc -l < "$T/tip.$f.uses") lines)"; else bad "$f: uses: pins differ" "$(cat "$T/d")"; fi
    if diff "$T/base.$f.persist" "$T/tip.$f.persist" > "$T/d"; then ok "$f: persist-credentials lines identical ($(wc -l < "$T/tip.$f.persist"))"; else bad "$f: persist-credentials differ" "$(cat "$T/d")"; fi
done

# Parsed structure: permissions (workflow and job), job names, per-checkout persist.
python3 -I - "$T/base/.github/workflows" "$T/tip/.github/workflows" > "$T/py" 2>&1 <<'PY'
import sys, os, yaml
def load(d):
    out = {}
    for f in ("ci.yml", "integration.yml", "publish-installer.yml"):
        out[f] = yaml.safe_load(open(os.path.join(d, f)))
    return out
b, t = load(sys.argv[1]), load(sys.argv[2])
def surface(w):
    s = {"permissions": w.get("permissions"), "jobs": {}}
    for jid, j in w["jobs"].items():
        steps = j.get("steps") or []
        s["jobs"][jid] = {
            "name": j.get("name"),
            "permissions": j.get("permissions"),
            "checkouts": [(st.get("uses"), (st.get("with") or {}).get("persist-credentials"))
                          for st in steps if str(st.get("uses", "")).startswith("actions/checkout@")],
            "coe": [st.get("name") for st in steps if st.get("continue-on-error")] + (["<job>"] if j.get("continue-on-error") else []),
        }
    return s
for f in b:
    sb, st = surface(b[f]), surface(t[f])
    print(("PASS" if sb["permissions"] == st["permissions"] else "FAIL"), f, "workflow permissions", st["permissions"])
    if set(sb["jobs"]) != set(st["jobs"]):
        print("FAIL", f, "job ids differ", sorted(sb["jobs"]), sorted(st["jobs"]))
    for jid in sorted(st["jobs"]):
        jb, jt = sb["jobs"].get(jid, {}), st["jobs"][jid]
        for k in ("name", "permissions", "checkouts", "coe"):
            print(("PASS" if jb.get(k) == jt[k] else "FAIL"), f, jid, k, repr(jt[k]))
names = [j.get("name") for f in t for j in t[f]["jobs"].values()]
want = ["bash -n (Linux)", "bash -n and bash-3.2 lint (macOS bash 3.2)", "shellcheck",
        "fixture tests (Linux bash 5)", "fixture tests (macOS bash 3.2)", "hardening lints",
        "release manifest", "Node Manager UI tests", "checksum freshness", "Ubuntu 24.04 VM assertions"]
for n in want:
    print(("PASS" if names.count(n) == 1 else "FAIL"), "display name exactly once:", n, names.count(n))
ci = t["ci.yml"]["jobs"]
def runs(jid):
    return [str(st.get("run", "")) for st in ci[jid]["steps"]]
def has_step(jid, cmd):
    return any(cmd in r for r in runs(jid))
print(("PASS" if has_step("hardening-lint", "bash tools/check-network-hits.sh") else "FAIL"), "hardening-lint runs tools/check-network-hits.sh")
for tname in ("helper_test.sh", "install_ui_test.sh", "open_ui_test.sh"):
    print(("PASS" if has_step("ui-tests", "bash ui/tests/" + tname) else "FAIL"), "ui-tests runs", tname)
    print(("PASS" if has_step("parse-macos", "/bin/bash ui/tests/" + tname) else "FAIL"), "parse-macos runs", tname, "under /bin/bash")
for jid in ("hardening-lint", "ui-tests"):
    bad = [r for r in runs(jid) if "if [ -f" in r or "unittest" in r]
    print(("PASS" if not bad else "FAIL"), jid, "has no dead fallback")
pi = t["publish-installer.yml"]["jobs"]
print(("PASS" if not any(".nojekyll" in str(st.get("run", "")) for j in pi.values() for st in j.get("steps", [])) else "FAIL"), "publish-installer writes no .nojekyll")
PY
while IFS= read -r line; do
    case "$line" in
        PASS*) ok "${line#PASS }" ;;
        FAIL*) bad "${line#FAIL }" ;;
        *) bad "python: $line" ;;
    esac
done < "$T/py"
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
