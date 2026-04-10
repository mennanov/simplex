# Practical Wire Protocol Adaptations for Simplex Consensus

**References:** Chan & Pass, "Simplex Consensus" (CP23); Shoup, "Sing a Song of Simplex" (DispersedSimplex)

---

## 1. Motivation

The Simplex protocol as specified in CP23 transmits the *entire* notarized blockchain in three protocol actions: leader
proposals, vote validation, and iteration-advance forwarding. A literal implementation would send O(h) blocks and O(h)
notarizations per slot, where h is the current blockchain height. This is clearly impractical — after 10,000 committed
slots with 1KB blocks and 100-node notarizations (~5KB each), each proposal message would exceed 60MB.

This section specifies the minimal set of changes to the CP23 protocol that eliminate full-chain transmission while
preserving the original safety and liveness proofs with only trivial adjustments. The changes are:

1. Replace hash-chain block linking with height-based parent references.
2. Reduce the leader proposal message to contain only the new block.
3. Shift proposal validation from inspecting the proposal payload to checking local state.
4. Reduce iteration-advance forwarding to transmit only the triggering notarization.

Change 4 eliminates CP23's implicit catch-up mechanism (where every forwarding message carried the full chain). To
compensate, Section 8 specifies a dedicated catch-up protocol for nodes that fall behind during periods of asynchrony.

An optional fifth change (eager complaint on invalid payloads) is included as a performance improvement that does not
affect the proof structure.

All changes assume small block payloads (under ~100KB), so no erasure coding or information dispersal is introduced. The
protocol logic, state transitions, safety proof, and liveness proof remain structurally identical to CP23. The only
thing that changes is what travels over the wire.

## 2. Scope of Changes

The following table maps each CP23 protocol action to its modification status.

| Protocol action                 | CP23 message content                                              | Changed? | New message content                             |
|---------------------------------|-------------------------------------------------------------------|----------|-------------------------------------------------|
| Step 1: Timer / dummy vote      | `⟨vote, h, ⊥_h⟩_i`                                                | **No**   | —                                               |
| Step 2: Leader proposal         | `⟨propose, h, b₀, …, bₕ, S⟩_L`                                    | **Yes**  | `⟨propose, h, bₕ⟩_L`                            |
| Step 3: Vote on proposal        | `⟨vote, h, bₕ⟩_i`                                                 | **No**   | —                                               |
| Step 3: Validation logic        | Check `(b₀, …, bₕ₋₁, S)` from the proposal                        | **Yes**  | Check local state                               |
| Step 4: Finalize message        | `⟨finalize, h⟩_i`                                                 | **No**   | —                                               |
| Step 4: Forward notarized chain | Full notarized blockchain of height h                             | **Yes**  | Notarization for height h only                  |
| Step 5: Finalization output     | On 2n/3 finalize msgs for h                                       | **No**   | —                                               |
| Block structure                 | `(h, H(b₀, …, bₕ₋₁), txs)`                                        | **Yes**  | `(h, h_parent, txs)`                            |
| Catch-up for lagging nodes      | Not specified (full-chain forwarding serves as implicit catch-up) | **New**  | Dedicated request/response protocol (Section 8) |

## 3. Change 1: Block Structure

### 3.1. CP23 definition

A block is a tuple `(h, parent_hash, txs)` where:

- `h` is the block height.
- `parent_hash = H(b₀, …, bₕ₋₁)` is a collision-resistant hash over the entire parent blockchain.
- `txs` is a sequence of transactions.

The genesis block is `b₀ = (0, ∅, ∅)`.

### 3.2. Modified definition

A block is a tuple `(h, h_parent, txs)` where:

- `h` is the block height (equivalently, the slot number).
- `h_parent` is the height of the highest non-dummy ancestor block in the parent chain. `h_parent = 0` indicates the
  genesis block is the direct parent.
- `txs` is a sequence of transactions.

The genesis block is `b₀ = (0, 0, ∅)`.

The dummy block for height h is `⊥_h = (h, ⊥, ⊥)`, unchanged from CP23. Dummy blocks do not reference a parent height
because, as in CP23, voters may disagree on the parent chain of a dummy block, and fixing a parent would split votes.

### 3.3. Correctness argument

CP23's consistency proof (Theorem 3.1) uses the hash `H(b₀, …, bₕ₋₁)` only in its final step: having established that
`bₕ = b'ₕ` (via quorum intersection), it invokes collision resistance to conclude that the parent chains must be
identical.

Under the modified block structure, this final step is replaced by the following inductive argument. Suppose two honest
parties both hold a notarized non-dummy block at height h, and both blocks have `h_parent = p`. By the quorum
intersection lemma (CP23 Lemma 3.2), there is at most one notarized non-dummy block at any given height. Therefore the
block at height p is uniquely determined. Dummy blocks do not break this induction: the dummy block `⊥_k = (k, ⊥, ⊥)` is
structurally identical for all parties at a given height k, so intermediate dummy slots between p and h contribute no
ambiguity. Applying the same argument to the block at height p and its own `h_parent` field, and continuing inductively
down to the genesis block, we recover the property that the full ancestor chain is identical.

Shoup confirms this independently: "while the Simplex protocol as specified in [CP23] relies on hash-based chaining of
blocks, this turns out to be unnecessary" (DispersedSimplex, Section 1).

