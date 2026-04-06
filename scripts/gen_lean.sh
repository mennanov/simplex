#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BOOTSTRAP=false

# ── Argument parsing ───────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --bootstrap) BOOTSTRAP=true ;;
    *)
      echo "Error: unknown argument '$arg'" >&2
      echo "Usage: gen_lean.sh [--bootstrap]" >&2
      exit 1
      ;;
  esac
done

# ── Pinned tool versions ───────────────────────────────────────────────────────
# Charon and Aeneas publish only nightly pre-releases; there are no stable tags.
# We pin specific release tags so that `make lean` and `lake build` are
# reproducible and do not break silently when a new nightly drops.
#
# IMPORTANT: these two tags must be kept in sync with the Aeneas library revision
# pinned in proof/lakefile.toml (`[[require]] rev = "..."`).  The commit hash
# embedded in AENEAS_TAG must match that rev exactly, because the binary and the
# Lean library it ships with must come from the same build.
#
# To upgrade:
#   1. Update CHARON_TAG and AENEAS_TAG to the new release tags.
#   2. Update the `rev` in proof/lakefile.toml to the commit hash in AENEAS_TAG.
#   3. Run `make lean-bootstrap` then `cd proof && lake update && lake build`.
#   4. If `lake build` fails, revisit the patch section (Step 4) below.
CHARON_TAG="build-2026.04.03.155040-77d520657e76f265f21a0516c2e4d8d49ba27056"
AENEAS_TAG="build-2026.04.05.213617-3cd6970451d7bebee6e34fec3bace4e08690a83a"

# ── Helpers ────────────────────────────────────────────────────────────────────
detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}-${arch}" in
    Linux-x86_64)  echo "linux-x86_64" ;;
    Darwin-arm64)  echo "macos-aarch64" ;;
    Darwin-x86_64) echo "macos-x86_64" ;;
    *)
      echo "Error: unsupported platform ${os}-${arch}" >&2
      return 1
      ;;
  esac
}

# ── Bootstrap ─────────────────────────────────────────────────────────────────
install_tool() {
  # Downloads a pinned GitHub release binary tarball and installs to ~/.local/bin/<name>.
  # Arguments: <binary-name> <github-repo-owner/name> <release-tag>
  local name="$1" repo="$2" tag="$3"
  local platform url tmpdir binary

  if ! platform="$(detect_platform)"; then
    return 1
  fi
  echo "==> Installing ${name} from ${repo} @ ${tag}..."

  url="https://github.com/${repo}/releases/download/${tag}/${name}-${platform}.tar.gz"
  echo "    URL: ${url}"

  tmpdir="$(mktemp -d)"
  trap 'chmod -R u+w "$tmpdir" 2>/dev/null; rm -rf "$tmpdir"' EXIT
  curl -fsSL "$url" | tar xz -C "$tmpdir"

  # Find the main binary, then copy its entire directory to ~/.local/bin/.
  # This preserves siblings (e.g. charon-driver) and relative library paths
  # (e.g. aeneas expects libs/libgmp.10.dylib next to itself).
  binary="$(find "$tmpdir" -type f -name "$name" | head -1)"
  if [ -z "$binary" ]; then
    echo "Error: could not locate ${name} binary in downloaded archive" >&2
    return 1
  fi

  mkdir -p "$HOME/.local/bin"
  chmod -R u+w "$HOME/.local/bin/" 2>/dev/null || true
  cp -r "$(dirname "$binary")/." "$HOME/.local/bin/"
  chmod +x "$HOME/.local/bin/$name"
  trap - EXIT
  chmod -R u+w "$tmpdir" 2>/dev/null
  rm -rf "$tmpdir"
  echo "    Installed: ~/.local/bin/${name}"
}

if [ "$BOOTSTRAP" = true ]; then
  install_tool charon AeneasVerif/charon "$CHARON_TAG"
  install_tool aeneas AeneasVerif/aeneas "$AENEAS_TAG"
  echo "==> Bootstrap complete. Make sure ~/.local/bin is on your PATH."
fi

# ── Preflight checks ───────────────────────────────────────────────────────────
if ! command -v charon &>/dev/null; then
  echo "Error: 'charon' not found on PATH." >&2
  echo "       Run with --bootstrap to install it automatically," >&2
  echo "       or follow https://github.com/AeneasVerif/charon#installation" >&2
  exit 1
fi

if ! command -v aeneas &>/dev/null; then
  echo "Error: 'aeneas' not found on PATH." >&2
  echo "       Run with --bootstrap to install it automatically," >&2
  echo "       or follow https://github.com/AeneasVerif/aeneas#installation" >&2
  exit 1
fi

# ── Paths ──────────────────────────────────────────────────────────────────────
LLBC_DIR="$PROJECT_ROOT/target/charon"
AENEAS_OUT="$PROJECT_ROOT/target/aeneas-out"
LEAN_DEST="$PROJECT_ROOT/proof/Proof"
LLBC_FILE="$LLBC_DIR/simplex.llbc"
AENEAS_LEAN="$AENEAS_OUT/Simplex.lean"
TARGET_LEAN="$LEAN_DEST/Consensus.lean"

mkdir -p "$LLBC_DIR" "$AENEAS_OUT"

