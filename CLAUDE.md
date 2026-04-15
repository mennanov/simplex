# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A `no_std` Rust implementation of the Simplex BFT consensus protocol with formal verification via Lean 4. The pipeline automatically translates the Rust state machine to Lean 4 using Charon + Aeneas for mathematical proof generation.

## Commands

### Rust
```bash
cargo build
cargo test
cargo clippy --all-targets --all-features -- -D warnings
cargo fmt --all -- --check
```

To run a single test:
```bash
cargo test <test_name>
```

### Lean Proof Generation
```bash
make lean                    # Generate Lean from Rust (charon + aeneas must be on PATH)
make lean-bootstrap          # Auto-install Charon + Aeneas, then generate
cd proof && lake exe cache get  # Download mathlib cache (run before first build)
cd proof && lake build       # Build the Lean proof project
```

## Architecture

### Rust State Machine (`src/`)

The consensus logic is a pure state machine with no I/O:

- **`types.rs`**: Core types — `PeerId` (32-byte validator ID), `View` (round number, `u64`), `Block`, `BlockHash`, `TimerId`
- **`message.rs`**: Protocol messages — `Proposal` (leader proposes block), `Vote` (real block or dummy/timeout via `Option<BlockHash>`), `Finalize`, and `Message` enum
- **`consensus.rs`**: `Consensus` struct with `handle_event(Event) -> Vec<Action>`. Events are `MessageReceived` or `TimerExpired`; Actions are `Broadcast`, `FinalizeBlock`, `SetTimer`, `CancelTimer`

The crate is `#![no_std]` with `extern crate alloc`. `BTreeMap` is used instead of `HashMap` for deterministic, sorted storage — this is required for formal verification. Hashbrown is used for cases where `no_std` HashMap is needed, though it currently has a known Aeneas translation limitation (closures not supported).

### Lean Proof Pipeline (`proof/`, `scripts/gen_lean.sh`)

```
Rust source → charon (→ .llbc LLBC IR) → aeneas (→ Lean 4) → proof/Proof/Consensus.lean
```

`proof/Proof/Consensus.lean` is auto-generated and not checked into git. The script applies Python regex patches to work around known Aeneas bugs (naming mismatches in `PartialOrd`/`Ord` struct fields).

Tool versions are pinned in `scripts/gen_lean.sh` (`CHARON_TAG`, `AENEAS_TAG`) and must stay in sync with the `aeneas` git dependency commit in `proof/lakefile.toml` — enforced by the `blockwatch` CI job.

### Protocol Notes

`Vote.block_hash = None` represents a vote for the dummy block ⊥ (timeout). A quorum of these (`> 2n/3`) triggers moving to the next view. The `docs/simplex_improvements.md` document specifies practical wire protocol optimizations over the original CP23 paper (e.g., using `parent_view` instead of full chain hashes to reduce O(h) message sizes).

## Implementation Status

- Dummy block (timeout) vote handling: complete
- Real block proposal/voting: TODO
- Finalization logic: TODO
- Timer expiration: TODO