> **Design note.** A production implementation may still include a hash field for protocol-external purposes (e.g.,
> content addressing, archival integrity checks). This is orthogonal to consensus safety and can be added as a
> non-consensus-critical metadata field on the block.

## 4. Change 2: Leader Proposal Message

### 4.1. CP23 specification

When the leader `L_h` enters iteration h, it multicasts:

```
⟨propose, h, b₀, b₁, …, bₕ, S⟩_L
```

where `(b₀, …, bₕ₋₁, S)` is a notarized blockchain of height `h - 1` in the leader's view, and `bₕ` is the leader's new
block.

### 4.2. Modified specification

When the leader `L_h` enters iteration h, it multicasts:

```
⟨propose, h, bₕ⟩_L
```

where `bₕ = (h, h_parent, txs)` is the leader's new block. The message is signed by the leader.

No parent chain, no notarizations — just the block itself.

### 4.3. Why this is sufficient

When the leader enters iteration h, it has seen a notarized blockchain of height `h - 1`. By CP23 Lemma 3.4 ("
Synchronized Iterations"), every honest party enters iteration h within δ time of the first honest party entering h. To
enter iteration h, a party must have seen a notarized blockchain of height `h - 1`. Therefore, by the time any honest
voter receives the leader's proposal, it already possesses — in its local state — all notarized blocks (real and dummy)
for heights 1 through `h - 1`.

The proposal therefore does not need to carry redundant data that the voter already has.

### 4.4. Message size

The proposal message contains: 1 slot number (8 bytes) + 1 block (8 + 8 + |txs| bytes) + 1 signature (~48 bytes for
BLS, ~64 bytes for Ed25519). For a 10KB transaction payload, this is approximately 10.1KB — compared to the O(h × (
|block| + |notarization|)) of the original.

## 5. Change 3: Proposal Validation Against Local State

### 5.1. CP23 specification

On receiving `⟨propose, h, b₀, …, bₕ, S⟩_L` from the leader, voter `i` checks:

- `bₕ ≠ ⊥_h`
- `b₀, …, bₕ` is a valid blockchain
- `(b₀, …, bₕ₋₁, S)` is a notarized blockchain of height `h - 1`

If all checks pass, the voter multicasts `⟨vote, h, bₕ⟩_i`.

### 5.2. Modified specification

On receiving `⟨propose, h, bₕ⟩_L` from the leader, where `bₕ = (h, h_parent, txs)`, voter `i` checks:

1. **Well-formedness:** `bₕ ≠ ⊥_h`, and `0 ≤ h_parent < h`.
2. **Parent exists:** The voter's local state contains a notarized non-dummy block at height `h_parent`, or
   `h_parent = 0` (genesis).
3. **Intermediate slots covered:** For every height `k` in the range `h_parent + 1, …, h - 1`, the voter's local state
   contains a notarized block at height `k` (this will necessarily be a notarized dummy block `⊥_k`).
4. **Payload validity:** `txs` satisfies application-level validity conditions (e.g., no duplicate transactions, valid
   against the committed state through `h_parent`).

If all checks pass, the voter multicasts `⟨vote, h, bₕ⟩_i`.

### 5.3. Deferred validation

Conditions (2) and (3) may not hold at the instant the proposal message arrives. For example, the notarization for
height `h - 1` may still be in transit. This is handled by deferring: the voter stores the proposal and re-evaluates
conditions (2) and (3) whenever a new notarization is added to its local state. This is functionally identical to what
happens in CP23 when a voter receives a proposal containing parent-chain data it cannot yet verify — the voter must wait
regardless.

> **Implementation note.** Maintain a pending-proposals buffer keyed by slot number. On receiving any new notarization,
> re-check all pending proposals whose conditions were previously unsatisfied. The buffer should hold at most one
> proposal
> per slot (the first valid-looking one from the leader). Proposals for slots the voter has already left are discarded.
>
> "Valid-looking" means the proposal passes structural checks before buffering: correct slot number, valid leader
> signature, `h_parent` in the expected range, and payload size below a configured maximum `MAX_BLOCK_SIZE`. Proposals
> exceeding `MAX_BLOCK_SIZE` are dropped without buffering to prevent memory exhaustion from a Byzantine leader. A
> Byzantine leader that sends an equivocating second proposal (a different block for the same slot) is detected by
> comparing against the buffered proposal; the second proposal is discarded. Equivocation detection is not required for
> safety — the voter votes for at most one proposal — but is useful for diagnostics and peer reputation tracking.

### 5.4. Correctness argument

The validation conditions (1)–(3) are logically equivalent to the CP23 conditions, with the data source changed from "
the proposal message" to "local state." The safety proof does not depend on where the voter obtained the notarized
parent chain — only on the fact that the voter verified the existence of a notarized parent chain before casting its
vote.

Specifically:

- **Lemma 3.2 (quorum intersection on votes):** Depends only on honest voters voting for at most one non-dummy block per
  height. This is preserved: the voter still votes for at most the first valid proposal from the leader.
- **Lemma 3.3 (quorum intersection on finalize vs. dummy):** Depends only on honest voters sending either `finalize` or
  a dummy vote, never both. This is preserved: the finalize/dummy logic is unchanged.
- **Lemma 3.4 (synchronized iterations):** Depends only on forwarding notarized blockchains when entering a new
  iteration. This is addressed by Change 4.
- **Lemma 3.5 (honest leader liveness):** Depends on all honest voters receiving and validating the leader's proposal
  within δ. Since all honest voters already have the parent chain data locally (having entered iteration h), they can
  validate the compact proposal immediately.

## 6. Change 4: Iteration-Advance Forwarding

### 6.1. CP23 specification

When a party sees a notarized blockchain of height h and enters iteration `h + 1`, it "multicasts its current view of
the notarized blockchain to everyone else."

### 6.2. Modified specification

When a party sees a notarized blockchain of height h and enters iteration `h + 1`, it multicasts:

```
⟨notarization, h, bₕ, V⟩
```

where `bₕ` is the notarized block at height h, and `V` is the set of 2n/3 vote signatures constituting the notarization.

For dummy blocks: `bₕ = ⊥_h` and the notarization consists of 2n/3 signatures on `⟨vote, h, ⊥_h⟩`.

### 6.3. Why the full chain is unnecessary

The purpose of this forwarding step is to ensure that every honest party can also enter iteration `h + 1` within δ
time (this is the mechanism underlying CP23 Lemma 3.4). To enter iteration `h + 1`, a party needs a notarized blockchain
of height h. Since honest parties are synchronized to within one iteration of each other (Lemma 3.4), a receiving party
is at iteration h or h − 1. In either case:

- If at iteration h: the party already has notarized blocks for all heights through h − 1, and needs only the
  notarization for height h.
- If at iteration h − 1: the party is waiting for a notarized blockchain of height h − 1 to arrive. It will receive this
  through normal protocol operation (someone else forwarding the notarization for h − 1). Once it enters iteration h, it
  then only needs the notarization for height h.

In both cases, the height-h notarization is the only piece of data the receiver is missing. No earlier chain data needs
to be retransmitted.

### 6.4. Message size

The forwarded notarization contains: 1 slot number (8 bytes) + 1 block (8 + 8 + |txs| bytes or a fixed-size dummy
block) + 2n/3 vote signatures. For n = 100 with 48-byte BLS signatures, this is approximately 3.2KB + |txs| — compared
to O(h × 5KB) for the full chain.

### 6.5. Correctness argument

Lemma 3.4 states: "If some honest process has entered iteration h by time t, then every honest process has entered
iteration h by time max(GST, t + δ)." The proof relies solely on the forwarding party sending enough data for the
receiver to construct a notarized blockchain of height h − 1 (thereby entering iteration h). Under our modified
forwarding:

1. The receiver gets the height-h notarization from the forwarding party.
2. The receiver already holds all notarized blocks for heights 1 through h − 1 (or will receive them within δ from other
   forwarding messages).
3. Therefore, the receiver can construct a full notarized blockchain of height h and enter iteration h + 1.

The timing bound of max(GST, t + δ) is preserved because the forwarded message arrives within δ, and the receiver's
local state already contains the prerequisite data.

> **Implementation note: out-of-order delivery and catch-up.** The liveness argument above assumes δ-synchronous
> delivery, under which all forwarded notarizations arrive in order and honest parties stay within one iteration of each
> other. In a real deployment, two situations break this assumption:
>
> 1. *Out-of-order delivery within synchrony:* Over TCP, messages are reliably delivered but notarizations may arrive
     out of order (e.g., the notarization for height h arrives before the one for h−1). The implementation should buffer
     notarizations for future iterations and process them when the party advances to the relevant iteration.
> 2. *Lagging nodes after asynchrony:* A node that experiences a network partition or temporary disconnection will miss
     multiple iterations. When connectivity resumes, it receives notarizations for the current height but lacks
     intermediate notarizations and cannot advance. Unlike CP23's full-chain forwarding (which delivers the entire chain
     in every forwarding message), our compact forwarding does not allow a lagging node to catch up from normal protocol
     traffic alone.
