# Practical Wire Protocol Adaptations for Simplex Consensus

**References:** Chan & Pass, "Simplex Consensus" (CP23); Shoup, "Sing a Song of Simplex" (DispersedSimplex).

## 1. Motivation and Scope

The Simplex protocol as specified in CP23 transmits the entire notarized blockchain in three protocol actions: leader
proposals, proposal validation, and view-advance forwarding. A literal implementation would send O(h) blocks and O(h)
notarizations per view, where h is the current chain height. This is clearly impractical.

This document specifies a minimal adaptation of CP23 for production implementation, prioritizing **verification
tractability** (Aeneas → Lean4 pipeline) over communication efficiency. The protocol logic, state transitions, safety
proof, and liveness proof remain structurally identical to CP23; only the wire format changes.

### 1.1. Relaxed responsibilities

The consensus engine is deliberately restricted to a narrow role:

- Consensus produces a stream of *finalized-block events*. Gaps are permitted: consensus may emit `Finalize(v', …)`
  without having previously emitted `Finalize(v)` for every `v < v'`.
- Consensus treats block payloads as opaque bytes. It does not validate transactions, does not maintain application
  state, and does not call back into the application layer during voting.
- Consensus does not recover missing blocks or replay history. If the application layer needs block payloads it did
  not receive via consensus, it fetches them through a separate, out-of-scope protocol.

These relaxations eliminate the need for a consensus-layer catch-up protocol, a syncing-state hook, and all
state-dependent proposal validation. The consensus engine's only job is to produce finalized blocks with 2n/3
threshold signatures; downstream concerns are the application layer's.

### 1.2. Changes from CP23

1. **Height-based parent references** replace hash-chain block linking.
2. **Self-contained proposals.** The leader attaches a chain of notarizations for every view from `finalized_view + 1`
   through `view - 1` inclusive. Voters validate and advance using only the proposal's contents.
3. **Compact iteration-advance forwarding.** When advancing views, nodes forward only the triggering notarization
   rather than the full chain.

All changes assume small block payloads (under ~100KB). For larger blocks, DispersedSimplex's erasure-coded dispersal
is the appropriate design; it is out of scope here.

## 2. Block Structure

A block is a tuple `(h, h_parent, txs)`:

- `h`: height of the block.
- `h_parent`: height of the highest non-dummy ancestor. `h_parent = 0` means the genesis block is the direct parent.
- `txs`: opaque transaction payload, treated by consensus as bytes.

Genesis: `b₀ = (0, 0, ∅)`. Dummy block at height `h`: `⊥_h = (h, ⊥, ⊥)`, unchanged from CP23.

**Correctness.** CP23's consistency proof (Theorem 3.1) uses the parent hash only to establish that when two honest
parties hold a notarized non-dummy block at height `h`, their ancestor chains must agree. Under height references,
this is re-established inductively: by Lemma 3.2, at most one non-dummy block is notarized per height; the block at
height `h_parent` is therefore uniquely determined, and the argument recurses down to genesis. Shoup (DispersedSimplex
§1) confirms hash chaining is unnecessary for Simplex.

A production implementation may include a content hash for archival or content-addressing purposes; this is a
non-consensus-critical metadata field.

## 3. Leader Proposal

When the leader `L_h` enters view `h`, it multicasts:

```
⟨propose, h, bₕ, π_chain⟩_L
```

where `bₕ = (h, h_parent, txs)` is the leader's new block, and `π_chain` is the sequence of notarizations for every
view in `[state.finalized_view + 1, h - 1]` inclusive, ordered by view. `π_chain` may be empty (when
`state.finalized_view + 1 ≥ h`, i.e., immediately after finalization catches up to the tip).

Each notarization in `π_chain` witnesses either a non-dummy block (with its block payload) or a dummy block at its
view.

The leader always has these notarizations: it built its own notarized chain to reach view `h`, so by construction it
holds a notarization for every view between `finalized_view + 1` and `h - 1`.

## 4. Proposal Validation

On receiving `⟨propose, h, bₕ, π_chain⟩_L`, voter `i` checks:

1. **Well-formedness.** `bₕ ≠ ⊥_h`, `0 ≤ h_parent < h`, `|bₕ| ≤ MAX_BLOCK_SIZE`, signed by `leader(h)`.
2. **View alignment.** `h == state.current_view`, or the voter can advance to `h` using `π_chain` (see step 4).
3. **Parent view not below finalized.** `h_parent ≥ state.finalized_view`. (A proposal extending a finalized fork
   cannot be notarized by any honest quorum.)
