---
name: regenerating-lean-proofs
description: Use when Rust source under `src/` changes and the Lean proof project needs re-derived types/functions — covers the pipeline, which files are generated vs hand-maintained, and the expected noise.
---

# Regenerating Lean proofs

The Lean proof project is partly auto-generated from Rust via Charon + Aeneas. Edits to `src/*.rs` that affect translated types or functions require regeneration; if you forget, `proof/Simplex/` drifts from the Rust state machine and proofs become meaningless.

## Pipeline

```
src/*.rs  → charon  → target/charon/simplex.llbc
          → aeneas  → target/aeneas-out/{Types,Funs,TypesExternal_Template,FunsExternal_Template}.lean
          → cp      → proof/Simplex/{Types,Funs}.lean
```

`make lean` runs the whole thing. `make lean-bootstrap` also downloads the pinned Charon/Aeneas binaries to `~/.local/bin` first.

## Which files are committed vs generated

| Path | Status | Who writes it |
|------|--------|---------------|
| `proof/Simplex/Types.lean` | committed, **overwritten every run** | `gen_lean.sh` |
| `proof/Simplex/Funs.lean` | committed, **overwritten every run** | `gen_lean.sh` |
| `proof/Simplex/TypesExternal.lean` | committed, **hand-maintained** | you (seeded from template on first run) |
| `proof/Simplex/FunsExternal.lean` | committed, **hand-maintained** | you (seeded from template on first run) |
| `target/aeneas-out/*_Template.lean` | git-ignored | aeneas — shows what holes exist |

**Commit the regenerated `Types.lean` / `Funs.lean` in the same commit as the Rust change** so reviewers see the translation shift. CI does `make lean && lake build` but does not (today) assert the committed Lean matches a fresh regen.

## Steps

1. Edit Rust under `src/`.
2. `make lean` (or `make lean-bootstrap` if Charon/Aeneas aren't installed).
3. `cd proof && lake exe cache get` once per clone — downloads mathlib cache.
4. `cd proof && lake build`.
5. If new opaque functions appear: compare `target/aeneas-out/*External_Template.lean` against `proof/Simplex/*External.lean` and copy over any new `axiom` / opaque declarations, then fill the definitions by hand.
6. Commit `src/*.rs` **and** `proof/Simplex/{Types,Funs}.lean` (**and** `*External.lean` if you edited it) together.

## Expected noise

- Aeneas warnings about `OccupiedEntry`, `VacantEntry`, `btree::set::Iter` having unmodeled region parameters — harmless; these are `BTreeMap` internals we don't touch.
- "Generated: …/TypesExternal_Template.lean / FunsExternal_Template.lean" each run — templates live in `target/`, regenerated every run.
- Seed messages only on first run of a fresh clone.

## Pitfalls

- **Editing `*External.lean` manually is fine; editing `Types.lean` or `Funs.lean` is not** — the next `make lean` wipes it. Put custom definitions in the `*External.lean` files.
- **Adding a new opaque function in Rust** (e.g., bringing in a trait method Aeneas can't translate) silently adds a new `axiom` to `*External_Template.lean` but the script only seeds `*External.lean` when missing. You must manually add the new entry to the existing hand-maintained file or proofs won't find the symbol.
- **`no_std` / hashbrown constraints** still apply — if `make lean` fails at the Aeneas step, the cause is usually in your Rust (closures in hashbrown, `HashMap` where `BTreeMap` is required, etc.), not the pipeline.
- **Charon or Aeneas version bump?** Use the `updating-aeneas-charon` skill — different workflow.
