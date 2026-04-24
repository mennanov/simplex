---
name: writing-aeneas-compatible-rust
description: Use when adding or modifying Rust code under `src/` — covers the constraints that keep the state machine translatable to Lean via Charon + Aeneas, and what to do when you need something Aeneas can't translate.
---

# Writing Aeneas-compatible Rust

The consensus state machine must round-trip cleanly through `charon → aeneas → Lean`. Aeneas translates a large but not complete subset of Rust. Code that works fine for `cargo build` may still break `make lean` or produce Lean that can't be proven about.

## Non-negotiables

| Rule | Why |
|------|-----|
| `#![no_std]` with `extern crate alloc` | Aeneas models `alloc` collections but not `std` I/O / threading / time. |
| `BTreeMap` / `BTreeSet` over `HashMap` / `HashSet` | Deterministic iteration is required for formal proofs; Aeneas' `HashMap` support is limited. |
| No closures in iterator chains on `hashbrown` maps | Known Aeneas limitation — closures in `.iter().filter(|_| ...)` style don't translate. Use explicit `for` loops. |
| No `unsafe`, no FFI, no `async` | Aeneas rejects or silently skips. |
| No `std::time` / `std::sync` / threads | Model time as a `View` (`u64`) and actions as events; I/O belongs outside the state machine. |
| Keep the state machine pure | `Consensus::handle_event(Event) -> Vec<Action>` is the interface. No side effects inside. |

## Preferred patterns

- **Types are data.** `PeerId`, `View`, `BlockHash` are newtypes over fixed-size arrays or `u64`. Avoid traits with associated types unless Aeneas handles them (basic `Ord`/`PartialOrd`/`Eq` are fine).
- **Options over sentinels.** `Vote.block_hash: Option<BlockHash>` encodes the dummy block / timeout cleanly — Aeneas translates `Option` well.
- **Explicit matches over `if let` chains** in complex cases — translates to cleaner Lean.
- **Small, total functions.** Aeneas proofs get harder as functions grow or panic conditionally.

## When you need something Aeneas can't translate

1. **Put it in a module marked opaque** — Aeneas emits an `axiom` in `*External_Template.lean`, and you fill the corresponding `*External.lean` by hand. Good for e.g. cryptographic hashing primitives.
2. **Keep the opaque surface tiny.** Every opaque function is an unverified trust boundary.
3. **Regenerate and fill the hole** — see the `regenerating-lean-proofs` skill for the workflow around `*External.lean`.

## Early warning signs

- Aeneas warning "Found an unknown type declaration with region parameters" on your type → likely an unusual lifetime pattern; simplify or make opaque.
- Charon succeeds but `make lean` fails at step 2 with a named function — that function hit a translation limit. Check for closures, complex generics, or trait objects.
- `cargo test` passes but `lake build` produces a type mismatch in `Funs.lean` → Aeneas translated something surprising; read the generated Lean for that function and adjust the Rust to be more direct.

## Known patch-worthy upstream bugs

See the `aeneas-patches` block in `scripts/gen_lean.sh` for patches currently applied to Aeneas output. If you hit a new translation issue that looks upstream-ish, check there first — it may be a known issue with a workaround or already-fixed in a newer Aeneas (see `updating-aeneas-charon`).

## Verification loop

After any non-trivial change:

1. `cargo clippy --all-targets --all-features -- -D warnings`
2. `cargo test`
3. `make lean` — catches translation breakage
4. `cd proof && lake build` — catches Lean-level type issues in the regenerated code
5. Commit Rust + regenerated `proof/Simplex/{Types,Funs}.lean` together.
