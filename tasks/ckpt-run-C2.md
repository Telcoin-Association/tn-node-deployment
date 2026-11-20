status: done

Unit C2: wording round on tip e957fd9 of docs/run-telcoin-network-links (worktree tnd-spec-13).

Finished steps:
- read: human-writing skill loaded; git show HEAD; contract "Amended after verification" and Gates section
- edits: AGENTS.md (publish trigger, fetch, checks bullet rewritten, new files/assets/logo bullet,
  "never renamed or removed"); README.md (trigger, fetch); CHANGELOG.md (trigger, fetch).
  Widths <= each file's max, CHANGELOG ASCII, diff --check clean.
- point 5 checked: no other added sentence made untrue by the amendment. Incomplete but true:
  "A new document or a renamed directory needs a matching change to the document list in
  build-site.sh" (the amendment adds site/404.html and the site README's Links table).
- amended: new tip bb4f8a5 (parent 797dcb5), message from scratchpad/c2/msg.txt, no trailers.
- verified: 4 commits origin/main..HEAD; status only tasks/; diff --stat e957fd9 HEAD = 3 files
  (31+, 17-); diff --check clean; HEAD:docs/partner = a6d248bef3e9ab15ce1bdba978fa62da1028ffec.