>
> Situation (2) requires a dedicated catch-up protocol. See Section 8 for the specification.

## 7. Optional Change 5: Eager Complaint on Invalid Payload

### 7.1. Motivation

In the unmodified protocol, when a voter receives a proposal with an invalid or malformed payload from a corrupt leader,
it takes no special action. The slot eventually times out after 3Δ, at which point the voter sends a dummy vote. With Δ
set conservatively (e.g., 10 seconds), this means a corrupt leader sending garbage costs 30+ seconds of wasted time.

### 7.2. Modified behavior

When voter i receives `⟨propose, h, bₕ⟩_L` from the leader and determines that the payload is invalid (e.g., malformed
transactions, application-level validation failure), the voter immediately multicasts a dummy vote:

```
⟨vote, h, ⊥_h⟩_i
```

This replaces the normal path where the voter would wait for the timer to fire before voting for the dummy block.

The voter also cancels any further proposal processing for this slot — it will not vote for a subsequently received (
potentially corrected) proposal from the same leader, since it has already voted for the dummy block.

### 7.3. Correctness argument

**Safety.** Voting for the dummy block is always a safe action in CP23. An honest voter is permitted to vote for the
dummy block at any time during an iteration (the timer is a liveness mechanism, not a safety mechanism). The quorum
intersection arguments (Lemmas 3.2 and 3.3) are not affected, because they depend only on the constraint that an honest
voter sends at most one vote for a non-dummy block and at most one of {dummy-vote, finalize} — both constraints remain
satisfied.

**Liveness.** If the leader is honest and the payload is valid, this code path is never triggered, so Lemma 3.5 is
unaffected. If the leader is corrupt, the recovery time improves from 3Δ + δ (Lemma 3.6) to approximately 2δ in the case
where the corrupt leader sends an identifiably bad proposal to all honest parties.

