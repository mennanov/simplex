# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A `no_std` Rust implementation of the **pragmatically-simplified Simplex BFT consensus protocol** (based on Chan & Pass, CP23), with formal verification via Lean 4. The Rust state machine is automatically translated to Lean 4 through Charon + Aeneas for mathematical proof generation.

The **authoritative algorithm spec** is `docs/streamlined_simplex.md` — read it before making semantic changes. Key simplifications over vanilla CP23:

- **Local Highest Rule**: proposals carry only two constant-size certificates (`π_prev` for `view-1`, `π_parent` for `h_parent`). No chain forwarding. Voters reject proposals whose `h_parent < highest_notarized_non_dummy`; safety via quorum intersection.
- **O(1) `NotarizeMsg`** for view-advance / catch-up — one cert + an optional `pi_last_real` hint.
- **Static `3Δ` timeout** everywhere, preserving CP23's Lemma 3.6 liveness bounds verbatim.
- **Dummy vote encoding**: `Vote.block_hash = None` represents ⊥ (timeout); a quorum of these advances the view.

## Commands

### Rust
```bash
cargo build
cargo test
cargo clippy --all-targets --all-features -- -D warnings
cargo fmt --all -- --check
cargo test <test_name>         # single test
```

### Lean proof generation
```bash
make lean                      # charon + aeneas must be on PATH
make lean-bootstrap            # auto-installs pinned charon + aeneas
cd proof && lake exe cache get # mathlib cache (first build)
cd proof && lake build
```

### Version invariants
```bash
scripts/check_versions.sh      # Aeneas-hash ↔ lakefile-rev, LEAN_TOOLCHAIN ↔ lean-toolchain
```
Runs as a pre-commit hook and from the `gen_lean.sh` preflight.

## Architecture

### Rust state machine (`src/`)

Pure, I/O-free. Single owned state; no `Rc`/`Arc`/`RefCell`.

- **`types.rs`** — `PeerId` (32-byte), `View` (`u64`), `Block`, `BlockHash`, `TransactionHash`, `TimerId`.
- **`message.rs`** — `Proposal`, `Vote` (with `block_hash: Option<BlockHash>` for ⊥), `Finalize`, and `Message` enum. `NotarizeMsg` is part of the approved spec but not yet implemented.
- **`consensus.rs`** — `Consensus<L: LeaderElector>::handle_event(Event) -> Vec<Action>`. Events: `MessageReceived`, `TimerExpired`. Actions: `Broadcast`, `FinalizeBlock`, `SetTimer`, `CancelTimer`. `RoundRobinLeaderElector` is the default elector.

The crate is `#![no_std]` with `extern crate alloc`. **Use `BTreeMap` over `HashMap`** — deterministic iteration is required for proof stability, and flat keys (e.g. `(View, BlockHash, PeerId)`) are preferred over nested maps. `hashbrown` is used where `no_std` `HashMap` is needed, but has a known Aeneas limitation (closures in iterator chains don't translate).

### Lean proof pipeline (`proof/`, `scripts/gen_lean.sh`)

```
src/*.rs → charon → target/charon/simplex.llbc → aeneas → proof/Simplex/{Types,Funs}.lean
```

Files under `proof/Simplex/`:
- `Types.lean`, `Funs.lean` — **auto-generated**, overwritten every run. Commit them alongside the Rust change.
- `TypesExternal.lean`, `FunsExternal.lean` — **hand-maintained** (seeded once from templates in `target/aeneas-out/`). Fill new opaque-function holes here.

`gen_lean.sh` applies regex patches for residual Aeneas bugs (see the `aeneas-patches` block; prune on each Aeneas bump).

### Version coupling and enforcement

Four values move in lockstep on an Aeneas upgrade:

1. `AENEAS_TAG` in `scripts/gen_lean.sh` (40-hex suffix = Aeneas release commit)
2. `rev` in `proof/lakefile.toml` (must equal that hash)
3. `LEAN_TOOLCHAIN` in `scripts/gen_lean.sh`
4. `proof/lean-toolchain` (must equal `LEAN_TOOLCHAIN`)

`CHARON_TAG` is independently versioned.

Enforcement layers:
- **blockwatch** (`affects` cross-links + `line-pattern` format guards) forces co-modification and rejects malformed values. Runs in CI and via pre-commit.
- **`scripts/check_versions.sh`** asserts actual value equality (blockwatch can force touches, not agreement). Pre-commit hook + `gen_lean.sh` preflight.
- **CI `lean-proof` job** (`make lean && lake build`) is the ultimate backstop.

## Project skills

`.claude/skills/` hosts reference skills for recurring workflows:
- `updating-aeneas-charon` — bumping pinned tool versions
- `regenerating-lean-proofs` — Rust edits → Lean re-derivation
- `writing-aeneas-compatible-rust` — translation subset + opaque-module escape hatch

## Implementation status

- Dummy-block (timeout) vote handling: complete
- Real block proposal/voting: TODO
- Finalization logic: TODO
- Timer expiration: TODO
- `NotarizeMsg` (O(1) view-advance): TODO
