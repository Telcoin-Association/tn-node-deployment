status: done

# HW-UI-PAGE checkpoint

Sections:
- [x] page (ui/static/index.html stepPreflight/hwCores/hwDiskLabel/hwTierRows/hwInfoRow)
- [x] tests (ui/test_page_wiring.py)
- [x] rendered rows (node:22-slim container, scratch outside the tree)
- [x] gates (pytest in python:3.10-slim; check-network-hits; git diff --stat; commit)

Round 2 (coordinator: Detected disk in decimal GB, like the shell):
- [x] page: disk conversion only, Math.round(total_kb*1024/1e9), ? for null, RAM unchanged
- [x] test: one test in PreflightHardwareTest
- [x] re-render the three info rows (360000000 kB -> 369 GB)
- [x] pytest ui in python:3.10-slim; second commit

Round 3 (verifier F2 + F8, one commit on cc6049c):
- [x] page: RAM ?? '?' in tier row and recommendation; cpu_kind==='logical' wording + note
- [x] tests in PreflightHardwareTest
- [x] render five objects (testnet, logical cpu 8, old server, two F8 partials)
- [x] gates (pytest ro mount, network-hits) and third commit

Notes:
- round 3 gates: pytest ui 296 passed (+1273 subtests), ro mount, PYTHONDONTWRITEBYTECODE=1; network-hits clean; committed 66aa553.
- round 3: page + tests done (2 new tests red on cc6049c; 2 own literals updated to ?? '?'); render3.js five objects clean; non-logical output byte-identical to cc6049c over 36 cases (same.js).
- round 2 done: diskGb = Math.round(kb*1024/1e9) in hwInfoRow (RAM gb unchanged); test_the_detected_disk_is_decimal_gb_like_the_tiers (red on 46b8948); render 369 GB for 360000000 kB, null -> ?; pytest ui 294 passed (+1273 subtests); network-hits clean; committed cc6049c.
- gates: pytest ui 293 passed (+1273 subtests) on worktree tip; baseline 287 on git-archive of 01664cc; network-hits clean (153 annotated, 29 files); diff = index.html + test_page_wiring.py only; committed 46b8948.
- rendered: node:22-slim, scratch /var/tmp/claude-1000/-home-drtnarg-coding-telcoin-tn-node-deployment/46275ae3-5cf9-4f35-b799-c09950443243/scratchpad/hwpage/{extract.py,helpers.js,render.js}; three samples OK, no undefined/NaN/null, escaping OK. Open Q: Detected disk is GiB (343 GB) while tiers are decimal GB (350 GB meets) - left as today per spec.
- tests done: class PreflightHardwareTest (6 tests) after SetupWizardTest; host unittest 35/35 OK in the file; all 6 red against HEAD's page (scratch runner).
- page done: request ?network=encodeURIComponent(setupNetwork()); hwCores/hwDiskLabel one-liners before hwTierRows (null -> '? cores'/'? GB'); hwDiskLabel mirrors lib/common.sh:2193 (>=1000 && %1000==0); single-core sentence pushed only when the row has content.
- setupNetwork() (index.html:3563) always returns 'mainnet' or 'testnet'; state.setup.network starts 'adiri' -> 'testnet'. So the request is well-formed before step 2.
- node is not on the host; image node:22-slim exists locally.
- ui/dev/serve.py matches request.path (no query string), unaffected.
