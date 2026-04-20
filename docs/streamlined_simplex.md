# Pragmatically Simplified Simplex Consensus

**References:** Chan & Pass, "Simplex Consensus" (CP23); Simplified Engineering Iteration

## 1. Motivation

The vanilla Simplex protocol (CP23) possesses mathematically optimal latency bounds but suffers from O(h) message
complexity due to the requirement to forward the entire chain of notarizations with every proposal and view advance.

This document specifies a highly pragmatic, simplified architecture that heavily bounds all protocol messages to **O(1)
in chain-height** (~5KB of aggregated signatures) and aggressively strips down the state machine. By leveraging the
statistical properties of pseudo-random leader election and relying purely on local state guarantees, we eliminate
complex chain-validation logic without sacrificing BFT safety or theoretical liveness bounds.

*Note on Application Boundaries:* This consensus engine strictly separates metadata from block payloads. It treats
payloads as opaque bytes and emits abstract `FinalizeBlockEvent(view, hash)` events. The application layer is strictly
responsible for requesting missing payloads out-of-band from peers. The consensus state machine does not manage block
data replication.

## 2. Core Simplifications

### 2.1. The "Local Highest" Rule (Eliminating Proposal Chains)

In CP23, a leader must attach an unbroken chain of dummy notarizations to prove that no real block was bypassed
between $h_{parent}$ and the current view.
**The Simplification:** The leader attaches **no chain**. A proposal only includes two constant-height certificates:

1. $\pi_{prev}$: The notarization for $view - 1$ (proving the network legally entered this view).
2. $\pi_{parent}$: The notarization for $h_{parent}$ (proving the parent block is valid).

**The Verification Rule:** A voter simply checks if $block.h_{parent} \ge state.highest\_notarized\_non\_dummy$. If
true, they vote. If false, they drop the proposal. Safety is preserved via quorum intersection: if a real block was
notarized, at least $f+1$ honest nodes possess it locally and will reject any malicious proposal attempting to bypass
it.

### 2.2. O(1) Notarization Forwarding

In CP23, nodes multicast the entire chain to advance views.
**The Simplification:** When a node locally accumulates $2f+1$ votes and enters $view+1$, it multicasts only a single
`NotarizeMsg` message (carrying the primary certificate and an optional hint for the last known real notarization). This
satisfies the liveness requirement for partitioned peers without reintroducing $O(h)$ bandwidth bloat.

## 3. Protocol Definitions & State

**Network Configuration & Constants:**

* `n`: Total number of active validators.
* `f`: Maximum Byzantine tolerance, where `f = (n - 1) / 3`.
* `active_validator_set`: The fixed list of `PeerId`s participating in consensus for this protocol run (dynamic
  reconfiguration is out of scope).
* `quorum()`: Returns `2f + 1`.
* `self.id`: The local node's unique `PeerId`.
* `SEED`: A cryptographic seed derived from genesis for the leader schedule.
* `BASE_TIMEOUT`, `MAX_TIMEOUT`: Adaptive timeout parameters.
* `LOOKAHEAD_LIMIT = 10`: Prevents unbounded memory exhaustion from future-view spam.
* `DUMMY_HASH`: A reserved hash representing a timeout block ($\bot$).
* `GENESIS_HASH`: A reserved hash representing the genesis block.
* `GENESIS_NOTARIZATION`: A synthetic certificate `(view=0, hash=GENESIS_HASH, sigs={})` bootstrapped into all nodes.

**System Functions:**

* `expected_leader_for(view)`: Returns the deterministic `PeerId` of the leader for the given view via
  `hash(SEED || view) mod n`.
* `is_leader(state, view)`: Evaluates to a boolean. *(Relationship
  axiom: `is_leader(state, v) == (expected_leader_for(v) == self.id)`).*
* `reset_timer(view, consecutive_dummies)`: Cancels any pending timer and schedules a new view timeout to
  `BASE_TIMEOUT * 2^consecutive_dummies`, capped at `MAX_TIMEOUT`.
* `build_block(h_parent)`: Constructs a block with the given parent height from the leader's local mempool (mempool
  semantics out of scope).
* `verify_sig(peer_id, payload, sig)`: Returns true iff the signature is cryptographically valid AND the `peer_id` is in
  the `active_validator_set`.
* `verify_notarization(cert)`: Returns true iff `(cert.view == 0 and cert.hash == GENESIS_HASH and cert.sigs is empty)`
  OR `cert.sigs` contains $\ge quorum()$ distinct-peer signatures valid over `("vote", cert.view, cert.hash)`, and all
  signers are in the `active_validator_set`.

**Protocol Messages (All strictly O(1) in chain-height):**

* `Propose(view, block, π_prev, π_parent, leader_sig)` *(Note: π is defined as the tuple `(view, hash, sigs)`)*
* `Vote(view, block_hash, signature)`
* `Finalize(view, block_hash, signature)`
* `NotarizeMsg(view, block_hash, signatures, pi_last_real)`

**Local State & Bootstrap:**
At node startup, the state is initialized as follows, and `reset_timer(1, 0)` is invoked:

