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
view in `[chain_start, h - 1]` inclusive, ordered by view, where `chain_start = min(finalized_view + 1, h_parent)`.
The chain always includes the notarization for `h_parent` (when `h_parent > 0`): under long runs of unfinalized
non-dummy views, `h_parent` may itself be at `finalized_view`, in which case the chain extends one view below
`finalized_view + 1` to keep the parent's notarization inline with the proposal. In the common case
(`h_parent > finalized_view`), the rule collapses to `chain_start = finalized_view + 1`.

`π_chain` may be empty (when `h_parent = 0` and `h = 1`, i.e., the first real proposal after genesis).

Each notarization in `π_chain` witnesses either a non-dummy block (with its block payload) or a dummy block at its
view.

The leader always has these notarizations: it built its own notarized chain to reach view `h`, so by construction it
holds a notarization for every view from `finalized_view` up to `h - 1`.

## 4. Proposal Validation

On receiving `⟨propose, h, bₕ, π_chain⟩_L`, voter `i` checks:

1. **Well-formedness.** `bₕ ≠ ⊥_h`, `0 ≤ h_parent < h`, `|bₕ| ≤ MAX_BLOCK_SIZE`, signed by `leader(h)`.
2. **View alignment.** `h ≥ state.current_view`. If `h > state.current_view`, the voter advances using `π_chain` (see
   step 4).
3. **Parent view not below finalized.** `h_parent ≥ state.finalized_view`. (A proposal extending a finalized fork
   cannot be notarized by any honest quorum.)
4. **Chain coverage and bounds.** The voter considers only chain entries with view `≥ state.finalized_view` as
   *relevant*; entries below are silently ignored (not verified, not installed, not broadcast). The relevant
   subsequence must be contiguous ascending and every relevant entry must have a valid 2n/3 quorum signature and a
   view strictly less than `h`. Together with the voter's local `notarized_blocks`, the relevant chain entries must
   cover every view in `[state.finalized_view + 1, h - 1]`. This tolerates asymmetric finalization (an honest leader
   whose `finalized_view` is below the voter's will attach entries below the voter's `finalized_view`, which the
   voter harmlessly ignores) without creating a CPU-amplification vector (the voter only verifies signatures on
   relevant entries). No maximum chain length is enforced at the consensus layer — honest chains can grow
   arbitrarily long during extended asynchronous periods, and a bound would break liveness.
5. **Parent is non-dummy, supplied by chain.** When `h_parent > 0`, the notarization at `h_parent` must be in `π_chain`
   (the leader's chain rule guarantees this) and must witness a non-dummy block matching `bₕ`'s parent reference.
   When `h_parent = 0`, the genesis block is the parent and no notarization is needed.
6. **Intermediate views are dummy.** For every view `v` in `(h_parent, h)`, the chain must contain a notarization
   witnessing a dummy block at `v`. This prevents a Byzantine leader from pointing `h_parent` past a real non-dummy
   notarization.
7. **Payload.** Opaque — no application-level validation.

If all checks pass, the voter installs every new notarization from `π_chain` into its local `notarized_blocks`,
advances `current_view` to `h`, and multicasts `⟨vote, h, bₕ⟩_i`. If the voter has already voted in view `h` (real or
dummy vote), it skips the vote but still installs the chain contents.

The voter does **not** need notarizations for views below `state.finalized_view`, nor does it need to traverse each
intermediate view. Parent and intermediate-dummy checks are satisfied entirely from `π_chain`; local state is
consulted only for the chain-coverage check in step 4, and only to fill in views below the chain's lower bound.

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
    known_blocks:      Map<BlockHash, Block>                  // blocks seen via Propose or Notarization
    votes:             Map<(View, Option<BlockHash>), Map<PeerId, Sig>>  // deduped by signer
    finalizes:         Map<View, Map<PeerId, Sig>>                       // deduped by signer
    pending_quorums:   Set<(View, BlockHash)>                 // vote quorum reached but block body not yet known
    pending_finalizations: Set<View>                          // finalize quorum reached but block not yet notarized locally
    voted_view:        Set<View>                              // views where we cast a real vote
    dummy_voted_view:  Set<View>                              // views where we dummy-voted
    finalized_in_view: Set<View>                              // views where we sent finalize
}
```

Per-view data below `finalized_view` is prunable. A fresh node initializes all fields to empty / zero; it learns the
network's current view from the first arriving proposal.

**Configuration parameters** (no safety impact):

- `MAX_BLOCK_SIZE`: upper bound on proposal payload size. Proposals exceeding this are dropped.

(Message-size limits for oversized proposals — e.g., proposals with very long chains during extended
asynchronous periods — are the responsibility of the P2P transport layer and are not enforced here: honest chains
can legitimately grow arbitrarily long under extended partial synchrony pre-GST, and imposing a consensus-level
cap would break liveness.)

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

        // Chain covers [min(finalized_view + 1, h_parent), view - 1]. This always
        // includes h_parent's notarization (when h_parent > 0), so the voter can
        // validate the parent reference from the chain alone without depending on
        // its local notarized_blocks. Normally h_parent >= finalized_view + 1 and
        // this collapses to the common case; under long runs of unfinalized
        // non-dummy views, the chain may start below finalized_view + 1.
        chain_start = h_parent if h_parent > 0 and h_parent < state.finalized_view + 1
                      else state.finalized_view + 1

        // If the node arrived at this view via forwarded notarization from a
        // future view (§5), it may be missing notarizations for intermediate
        // views. Without those, it cannot construct a valid chain. Silently
        // abort proposal generation; the view will time out after 3Δ and the
        // network will advance via the normal skip path (Lemma 3.6). The node
        // still participates as a voter in this view (dummy-voting on timeout).
        if any v in (chain_start .. (view - 1)) where v not in state.notarized_blocks:
            return actions

        chain = [state.notarized_blocks[v].notarization
                 for v in chain_start .. (view - 1)]
        actions.append(Broadcast(Propose(view, block, chain)))

    return actions
```

