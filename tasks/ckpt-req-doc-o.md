status: done

# DOC-O checkpoint (OPERATOR.md only)

Sections:
- [x] pass 1: chain configs come from the pinned tag -- commit 8ef63e8 (was 5b4662d; a line split was folded in by autosquash)
- [x] pass 2: hardware requirements per network -- commit 0754d06
- [x] pass 3: the mainnet chain id is 731 -- commit 492e67d
- [x] self-check

Pass 1 notes:
- 2.2 step 8 (chain configs at the tag, clone prompt, offline), step 10 (search order, hint)
- 2.4 new row /etc/telcoin/chain-configs/<network>/; /opt/telcoin-source row
- 4.3 menu 13 row; menu 13 paragraph (mainnet refusal, Nothing to refresh, clone offer, manual hint, lock, devnet pulls); git pull failed sentence removed
- 9: 9 new rows after "Cannot tell which network"
- appendix chain-configs row

Pass 2 notes:
- 1.1 F5, F6, F1, F2 (once), F3/F4 tables, F7 paragraph; 2.2 step 2/3 F11; 2.11 F9/F10, cost; 4.5 wizard bullet; 6.1 prerequisite; 9 F8 row

Pass 3 notes:
- 206, 229, 268, 845, 2301 changed; 1923, 2205 kept; Caddy paragraph (2181) follows caddy_mainnet_gate

Self-check:
- 26.04 count 8 (unchanged)
- big grep: one hit, 2724, the scripts-v2.1.0 message quoted on purpose
- 487 sweep: one hit, 2181, a chain-487 genesis as the example of an unknown chain (not mainnet)
- network-hits lint rc 0; table column counts consistent; placeholders inside code spans
