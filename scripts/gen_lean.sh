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

# ── Helpers ────────────────────────────────────────────────────────────────────
latest_release() {
  # Fetch the tag of the most recent GitHub release for a given repo (owner/name).
  # Uses /releases (not /releases/latest) because Charon and Aeneas publish
  # pre-releases only, and /releases/latest returns 404 for pre-release-only repos.
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases" \
    | grep '"tag_name"' \
    | head -1 \
    | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'
}

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
  # Downloads a GitHub release binary tarball and installs to ~/.local/bin/<name>.
  # Arguments: <binary-name> <github-repo-owner/name>
  local name="$1" repo="$2"
  local platform tag url tmpdir binary

  if ! platform="$(detect_platform)"; then
    return 1
  fi
  echo "==> Fetching latest release of ${name} from ${repo}..."
  tag="$(latest_release "$repo")"
  if [ -z "$tag" ]; then
    echo "Error: could not determine latest release tag for ${repo}" >&2
    echo "       Check your internet connection or visit https://github.com/${repo}/releases" >&2
    return 1
  fi
  echo "    Tag: ${tag}"

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
  install_tool charon AeneasVerif/charon
  install_tool aeneas AeneasVerif/aeneas
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
echo "==> Done. Generated: $TARGET_LEAN"