## 8. Catch-Up Protocol for Lagging Nodes

### 8.1. Problem statement

Our compact forwarding (Change 4) creates a new requirement that does not exist in CP23 as literally specified: a node
that falls behind by more than one iteration cannot catch up from normal consensus messages alone.

This situation arises in three cases:

1. **Temporary network partition.** A node loses connectivity for some interval, during which the network advances
   through multiple iterations. When connectivity resumes, the node is multiple iterations behind.
2. **Slow node.** A node is too slow to process blocks at the rate the network produces them (e.g., due to CPU or disk
   bottleneck). It gradually falls behind.
3. **Crash and restart.** A node crashes and restarts, losing all in-memory state. (If state was persisted to disk, it
   restarts from its last persisted iteration.)

In all three cases, the lagging node P is at some iteration `h_old` while the network is at `h_current >> h_old`. P
receives consensus messages for `h_current` but cannot process them because it lacks notarized blocks for iterations
`h_old + 1` through `h_current - 1`.

Note that CP23's full-chain forwarding handles cases (1) and (2) automatically — the forwarding message contains the
entire chain, so any received message immediately brings P up to date. It does not handle case (3), because a crashed
node has no local state to build on regardless of what it receives. Our compact forwarding handles none of the three
cases from consensus messages alone, so all three require the catch-up protocol described below.

### 8.2. What a lagging node needs

To resume participation, node P needs two things:

1. **Committed state through `committed_height`.** This is either the sequence of all committed block payloads (from
   which P can reconstruct the application state), or an application-level state snapshot (checkpoint) at
   `committed_height`.

2. **The consensus tail: notarized blocks from `committed_height + 1` through `current_slot`.** This is the set of
   notarized blocks (real and dummy) that have not yet been committed. This tail is bounded in size — during synchrony
   with honest leaders, it is at most 1–2 blocks deep; during periods of consecutive corrupt leaders, it grows at most
   linearly with the number of corrupt-leader slots.

In practice, a checkpoint-based approach is strongly preferred: P requests a state snapshot at the latest
`committed_height` rather than replaying all blocks from genesis. The consensus tail is then just the small set of
post-commit notarized blocks.

### 8.3. Protocol

The catch-up protocol uses two new message types, exchanged point-to-point (not broadcast):

```
CatchUpRequest {
    my_height: Slot,           // P's current iteration
    my_committed: Slot,        // P's last committed height
}

CatchUpResponse {
    committed_height: Slot,    // Responder's last committed height
    committed_block: Block,    // The committed block at committed_height
    finalization: Vec<(PeerId, Sig)>,  // Finalization certificate for committed_height
    tail: Vec<(Block, Vec<(PeerId, Sig)>)>,  // Notarized blocks from committed_height+1 to current
}
```

**Trigger.** When node P receives a consensus message (proposal, vote, notarization, or finalize) for a slot `h` such
that `h > current_slot + CATCH_UP_THRESHOLD`, P concludes it is lagging and initiates catch-up. `CATCH_UP_THRESHOLD` is
a configuration parameter; a value of 2–5 is reasonable.

P should not initiate catch-up on every out-of-range message. A simple rate limit (at most one catch-up request per
`CATCH_UP_INTERVAL`, e.g., 1 second) prevents flooding.

**Request.** P sends a `CatchUpRequest` to the peer from which it received the out-of-range message. Optionally, P can
send catch-up requests to multiple peers in parallel and take the first valid response.

**Response.** On receiving a `CatchUpRequest`, an honest peer Q constructs a `CatchUpResponse` from its own local state.
Q includes:

- Its latest committed block and the corresponding finalization certificate (2n/3 finalize signatures).
- All notarized blocks after `committed_height` that Q has in its complete block tree.

**Validation.** On receiving a `CatchUpResponse`, P validates:

1. The finalization certificate is valid: 2n/3 valid signatures on `⟨finalize, committed_height⟩`.
2. The committed block at `committed_height` is notarized in the response (or P already has it).
3. Each block in the tail has a valid notarization (2n/3 vote signatures).
4. The tail forms a valid chain: each block's `h_parent` references an earlier block in the tail or the committed block.

If validation passes, P updates its local state:

- Sets `committed_height` to the response's `committed_height`.
- Adds all tail blocks to its local notarized-block store.
- Advances `current_slot` to the height of the latest block in the tail + 1.
- Delivers committed block payloads to the application layer.
- Resumes normal consensus participation.

### 8.4. Bounding the catch-up data

The size of the `CatchUpResponse` is bounded by the consensus tail, which is the gap between the current slot and the
last committed slot. This gap is bounded as follows:

- **During synchrony with honest leaders:** Each honest leader's block is committed within 3δ (Lemma 3.5). The tail is
  at most 1–2 blocks.
- **During synchrony with consecutive corrupt leaders:** Each corrupt leader slot is skipped within 3Δ + δ (Lemma 3.6).
  Blocks are not committed during this period, so the tail grows by 1 per corrupt leader slot. With f < n/3 corrupt
  parties and random leader selection, the expected run of consecutive corrupt leaders is ≤ 1.5 slots.
- **During asynchrony:** The tail can grow unboundedly in theory, but in practice timeout mechanisms ensure it remains
  manageable.