# ── Step 1: Charon (Rust → LLBC) ───────────────────────────────────────────────
echo "==> Running Charon..."
(cd "$PROJECT_ROOT" && charon cargo --preset=aeneas --dest-file "$LLBC_FILE")

# Guard against silent success: Charon may exit 0 without writing the file.
if [ ! -f "$LLBC_FILE" ]; then
  echo "Error: Charon did not produce $LLBC_FILE" >&2
  exit 1
fi
echo "    LLBC: $LLBC_FILE"

# ── Step 2: Aeneas (LLBC → Lean) ───────────────────────────────────────────────
echo "==> Running Aeneas..."
aeneas -backend lean -dest "$AENEAS_OUT" "$LLBC_FILE"

# Guard against silent success: Aeneas may exit 0 without writing the file.
if [ ! -f "$AENEAS_LEAN" ]; then
  echo "Error: Aeneas did not produce $AENEAS_LEAN" >&2
  echo "       Contents of $AENEAS_OUT:" >&2
  ls "$AENEAS_OUT" 2>/dev/null >&2 || echo "       (directory does not exist)" >&2
  exit 1
fi

# ── Step 3: Place output in Lean project ───────────────────────────────────────
mkdir -p "$LEAN_DEST"
cp "$AENEAS_LEAN" "$TARGET_LEAN"

# ── Step 4: Patch known Aeneas binary/library mismatches ───────────────────────
# As of the pinned nightly above, the Aeneas binary and the Lean library it
# ships with are inconsistent in two ways.  Both are upstream bugs; we work
# around them here so the generated file compiles without modifying the
# generator itself.
#
# Bug 1 — wrong instance name for scalar PartialOrd (binary vs library naming):
#   The binary emits `core.cmp.impls.PartialCmpU64.partial_cmp` when calling
#   u64's PartialOrd implementation inside a derived PartialOrd for a newtype.
#   The Lean library (Aeneas/Std/Scalar/EqOrd.lean) defines this function as
#   `core.cmp.impls.PartialOrdU64.partial_cmp` via the `scalar` macro.
#   Fix: replace every occurrence of the wrong name with the correct one.
#
# Bug 2 — incomplete PartialOrd struct literals (missing lt/le/gt/ge):
#   The Lean library's `core.cmp.PartialOrd` structure requires six fields:
#   partialEqInst, partial_cmp, lt, le, gt, ge.  The binary only emits the
#   first two for derived PartialOrd impls on newtypes.  The library provides
#   default implementations for the missing four in terms of partial_cmp.
#   Fix: for any struct literal whose last field is `partial_cmp`, append the
#   four missing fields using their library-provided default expressions.
#
# Bug 3 — incomplete Ord struct literals (missing max/min/clamp):
#   Similarly, `core.cmp.Ord` requires eqInst, partialOrdInst, cmp, max, min,
#   clamp, but the binary only emits the first three.  The library provides
#   default implementations for max/min/clamp in terms of the partialOrdInst's
#   lt/le/gt fields.
#   Fix: for any struct literal whose last two fields are `partialOrdInst` then
#   `cmp`, append max/min/clamp via the library defaults.
python3 - "$TARGET_LEAN" <<'PYEOF'
import re, sys

content = open(sys.argv[1]).read()

# Bug 1: rename PartialCmpU64 → PartialOrdU64 throughout.
content = content.replace(
    'core.cmp.impls.PartialCmpU64.partial_cmp',
    'core.cmp.impls.PartialOrdU64.partial_cmp',
)

# Bug 2: add missing lt/le/gt/ge to PartialOrd struct literals.
# Pattern: a struct literal whose last field is `partial_cmp := EXPR` followed
# immediately by the closing `}` on its own line.
content = re.sub(
    r'^  partial_cmp := ([^\n]+)$\n^}$',
    lambda m: (
        f'  partial_cmp := {m.group(1)}\n'
        f'  lt := fun x y => core.cmp.PartialOrd.lt.default {m.group(1)} x y\n'
        f'  le := fun x y => core.cmp.PartialOrd.le.default {m.group(1)} x y\n'
        f'  gt := fun x y => core.cmp.PartialOrd.gt.default {m.group(1)} x y\n'
        f'  ge := fun x y => core.cmp.PartialOrd.ge.default {m.group(1)} x y\n'
        '}'
    ),
    content,
    flags=re.MULTILINE,
)

# Bug 3: add missing max/min/clamp to Ord struct literals.
# Pattern: a struct literal whose last two fields are `partialOrdInst := POI`
# then `cmp := EXPR` followed immediately by the closing `}` on its own line.
# max/min/clamp are derived from the partialOrdInst's lt/le/gt projections.
content = re.sub(
    r'^  partialOrdInst := ([^\n]+)$\n^  cmp := ([^\n]+)$\n^}$',
    lambda m: (
        f'  partialOrdInst := {m.group(1)}\n'
        f'  cmp := {m.group(2)}\n'
        f'  max := core.cmp.Ord.max.default {m.group(1)}.lt\n'
        f'  min := core.cmp.Ord.min.default {m.group(1)}.lt\n'
        f'  clamp := core.cmp.Ord.clamp.default {m.group(1)}.le {m.group(1)}.lt {m.group(1)}.gt\n'
        '}'
    ),
    content,
    flags=re.MULTILINE,
)

open(sys.argv[1], 'w').write(content)
PYEOF

echo "==> Done. Generated: $TARGET_LEAN"
