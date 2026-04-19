# Pragmatically Simplified Simplex Consensus

**References:** Chan & Pass, "Simplex Consensus" (CP23); Simplified Engineering Iteration

## 1. Motivation

The vanilla Simplex protocol (CP23) possesses mathematically optimal latency bounds but suffers from O(h) message
complexity due to the requirement to forward the entire chain of notarizations with every proposal and view advance.

This document specifies a highly pragmatic, simplified architecture that strictly bounds all protocol messages to **O(1)
size** and aggressively strips down the state machine. By leveraging the statistical properties of pseudo-random leader
election and relying purely on local state guarantees, we eliminate complex chain-validation logic without sacrificing
BFT safety or theoretical liveness bounds.

*Note on Application Boundaries:* This consensus engine treats block payloads as opaque bytes and emits abstract
`FinalizeBlockEvent(view, hash)` events. The application layer is strictly responsible for requesting missing payloads
out-of-band from peers. The consensus state machine does not manage block data replication.

## 2. Core Simplifications

### 2.1. The "Local Highest" Rule (Eliminating Proposal Chains)

In CP23, a leader must attach an unbroken chain of dummy notarizations to prove that no real block was bypassed
between $h_{parent}$ and the current view.
**The Simplification:** The leader attaches **no chain**. A proposal only includes two O(1) certificates:

1. $\pi_{prev}$: The notarization for $view - 1$ (proving the network legally entered this view).
2. $\pi_{parent}$: The notarization for $h_{parent}$ (proving the parent block is valid).

**The Verification Rule:** A voter simply checks if $block.h_{parent} \ge state.highest\_notarized\_non\_dummy$. If
true, they vote. If false, they drop the proposal. Safety is preserved via quorum intersection: if a block was
notarized, at least $f+1$ honest nodes possess it locally and will reject any malicious proposal attempting to bypass
it.

### 2.2. O(1) Notarization Forwarding

In CP23, nodes multicast the entire chain to advance views.
**The Simplification:** When a node accumulates $2f+1$ votes and enters $view+1$, it multicasts only a single, $O(1)$
`Notarization(view)` message. This satisfies the liveness requirement for partitioned peers (preventing adversarial
scheduling deadlocks) without reintroducing $O(h)$ bandwidth bloat.

## 3. Protocol State and Messages

**Protocol Constants:**

* `LOOKAHEAD_LIMIT = 10` (Prevents unbounded memory exhaustion from future-view spam).

**Protocol Messages (All strictly O(1) in size):**

* `Propose(view, block, π_prev, π_parent)`
* `Vote(view, block_hash, signature)`
* `Finalize(view, block_hash, signature)`
* `Notarization(view, block, signatures)`

**Local State:**

* `current_view`: Integer
* `finalized_view`: Integer
* `highest_notarized_non_dummy`: Integer
* `last_real_notarization`: Option<(View, Block, Signatures)> *(Persisted across pruning)*
* `voted_in_view`: Map<View, BlockHash>
* `votes`: Map<(View, BlockHash), Map<PeerId, Signature>>
* `finalizes`: Map<(View, BlockHash), Map<PeerId, Signature>>

## 4. Safety and Liveness Analysis

### 4.1. Safety (No Bypassing)

**Assertion:** A malicious leader cannot cause the network to finalize a fork by bypassing a validly notarized block.
**Proof:** 1. Assume a real block $b$ was successfully notarized at view $v$. This requires $2f+1$ nodes to have voted
for it.

2. Therefore, at least $f+1$ honest nodes have updated their local state such that
   `highest_notarized_non_dummy` $\ge v$.
3. If a Byzantine leader in a future view proposes a block with $h_{parent} < v$, the proposal will be received by
   those $f+1$ honest nodes.
4. They evaluate $block.h_{parent} < state.highest\_notarized\_non\_dummy$. The check fails. They drop the proposal.
5. The Byzantine leader can gather at most $f$ (Byzantine) + $f$ (ignorant honest) = $2f$ votes. Quorum intersection
   ensures the malicious bypass can never be notarized. Safety is perfectly preserved.

### 4.2. Liveness (Catch-up)

**Assertion:** A lagging node can safely resynchronize with the network tip without a heavy catch-up protocol.
**Proof:**
If a node is partitioned and misses a view, it will receive the $O(1)$ `Notarization(v)` message from honest peers
advancing to $v+1$. The node verifies the notarization, updates `highest_notarized_non_dummy`, and advances its
`current_view`, naturally re-entering the active consensus pipeline.

## 5. Latency Analysis & Comparisons

By intentionally retaining the `Finalize` message, this simplified Simplex maintains the absolute lowest possible
Proposal Confirmation Time among partial-synchrony BFT algorithms.

| Consensus Algorithm         | Optimistic Block Time | Proposal Confirmation Time | Proof Type              |
|:----------------------------|:----------------------|:---------------------------|:------------------------|
| **Vanilla Simplex (CP23)**  | $2\delta$             | **$3\delta$**              | Explicit (Finalize Msg) |
| **Simplified Simplex**      | $2\delta$             | **$3\delta$**              | Explicit (Finalize Msg) |
| **Jolteon / Fast-HotStuff** | $2\delta$             | $4\delta$ (2 view changes) | Implicit (Pipelined)    |
| **Standard HotStuff**       | $2\delta$             | $6\delta$ (3 view changes) | Implicit (Pipelined)    |