For typical parameters (n = 100, Δ = 10s, honest majority of leaders), the tail is almost always under 10 blocks. Even
in adversarial conditions, the tail is bounded by the number of slots elapsed during the asynchronous period.

### 8.5. Safety argument

The catch-up protocol does not affect consensus safety. A catching-up node P does not cast any votes or send any
consensus messages until it has completed catch-up and advanced to the current iteration. During catch-up, P is a
passive observer.

The catch-up response is self-authenticating: the finalization certificate and notarizations contain the same 2n/3
threshold signatures used by the consensus protocol itself. A Byzantine peer cannot fabricate a valid catch-up response
containing blocks or finalization certificates that were not actually produced by the consensus protocol (this follows
from the same Quorum Size Property used throughout CP23).

A Byzantine peer *can* send a stale catch-up response (e.g., one that is several slots behind the true current state).
This is harmless: P will catch up to the stale state, resume consensus, and then immediately detect that it is still
behind (because it will receive consensus messages for slots beyond its new `current_slot`), triggering another catch-up
round.

### 8.6. Liveness argument

The catch-up protocol restores the liveness property that was lost by compact forwarding. Specifically:

**Claim.** Suppose the network is δ-synchronous over [T, T + Δ_catchup] for some Δ_catchup, and at time T some honest
node P is at iteration h_old while all other honest nodes are at iteration h_current. Then P will complete catch-up and
resume consensus participation before time T + 3δ + Δ_catchup, where Δ_catchup accounts for the time to transmit the
catch-up response.

**Argument.** At time T, P receives a consensus message for h_current from some honest peer Q, triggering a catch-up
request (within T + δ). Q responds with a valid `CatchUpResponse` (within T + 2δ). P validates and applies the
response (within T + 2δ + computation time). P then advances to the current iteration and resumes normal participation.

The total catch-up time is dominated by the transmission time for the catch-up response, which is proportional to the
size of the consensus tail. For the typical case (tail of 1–10 blocks at 10KB each), this is under 1ms of transmission
time at 1Gbps, negligible compared to δ.

### 8.7. Interaction with consensus participation

While catching up, node P must handle an edge case: it may receive consensus messages for the current iteration from
other nodes *during* the catch-up process. The implementation should:

1. **Buffer all consensus messages** received during catch-up, keyed by slot number.
2. **After catch-up completes**, process buffered messages for `current_slot` normally (they may contain proposals,
   votes, or notarizations that allow P to immediately participate).
3. **Discard buffered messages** for slots before `current_slot` — they are no longer relevant.

This ensures P transitions smoothly from catch-up to active consensus without missing the current slot's activity.

### 8.8. Comparison to CP23 full-chain forwarding

| Property                        | CP23 full-chain forwarding                | Compact forwarding + catch-up                     |
|---------------------------------|-------------------------------------------|---------------------------------------------------|
| Steady-state bandwidth per slot | O(h × n × (\|block\| + \|notarization\|)) | O(n × (\|block\| + \|notarization\|))             |
| Catch-up latency                | 0 (built into every message)              | 1 round trip (catch-up request/response)          |
| Catch-up bandwidth              | Amortized into steady-state cost          | O(tail_length × \|block\|), paid only when needed |
| Crash recovery                  | Does not help (no local state)            | Same mechanism handles both partition and crash   |
| Implementation complexity       | None (part of protocol)                   | Requires catch-up protocol + message buffering    |

The compact forwarding + catch-up approach trades a constant 1-round-trip catch-up cost (paid only by lagging nodes,
only when they are actually behind) for an O(h) reduction in steady-state per-slot bandwidth (paid by every node, every
slot). For any chain longer than a few dozen blocks, this is a decisive win.

## 9. Resulting Message Types

The protocol uses seven message types — five for consensus (unchanged from Section 8 of the previous revision) and two
for catch-up:

| Message                                                    | Sender                          | Recipients                       | Size                                |
|------------------------------------------------------------|---------------------------------|----------------------------------|-------------------------------------|
| `Propose(h, bₕ)`                                           | Leader                          | All (broadcast)                  | O(\|txs\|)                          |
| `Vote(h, block_id, sig)`                                   | Each voter                      | All (broadcast)                  | O(\|sig\|)                          |
| `Finalize(h, sig)`                                         | Each voter                      | All (broadcast)                  | O(\|sig\|)                          |
| `Notarization(h, bₕ, votes)`                               | Each party on iteration advance | All (broadcast)                  | O(n · \|sig\| + \|txs\|)            |
| `CatchUpRequest(my_height, my_committed)`                  | Lagging node                    | Single peer (point-to-point)     | O(1)                                |
| `CatchUpResponse(...)`                                     | Responding peer                 | Requesting node (point-to-point) | O(tail × (\|block\| + n · \|sig\|)) |
| (dummy vote is a `Vote` where `block_id` identifies `⊥_h`) |                                 |                                  |                                     |

For n = 100 with Ed25519 signatures (64 bytes) and 10KB block payloads:

| Message                    | Approximate size |
|----------------------------|------------------|
| Propose                    | 10.1 KB          |
| Vote                       | 80 bytes         |
| Finalize                   | 72 bytes         |
| Notarization (real block)  | 16.5 KB          |
| Notarization (dummy block) | 6.5 KB           |

