# simplex

Verified Simplex Consensus in Rust via Functional Translation to Lean

## Usage

Add this to your `Cargo.toml`:

```toml
[dependencies]
simplex = { git = "https://github.com/mennanov/simplex" }
```

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
