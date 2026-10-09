status: done

# Track A committer checkpoint

## Completed sections
- PRE: pre-checks passed
- A1: a1b6b81 fix(lib/fallback,install-caddy) ...
- A2: 1a7828f feat(setup-node): public RPC at install time
- A3: d4d4ed7 feat(check-node,firewall-setup): public RPC report; reset keeps 80/443
- A4: f1646c5 chore(release): public RPC docs + changelog, update-scripts 1.1.66, UI 1.8.7 (status after: only untracked tasks/ files and .claude/)

- A5: e6e4c24 Merge origin/main (#9) into public RPC work
- A6 commit: b5d912b chore(release): versions + changelog for #9 (pushed: origin/main 1f0385d..b5d912b)

## Pre-check results
- fetch ok; HEAD..origin/main = only 1f0385d (Fix/finalize onchain check must not abort (#9))
- status: exactly 15 modified tracked files (README.md, check-node.sh, firewall-setup.sh, install-caddy.sh, lib/fallback.sh, setup-node.sh, ui/server.py, update-scripts.sh + 7 .sha256), untracked only tasks/ and .claude/
- gen-checksums.sh changed nothing (sidecar diff hash identical before/after)

## Next
- none (done)

## A5 progress
- `git merge --no-ff --no-commit origin/main` started; conflicts: setup-node.sh, setup-node.sh.sha256, ui/server.py.sha256. Auto-merged: lib/common.sh(+sidecar), ui/server.py.
- Resolved setup-node.sh parser hunk (kept local cases; inserted upstream --public-rpc-url/--public-ws-url/--rpc-http/--rpc-ws after --rpc-public, before --rpc-domain; added all 4 to missing_option_value guard). Globals, keygen rpc_args (both paths), `|| true` onchain check, heredoc PUBLIC_RPC_URL/PUBLIC_WS_URL auto-merged.
- Sidecars regenerated; lib/common.sh.sha256 == upstream. Gates OK. Functional parser drive under /bin/bash OK.
- Merge committed: e6e4c24

## Result
- A_HEAD=b5d912b7def8a44712b84fdc52457e959f8b9801
- origin/main == HEAD; origin/main..HEAD empty