> **Design note: block payload in notarization messages.** Including the full block `bₕ` in the `Notarization` message
> means that on iteration advance, every party broadcasts O(|txs|) to all peers — a total of O(n² · |txs|) aggregate
> bandwidth for forwarding alone. For the small-block regime targeted by this document (|txs| < 100KB), this is
> acceptable: with n=100 and 10KB blocks, the forwarding overhead is ~16.5KB × 100 ≈ 1.6MB aggregate per slot, well
> within
> the bandwidth budget.
>
> An alternative is to send `Notarization(h, block_hash, votes)` (omitting the block body) and require peers to fetch
> the block via a pull request if they missed the `Propose` message. This saves bandwidth at the cost of an additional
> round trip for the fetch, which adds latency in the case where a party missed the proposal. For small blocks, this
> tradeoff favors simplicity — include the block and avoid the pull mechanism entirely. For large blocks (
> megabyte-scale),
> this entire forwarding strategy should be replaced by DispersedSimplex's erasure-coded information dispersal, which is
> explicitly out of scope for this document.

## 10. Local State Requirements

Each party maintains the following state:

| Data structure                                                 | Description                                                                                                             | Bounded by                                                   |
|----------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------|
| `notarized_blocks: BTreeMap<Slot, NotarizedBlock>`             | All notarized blocks (real and dummy) seen so far.                                                                      | Height of the chain (prunable below last commit).            |
| `committed_height: Slot`                                       | Height of the last explicitly committed (finalized) block.                                                              | Single value.                                                |
| `current_slot: Slot`                                           | The party's current iteration.                                                                                          | Single value.                                                |
| `votes_received: HashMap<(Slot, BlockId), Vec<(PeerId, Sig)>>` | Votes collected per slot per block, used to form notarizations.                                                         | O(n) per active slot; old slots pruned.                      |
| `finalize_received: HashMap<Slot, Vec<(PeerId, Sig)>>`         | Finalize messages collected per slot.                                                                                   | O(n) per active slot; old slots pruned.                      |
| `pending_proposal: Option<(Slot, Block)>`                      | A proposal received from the leader that cannot yet be validated (deferred; see Section 5.3).                           | At most 1 entry.                                             |
| `voted_in_slot: HashSet<Slot>`                                 | Slots in which this party has already cast a vote (prevents double-voting).                                             | Bounded by gap between current slot and last committed slot. |
| `complained_in_slot: HashSet<Slot>`                            | Slots in which this party has already voted for the dummy block (prevents sending both finalize and dummy).             | Same bound.                                                  |
| `finalized_in_slot: HashSet<Slot>`                             | Slots in which this party has sent a finalize message.                                                                  | Same bound.                                                  |
| `future_notarizations: BTreeMap<Slot, Notarization>`           | Notarizations received for slots beyond `current_slot`, buffered for later processing or catch-up detection.            | Bounded by catch-up threshold; excess discarded.             |
| `catching_up: bool`                                            | Whether the party is currently executing the catch-up protocol (Section 8). While true, no consensus messages are sent. | Single value.                                                |

**Pruning rule.** All per-slot data structures can be pruned for slots below `committed_height`. Committed blocks and
their payloads are passed to the application layer and do not need to be retained by the consensus engine (unless
serving state-sync requests).

## 11. Summary of Proof Impact

| CP23 proof element                                  | Affected?            | Notes                                                                                                                                                                       |
|-----------------------------------------------------|----------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Lemma 3.1 (signature unforgeability)                | No                   | Cryptographic assumption, unchanged.                                                                                                                                        |
| Lemma 3.2 (quorum intersection, votes)              | No                   | Depends on honest voters voting once per height. Unchanged.                                                                                                                 |
| Lemma 3.3 (quorum intersection, finalize vs. dummy) | No                   | Depends on honest voters sending one of {finalize, dummy}. Unchanged.                                                                                                       |
| Theorem 3.1 (consistency)                           | **Minor adjustment** | Final step uses inductive uniqueness of notarized blocks per height instead of collision-resistant hash chaining. See Section 3.3.                                          |
| Lemma 3.4 (synchronized iterations)                 | **Minor adjustment** | Forwarding sends only height-h notarization. Receivers reconstruct the full notarized chain from local state. Timing bound preserved. See Section 6.5.                      |
| Lemma 3.5 (honest leader, 3δ commit)                | No                   | All honest voters have local state to validate the compact proposal. Timing unchanged.                                                                                      |
| Lemma 3.6 (faulty leader, 3Δ + δ skip)              | No                   | Timer and dummy-vote logic unchanged. Improved to ~2δ with optional Change 5.                                                                                               |
| Theorem 3.2 (optimistic confirmation, 5δ)           | No                   | Follows from Lemmas 3.4 and 3.5, both preserved.                                                                                                                            |
| Theorem 3.3 (worst-case confirmation)               | No                   | Follows from Lemmas 3.5 and 3.6, both preserved.                                                                                                                            |
| Theorem 3.4 (expected view-based liveness)          | No                   | Follows from Lemmas 3.5 and 3.6, both preserved.                                                                                                                            |
| Catch-up protocol (Section 8)                       | **New**              | Not present in CP23. Required by compact forwarding (Change 4). Does not affect safety (catching-up node is passive). Restores liveness for lagging nodes after asynchrony. |

## 12. Comparison with CommonWare's Simplex Implementation

CommonWare provides a production-grade, open-source Rust implementation of Simplex consensus (`commonware-consensus`
crate, module `simplex`). Since it is the most mature public implementation of the Simplex protocol family, this section
documents the design similarities and differences between our approach and theirs. The comparison is based on
CommonWare's published documentation and API surface as of version 2026.3.0.

