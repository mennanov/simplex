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
# <block name="charon-tag">
CHARON_TAG="build-2026.04.15.180725-fbd54169205bf97e3c42cbfef95ca5807d697bfb"
# </block>

# The commit hash embedded in AENEAS_TAG must match the `rev` in
# proof/lakefile.toml — blockwatch enforces that both are updated together.
# Also update proof/lean-toolchain to match the Lean version the new
# Aeneas library requires (check backends/lean/lean-toolchain in the tarball).
# <block name="aeneas-tag" affects="proof/lakefile.toml:aeneas-rev">
AENEAS_TAG="build-2026.04.15.082433-8ab2e7e4e47fe73fd5b2a0c061293e00b30013fe"
# </block>

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
LEAN_DEST="$PROJECT_ROOT/proof/Simplex"
LLBC_FILE="$LLBC_DIR/simplex.llbc"

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
aeneas -backend lean -split-files -dest "$AENEAS_OUT" "$LLBC_FILE"

# Guard against silent success: Aeneas may exit 0 without writing the files.
for f in Types.lean Funs.lean; do
  if [ ! -f "$AENEAS_OUT/$f" ]; then
    echo "Error: Aeneas did not produce $AENEAS_OUT/$f" >&2
    echo "       Contents of $AENEAS_OUT:" >&2
    ls "$AENEAS_OUT" 2>/dev/null >&2 || echo "       (directory does not exist)" >&2
    exit 1
  fi
done

# ── Step 3: Place output in Lean project ───────────────────────────────────────
mkdir -p "$LEAN_DEST"
# Copy auto-generated files (overwritten every run).
cp "$AENEAS_OUT/Types.lean" "$LEAN_DEST/Types.lean"
cp "$AENEAS_OUT/Funs.lean"  "$LEAN_DEST/Funs.lean"

# Seed external-definition files from templates if they don't exist yet.
# These are hand-maintained — never overwrite them.
for kind in Types Funs; do
  tpl="$AENEAS_OUT/${kind}External_Template.lean"
  dest="$LEAN_DEST/${kind}External.lean"
  if [ -f "$tpl" ] && [ ! -f "$dest" ]; then
    echo "    Seeding $dest from template (edit manually to fill holes)"
    cp "$tpl" "$dest"
  fi
done

# ── Step 4: Patch remaining Aeneas bugs ────────────────────────────────────────
# All four bugs are still present as of Aeneas build-2026.04.15.082433.
#
# Bug 1 — wrong instance name for scalar PartialOrd (binary vs library naming):
#   The binary emits `core.cmp.impls.PartialCmpU64.partial_cmp` when calling
#   u64's PartialOrd implementation inside a derived PartialOrd for a newtype.
#   The Lean library defines it as `core.cmp.impls.PartialOrdU64.partial_cmp`.
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
#   clamp, but the binary only emits the first three.
#   Fix: for any struct literal whose last two fields are `partialOrdInst` then
#   `cmp`, append max/min/clamp via the library defaults.
#
# Bug 4 — wrong argument in Entry inductive constructor return types:
#   The `Entry` inductive has parameters `(K V : Type) {A : Type}
#   (corecloneCloneInst : core.clone.Clone A)` but its constructor return
#   types pass `A` (the implicit Type) instead of `corecloneCloneInst`
#   (the explicit Clone instance).
#   Fix: replace `Entry K V A` with `Entry K V corecloneCloneInst`.
python3 - "$LEAN_DEST/Types.lean" "$LEAN_DEST/Funs.lean" <<'PYEOF'
import re, sys

for path in sys.argv[1:]:
    content = open(path).read()
    original = content

    # Bug 4: fix Entry constructor return types.
    content = content.replace(
        'alloc.collections.btree.map.entry.Entry K V A',
        'alloc.collections.btree.map.entry.Entry K V corecloneCloneInst',
    )

    # Bug 1: rename PartialCmpU64 → PartialOrdU64 throughout.
    content = content.replace(
        'core.cmp.impls.PartialCmpU64.partial_cmp',
        'core.cmp.impls.PartialOrdU64.partial_cmp',
    )

    # Bug 2: add missing lt/le/gt/ge to PartialOrd struct literals.
    # The partial_cmp value may span one or two lines (Aeneas wraps long names).
    content = re.sub(
        r'^  partial_cmp :=\s*\n?\s*(\S+)$\n^}$',
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
    # The partialOrdInst value may span one or two lines.
    content = re.sub(
        r'^  partialOrdInst :=\s*\n?\s*(\S+)$\n^  cmp := ([^\n]+)$\n^}$',
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

    if content != original:
        open(path, 'w').write(content)
PYEOF

echo "==> Done. Generated: $LEAN_DEST/{Types,Funs}.lean"
