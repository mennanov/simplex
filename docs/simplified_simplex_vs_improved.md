# Architectural Comparison: CP23-Fidelity vs. State-Machine Minimality

**Subject:** Evaluation of two practical adaptations of the Simplex Consensus protocol (CP23) targeted for
Aeneas $\rightarrow$ Lean4 formal verification.

1. **The Original Adaptation (`simplex_improvements.md`)**: Optimized for mechanical translation of CP23's mathematical
   proofs, retaining explicit historical chains and coupled payloads.
2. **The Streamlined Adaptation (Final)**: Optimized for a minimal, flat state machine, strict $O(1)$ message bounds,
   decoupled payloads, and localized view-advancement.

## Executive Summary: The Core Tradeoff

The divergence between the two designs represents an engineering tradeoff between **Proof-Structure Fidelity** and *
*State-Machine Minimality**.

The **Original Adaptation** maximizes fidelity to the structural proofs of CP23. It handles block payloads internally
and uses explicit, self-verifying historical chains. While its safety arguments map directly to the published paper, its
state machine is deep and complex, requiring asynchronous buffers to handle out-of-order data races.

The **Streamlined Adaptation** aggressively flattens the software implementation. It strips out block payloads,
eliminates historical chains, and removes asynchronous state buffering entirely. To achieve this minimal software
footprint, it alters the safety argument—replacing explicit chain verification with a local state invariant (the Local
Highest Rule). Importantly, the final iteration **re-aligns with CP23's static $3\Delta$ timeout logic**, ensuring that
while the safety proofs require novel derivations, the liveness asymptotics (Lemma 3.6) remain mechanically anchored to
CP23.

---

## 1. Proposal Mechanics & Safety Defenses

### 1.1 Bypassing Defense

* **Original (Explicit Chain Validation):** To prevent a Byzantine leader from bypassing a valid block, proposals carry
  a variable-length $\pi\_chain$ of historical dummy notarizations. Voters iterate this chain to explicitly verify that
  no real blocks were bypassed. **Advantage:** Every proposal is mathematically self-contained and self-verifying
  regardless of the voter's local memory.
* **Streamlined (Local Highest Rule):** Proposals carry strictly $O(1)$ certificates ($\pi\_prev$ and $\pi\_parent$).
  Voters rely on a local high-water mark (`highest_notarized_non_dummy`). **Advantage:** Eliminates unbounded chain
  processing. Safety relies on quorum intersection: if a real block was notarized, $f+1$ honest nodes will remember it
  and block the bypass locally.

### 1.2 Leader Authentication

* **Original:** Authenticates proposals via a signature over the entire message structure (implicit binding).
* **Streamlined:** Authenticates proposals via an explicit `leader_sig` field bound strictly to
  `("propose", view, hash)`. **Advantage:** Cleaner cryptographic domain separation for the Lean4 theorem prover.

---

## 2. State Machine & Payload Handling

### 2.1 Payload Coupling & Asynchronous Buffering

* **Original (Coupled State):** The consensus engine manages block payloads alongside metadata. Because votes can arrive
  before block payloads, the state machine requires complex asynchronous buffering (`pending_quorums`,
  `pending_finalizations`).
* **Streamlined (Decoupled State):** The consensus state machine operates *exclusively* on hashes. There is no
  buffering; view advancement triggers instantly on metadata quorums. **Tradeoff:** This shrinks the verified consensus
  state space significantly, but relocates complexity to the application layer, which must implement an out-of-band
  payload fetch protocol to resolve `FinalizeBlockEvent`s.

---

## 3. Liveness & Synchronization

### 3.1 View Timeouts & Lemma 3.6

* **Both Designs (Static $3\Delta$):** Both the Original and the finalized Streamlined design utilize a static $3\Delta$
  timeout inside the verified consensus core.
* **Advantage:** This perfectly preserves CP23's **Lemma 3.6**, which mathematically guarantees the protocol will
  cleanly skip a faulty leader in bounded time. By pushing any dynamic exponential backoff into the unverified
  networking wrapper, the Lean4 proof verification retains its exact mapping to the paper.

### 3.2 Lagging Leader Behavior

* **Original (Silent Abstention):** If a node becomes the leader but lacks the necessary historical chain, it silently
  abstains from proposing. The network smoothly skips the view via a clean timeout.
* **Streamlined (NotarizeMsg Hinting):** View advancement relies on an $O(1)$ `NotarizeMsg`. To prevent lagging leaders
  from guessing stale parents, this message includes an explicit `pi_last_real` hint. **Tradeoff:** In rare cases of
  adversarial network splits, a lagging leader may still propose a stale parent, resulting in a rejected proposal. This
  is a documented, accepted degradation that resolves within $O(f)$ leader rotations post-GST, remaining within CP23's
  standard liveness envelope.

---

## 4. Communication Latency & Bandwidth

| Metric                    | Original (`simplex_improvements.md`)    | Streamlined Simplex (Final)   |
|:--------------------------|:----------------------------------------|:------------------------------|
| **Optimistic Block Time** | $2\delta$                               | $2\delta$                     |
| **Proposal Confirmation** | $3\delta$                               | $3\delta$                     |
| **Lag-Recovery Latency**  | $1\delta$ (via Forwarded Notarizations) | $1\delta$ (via `NotarizeMsg`) |
| **Message Complexity**    | Expected $O(1)$, Worst-case $O(h)$      | Strictly bounded $O(1)$       |

*Note: In the Original design, $O(h)$ is a theoretical worst-case during extended asynchrony. Under normal operation,
the chain length is 0 to 5 views, making average bandwidth nearly identical between the two designs.*

---

## 5. Formal Verification Implications (Aeneas $\rightarrow$ Lean4)

The shift to the Streamlined design fundamentally alters the Lean4 proof repository structure, exchanging proof
translation effort for state-machine simplicity.

### Original Design Verification Profile

* **Proof Structure:** Highly faithful to CP23. Safety proofs (chain validation) and liveness proofs map directly to the
  published theorems.
* **State Machine Challenge:** High. The Lean4 state definition must model asynchronous buffers (`pending_quorums`,
  `pending_finalizations`), payload availability states, and recursive chain validation logic.

### Streamlined Design Verification Profile

* **Proof Structure:** Mixed. Liveness proofs remain anchored to CP23 (due to the static $3\Delta$ timeout and restored
  Lemma 3.3 invariant). Safety requires a novel proof combining the `Local Highest Rule` with quorum intersection.
* **State Machine Challenge:** Low. The Lean4 state machine definition is trivially simple. Transitions are strictly
  linear, state fields require simple scalar monotonicity proofs (`highest_notarized_non_dummy` only goes up), and the
  verified system never blocks on missing data.