4. **Chain verifies.** Every notarization in `π_chain` has a valid 2n/3 quorum signature, covers a distinct view in
   `[state.finalized_view + 1, h - 1]`, and collectively forms a contiguous sequence. The non-dummy notarization at
   `h_parent` (if `h_parent > state.finalized_view`) witnesses `bₕ`'s claimed parent.
5. **Payload.** Opaque — no application-level validation.

If all checks pass, the voter installs every notarization from `π_chain` into its local `notarized_blocks`, advances
`current_view` to `h`, and multicasts `⟨vote, h, bₕ⟩_i`. If the voter has already voted in view `h` (real or dummy
vote), it skips the vote but still installs the chain contents.

The voter does **not** need notarizations for views below `state.finalized_view`, nor does it need to traverse each
intermediate view. The chain itself is a cryptographic witness that the claimed sequence of views was notarized by
the honest quorum.

### 4.1. Deferred validation

A proposal may arrive before its chain is fully buildable in the voter's frame (for example, the voter's
`finalized_view` is temporarily behind the leader's). This does not require buffering or special handling: the voter
drops the proposal and recovers via arrival of the next proposal, which will include a chain starting from the
voter's (possibly-updated) `finalized_view + 1`. Since proposals are broadcast every view under honest-leader
conditions, the delay is bounded.

### 4.2. Correctness

The validation checks are equivalent to CP23's proposal validation: `π_chain` is precisely the notarized blockchain
of height `h - 1` that CP23 requires the proposal to carry, minus the blocks below `finalized_view` (which are
already finalized and therefore uniquely determined by quorum intersection). Safety and liveness lemmas (CP23 Lemmas
3.2–3.6 and Theorems 3.1–3.4) hold unchanged; the only difference is the data source for the notarized parent chain.

## 5. Iteration-Advance Forwarding

When a party observes a notarization for view `h` and advances to view `h + 1`, it multicasts:

```
⟨notarization, h, bₕ, V⟩
```

where `V` is the 2n/3 vote signatures constituting the notarization.

This is redundant with the proposal's chain in the common case: a voter that receives the proposal for view `h + 1`
already gets view `h`'s notarization via `π_chain`. Forwarding remains useful for voters who temporarily miss a
proposal — they can still advance on the strength of forwarded notarizations from other honest peers.

**Correctness.** CP23 Lemma 3.4 (synchronized iterations) holds: every honest party enters view `h + 1` within δ of
the first honest party entering `h + 1`. The proof relies only on the receiver being able to reconstruct a notarized
chain of height `h`; whether this arrives via proposal or via forwarded notarization does not affect the timing.

## 6. Finalization

Finalization is unchanged from CP23. When a party observes 2n/3 `Finalize(v)` messages for view `v`, it outputs the
finalized block at view `v` to the application layer via `FinalizeBlock(v, block)`.

The application layer may receive finalized blocks with gaps — e.g., `FinalizeBlock(v)` followed by
`FinalizeBlock(v')` with `v' > v + 1` — and is responsible for fetching intermediate block payloads through its own
protocol if it needs them for state replay.

## 7. Message Types

| Message                      | Sender                     | Size                                    |
|------------------------------|----------------------------|-----------------------------------------|
| `Propose(h, bₕ, π_chain)`    | Leader                     | O(\|txs\| + chain_length × n · \|sig\|) |
| `Vote(h, block_id, sig)`     | Each voter                 | O(\|sig\|)                              |
| `Finalize(h, sig)`           | Each voter                 | O(\|sig\|)                              |
| `Notarization(h, bₕ, votes)` | Each party on view advance | O(\|txs\| + n · \|sig\|)                |

`chain_length` is bounded by `h - finalized_view - 1`, which under normal operation (honest majority, partial
synchrony) is probabilistically small — typically 1–5 views. In the common case where `h = finalized_view + 1`, the
chain is empty and the proposal carries only the new block.

Dummy votes are encoded as `Vote` messages where `block_id` identifies `⊥_h`.

**Sizes for n = 100 with Ed25519 signatures and 10KB payloads:**

| Message                    | Size      |
|----------------------------|-----------|
| Vote, Finalize             | ~80 bytes |
| Notarization (real block)  | ~16.5 KB  |
| Notarization (dummy block) | ~6.5 KB   |
| Propose, chain_length = 0  | ~10 KB    |
| Propose, chain_length = 3  | ~35 KB    |