*Note: $\delta$ represents actual network message delay.*

## 6. Pseudocode Specification

### 6.1. Helper: Install Notarization

Funnel to extract high-water marks and conditionally advance views.

```python
function install_notarization(state, view, block, signatures) -> Vec<Action>:
    if view <= state.finalized_view: return []

    // Update highest known real block and retain for future parent pointers
    if not block.is_dummy():
        state.highest_notarized_non_dummy = max(state.highest_notarized_non_dummy, view)
        if state.last_real_notarization is null or view > state.last_real_notarization.view:
            state.last_real_notarization = (view, block, signatures)

    // Advance view if this proves the network moved forward
    if view >= state.current_view:
        state.current_view = view + 1
        reset_timer(state.current_view)
        return [Broadcast(Notarization(view, block, signatures))]

    return []
```

### 6.2. Handle Propose

Processes $O(1)$ proposals and applies the Local Highest rule.

```python
function handle_propose(state, msg) -> Vec<Action>:
    if msg.view < state.current_view: return []
    if msg.view in state.voted_in_view: return [] // Prevent honest equivocation
    if msg.block.h_parent >= msg.view: return []  // Prevent time-traveling parents

    // 1. Verify and install certificates
    if not verify_notarization(msg.pi_prev) or msg.pi_prev.view != msg.view - 1: return []
    if not verify_notarization(msg.pi_parent) or msg.pi_parent.view != msg.block.h_parent: return []
    if msg.pi_parent.block.is_dummy(): return []

    actions = []
    actions.extend(install_notarization(state, msg.pi_prev.view, msg.pi_prev.block, msg.pi_prev.sigs))
    actions.extend(install_notarization(state, msg.pi_parent.view, msg.pi_parent.block, msg.pi_parent.sigs))

    // 2. The Local Highest Rule (Safety against bypassing)
    if msg.block.h_parent < state.highest_notarized_non_dummy:
        return [] // Leader is bypassing known history

    state.voted_in_view[msg.view] = hash(msg.block)
    actions.append(Broadcast(Vote(msg.view, hash(msg.block), sign("vote", msg.view, hash(msg.block)))))
    return actions
```

### 6.3. Handle Vote

Aggregates votes locally to natively advance views.

```python
function handle_vote(state, msg) -> Vec<Action>:
    if msg.view <= state.finalized_view: return []
    if msg.view > state.current_view + LOOKAHEAD_LIMIT: return [] // Prevent memory DoS
    if not verify_sig(msg.from, ("vote", msg.view, msg.block_hash), msg.sig): return []

    // Deduplication guard
    if msg.from in state.votes[(msg.view, msg.block_hash)]: return []
    state.votes[(msg.view, msg.block_hash)][msg.from] = msg.sig

    if len(state.votes[(msg.view, msg.block_hash)]) == quorum():
        block = lookup_or_create_dummy(msg.block_hash)
        actions = install_notarization(state, msg.view, block, state.votes[(msg.view, msg.block_hash)])

        if not block.is_dummy():
            actions.append(Broadcast(Finalize(msg.view, msg.block_hash, sign("finalize", msg.view, msg.block_hash))))

        // If we are the NEXT leader, natively propose using the newly built pi_prev.
        if is_leader(state, msg.view + 1):
            pi_prev = (msg.view, block, state.votes[(msg.view, msg.block_hash)])
            pi_parent = state.last_real_notarization
            actions.append(Broadcast(Propose(msg.view + 1, build_block(), pi_prev, pi_parent)))

        return actions
    return []
```

### 6.4. Handle Finalize

```python
function handle_finalize(state, msg) -> Vec<Action>:
    if msg.view <= state.finalized_view: return []
    if msg.view > state.current_view + LOOKAHEAD_LIMIT: return []
    if not verify_sig(msg.from, ("finalize", msg.view, msg.block_hash), msg.sig): return []

    // Deduplication guard
    if msg.from in state.finalizes[(msg.view, msg.block_hash)]: return []
    state.finalizes[(msg.view, msg.block_hash)][msg.from] = msg.sig

    if len(state.finalizes[(msg.view, msg.block_hash)]) == quorum():
        state.finalized_view = msg.view
        prune_state_below(state, msg.view) // Note: last_real_notarization is retained

        // Push to application layer (resolves payloads out-of-band if missing)
        return [CancelTimer(msg.view), FinalizeBlockEvent(msg.view, msg.block_hash)]

    return []
```

### 6.5. Handle Notarization (Synchronization)

Processes incoming $O(1)$ view-advance fallbacks.

```python
function handle_notarization(state, msg) -> Vec<Action>:
    if msg.view <= state.finalized_view: return []
    if msg.view > state.current_view + LOOKAHEAD_LIMIT: return []
    if not verify_notarization(msg): return []

    return install_notarization(state, msg.view, msg.block, msg.sigs)
```

### 6.6. Handle Timeout

Generates dummy votes to drive view advancement upon network failure.

```python
function handle_timeout(state, view) -> Vec<Action>:
    if view != state.current_view: return []
    if view in state.voted_in_view: return []

    state.voted_in_view[view] = DUMMY_HASH
    return [Broadcast(Vote(view, DUMMY_HASH, sign("vote", view, DUMMY_HASH)))]
```
