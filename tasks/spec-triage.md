# Triage of the review findings (orchestrator, 2026-10-15)

Policy (from the user's decision on refresh scope): correct every stale statement; add short
subsections only where the chapter structure has a natural home (gas penalty, fork gates,
transaction forwarding); no new chapters; no operator material; a partner document, not an
integration manual. Additions that ride on a correction (one sentence, same paragraph) stay;
standalone new material that is internal detail, operator or integration how-to, or a claim
about something not live at the tag goes. Item ids below are Q1's (`tasks/ckpt-spec-Q1.md`
section C) and Q2a/b/c's (their checkpoints); line numbers are in the FINAL Markdown at the time
of review and will shift as edits land, so locate by content.

## From Q1 (fidelity and scope)

### Fix (section B)
- B1: line 290 "serves epoch N+2" is wrong; the committee drawn when epoch N closes serves
  epoch N+3 (lines 289, 350, 373, 374 already say so). Fix the sentence and its rider C21, and
  correct log entry 71.
- Log gaps: entries 29 (rationale clause at line 77), 160 (clause at line 518), the list
  reorder at 532-534, entry 180 (the dropped "evading penalties" reason). Add the missing
  words to the log; no text change needed unless the fix-up changes those lines anyway.

### Drop (section C, out of scope)
C6, C15, C17, C19, C24 (the Governance Safe row of the fork table; keep the other five rows),
C35, C42, C45, C49, C52, C53, C59, C67, C68. Also drop these nice-to-have items that are
integration or internal detail: C38, C44, C48, C50, C56 (only its third sentence, the RPC
how-to at line 599; keep the message layout and the on-chain check), C60, C62, C51's "from
the node's configuration" wording (keep the exemption itself).

### Reword (section C)
- C25 (mainnet "in force from genesis", lines 325-326): no mainnet claims. Replace with one
  network-neutral sentence: a network whose genesis postdates a fork applies that rule from
  its first epoch. Keep the Adiri table.
- C33 (delegation procedure, 385-387): one sentence, "the validator authorises the delegation
  by signing it", nothing about functions, digests, nonces or RPCs.
- C39 (transport timeouts, 471-473): keep the correction that stale connections are cleared
  by the QUIC keep-alive and idle timeout within about half a minute; drop the 5 s / 30 s /
  handshake-ceiling numbers.
- C43 (forwarding retention, 514): keep "a transaction that does not reach the committee stays
  in the node's pool and is sent again"; drop the three-outputs detail.

### Deduplicate (keep one)
- C2 (43-44) vs 685: keep 43-44; shorten 685 to a clause.
- C3 (46-47) vs C65 (693-694): keep 693-694 in Trustless synchronization; drop 46-47.
- C9 (148-149) vs C57 (601-603): keep both, but 148-149 becomes one sentence naming the two
  precompiles and their purpose; the ABI, gas and value rule stay only in chapter 9.
- C19 vs C28: C19 is dropped; C28 keeps "slashing is supported by the contract and not
  applied" once.
- C30 (370) vs 477 vs 608: keep the Ed25519 derivation statement in chapter 9 (608); 370 and
  477 refer to it in a few words.
- C58 (617-621) vs 279-284: chapter 9 keeps one sentence and a heading link to
  `[Committee shuffle](#committee-shuffle)`.
- C66 (723) vs 125-127: drop 723.

### Keep
C14, C16, C23, C27, C28 (partner-needed) and every other nice-to-have rider not listed above.

### Cosmetic (section D)
Make these consistent across the document: table delimiter style (`|---|` everywhere), how
multi-sentence list items wrap (one sentence per line inside the item, continuation lines
indented), straight quotes, `Retired` in backticks like the other statuses, function names
written with `()` consistently.

## From Q2a (chapters 1-5; `tasks/ckpt-spec-Q2a.md`)