## 8. Local State

```
State {
    id:                PeerId
    n:                 uint                                   // total validators
    current_view:      View                                   // starts at 0
    finalized_view:    View                                   // last finalized height
    notarized_blocks:  BTreeMap<View, (Block, Notarization)>  // prunable below finalized_view
    votes:             Map<(View, Option<BlockHash>), Vec<(PeerId, Sig)>>
    finalizes:         Map<View, Vec<(PeerId, Sig)>>
    voted_view:        Set<View>                              // views where we cast a real vote
    dummy_voted_view:  Set<View>                              // views where we dummy-voted
    finalized_in_view: Set<View>                              // views where we sent finalize
}
```

Per-view data below `finalized_view` is prunable. A fresh node initializes all fields to empty / zero; it learns the
network's current view from the first arriving proposal.

**Configuration parameters** (no safety impact):

- `MAX_BLOCK_SIZE`: upper bound on proposal payload size.

## 9. State Machine

```
Event =
    | MessageReceived(from: PeerId, msg: Message)
    | TimerExpired(view: View)

Message =
    | Propose(view, block, chain: Vec<Notarization>)
    | Vote(view, block_hash: Option<BlockHash>, sig)
    | Finalize(view, sig)
    | Notarization(view, block, votes: Vec<(PeerId, Sig)>)

Action =
    | Broadcast(msg)
    | FinalizeBlock(view, block)
    | SetTimer(view, 3Δ)
    | CancelTimer(view)
```

### 9.1. Core loops

```
function leader(view) -> PeerId:
    return validators[H(view) mod n]

function quorum() -> uint:
    return floor(2 * n / 3) + 1

function handle_event(state, event) -> Vec<Action>:
    match event:
        MessageReceived(from, msg) -> handle_message(state, from, msg)
        TimerExpired(view)         -> handle_timeout(state, view)
```

### 9.2. Entering a new view

```
function enter_view(state, view) -> Vec<Action>:
    state.current_view = view
    actions = [SetTimer(view, 3Δ)]

    if leader(view) == state.id:
        h_parent = highest notarized non-dummy block height, or 0
        block    = Block(view, h_parent, build_txs())
        chain    = [state.notarized_blocks[v].notarization
                    for v in (state.finalized_view + 1) .. (view - 1)]
        actions.append(Broadcast(Propose(view, block, chain)))

    return actions
```

### 9.3. Handling messages

```
function handle_message(state, from, msg) -> Vec<Action>:
    match msg:

        Propose(view, block, chain):
            // Well-formedness
            if block.is_dummy():                     return []
            if block.h_parent < 0 or block.h_parent >= view: return []
            if size_of(block) > MAX_BLOCK_SIZE:      return []
            if from != leader(view):                 return []
            if not verify_leader_signature(msg):     return []

            // Stale proposals
            if view < state.current_view:            return []

            // Parent not below finalized
            if block.h_parent < state.finalized_view: return []

            // Verify chain: contiguous notarizations covering
            // [state.finalized_view + 1, view - 1]
            expected_range = (state.finalized_view + 1) .. (view - 1)
            if chain.views() != expected_range:      return []
            for notarization in chain:
                if not verify_notarization(notarization): return []

            // Parent check: the chain's notarization at h_parent (if in range)
            // must be for block.h_parent's referenced parent
            if block.h_parent > state.finalized_view:
                parent_not = chain.find(block.h_parent)
                if parent_not.block.is_dummy():      return []

            // Install chain, advance view
            actions = []
            for notarization in chain:
                state.notarized_blocks[notarization.view] = (notarization.block, notarization.votes)
                actions.append(Broadcast(Notarization(notarization.view,
                                                     notarization.block,
                                                     notarization.votes)))
            if view > state.current_view:
                actions.extend(enter_view(state, view))

            // Vote, unless we've already acted on this view
            if view in state.voted_view:       return actions
            if view in state.dummy_voted_view: return actions
            state.voted_view.add(view)
            actions.append(Broadcast(Vote(view, Some(hash(block)),
                                          sign("vote", view, hash(block)))))
            return actions

        Vote(view, block_hash, sig):
            if view < state.finalized_view: return []
            if not verify_sig(from, (view, block_hash), sig): return []
            state.votes[(view, block_hash)].append((from, sig))
            if len(state.votes[(view, block_hash)]) == quorum():
                return handle_quorum(state, view, block_hash)
            return []

        Finalize(view, sig):
            if view < state.finalized_view: return []
            if not verify_sig(from, ("finalize", view), sig): return []
            state.finalizes[view].append((from, sig))
            if len(state.finalizes[view]) == quorum():
                block = state.notarized_blocks[view].block
                state.finalized_view = view
                prune_state_below(state, view)
                return [CancelTimer(view), FinalizeBlock(view, block)]
            return []

        Notarization(view, block, votes):
            if view < state.current_view: return []
            if not verify_notarization(view, block, votes): return []
            state.notarized_blocks[view] = (block, votes)
            if view == state.current_view:
                return [Broadcast(Notarization(view, block, votes))]
                     ++ enter_view(state, view + 1)
            return []
```