### 9.3. Handling messages

`verify_notarization(view, block, votes)` returns `true` iff `votes` is a set of at least `quorum()` vote signatures
by *distinct* validator identities, each signing `(view, hash(block))` (or `(view, None)` if `block` is a dummy).
Distinctness is essential: a single Byzantine validator must not be able to fabricate a notarization by signing
multiple times. The same distinctness requirement applies to the `Vote` and `Finalize` handlers below, where the
`votes`/`finalizes` maps are keyed by `PeerId` to enforce this.

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

            // Chain well-formedness and bounds. We process only entries at
            // or above voter.finalized_view — entries below it are irrelevant
            // (already finalized, not needed for coverage, parent, or
            // intermediate checks) and are silently ignored without signature
            // verification. This tolerates asymmetric finalization (leader's
            // finalized_view may be lower than voter's, so honest chains may
            // include entries below voter.finalized_view) while avoiding CPU
            // amplification from Byzantine attachment of pruned historical
            // notarizations.
            //
            // No hard cap on chain length: under long asynchronous periods,
            // honest chains can legitimately grow arbitrarily long. Message
            // size limits are a P2P-layer concern, not a consensus concern.
            relevant = [n for n in chain if n.view >= state.finalized_view]
            if not relevant.is_contiguous_ascending(): return []
            for notarization in relevant:
                if notarization.view >= view:          return []
                if not verify_notarization(notarization): return []

            // Build the set of views covered by (relevant chain ∪ local notarized_blocks).
            // This set must include every view in [finalized_view + 1, view - 1].
            covered = { n.view for n in relevant }
                    ∪ { v for v in state.notarized_blocks.keys() if v < view }
            for v in (state.finalized_view + 1) .. (view - 1):
                if v not in covered:                   return []

            // Parent check: the chain must supply h_parent's notarization and
            // it must witness a non-dummy block. The leader's chain rule
            // (§3) guarantees h_parent is always in the chain when h_parent > 0.
            // Filter 3 guarantees h_parent >= finalized_view, so the parent is
            // in the relevant range.
            if block.h_parent > 0:
                parent = relevant.find(block.h_parent)
                if parent is None or parent.block.is_dummy(): return []

            // Intermediate-dummy enforcement: every view strictly between
            // block.h_parent and view must have a notarization in the chain
            // witnessing a DUMMY block. Range is (h_parent, view), all within
            // the relevant range since h_parent >= finalized_view.
            for v in (block.h_parent + 1) .. (view - 1):
                intermediate = relevant.find(v)
                if intermediate is None:              return []
                if not intermediate.block.is_dummy(): return []

            // Install relevant chain entries that are new to local state,
            // re-broadcast them, and resolve any pending quorums/finalizations
            // they unlock.
            actions = []
            for notarization in relevant:
                actions.extend(maybe_resolve_pending_quorum(state,
                    notarization.view, hash(notarization.block), notarization.block))
                if notarization.view not in state.notarized_blocks:
                    state.notarized_blocks[notarization.view] = (notarization.block, notarization.votes)
                    actions.extend(on_notarization_installed(state, notarization.view))
                    actions.append(Broadcast(Notarization(notarization.view,
                                                         notarization.block,
                                                         notarization.votes)))

            // Register the proposed block and resolve any pending quorum for it
            // (votes may have arrived ahead of the proposal).
            actions.extend(maybe_resolve_pending_quorum(state, view, hash(block), block))

            // Advance to the proposal's view if we're behind
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
            // Deduplicate by PeerId: a Byzantine node cannot reach quorum
            // single-handedly by spamming valid-signed duplicates.
            if from in state.votes[(view, block_hash)]: return []
            state.votes[(view, block_hash)][from] = sig
            if len(state.votes[(view, block_hash)]) == quorum():
                return handle_quorum(state, view, block_hash)
            return []

        Finalize(view, sig):
            if view < state.finalized_view: return []
            if not verify_sig(from, ("finalize", view), sig): return []
            // Deduplicate by PeerId, same rationale as Vote.
            if from in state.finalizes[view]: return []
            state.finalizes[view][from] = sig
            if len(state.finalizes[view]) == quorum():
                return maybe_finalize(state, view)
            return []

        Notarization(view, block, votes):
            // Reject notarizations for already-finalized views. Without this
            // guard, a Byzantine peer can replay valid historical notarizations
            // for pruned views; verify_notarization passes, notarized_blocks is
            // re-populated with a view that will never be pruned again
            // (maybe_finalize won't fire for an already-finalized view), and
            // on_notarization_installed emits a stale Finalize broadcast.
            if view <= state.finalized_view: return []
            if view < state.current_view and view in state.notarized_blocks: return []
            if not verify_notarization(view, block, votes): return []
            newly_installed = view not in state.notarized_blocks
            if newly_installed:
                state.notarized_blocks[view] = (block, votes)

            actions = []

            // Resolve any pending quorum and any pending finalization for this view
            actions.extend(maybe_resolve_pending_quorum(state, view, hash(block), block))
            if newly_installed:
                actions.extend(on_notarization_installed(state, view))

            // Advance if this notarization puts us at or past current_view.
            // Advancing by more than one view at once is safe: any future
            // proposal's chain will cover any remaining intermediate gaps.
            if view >= state.current_view:
                actions.append(Broadcast(Notarization(view, block, votes)))
                actions.extend(enter_view(state, view + 1))
            return actions