Accept every `wrong`, `imprecise`, `stale` and `inconsistent` item as written in the checkpoint
(the corrected sentences are there). Highlights: the N+3 committee rule (lines 289-290, 89 and
log entry 71, same as Q1 B1); lines 154-155 rewritten for the extended header-field table; the
reputation window is 60 leader rounds (120 consensus rounds) keyed on the round number, and
"never more than a third" softened; line 6 names the admitted transaction types (legacy,
EIP-2930, EIP-1559; EIP-7702 and blob transactions rejected); line 111 block rewards; line 57
Execution Chain cell; "2ƒ+1" versus floor(2n/3)+1 at lines 41/45 (define the threshold once,
use it consistently); the fork-section overstatements at 307 and 314 and the loose rows 322 and
325. Scope flags: the 100M system-call constant may stay (it is a protocol parameter, stated
once); drop the internal scheduling constants if they are not needed to explain a corrected
sentence; the Governance Safe row is already dropped under Q1 C24.

## From Q2b (chapters 6, 7, 10; `tasks/ckpt-spec-Q2b.md`)

Accept every `imprecise`, `stale` and `inconsistent` item as written in the checkpoint.
Highlights: the N+3 rule again (290 versus 373); ejection by NFT burn also forfeits unclaimed
rewards and cannot empty a committee, and the ejected validator keeps its seat until the epoch
ends (349-350); `final_state` only pins a consensus pack's start state, divergence is caught by
the leader's execution-block check (725, keep 724); early unstake only before `activate()`, and
reward claims have no status gate but a minimum amount (377-378); 734 (ejection tolerance,
four-member floor only for a shrunken committee, shrinks compound) and 669/671 ("every state
transition" versus a snapshot-started node); 696: say "epoch length is a genesis parameter"
without naming the mainnet value; the node-mode inconsistencies (412, 416-417, 433, 437:
membership re-check after catch-up, epoch-record veto, `CvvInactive` carrying over); the
transaction-intake row follows the committee seat (449, 423-424); 706 author check only for
outputs that carry batches. Scope: drop "No node is configured into this mode" (419, change
history); replace the `Any` sentinel mention at 365 with plain prose. Unsettled items (mid-epoch
drop of an ejected validator, snapshot state-root recomputation, the "most often follows a
restart" frequency at 408): word them so the text makes no claim the code does not settle.

## From Q2c (chapters 8-9; `tasks/ckpt-spec-Q2c.md`, status done)

Accept every `wrong`, `imprecise` and `inconsistent` item as written in the checkpoint, with its
corrected sentence. Highlights: 571 (only previous, current and next committee members are
exempt from scoring; drop the trusted/bootstrap-peer claim entirely, which also settles Q1
C51); 472 (a connection attempt is cut after about ten seconds, the libp2p transport timeout;
with C39 this becomes one sentence without the other numbers); 556 (drop the sentence, per Q1
C49); 457 ("sole transport" becomes "peer-to-peer communication", since forwarding uses
JSON-RPC over HTTPS); 615 versus 26 (a ConsensusHeader digest is BLAKE3 over the parent hash,
sub-DAG digest, number and reserved field; a certificate's digest is its header's); 492 (gossip
ids `/tn-meshsub-{chain_id}/1.1.0` and `/1.0.0`); 513 (a single rejection also stands when no
other validator can be reached); 568 versus 572; 590 (every node signs its node record); 602
(4,096-byte cap, or drop the cap); 656-658 (indirect verification may chain). Also fix the two
cross-chapter inconsistencies it found outside its slice: 703 versus 537 (sync requests outputs
by number, then checks the hash) and 280 versus 619 (the seed message also binds the previous
epoch record's digest).

Scope, numbers: the original April document already carried a reputation-levels table, so the
three-level table keeps its score thresholds and the reconnect-refusal and ban durations that
define the levels. Every other configurable default in chapters 8-9 (QUIC timers, republish
interval, peer counts, message size caps, decay half-life, penalty sizes and counts, "three
outputs", "every 50th round") goes, or becomes a qualitative statement without the number; the
code calls the scoring model experimental (peers/score.rs:4), so the text may say the values
are protocol defaults that may change.
