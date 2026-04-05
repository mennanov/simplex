# simplex

Verified Simplex Consensus in Rust via Functional Translation to Lean

## Usage

Add this to your `Cargo.toml`:

```toml
[dependencies]
simplex = { git = "https://github.com/mennanov/simplex" }
```

## Lean Code Generation

The pipeline translates the Rust consensus state machine to Lean 4 using [Charon](https://github.com/AeneasVerif/charon) + [Aeneas](https://github.com/AeneasVerif/aeneas), producing `proof/Proof/Consensus.lean`.

```bash
# If charon and aeneas are already on PATH:
make lean

# Install charon and aeneas automatically, then generate:
make lean-bootstrap
```

After running, build the Lean proof project:

```bash
cd proof && lake build
```

The generated `proof/Proof/Consensus.lean` is excluded from git — regenerate it from source as needed.

## Contribute

Development requires Rust and `pre-commit`.

```bash
# Build & Test
cargo build
cargo test

# Linting
cargo clippy
cargo fmt --all -- --check

# Git Hooks
pre-commit install
pre-commit run --all-files
```