* `current_view`: Integer *(Initialized to 1)*
* `finalized_view`: Integer *(Initialized to 0)*
* `consecutive_dummies`: Integer *(Initialized to 0)*
* `highest_notarized_non_dummy`: Integer *(Initialized to 0)*
* `last_real_notarization`: Tuple `(View, Hash, Signatures)` *(Initialized to `GENESIS_NOTARIZATION`, persisted across
  pruning)*
* `voted_in_view`: Map<View, BlockHash> *(Initialized empty)*
* `votes`: Map<(View, BlockHash), Map<PeerId, Signature>> *(Initialized empty)*
* `finalizes`: Map<(View, BlockHash), Map<PeerId, Signature>> *(Initialized empty)*

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
5. Quorum intersection ensures the malicious bypass can never be notarized. Safety is perfectly preserved.
   *(Invariant: Due to Byzantine equivocation, a dummy and a real notarization may coexist for the same view on
   different node subsets, but by quorum intersection, each view has at most one REAL notarization. Only real
   notarizations raise `highest_notarized_non_dummy`, and only real notarizations are valid as π_parent).*

### 4.2. Liveness (Partition Catch-up & Expected Degradation)

**Assertion:** A lagging node can safely resynchronize and propose without a heavy catch-up protocol.
**Mechanism:** If a node misses a view, it receives `NotarizeMsg(v)` from peers advancing to $v+1$. The message attaches
the most recent real notarization (`pi_last_real`). The quiet install funnel seamlessly updates the node's
`highest_notarized_non_dummy`, and the primary install advances the view and triggers its `Propose` routine if it is the
designated leader.
**Acceptable Degradation (The Notarization Split):** If an adversary causes a view to split (some honest nodes hold a
real notarization, others hold nothing and time out), a leader drawn from the lagging subset will propose with a
stale $\pi_{parent}$, which the network will reject. This degradation is bounded within standard CP23 partial-synchrony
liveness guarantees: after GST, within $O(f)$ leader rotations, a leader from the real-notarization subset is elected,
which repairs the split via its valid proposal. The simplified protocol thus inherits CP23's liveness asymptotics
unchanged while preserving O(1) state machine linearity.

## 5. Latency Analysis & Comparisons

| Consensus Algorithm         | Optimistic Block Time | Proposal Confirmation Time | Lag-Recovery Latency       |
|:----------------------------|:----------------------|:---------------------------|:---------------------------|
| **Vanilla Simplex (CP23)**  | $2\delta$             | **$3\delta$**              | $1\delta$ (via $O(h)$ msg) |
| **Simplified Simplex**      | $2\delta$             | **$3\delta$**              | $1\delta$ (via $O(1)$ msg) |
| **Jolteon / Fast-HotStuff** | $2\delta$             | $4\delta$                  | Varies                     |

## 6. Pseudocode Specification

### 6.1. Helpers: Install Notarization

The funnels for metadata high-water marks, view advancement, and leader proposal generation. Note: State transitions are
strictly sequential; `handle_*` functions execute atomically.

```python
function install_notarization_quiet(state, view, hash, signatures):
    """Updates metadata safely without triggering view advance or proposals."""
    if view <= state.finalized_view: return
    if hash != DUMMY_HASH:
        state.highest_notarized_non_dummy = max(state.highest_notarized_non_dummy, view)
        if view > state.last_real_notarization.view:
            state.last_real_notarization = (view, hash, signatures)

function install_notarization(state, view, hash, signatures) -> Vec<Action>:
    """Primary state-advance funnel."""
    if view <= state.finalized_view: return []

    install_notarization_quiet(state, view, hash, signatures)

    // Advance view if this proves the network moved forward
    actions = []
    if view >= state.current_view:
        if hash == DUMMY_HASH:
            state.consecutive_dummies += 1
        else:
            state.consecutive_dummies = 0

        state.current_view = view + 1
        reset_timer(state.current_view, state.consecutive_dummies)

        // Natively propose upon entering the view if designated leader
        if is_leader(state, view + 1):
            pi_prev = (view, hash, signatures)
            pi_parent = state.last_real_notarization
            block = build_block(h_parent=pi_parent.view)
            leader_sig = sign("propose", view + 1, hash(block))
            actions.append(Broadcast(Propose(view + 1, block, pi_prev, pi_parent, leader_sig)))

    return actions
```

### 6.2. Handle Propose

