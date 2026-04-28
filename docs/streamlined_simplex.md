# Pragmatically Simplified Simplex Consensus

**References:** Chan & Pass, "Simplex Consensus" (CP23); Simplified Engineering Iteration

## 1. Motivation

The vanilla Simplex protocol (CP23) possesses mathematically optimal latency bounds but suffers from $O(h)$ message
complexity due to the requirement to forward the entire chain of notarizations with every proposal and view advance.

This document specifies a highly pragmatic, simplified architecture that heavily bounds all protocol messages to *
*$O(1)$ in chain-height** (~5KB of aggregated signatures) and aggressively strips down the state machine. By leveraging
the statistical properties of pseudo-random leader election and relying purely on local state guarantees, we eliminate
complex chain-validation logic without sacrificing BFT safety or theoretical liveness bounds.

*Note on Application Boundaries & Data Availability:* This consensus engine strictly separates metadata from block
payloads. It treats payloads as opaque bytes and emits abstract `FinalizeBlockEvent(view, hash)` events. To
mathematically guarantee data availability (DA) for lagging nodes, the implementation must enforce a strict **"No Data,
No Vote"** rule: the external application wrapper must never feed a `Propose` message into this state machine until the
corresponding payload bytes have been physically downloaded and stored.

## 2. Core Simplifications

### 2.1. The "Local Highest" Rule (Eliminating Proposal Chains)

In CP23, a leader must attach an unbroken chain of dummy notarizations to prove that no real block was bypassed
between $h_{parent}$ and the current view.

**The Simplification:** The leader attaches **no chain**. A proposal only includes two constant-height certificates:

1. $\pi_{prev}$: The notarization for $view - 1$ (proving the network legally entered this view).
2. $\pi_{parent}$: The notarization for $h_{parent}$ (proving the parent block is valid).

**The Verification Rule:** A voter checks if $block.h_{parent} \ge state.last\_real\_notarization.view$ AND ensures the
block's internal $h_{parent\_hash}$ perfectly matches the hash signed in $\pi_{parent}$. If true, they vote. If false,
they drop the proposal. Safety is preserved via quorum intersection: if a real block was notarized, at least $f+1$
honest nodes possess it locally and will reject any malicious proposal attempting to bypass it.

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
* `DELTA` ($\Delta$): The assumed upper bound on network message delay.
* `LOOKAHEAD_LIMIT = 10`: Prevents unbounded memory exhaustion from future-view spam on uncertified messages (`Vote`,
  `Finalize`) and proposals.
* `DUMMY_HASH`: A reserved hash representing a timeout block ($\bot$).
* `GENESIS_HASH`: A reserved hash representing the genesis block.
* `GENESIS_NOTARIZATION`: A synthetic certificate `(view=0, hash=GENESIS_HASH, sigs={})` bootstrapped into all nodes.

**System Functions:**
*(Note for Charon translation: Cryptographic functions must be isolated behind an `extern` module or trait
marked `#[charon::opaque]` to axiomatize signature validity in Lean 4).*

* `expected_leader_for(view)`: Returns the deterministic `PeerId` of the leader for the given view via
  `hash(SEED || view) mod n`.
* `is_leader(state, view)`: Evaluates to a boolean. *(Definitional
  equality: `is_leader(state, v) == (expected_leader_for(v) == self.id)`).*