### 9.4. Quorum reached

```
function handle_quorum(state, view, block_hash) -> Vec<Action>:
    actions = []

    if block_hash is Some(h):
        block = find_block_for_hash(h)
        votes = state.votes[(view, block_hash)]
        state.notarized_blocks[view] = (block, votes)

        if view not in state.dummy_voted_view and view not in state.finalized_in_view:
            state.finalized_in_view.add(view)
            actions.append(Broadcast(Finalize(view, sign("finalize", view))))
    else:
        dummy = DummyBlock(view)
        votes = state.votes[(view, None)]
        state.notarized_blocks[view] = (dummy, votes)

    actions.append(Broadcast(Notarization(view,
                                         state.notarized_blocks[view].block,
                                         state.notarized_blocks[view].votes)))
    actions.extend(enter_view(state, view + 1))
    return actions
```

### 9.5. Timeout

```
function handle_timeout(state, view) -> Vec<Action>:
    if view != state.current_view:     return []
    if view in state.dummy_voted_view: return []
    if view in state.finalized_in_view: return []

    state.dummy_voted_view.add(view)
    return [Broadcast(Vote(view, None, sign("vote", view, None)))]
```

## 10. Proof Impact

| CP23 proof element                                  | Affected?            | Notes                                                                                                                                 |
|-----------------------------------------------------|----------------------|---------------------------------------------------------------------------------------------------------------------------------------|
| Lemma 3.1 (signature unforgeability)                | No                   | Unchanged cryptographic assumption.                                                                                                   |
| Lemma 3.2 (quorum intersection, votes)              | No                   | Unchanged.                                                                                                                            |
| Lemma 3.3 (quorum intersection, finalize vs. dummy) | No                   | Unchanged.                                                                                                                            |
| Theorem 3.1 (consistency)                           | **Minor adjustment** | Final step uses inductive uniqueness of notarized blocks per height instead of hash chaining. See §2.                                 |
| Lemma 3.4 (synchronized iterations)                 | No                   | The proposal's `π_chain` delivers the notarized chain in one message; forwarding is redundant backup. Timing bound preserved. See §5. |
| Lemma 3.5 (honest leader, 3δ commit)                | No                   | Voters validate proposals directly from `π_chain` without waiting on forwarding. Timing unchanged.                                    |
| Lemma 3.6 (faulty leader, 3Δ + δ skip)              | No                   | Timer and dummy-vote logic unchanged.                                                                                                 |
| Theorem 3.2–3.4 (liveness theorems)                 | No                   | Follow from Lemmas 3.4–3.6, all preserved.                                                                                            |

## 11. What is Out of Scope

This document specifies consensus only. The following are intentionally excluded:

- **Application-layer block-payload synchronization.** The app layer is responsible for fetching block payloads for
  finalized views it missed, and for applying blocks to its state in whatever order it can.
- **Transaction validation.** The consensus engine treats `txs` as opaque bytes. Byzantine leaders proposing invalid
  transaction payloads will see those payloads finalized; the app layer skips invalid blocks during replay. This is a
  deliberate trade for simplicity.
- **Leader election beyond the deterministic `H(view) mod n` rule.** Verifiable random leader election (VRF-based) is
  a future extension.
- **Persistence, crash recovery, epoch transitions, reconfiguration, slashing, and equivocation evidence export.**
  All out of scope for the initial verification target.
- **Erasure coding / information dispersal** for large blocks. Targeting the small-block regime (|txs| ≤ ~100KB)
  only; large-block deployments should use DispersedSimplex.