```python
function handle_propose(state, msg) -> Vec<Action>:
    if msg.view < state.current_view: return []
    if msg.view in state.voted_in_view: return [] // Prevent honest equivocation
    if msg.block.h_parent >= msg.view: return []  // Prevent time-traveling parents

    // 1. Verify leader authentication and certificates
    expected_leader = expected_leader_for(msg.view)
    if not verify_sig(expected_leader, ("propose", msg.view, hash(msg.block)), msg.leader_sig): return []
    if not verify_notarization(msg.pi_prev) or msg.pi_prev.view != msg.view - 1: return []
    if not verify_notarization(msg.pi_parent) or msg.pi_parent.view != msg.block.h_parent: return []
    if msg.pi_parent.hash == DUMMY_HASH: return []

    // Quietly update high-water marks without triggering view advances or auto-proposals
    install_notarization_quiet(state, msg.pi_prev.view, msg.pi_prev.hash, msg.pi_prev.sigs)
    install_notarization_quiet(state, msg.pi_parent.view, msg.pi_parent.hash, msg.pi_parent.sigs)

    // 2. The Local Highest Rule
    if msg.block.h_parent < state.highest_notarized_non_dummy:
        return [] // Leader is bypassing known history

    state.voted_in_view[msg.view] = hash(msg.block)
    return [Broadcast(Vote(msg.view, hash(msg.block), sign("vote", msg.view, hash(msg.block))))]
```

### 6.3. Handle Vote

```python
function handle_vote(state, msg) -> Vec<Action>:
    if msg.view <= state.finalized_view: return []
    if msg.view > state.current_view + LOOKAHEAD_LIMIT: return [] // Prevent memory DoS
    if not verify_sig(msg.from, ("vote", msg.view, msg.block_hash), msg.sig): return []

    // Deduplication guard
    if msg.from in state.votes[(msg.view, msg.block_hash)]: return []
    state.votes[(msg.view, msg.block_hash)][msg.from] = msg.sig

    if len(state.votes[(msg.view, msg.block_hash)]) == quorum():
        actions = install_notarization(state, msg.view, msg.block_hash, state.votes[(msg.view, msg.block_hash)])

        // Broadcast NotarizeMsg ONLY on exact local aggregation to prevent O(n^2) amplification
        actions.append(Broadcast(NotarizeMsg(
            msg.view, msg.block_hash, state.votes[(msg.view, msg.block_hash)], state.last_real_notarization
        )))

        if msg.block_hash != DUMMY_HASH:
            actions.append(Broadcast(Finalize(msg.view, msg.block_hash, sign("finalize", msg.view, msg.block_hash))))

        return actions
    return []
```

### 6.4. Handle Finalize

```python
function handle_finalize(state, msg) -> Vec<Action>:
    if msg.block_hash == DUMMY_HASH: return [] // Dummy blocks cannot be finalized
    if msg.view <= state.finalized_view: return []
    if msg.view > state.current_view + LOOKAHEAD_LIMIT: return []
    if not verify_sig(msg.from, ("finalize", msg.view, msg.block_hash), msg.sig): return []

    // Deduplication guard
    // Note: Accepts messages for any hash in the LOOKAHEAD. Bounded DoS vector (O(LOOKAHEAD_LIMIT * f * churn)).
    if msg.from in state.finalizes[(msg.view, msg.block_hash)]: return []
    state.finalizes[(msg.view, msg.block_hash)][msg.from] = msg.sig

    if len(state.finalizes[(msg.view, msg.block_hash)]) == quorum():
        state.finalized_view = msg.view
        prune_state_below(state, msg.view)

        // Push to app layer (resolves payloads out-of-band if missing)
        // Note: A node may finalize a view before catching up enough to install its notarization.
        // In this edge case, last_real_notarization may temporarily lag finalized_view.
        return [FinalizeBlockEvent(msg.view, msg.block_hash)]

    return []
```

### 6.5. Handle NotarizeMsg (Synchronization)

Processes incoming view-advance fallbacks, strictly ordering the hint installation to safely update metadata before
triggering any `Propose` actions.

```python
function handle_notarize_msg(state, msg) -> Vec<Action>:
    if msg.view <= state.finalized_view: return []
    if msg.view > state.current_view + LOOKAHEAD_LIMIT: return []
    // Verify the primary certificate first to guarantee structure
    if not verify_notarization((msg.view, msg.block_hash, msg.signatures)): return []

    // Quietly install the last_real_notarization hint to prevent stale-parent liveness bugs
    if msg.pi_last_real is not null:
        if msg.pi_last_real.view > msg.view: return [] // Guard against future-hint attack
        if msg.pi_last_real.view < msg.view and verify_notarization(msg.pi_last_real):
            install_notarization_quiet(state, msg.pi_last_real.view, msg.pi_last_real.hash, msg.pi_last_real.sigs)
        // (If pi_last_real.view == msg.view, the hint is redundant with primary. Skip silently.)

    // Execute primary install which may trigger view advance and proposals
    return install_notarization(state, msg.view, msg.block_hash, msg.signatures)
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

### 6.7. State Pruning

Executes upon reaching a `Finalize` quorum.

```python
function prune_state_below(state, view):
    // Clear out stale dictionaries (optimized to clean up the finalized view itself)
    delete entries in state.votes where entry.view <= view
    delete entries in state.finalizes where entry.view <= view
    delete entries in state.voted_in_view where entry.view <= view

    // Retained components:
    // - state.highest_notarized_non_dummy (Monotonically increases, never pruned)
    // - state.last_real_notarization (Required for future parent pointers)
    // - state.current_view, state.finalized_view
    // - state.consecutive_dummies
```