```

### 9.4. Quorum reached

```
function handle_quorum(state, view, block_hash) -> Vec<Action>:
    if block_hash is None:
        // Dummy-block quorum: block body is synthetic, always available
        dummy = DummyBlock(view)
        votes = state.votes[(view, None)]
        state.notarized_blocks[view] = (dummy, votes)
        actions = on_notarization_installed(state, view)
        actions.append(Broadcast(Notarization(view, dummy, votes)))
        // Only advance if this notarization is at or past current_view.
        // A late-arriving quorum for an older view should still install and
        // broadcast, but must not regress current_view.
        if view >= state.current_view:
            actions.extend(enter_view(state, view + 1))
        return actions

    // Real-block quorum: block body may not have arrived yet
    h = block_hash
    if h not in state.known_blocks:
        // Votes raced ahead of the proposal. Mark quorum as pending; it will
        // be resolved when the block arrives via Propose or Notarization.
        state.pending_quorums.add((view, h))
        return []

    return finalize_notarization(state, view, h)

function finalize_notarization(state, view, block_hash) -> Vec<Action>:
    block = state.known_blocks[block_hash]
    votes = state.votes[(view, Some(block_hash))]
    state.notarized_blocks[view] = (block, votes)

    // on_notarization_installed handles the Finalize broadcast centrally
    // (see §9.4 comment) and resolves any pending finalization.
    actions = on_notarization_installed(state, view)

    actions.append(Broadcast(Notarization(view, block, votes)))
    // Only advance if this notarization is at or past current_view. See
    // handle_quorum for rationale.
    if view >= state.current_view:
        actions.extend(enter_view(state, view + 1))
    return actions

function maybe_resolve_pending_quorum(state, view, block_hash, block) -> Vec<Action>:
    // Called from Propose and Notarization handlers when a block body arrives.
    // Record the block and, if a quorum was previously pending for it, complete
    // the notarization now.
    state.known_blocks[block_hash] = block
    actions = []
    if (view, block_hash) in state.pending_quorums:
        state.pending_quorums.remove((view, block_hash))
        actions.extend(finalize_notarization(state, view, block_hash))
    return actions

function maybe_finalize(state, view) -> Vec<Action>:
    // Finalize quorum has been reached for `view`. A quorum of Finalize
    // messages is a cryptographic witness that the network has finalized
    // `view`, so we advance finalized_view immediately — even if we lack
    // the block body locally. This prevents a permanent liveness deadlock
    // in which the node cannot accept future proposals (coverage check
    // demands notarizations for views below the true finalized height that
    // were never observed) and cannot advance finalized_view (the block
    // for `view` hasn't arrived).
    //
    // The FinalizeBlock action — the app-layer handoff — is deferred until
    // the block body is known locally. See on_notarization_installed.
    if view <= state.finalized_view:
        // Already finalized; ignore duplicate quorum.
        return []

    state.finalized_view = view
    prune_state_below(state, view)
    actions = [CancelTimer(view)]

    if view not in state.notarized_blocks:
        // Block body not yet known. Defer the FinalizeBlock handoff until
        // on_notarization_installed fires for this view.
        state.pending_finalizations.add(view)
        return actions

    block = state.notarized_blocks[view].block
    actions.append(FinalizeBlock(view, block))
    return actions