* `reset_timer(view)`: Cancels any pending timer and schedules a new static view timeout of **$3\Delta$**. *(Production
  Note: To prevent network churn during sustained outages, an exponential backoff logic can be injected directly into
  the external networking/timer wrapper. Scaling the actual timeout duration dynamically outside of the verified
  consensus state machine ensures the network behaves practically in production while allowing the Lean 4 proofs to rely
  mechanically on CP23's original static $3\Delta$ bounds).*
* `build_block(h_parent, h_parent_hash)`: Constructs a block with the given parent pointers from the leader's local
  mempool (mempool semantics out of scope).
* `verify_sig(peer_id, payload, sig)`: Returns true iff the signature is cryptographically valid AND the `peer_id` is in
  the `active_validator_set`.
* `verify_notarization(cert)`: Returns true iff `(cert.view == 0 and cert.hash == GENESIS_HASH and cert.sigs is empty)`
  OR `cert.sigs` contains $\ge quorum()$ distinct-peer signatures valid over `("vote", cert.view, cert.hash)`, and all
  signers are in the `active_validator_set`.

**Protocol Messages (All strictly O(1) in chain-height):**

* `Propose(view, block, π_prev, π_parent, leader_sig)` *(Note: $\pi$ is defined as the tuple `(view, hash, sigs)`)*
* `Vote(view, block_hash, signature)`
* `Finalize(view, block_hash, signature)`
* `NotarizeMsg(view, block_hash, signatures, pi_last_real)`

**Local State & Bootstrap:**
At node startup, the state is initialized as follows, and `reset_timer(1)` is invoked.
*(Note for Charon translation: Collections use flat `BTreeMap`s to guarantee deterministic ordering and inductive
simplicity).*

* `current_view`: Integer *(Initialized to 1)*
* `finalized_view`: Integer *(Initialized to 0)*
* `last_real_notarization`: Tuple `(View, Hash, Signatures)` *(Initialized to `GENESIS_NOTARIZATION`, persisted across
  pruning)*
* `voted_in_view`: BTreeMap<View, BlockHash> *(Initialized empty)*
* `votes`: BTreeMap<(View, PeerId), (BlockHash, Signature)> *(Initialized empty)*
* `finalizes`: BTreeMap<(View, PeerId), (BlockHash, Signature)> *(Initialized empty)*

## 4. Safety and Liveness Analysis

### 4.1. Safety (No Bypassing)

**Assertion:** A malicious leader cannot cause the network to finalize a fork by bypassing a validly notarized block.

**Proof:**

1. Assume a real block $b$ was successfully notarized at view $v$. This requires $2f+1$ nodes to have voted for it.
2. Of these voters, at most $f$ are Byzantine, so at least $f+1$ are honest. Each of those honest nodes has updated its
   local state such that `last_real_notarization.view` $\ge v$.
3. If a Byzantine leader in a future view proposes a block with $h_{parent} < v$, the proposal will be received by
   those $f+1$ honest nodes.
4. They evaluate $block.h_{parent} < state.last\_real\_notarization.view$. The check fails. They drop the proposal.
5. Quorum intersection ensures the malicious bypass can never be notarized. Safety is perfectly preserved.
   *(Invariant: Due to the vote-once rule and quorum intersection, at most one hash—real OR dummy—can be notarized per
   view. Only real notarizations update `last_real_notarization`, and only real notarizations are valid
   as $\pi_{parent}$).*

### 4.2. Liveness (Partition Catch-up & Expected Degradation)

**Assertion:** A lagging node can safely resynchronize and propose without a heavy catch-up protocol.

**Mechanism:** If a node misses a view, it receives `NotarizeMsg(v)` from peers advancing to $v+1$. Because proper
notarization certificates are cryptographically unforgeable, nodes accept valid `NotarizeMsg`s regardless of how far in
the future they are, bypassing standard lookahead limits. The quiet install funnel seamlessly updates the node's
`last_real_notarization`, and the primary install advances the view and triggers its `Propose` routine if it is the
designated leader.

*Note: A `Propose(V)` exceeding `current_view + LOOKAHEAD_LIMIT` is dropped, and the node waits for `NotarizeMsg` to
bridge the gap. Within the lookahead window, `Propose` messages are accepted via certificate validation alone—`pi_prev`
proves legal entry to view $V$—and the quiet installs update `last_real_notarization` even before `current_view` has
caught up. This two-lane handling means small lag self-corrects through the steady-state vote/notarize path; only deep
lag requires `NotarizeMsg`-driven catch-up.*

**Acceptable Degradation (The Notarization Split):** If an adversary causes a view to split (some honest nodes hold a
real notarization, others hold nothing and time out), a leader drawn from the lagging subset will propose with a
stale $\pi_{parent}$, which the network will reject. This degradation is bounded within standard CP23 partial-synchrony
liveness guarantees: after GST, within $O(f)$ leader rotations, a leader from the real-notarization subset is elected,
which repairs the split via its valid proposal. Because the timeout uses a static $3\Delta$, the simplified protocol
inherits CP23's **Lemma 3.6** and its partial-synchrony liveness guarantees verbatim.

## 5. Latency Analysis & Comparisons

| Consensus Algorithm         | Optimistic Block Time | Proposal Confirmation Time | Lag-Recovery Latency       |
|:----------------------------|:----------------------|:---------------------------|:---------------------------|
| **Vanilla Simplex (CP23)**  | $2\Delta$             | **$3\Delta$**              | $1\Delta$ (via $O(h)$ msg) |
| **Simplified Simplex**      | $2\Delta$             | **$3\Delta$**              | $1\Delta$ (via $O(1)$ msg) |
| **Jolteon / Fast-HotStuff** | $2\Delta$             | $4\Delta$                  | Varies                     |

## 6. Pseudocode Specification

### 6.1. Helpers: Install Notarization

The funnels for metadata high-water marks, view advancement, and leader proposal generation. Note: State transitions are
strictly sequential; `handle_*` functions execute atomically.

```python
function install_notarization_quiet(state, view, hash, signatures):
    """Updates metadata safely without triggering view advance or proposals."""
    if view <= state.finalized_view: return
    if hash != DUMMY_HASH:
        if view > state.last_real_notarization.view:
            state.last_real_notarization = (view, hash, signatures)

function install_notarization(state, view, hash, signatures) -> Vec<Action>:
    """Primary state-advance funnel."""
    if view <= state.finalized_view: return []

    install_notarization_quiet(state, view, hash, signatures)

    // Advance view if this proves the network moved forward
    actions = []
    if view >= state.current_view:
        state.current_view = view + 1
        reset_timer(state.current_view)

        // Bound memory: discard stale vote/finalize entries outside the active window.
        // Uses `saturating_sub` to map cleanly to Lean 4's `Nat.sub` without runtime underflow.
        prune_state_below(state, state.current_view.saturating_sub(LOOKAHEAD_LIMIT))

        // Natively propose upon entering the view if designated leader
        if is_leader(state, view + 1):
            pi_prev = (view, hash, signatures)
            pi_parent = state.last_real_notarization
            block = build_block(h_parent=pi_parent.view, h_parent_hash=pi_parent.hash)
            leader_sig = sign("propose", view + 1, hash(block))
            actions.append(Broadcast(Propose(view + 1, block, pi_prev, pi_parent, leader_sig)))

    return actions
```

### 6.2. Handle Propose

```python
function handle_propose(state, msg) -> Vec<Action>:
    // PRECONDITION (Data Availability Gate):
    // The application layer MUST NOT invoke handle_propose until the
    // opaque payload for msg.block has been physically downloaded and stored.

    if msg.view <= state.finalized_view: return []
    if msg.view < state.current_view: return []
    if msg.view > state.current_view + LOOKAHEAD_LIMIT: return [] // Prevent bounded memory exhaustion
    if msg.view in state.voted_in_view: return [] // Prevent honest equivocation
    if msg.block.h_parent >= msg.view: return []  // Prevent time-traveling parents
    if msg.block.h_parent < state.finalized_view: return [] // Never build on pre-finalized history

    // 1. Verify leader authentication and certificates
    expected_leader = expected_leader_for(msg.view)
    if not verify_sig(expected_leader, ("propose", msg.view, hash(msg.block)), msg.leader_sig): return []
    if not verify_notarization(msg.pi_prev) or msg.pi_prev.view != msg.view - 1: return []
    if not verify_notarization(msg.pi_parent) or msg.pi_parent.view != msg.block.h_parent: return []
    if msg.pi_parent.hash == DUMMY_HASH: return []
    if msg.pi_parent.hash != msg.block.h_parent_hash: return [] // Ensure block internals align with proof

    // Quietly update high-water marks without triggering view advances or auto-proposals.
    // Note: Intentional lack of view-advancement here keeps state funneled to handle_vote/handle_notarize_msg.
    // Spurious dummy timeouts for old views may occur if the node is lagging, but are harmlessly dropped.
    install_notarization_quiet(state, msg.pi_prev.view, msg.pi_prev.hash, msg.pi_prev.sigs)
    install_notarization_quiet(state, msg.pi_parent.view, msg.pi_parent.hash, msg.pi_parent.sigs)

    // 2. The Local Highest Rule
    if msg.block.h_parent < state.last_real_notarization.view:
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

    // Flat map insertion and deduplication guard.
    // By keying solely on (View, PeerId), we explicitly guarantee one vote per peer per view.
    // Note: This intentionally discards equivocating votes (a Byzantine peer's second vote
    // for a different hash is silently dropped). Simplex does not slash, so retaining
    // equivocation evidence is unnecessary; the structural memory bound is the verification benefit.
    if (msg.view, msg.from) in state.votes: return []
    state.votes[(msg.view, msg.from)] = (msg.block_hash, msg.sig)

    // Extract signatures specific to this view and hash
    // (Helper aggregates by iterating the view's subset and filtering for msg.block_hash)
    let current_votes = get_signatures(state.votes, msg.view, msg.block_hash)

    if len(current_votes) == quorum():
        actions = install_notarization(state, msg.view, msg.block_hash, current_votes)

        // Broadcast NotarizeMsg ONLY on exact local aggregation to prevent O(n^2) amplification.
        // Reliable propagation is delegated to the P2P gossip layer.
        actions.append(Broadcast(NotarizeMsg(
            msg.view, msg.block_hash, current_votes, state.last_real_notarization
        )))

        // Broadcast Finalize if we explicitly voted for this real block.
        // Note for formalization: This establishes the structural invariant that broadcasting
        // Finalize(v, h) implies voted_in_view[v] == h, which is critical for intersection proofs.
        voted_hash = state.voted_in_view.get(msg.view, default=null)
        if msg.block_hash != DUMMY_HASH and voted_hash == msg.block_hash:
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

    // Flat map insertion and deduplication guard
    // Guarantees one finalize message per peer per view.
    if (msg.view, msg.from) in state.finalizes: return []
    state.finalizes[(msg.view, msg.from)] = (msg.block_hash, msg.sig)

    // Extract finalizes specific to this view and hash
    let current_finalizes = get_signatures(state.finalizes, msg.view, msg.block_hash)

    if len(current_finalizes) == quorum():
        state.finalized_view = msg.view
        prune_state_below(state, msg.view)

        // Push to app layer (resolves payloads out-of-band if missing)
        // Note: A node may finalize a view before catching up enough to install its notarization.
        // In this edge case, last_real_notarization may temporarily lag finalized_view. If this node
        // becomes leader during this window, its proposal will use a stale pi_parent and be rejected
        // by the network (wasting one view), safely falling back to standard timeout recovery.
        // Note: FinalizeBlockEvent fires only for the specific view that hit quorum. Intermediate
        // views skipped via NotarizeMsg jumps are transitively finalized; the application layer must reconstruct them.
        return [FinalizeBlockEvent(msg.view, msg.block_hash)]

    return []
```

### 6.5. Handle NotarizeMsg (Synchronization)

Processes incoming view-advance fallbacks, strictly ordering the hint installation to safely update metadata before
triggering any `Propose` actions. Note: This handler explicitly omits `LOOKAHEAD_LIMIT` checks because valid
notarization certificates represent cryptographic proof of network progression, allowing safely bridging deep partition
gaps.

```python
function handle_notarize_msg(state, msg) -> Vec<Action>:
    if msg.view <= state.finalized_view: return []

    // Verify the primary certificate first to guarantee structure
    if not verify_notarization((msg.view, msg.block_hash, msg.signatures)): return []

    // Quietly install the last_real_notarization hint to prevent stale-parent liveness bugs.
    // Explicit DUMMY_HASH and View scalar guards save verification CPU cycles and enforce the real-hint invariant.
    if msg.pi_last_real is not null and msg.pi_last_real.hash != DUMMY_HASH and msg.pi_last_real.view < msg.view:
        if verify_notarization(msg.pi_last_real):
            install_notarization_quiet(state, msg.pi_last_real.view, msg.pi_last_real.hash, msg.pi_last_real.sigs)
        // (If pi_last_real.view >= msg.view, the hint is either redundant or malicious. Skip silently.)

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

```python
function prune_state_below(state, view):
    // Clear out stale dictionaries to tightly bound memory usage.
    // This is invoked on Finalize quorums, and unconditionally on every view advance
    // to strictly enforce the LOOKAHEAD_LIMIT memory bound even if finalization lags.

    // Safety of voted_in_view pruning: prune_state_below(state, X) is called with X
    // in {state.finalized_view, state.current_view.saturating_sub(LOOKAHEAD_LIMIT)}.
    // Any future handle_propose(msg) write to voted_in_view[msg.view] requires
    // msg.view > state.finalized_view and msg.view >= state.current_view, both strictly
    // larger than the respective pruning bounds. Hence pruned keys are unreachable.
    delete entries in state.votes where entry.view <= view
    delete entries in state.finalizes where entry.view <= view
    delete entries in state.voted_in_view where entry.view <= view

    // Retained components:
    // - state.last_real_notarization (Monotonically increases, never pruned. Required for future parent pointers)
    // - state.current_view, state.finalized_view
```

## 7. Formal Verification Blueprint (Rust $\rightarrow$ Aeneas $\rightarrow$ Lean 4)

To bridge the gap between this consensus logic and a step-indexed interactive theorem prover via the Charon/Aeneas
pipeline, the Rust implementation must adhere strictly to Aeneas' supported language subset.

### 7.1. State Structure and Determinism

* **Use `BTreeMap`:** Do not use `HashMap`. Aeneas and Lean 4 require deterministic iteration order for proof stability.
  By flattening the map keys (e.g., `(View, PeerId)`), we explicitly guarantee one entry per peer per view, eliminating
  DoS vectors and reducing the inductive complexity of the state definition.
* **Flat State:** State must be a single, owned `struct`. Avoid `Rc`, `Arc`, `RefCell`, or any interior mutability, as
  these block pure-functional translation.

### 7.2. Arithmetic and Purity

* **Underflow Safety:** The pruning bounds must use `.saturating_sub(LOOKAHEAD_LIMIT)`. This maps directly to Lean 4's
  `Nat.sub` (which saturates at 0) without generating panic branches in the generated code.
* **Sequential Handlers:** Handlers must not use `async` or blocking I/O. They must be pure functions conforming to
  `State → Msg → (State × List Action)`. All side-effects (like `Broadcast` or `FinalizeBlockEvent`) must be returned
  purely as data payloads in the `Vec<Action>`.

### 7.3. Cryptographic Isolation

* All cryptographic functions (`verify_sig`, `verify_notarization`, `sign`) must be isolated behind an `extern` module
  or trait marked with `#[charon::opaque]`.
* This explicitly tells the toolchain *not* to translate complex cryptographic libraries into Lean 4, allowing the
  provers to instead axiomatize signature validity (e.g., `verify_sig(pk, msg, sig) = true → signed_by(pk, msg, sig)`).

### 7.4. Core Invariants (The Proof Strategy)

Once translated to Lean 4, the safety of the protocol fundamentally reduces to proving the following lemmas:

1. **`MonotonicHighest`:** The high-water mark only moves forward.
    * `∀ s c, install_quiet s c → s'.last_real_notarization.view ≥ s.last_real_notarization.view`
2. **`FinalizedPrefixSafety`:** Honest nodes cannot fork prior history.
    * `∀ v, v ≤ finalized_view → ¬∃ proposal voting on parent < v` (Discharged trivially by the
      `msg.block.h_parent < state.finalized_view` guard in `handle_propose`).
3. **`BoundedStateWindow`:** Maps do not grow infinitely.
    * `∀ s, |s.votes| + |s.finalizes| + |s.voted_in_view| ≤ (4n + 2) * LOOKAHEAD_LIMIT` (Guaranteed by the
      `prune_state_below` trigger inside `install_notarization`. The active sliding window spans from
      `current_view - LOOKAHEAD_LIMIT` to `current_view + LOOKAHEAD_LIMIT`, creating a maximum width
      of $2 \cdot \text{LOOKAHEAD\_LIMIT}$ bounded structurally by `(View, PeerId)`).

---

## 8. Implementation Architecture (Context Integration)

While this document outlines the pure state machine logic necessary for formal verification, the protocol is intended to
operate within a broader networking environment (such as CommonWare or a generic Rust libp2p stack).

To preserve the `State → Msg → (State × List Action)` purity required by Aeneas:

* **The Data Availability Gate ("No Data, No Vote"):** The consensus engine relies on the application wrapper to enforce
  data availability. The wrapper **must not** deliver a `Propose` message to the state machine until the opaque payload
  associated with `msg.block` has been physically downloaded and verified. This ensures quorum intersection
  guarantees $f+1$ honest data replicas.
* **Networking** (gossip, peer discovery, targeted sends) must be completely abstracted away. The consensus engine
  solely consumes deserialized messages and emits abstract `Action` structs.
* **Retrievability contract:** Consensus-layer safety guarantees that $\ge f+1$ honest peers received each finalized
  block's payload at vote time, but the consensus layer does not specify retention. The application layer is responsible
  for: (1) persisting block payloads on `FinalizeBlockEvent`, and (2) retaining payloads of voted-on but
  not-yet-finalized blocks for at least K views, where K bounds the deployment's worst-case GST plus finalization-gossip
  latency. Chain reconstruction back to genesis is self-contained at the application layer via the `h_parent_hash` field
  in each block — no intermediate notarization certs are required.
* **Timers** are managed externally. The `reset_timer(view)` function should emit an intent to an external Tokio/async
  task, keeping the core verification logic completely synchronous and deterministic.
