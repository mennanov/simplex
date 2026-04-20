# Architectural Comparison: CP23-Fidelity vs. State-Machine Minimality

**Subject:** Evaluation of two practical adaptations of the Simplex Consensus protocol (CP23).

1. **The Original Adaptation (`simplex_improvements.md`)**: Optimized for mechanical translation of CP23's mathematical
   proofs.
2. **The Streamlined Adaptation**: Optimized for minimal code surface area, strict $O(1)$ message bounds, and linear
   state transitions.

## Executive Summary: The Core Tradeoff

The divergence between the two designs represents a fundamental engineering tradeoff: **Proof-Structure Fidelity vs.
State-Machine Minimality.**

The **Original Adaptation** retains the structural proofs and static timeout behaviors of CP23. It handles block
payloads internally and uses explicit, self-verifying historical chains, making its safety and liveness arguments
trivial to map to the published paper.

The **Streamlined Adaptation** drastically flattens the software implementation. It strips out block payloads,
eliminates historical chains, and removes asynchronous state buffering. However, to achieve this minimal software
footprint, it fundamentally breaks the 1-to-1 mapping with CP23's proofs, requiring fresh mathematical derivations for
safety (via a new Local Highest Rule) and liveness (due to exponential backoffs and notarization splits).

---

## 1. Protocol Mechanics & State

### 1.1 Bypassing Defense (Safety)

* **Original (Explicit Chain Validation):** To prevent a Byzantine leader from bypassing a valid block, proposals carry
  a variable-length $\pi\_chain$ of historical dummy notarizations. Voters iterate this chain to explicitly verify that
  no real blocks were bypassed. **Advantage:** Every proposal is mathematically self-contained and self-verifying.
* **Streamlined (Local Highest Rule):** Proposals carry no historical chain (only $\pi\_prev$ and $\pi\_parent$).
  Instead, voters rely on a local high-water mark (`highest_notarized_non_dummy`). **Advantage:** Eliminates unbounded
  chain processing. Safety relies on quorum intersection ensuring that $f+1$ honest nodes will always remember the
  high-water mark and block the bypass.

### 1.2 State Machine & Payload Handling

* **Original (Coupled State):** The consensus engine manages block payloads alongside metadata. Because votes can arrive
  out of order from block payloads, the state machine requires asynchronous buffering (`pending_quorums`,
  `pending_finalizations`).
* **Streamlined (Decoupled State):** The consensus state machine operates *exclusively* on hashes. There is no
  buffering; view advancement triggers instantly on metadata quorums. **Tradeoff:** While this shrinks the consensus
  state space, the complexity is relocated to the application layer, which must implement an out-of-band payload fetch
  protocol to resolve `FinalizeBlockEvent(view, hash)` events.

---

## 2. Liveness & Synchronization

### 2.1 View Timeouts

* **Original (Static $3\Delta$):** Uses a fixed timeout per view. **Advantage:** Perfectly preserves CP23's Lemma 3.6,
  which guarantees the protocol will cleanly skip a faulty leader in bounded time.
* **Streamlined (Adaptive Exponential Backoff):** Uses an exponential backoff (`BASE_TIMEOUT * 2^consecutive_dummies`).
  **Advantage:** Much more resilient to network floods and sustained adversarial DoS. **Tradeoff:** Completely breaks
  the applicability of Lemma 3.6; liveness under backoff must be mathematically re-derived.

### 2.2 Lagging Leader Behavior & The Notarization Split

* **Original (Silent Abstention):** If a node becomes the leader but has holes in its local history, it silently
  abstains from proposing. The network smoothly skips the view via a single $3\Delta$ timeout.
* **Streamlined (Notarization Split Degradation):** If the network splits (some nodes see a real block, others time
  out), a lagging leader will actively broadcast a proposal with a stale $\pi\_parent$. The network will actively reject
  this proposal, wasting bandwidth before timing out. **Tradeoff:** This introduces a bounded liveness delay of $O(f)$
  leader rotations post-GST before a fully synced leader is elected to heal the split.

### 2.3 Lag-Recovery Latency

* **Both Designs:** Both designs allow a partitioned node to catch up to the current view in **$1\delta$**. The Original
  uses iterative `Notarization` forwarding, while the Streamlined design uses the `NotarizeMsg`.
* **The Difference:** The Streamlined design attaches a `pi_last_real` hint to its message, ensuring that a recovering
  node not only advances its view but also learns the correct parent needed if it is the very next scheduled leader.

---

## 3. Communication Latency & Bandwidth

| Metric                             | Original (`simplex_improvements.md`) | Streamlined Simplex     |
|:-----------------------------------|:-------------------------------------|:------------------------|
| **Optimistic Block Time**          | $2\delta$                            | $2\delta$               |
| **Proposal Confirmation**          | $3\delta$                            | $3\delta$               |
| **Lag-Recovery Latency**           | $1\delta$                            | $1\delta$               |
| **Message Complexity (Bandwidth)** | Expected $O(1)$, Worst-case $O(h)$   | Strictly bounded $O(1)$ |

*Note: In the Original design, $O(h)$ is a theoretical worst-case during extended asynchrony. Under normal operation,
the chain length is 0 to 5 views, making average bandwidth nearly identical between the two designs.*

---

## 4. Formal Verification Implications (Aeneas → Lean4)

The choice between these designs dictates the structure of the Lean4 proof repository.

### Original Design Verification Profile

* **Proof Reuse:** High.
* **Structure:** The safety proofs and liveness proofs map directly to CP23's Theorems and Lemmas.
* **Challenge:** The Lean4 state machine definition will be complex, requiring modeling of asynchronous buffers (
  `pending_quorums`) and recursive chain-validation logic.

### Streamlined Design Verification Profile

* **Proof Reuse:** Low. Requires novel proofs for safety (Local Highest Rule) and liveness (Exponential Backoff & Split
  degradation).
* **Structure:** A "Section 7: CP23 Proof Deviations" must be authored to replace the deprecated lemmas.
* **Challenge:** The Lean4 state machine definition will be trivially simple (linear transitions, scalar monotonicity,
  and purely hash-based state), but the human proof-engineering workload shifts from *translating* proofs to *authoring*
  proofs.