function on_notarization_installed(state, view) -> Vec<Action>:
    // Called whenever a view's notarization is newly added to
    // state.notarized_blocks, regardless of whether it was installed from a
    // local vote quorum, a forwarded Notarization message, or a proposal's
    // π_chain. This centralization ensures CP23 Step 4 (finalize broadcast on
    // first notarization sighting) fires uniformly for all delivery paths —
    // otherwise nodes that catch up via forwarding would not contribute to
    // finalization quorums, risking permanent finalization stalls.
    actions = []

    // CP23 Step 4: broadcast Finalize(view) upon seeing a notarized non-dummy
    // block at `view` for the first time, provided we didn't dummy-vote at
    // `view` (CP23 Lemma 3.3) and haven't already finalized.
    block = state.notarized_blocks[view].block
    if not block.is_dummy()
       and view not in state.dummy_voted_view
       and view not in state.finalized_in_view:
        state.finalized_in_view.add(view)
        actions.append(Broadcast(Finalize(view, sign("finalize", view))))

    // Resolve any pending finalization whose FinalizeBlock handoff was
    // deferred because the block body was unknown at Finalize-quorum time.
    // finalized_view was already advanced in maybe_finalize; we only need
    // to emit the FinalizeBlock event now that the block is available.
    if view in state.pending_finalizations:
        state.pending_finalizations.remove(view)
        actions.append(FinalizeBlock(view, block))

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

### 9.6. Pruning

```
function prune_state_below(state, view):
    // Called from maybe_finalize after finalized_view advances to `view`.
    // Drops per-view data that can no longer influence the state machine.
    state.notarized_blocks.retain(v -> v >= view)
    state.votes.retain((v, _) -> v >= view)
    state.finalizes.retain(v -> v >= view)
    state.voted_view.retain(v -> v >= view)
    state.dummy_voted_view.retain(v -> v >= view)
    state.finalized_in_view.retain(v -> v >= view)
    state.pending_quorums.retain((v, _) -> v >= view)
    state.pending_finalizations.retain(v -> v >= view)
    state.known_blocks.retain((_, block) -> block.view >= view)
```

Pruning bounds the steady-state footprint of every per-view map. `pending_quorums` and `pending_finalizations` in
particular cannot grow unboundedly: entries accumulate only for views in the unfinalized tail, and each view's
contribution is bounded by the number of distinct block hashes that have received legitimate quorum signatures (which
requires genuine validator signatures, not just Byzantine forgery). Once a view is finalized, all its pending entries
are pruned.

### 9.7. Message-ordering races

The state machine tolerates four common out-of-order delivery patterns without buffering proposals or relying on
timeouts:

- **Voter's `finalized_view` differs from leader's.** Proposal chain validation (§9.3) accepts any chain that,
  combined with the voter's local notarized blocks, covers every view in `[voter.finalized_view + 1, view - 1]`. The
  voter's `finalized_view` need not match the leader's.
- **Forwarded notarization for a future view.** The `Notarization` handler (§9.3) advances `current_view` whenever
  `notarization.view ≥ current_view`, not only on equality. A voter that missed the proposal and votes for the
  previous view can still advance on a forwarded notarization; the next proposal's chain supplies any intermediate
  notarizations needed for subsequent validation.
- **Vote quorum reached before proposal arrives.** `handle_quorum` (§9.4) records the quorum as pending if the block
  body is unknown locally. When the block later arrives via `Propose` or `Notarization`, the pending quorum is
  resolved immediately and the notarization completes.
- **Finalize quorum reached before notarization arrives.** `maybe_finalize` (§9.4) records the pending finalization
  if the view's notarization is not yet in local state. When the notarization arrives via the next proposal's chain
  or via forwarding, `on_notarization_installed` resolves the pending finalization and emits the `FinalizeBlock`
  action.
- **Leader with incomplete local history.** A node that advanced into its current view via a forwarded notarization
  from a future view (skipping intermediate views it did not observe) may lack the notarizations needed to build a
  valid `π_chain`. In that case `enter_view` (§9.2) silently abstains from proposing; the view times out after 3Δ
  and the network skips it via Lemma 3.6. The node still participates as a voter (dummy-voting on timeout).

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
