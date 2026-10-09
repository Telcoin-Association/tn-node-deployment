status: done (followup.md 182 lines)
task: write followup.md (repo root), operator nice-to-haves backlog
method: skeleton has @@SECTION@@ placeholders; each section replaced in turn
Completed sections:
- skeleton
- UI
- Scripts
- Caddy
- Validator
- Docs upstream
- Superseded
Verification notes:
- not in repo (proposed/upstream only): --bootstrap-peers, --enable-state-export, --state-export-keep, allow_private_forward_targets, keytool set-rpc, --rpc-cache.* (all verified upstream in ../telcoin-network or ../reth); --workers not found anywhere (phrase without name); OPERATOR.md not yet on disk (being written by another agent)
- wss probe waits full 8s on SUCCESS (not failure as plan said)
- rpc-enable does NOT write any .node-meta key (plan said it writes PUBLIC_RPC_DOMAIN)
- set-rpc/--rpc-http in local telcoin-network are in v0.12.0-adiri already (plan said v0.13.0)
- update-node uses --observer/--validator only to skip auto-detect; edit-config discards it
- fallback.sh comment mentions tn_isValidator; server.py still uses it; CHANGELOG (uncommitted, other agent) says view follows getValidator
- omit personal email from contact-email item