### 12.1. Shared design decisions

The following decisions were made independently by both our design and CommonWare's implementation. Their convergence
provides additional confidence that these are the correct practical adaptations of CP23.

**No hash chaining.** Both designs replace CP23's `H(b₀, …, bₕ₋₁)` parent hash with a simple view/slot number reference
to the parent. CommonWare uses `Proposal(view, parent_view, payload_digest)`; our design uses
`Block(slot, h_parent, txs)`. The motivation is identical: hash chaining requires knowledge of the full prefix chain and
provides no safety benefit given the quorum intersection property.

**No full-chain forwarding.** Both designs eliminate the CP23 requirement that every forwarding message carry the entire
notarized blockchain. CommonWare explicitly lists this as a deviation from the paper: "Fetch missing
notarizations/nullifications as needed rather than assuming each proposal contains a set of all
notarizations/nullifications for all historical blocks." Our design forwards only the height-h notarization (Change 4).

**Eager nullification on bad proposals.** Both designs immediately send a nullify/complaint vote when the leader's
proposal fails validation, rather than waiting for the full timeout. CommonWare lists two cases: "Treat local proposal
failure as immediate timeout expiry and broadcast nullify(v)" and "Treat local verification failure as immediate timeout
expiry and broadcast nullify(v)." Our Change 5 (eager complaint on invalid payload) is the same optimization.

**Proposal validation against local state.** Both designs validate proposals by checking local state for the required
notarizations and nullifications, rather than expecting the proposal message to carry proof of its ancestry.
CommonWare's Resolver component fetches missing certificates on demand; our design defers validation and re-checks when
missing notarizations arrive (Section 5.3).

**Dedicated catch-up mechanism.** Both designs include a mechanism for lagging nodes to request missing consensus
artifacts from peers. CommonWare implements this via a `Resolver` component with `Request`/`Response` types for fetching
missing notarizations and nullifications. Our design uses a simpler `CatchUpRequest`/`CatchUpResponse` protocol (Section
8) that transmits the committed block plus the consensus tail in a single exchange.

### 12.2. Differences

The following table summarizes the design differences. Each difference is classified by whether it represents a
deliberate simplification in our design (targeting formal verification), a CommonWare-specific production feature, or a
genuine design divergence.

| Aspect                         | CommonWare                                                                                                                                                                                                                                            | Our design                                                                                                                                  | Classification                                         |
|--------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------|
| **Terminology**                | Distinct message types: `notarize`, `nullify`, `finalize`. Nullification = CP23's notarized dummy block.                                                                                                                                              | Retains CP23 terminology: `Vote` for both real and dummy blocks, `Finalize` for the second-round message.                                   | Divergence (cosmetic).                                 |
| **Timer structure**            | Two timers per view: `leader_timeout` (2Δ) fires if no proposal received; `activity_timeout` (3Δ) fires if view has not advanced.                                                                                                                     | Single timer per slot (3Δ). No distinction between leader silence and general stall.                                                        | Deliberate simplification. See Section 12.3.           |
| **Inactive leader skip**       | `skip_timeout` parameter: if the designated leader has not participated in the last N views, nullify immediately (timer set to 0).                                                                                                                    | No skip mechanism. Every leader gets the full timeout regardless of history.                                                                | CommonWare feature. See Section 12.3.                  |
| **Certification step**         | After notarization, the application can delay or prevent finalization via `CertifiableAutomaton::certify()`. If certification fails, the participant nullifies instead of finalizing. Designed for erasure coding validation.                         | No certification step. Notarization triggers an immediate finalize vote (if the timer has not fired).                                       | Deliberate simplification.                             |
| **Optimistic finality**        | Explicitly documented "forced inclusion" property: a notarized block without any timeout is speculatively final after 2 hops.                                                                                                                         | Not discussed. Only full finalization (3 hops) is considered.                                                                               | CommonWare feature.                                    |
| **Message rebroadcast**        | Periodic rebroadcast (`timeout_retry`) of nullify votes and previous-view certificates while stuck in a view. Ensures progress even when messages are dropped.                                                                                        | No rebroadcast. Single forwarding of the notarization on iteration advance. Relies on catch-up protocol for recovery from dropped messages. | CommonWare feature. See Section 12.3.                  |
| **Retroactive vote broadcast** | Participants opportunistically broadcast votes for all tracked views, including past views. Useful for on-chain reward mechanisms.                                                                                                                    | Votes are only broadcast for the current slot.                                                                                              | CommonWare feature (application-specific).             |
| **Block data in consensus**    | Consensus operates on block digests (hashes). Block payloads are fetched separately via a `Relay` component.                                                                                                                                          | Consensus operates on full blocks. Payload is included in `Propose` and `Notarization` messages.                                            | Deliberate simplification.                             |
| **Signature verification**     | Lazy/batched: votes are collected unverified and batch-verified only when a quorum is met. Bisection search isolates invalid signatures. Supports Ed25519 (batch), BLS12-381 multisig (aggregate), secp256r1 (eager), BLS12-381 threshold (succinct). | Not specified. Assumed eager verification. Signature scheme abstracted behind a trait.                                                      | Deliberate simplification.                             |
| **Leader election**            | Pluggable `Elector` trait with built-in `RoundRobin` and `Random` (BLS threshold VRF). VRF seed embedded in every notarize/nullify message.                                                                                                           | Fixed `H*(h) mod n` (hash of slot number). No VRF.                                                                                          | Deliberate simplification.                             |
| **Persistence**                | Write-ahead log (segmented journal). Messages synced to disk before sending to prevent Byzantine behavior on unclean restart. In-memory cache on hot path.                                                                                            | Not specified. Persistence strategy deferred to implementation.                                                                             | CommonWare feature.                                    |
| **Equivocation evidence**      | Explicit types: `ConflictingNotarize`, `ConflictingFinalize`, `NullifyFinalize`. Exported as `Activity` for downstream slashing.                                                                                                                      | Mentioned briefly (Section 5.3) but no explicit types or reporting.                                                                         | CommonWare feature.                                    |
| **Architecture**               | Four components: `Batcher` (message collection + lazy verification), `Voter` (consensus state machine), `Resolver` (fetch missing data), `Application` (propose/verify). All non-blocking.                                                            | Sans-I/O pure state machine (`step(state, input) → outputs`). Single component. No async boundaries within the consensus engine.            | Deliberate divergence (targeting formal verification). |
| **Catch-up strategy**          | `Resolver` fetches missing notarizations/nullifications individually. Leaders broadcast best finalization certificate after nullification to help misaligned nodes.                                                                                   | Single `CatchUpRequest`/`CatchUpResponse` round trip returning the full consensus tail.                                                     | Divergence. See Section 12.3.                          |
| **Epoch / reconfiguration**    | Explicit `Epoch` type. Threshold keys reshared per epoch via DKG.                                                                                                                                                                                     | Not addressed.                                                                                                                              | Out of scope for initial version.                      |

