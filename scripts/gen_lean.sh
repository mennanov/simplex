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
# IMPORTANT: three values must stay in lockstep when upgrading Aeneas:
#   • AENEAS_TAG here  (commit hash suffix = Aeneas release commit)
#   • `rev` in proof/lakefile.toml  (must equal that commit hash)
#   • LEAN_TOOLCHAIN here  (must match proof/lean-toolchain, which must match
#     backends/lean/lean-toolchain in the Aeneas release tarball)
# Blockwatch cross-links all three; the preflight below additionally asserts
# that LEAN_TOOLCHAIN == contents of proof/lean-toolchain.
#
# To upgrade:
#   1. Update CHARON_TAG and AENEAS_TAG to the new release tags.
#   2. Update the `rev` in proof/lakefile.toml to the commit hash in AENEAS_TAG.
#   3. Update LEAN_TOOLCHAIN below AND proof/lean-toolchain to match
#      backends/lean/lean-toolchain in the Aeneas release tarball.
#   4. Run `make lean-bootstrap` then `cd proof && lake update && lake build`.
#   5. If `lake build` fails, revisit the patch section (Step 4) below.
# <block name="charon-tag" line-pattern='^CHARON_TAG="build-\d{4}\.\d{2}\.\d{2}\.\d{6}-[0-9a-f]{40}"$'>
CHARON_TAG="build-2026.05.12.153533-b85ac3b89f78084cacd456194a7a0c903382474c"
# </block>

# The commit hash embedded in AENEAS_TAG must match the `rev` in
# proof/lakefile.toml, and LEAN_TOOLCHAIN must match proof/lean-toolchain —
# blockwatch enforces that all three are updated together.
# <block name="aeneas-tag" affects="proof/lakefile.toml:aeneas-rev, :lean-toolchain, :aeneas-patches" line-pattern='^AENEAS_TAG="build-\d{4}\.\d{2}\.\d{2}\.\d{6}-[0-9a-f]{40}"$'>
AENEAS_TAG="build-2026.05.06.171205-d973341320c1d5c947a95992db2aa6f70b658ea2"
# </block>

# Mirror of proof/lean-toolchain.  The preflight check below asserts they match
# exactly; the blockwatch link to aeneas-tag forces both to be reviewed together
# on every Aeneas upgrade (aeneas-tag → lean-toolchain and the reverse).
# <block name="lean-toolchain" affects=":aeneas-tag" line-pattern='^LEAN_TOOLCHAIN="leanprover/lean4:[^"]+"$'>
LEAN_TOOLCHAIN="leanprover/lean4:v4.29.1"
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

# Assert proof/lean-toolchain matches LEAN_TOOLCHAIN above.  Blockwatch forces
# both to appear in the same diff on an Aeneas bump, but cannot check equality
# across files — that's what this does.
read -r _actual_toolchain < "$PROJECT_ROOT/proof/lean-toolchain"
if [ "$_actual_toolchain" != "$LEAN_TOOLCHAIN" ]; then
  echo "Error: proof/lean-toolchain ($_actual_toolchain) does not match" >&2
  echo "       LEAN_TOOLCHAIN in scripts/gen_lean.sh ($LEAN_TOOLCHAIN)." >&2
  echo "       Update one so they agree." >&2
  exit 1
fi
unset _actual_toolchain

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
# All previously identified bugs (1-5) are now fixed upstream in the pinned
# versions of Charon and Aeneas.
#
# The block below is blockwatch-linked to aeneas-tag: every Aeneas bump forces
# a diff here so the patch list gets reviewed (remove patches for bugs fixed
# upstream; add patches for new bugs encountered).  If the list is unchanged
# across a bump, make a no-op whitespace touch to acknowledge the review.
# <block name="aeneas-patches" affects=":aeneas-tag">
# Bug 6 — self-referential `lt` in derived PartialOrd struct literals (reviewed 2026-05-25):
#   The binary emits `lt := <Self>.lt` inside PartialOrd trait impls but
#   never generates a separate `lt` definition, creating a circular
#   reference Lean cannot prove terminates. The library defaults from
#   AeneasVerif/aeneas#940 provide the correct implementation.
#   Fix: strip the self-referential `lt` lines so defaults apply.
python3 - "$LEAN_DEST/Types.lean" "$LEAN_DEST/Funs.lean" <<'PYEOF'
import re, sys

for path in sys.argv[1:]:
    content = open(path).read()
    original = content

    # Bug 6: self-referential `lt` in PartialOrd struct literals.
    # The binary emits `lt := <Namespace>.Insts.CoreCmpPartialOrd<T>.lt`
    # but never defines a separate `lt` function, creating a circular
    # definition that Lean cannot prove terminates. Removing the line
    # lets the library default (from AeneasVerif/aeneas#940) apply.
    content = re.sub(
        r'^  lt := \S+\.Insts\.CoreCmpPartialOrd\S+\.lt$\n',
        '',
        content,
        flags=re.MULTILINE,
    )

    if content != original:
        open(path, 'w').write(content)
PYEOF
# </block>

echo "==> Done. Generated: $LEAN_DEST/{Types,Funs}.lean"
