#!/usr/bin/env bash
# Enforces cross-file version invariants that blockwatch's `affects` cannot
# express (blockwatch catches "both touched" but not "both agree"):
#
#   1. proof/lean-toolchain  ==  LEAN_TOOLCHAIN in scripts/gen_lean.sh
#   2. 40-hex suffix of AENEAS_TAG in scripts/gen_lean.sh
#      ==  `rev` field in proof/lakefile.toml
#
# Run by gen_lean.sh preflight and by the check-versions pre-commit hook.
# Pure shell — no dependency on charon/aeneas being on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

gen_lean="$PROJECT_ROOT/scripts/gen_lean.sh"
lakefile="$PROJECT_ROOT/proof/lakefile.toml"
toolchain_file="$PROJECT_ROOT/proof/lean-toolchain"

fail=0

# ── Check 1: proof/lean-toolchain matches LEAN_TOOLCHAIN constant ──────────────
expected_toolchain="$(grep -m1 '^LEAN_TOOLCHAIN=' "$gen_lean" \
  | sed -E 's/^LEAN_TOOLCHAIN="([^"]+)"$/\1/')"
read -r actual_toolchain < "$toolchain_file"
if [ "$actual_toolchain" != "$expected_toolchain" ]; then
  echo "Error: proof/lean-toolchain ($actual_toolchain) does not match" >&2
  echo "       LEAN_TOOLCHAIN in scripts/gen_lean.sh ($expected_toolchain)." >&2
  echo "       Update one so they agree." >&2
  fail=1
fi

# ── Check 2: AENEAS_TAG hash suffix matches lakefile.toml rev ──────────────────
aeneas_hash="$(grep -m1 '^AENEAS_TAG=' "$gen_lean" | grep -oE '[0-9a-f]{40}' || true)"
lake_rev="$(grep -m1 -E '^rev = "[0-9a-f]{40}"' "$lakefile" | grep -oE '[0-9a-f]{40}' || true)"
if [ -z "$aeneas_hash" ]; then
  echo "Error: could not extract a 40-hex commit hash from AENEAS_TAG in $gen_lean" >&2
  fail=1
elif [ -z "$lake_rev" ]; then
  echo "Error: could not extract a 40-hex rev from $lakefile" >&2
  fail=1
elif [ "$aeneas_hash" != "$lake_rev" ]; then
  echo "Error: Aeneas commit-hash mismatch:" >&2
  echo "       AENEAS_TAG suffix in scripts/gen_lean.sh:  $aeneas_hash" >&2
  echo "       rev in proof/lakefile.toml:                $lake_rev" >&2
  echo "       These must be the same commit — update one so they agree." >&2
  fail=1
fi

exit "$fail"