### 12.3. Discussion of selected differences

**Timer structure and inactive leader skip.** CommonWare's two-timer system reduces the cost of a
crashed-but-not-malicious leader from 3Δ to 2Δ. The `skip_timeout` reduces it further to zero for leaders known to be
offline. These are meaningful improvements: with Δ = 10s and n = 100, roughly 33 leaders are potentially offline, and
each costs 30s under our single-timer design versus 0s under CommonWare's skip mechanism.

Our design retains the single-timer approach because it exactly matches CP23 and minimizes the state machine surface for
formal verification. The two-timer system is a candidate for a future revision — it does not affect safety (nullifying
early is always safe) and the liveness argument requires only minor adjustment (the timeout bound in Lemma 3.6 improves
from 3Δ + δ to 2Δ + δ for leader timeout, or to δ for skipped leaders).

**Message rebroadcast.** CommonWare's periodic rebroadcast of nullify votes addresses a real concern: under our design,
if the single forwarded notarization message is dropped (e.g., due to a transient TCP failure), the receiving node has
no way to recover except through the catch-up protocol (Section 8). CommonWare's approach is more graceful — stuck nodes
periodically re-announce their state, giving peers another opportunity to advance.

Our design accepts this tradeoff because the catch-up protocol already handles the recovery case, and adding periodic
rebroadcast increases the message complexity of the steady-state protocol (every node in a timed-out view sends periodic
messages). For a small-scale deployment (n ≤ 100) where TCP connections are persistent and reliable, dropped messages
should be rare.

**Block data separation.** CommonWare runs consensus on block digests and fetches payloads separately via a `Relay`
component. This is the right architecture for large blocks (megabyte-scale), because it prevents block payloads from
inflating consensus messages and allows the data availability layer to operate independently.

Our design includes full block payloads in consensus messages. This is simpler (no separate fetch round, no Relay
component, no data availability concerns) and sufficient for the small-block regime (< 100KB) we are targeting. The
tradeoff is that our `Notarization` message is O(|txs| + n · |sig|) rather than O(n · |sig|). For 10KB blocks and n =
100, this adds ~10KB per notarization — acceptable.

Migration to a digest-based design would be required if block sizes grow significantly. At that point, the entire
protocol should transition to DispersedSimplex's erasure-coded information dispersal, which subsumes both the block
separation and the data availability concerns.

**Sans-I/O vs. multi-component architecture.** CommonWare splits the consensus engine into four non-blocking
components (`Batcher`, `Voter`, `Resolver`, `Application`) communicating via channels. This is natural for an async Rust
system optimizing for throughput: signature verification, block validation, and certificate fetching all proceed
concurrently without blocking the main consensus loop.

Our design uses a single synchronous state machine (`step(state, input) → outputs`) with no internal async boundaries.
This is a deliberate choice driven by our formal verification target: the Aeneas → Lean4 translation pipeline operates
on safe, synchronous Rust. The networking, timers, and I/O live in an unverified shell that feeds inputs to the verified
state machine and dispatches its outputs. This architecture sacrifices some concurrency (block validation blocks the
consensus step) but produces a verification-friendly surface with a clean, total `step` function.

**Certification.** CommonWare's certification step is an application-level hook between notarization and finalization.
It is particularly useful for systems that employ erasure coding: a node can delay its finalize vote until it has
reconstructed and validated the full block from erasure-coded fragments. If certification fails for a quorum of
participants, the view is nullified instead of finalized.

Our design has no certification step because we include the full block payload in consensus messages (no erasure coding,
no deferred validation). If we later adopt DispersedSimplex's erasure coding, a certification-like mechanism would
become necessary — it would correspond to the point where a node successfully decodes and validates the block from
received fragments before issuing its commit share.
