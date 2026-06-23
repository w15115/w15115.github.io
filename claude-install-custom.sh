#!/usr/bin/env bash
set -euo pipefail

ROOT_NAME="claude-code"
DOWNLOAD_BASE_URL="https://downloads.claude.ai/claude-code-releases"

# ── WSL detection ────────────────────────────────────────────────────────────
IS_WSL=false
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=true

# ── Helpers ──────────────────────────────────────────────────────────────────

usage() {
  cat <<'USAGE'
Usage: claude-install-custom.sh [BASE_DIR] [stable|latest|VERSION]

  Creates a '<BASE_DIR>/claude-code/' root directory and installs everything there.
  On WSL, Windows-style paths (D:\foo\bar) are accepted and auto-converted.

Examples:
  ./claude-install-custom.sh                        # $PWD/claude-code/
  ./claude-install-custom.sh /opt                   # /opt/claude-code/
  ./claude-install-custom.sh 'D:\tools' latest      # /mnt/d/tools/claude-code/
  ./claude-install-custom.sh ~/tools 2.1.177

Layout after install:
  <BASE_DIR>/claude-code/
    bin/      <- Claude binaries
    claude    <- launcher (sets CLAUDE_CONFIG_DIR automatically)
    .claude/  <- per-instance config & account (created on first run)
USAGE
}

is_version() {
  [[ "$1" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?)$ ]]
}

# Convert Windows path D:\foo\bar → /mnt/d/foo/bar
to_wsl_path() {
  local p="$1"
  if [[ "$p" =~ ^([A-Za-z]):[/\\](.*)$ ]]; then
    local drive="${BASH_REMATCH[1],}"      # lowercase drive letter
    local rest="${BASH_REMATCH[2]//\\//}" # backslash → forward slash
    echo "/mnt/$drive/$rest"
  else
    echo "$p"
  fi
}

# True if path lives on a Windows-mounted filesystem (DrvFs)
is_windows_fs() { [[ "$1" =~ ^/mnt/[a-z](/|$) ]]; }

download_file() {
  local url="$1" output="${2:-}"
  if command -v curl >/dev/null 2>&1; then
    [[ -n "$output" ]] && curl -fsSL -o "$output" "$url" || curl -fsSL "$url"
  else
    [[ -n "$output" ]] && wget -q -O "$output" "$url" || wget -q -O - "$url"
  fi
}

get_checksum_from_manifest() {
  local json="$1" platform="$2"
  json=$(echo "$json" | tr -d '\n\r\t' | sed 's/ \+/ /g')
  if [[ $json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    echo "${BASH_REMATCH[1]}"; return 0
  fi
  return 1
}

# ── Argument parsing ──────────────────────────────────────────────────────────

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

BASE_DIR="${1:-$PWD}"
TARGET="${2:-stable}"

# Allow passing version as sole arg: ./script 2.1.177
if [[ $# -eq 1 ]] && is_version "$1"; then
  BASE_DIR="$PWD"
  TARGET="$1"
fi

if ! is_version "$TARGET"; then
  echo "Error: invalid version '$TARGET'" >&2
  echo "Usage: $0 [BASE_DIR] [stable|latest|VERSION]" >&2
  exit 1
fi

# Resolve path: ~, Windows paths, relative → absolute
BASE_DIR="${BASE_DIR/#\~/$HOME}"
"$IS_WSL" && BASE_DIR="$(to_wsl_path "$BASE_DIR")"
BASE_DIR="$(realpath -m "$BASE_DIR")"

INSTALL_DIR="$BASE_DIR/$ROOT_NAME"
BIN_DIR="$INSTALL_DIR/bin"
DOWNLOAD_DIR="$INSTALL_DIR/downloads"
LAUNCHER_PATH="$INSTALL_DIR/claude"

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "Error: curl or wget is required" >&2; exit 1
fi

if "$IS_WSL" && is_windows_fs "$INSTALL_DIR"; then
  echo "Note: installing to a Windows filesystem ($INSTALL_DIR)."
  echo "  For faster I/O consider a Linux path, e.g.: ~/claude-code"
  echo ""
fi

# ── Detect platform ───────────────────────────────────────────────────────────

case "$(uname -s)" in
  Linux)  os="linux"  ;;
  Darwin) os="darwin" ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Error: run this script inside WSL, not Windows shell." >&2; exit 1 ;;
  *) echo "Unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64)   arch="x64"   ;;
  arm64|aarch64)  arch="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Rosetta detection (macOS)
if [[ "$os" == "darwin" && "$arch" == "x64" ]]; then
  [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == "1" ]] && arch="arm64"
fi

if [[ "$os" == "linux" ]]; then
  if [[ -f /lib/libc.musl-x86_64.so.1 || -f /lib/libc.musl-aarch64.so.1 ]] \
     || ldd /bin/ls 2>&1 | grep -q musl; then
    platform="linux-${arch}-musl"
  else
    platform="linux-${arch}"
  fi
else
  platform="${os}-${arch}"
fi

# ── Resolve version ───────────────────────────────────────────────────────────

case "$TARGET" in
  stable|latest) version="$(download_file "$DOWNLOAD_BASE_URL/$TARGET")" ;;
  *)             version="$TARGET" ;;
esac

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "Error: could not resolve a valid version (got: '$version')" >&2; exit 1
fi

# ── Setup dirs ────────────────────────────────────────────────────────────────

echo "Install root : $INSTALL_DIR"
echo "Version      : $version ($TARGET)"
echo "Platform     : $platform"
echo ""
mkdir -p "$BIN_DIR" "$DOWNLOAD_DIR"

binary_path="$BIN_DIR/claude-$version-$platform"

# ── Download (skip if already cached) ────────────────────────────────────────

if [[ -f "$binary_path" ]]; then
  echo "Binary already present, skipping download."
else
  manifest_json="$(download_file "$DOWNLOAD_BASE_URL/$version/manifest.json")"

  if command -v jq >/dev/null 2>&1; then
    checksum=$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].checksum // empty")
  else
    checksum=$(get_checksum_from_manifest "$manifest_json" "$platform")
  fi

  if [[ -z "$checksum" || ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
    echo "Error: platform '$platform' not found in manifest" >&2; exit 1
  fi

  tmp_path="$DOWNLOAD_DIR/claude-$version-$platform.tmp"
  echo "Downloading ..."
  download_file "$DOWNLOAD_BASE_URL/$version/$platform/claude" "$tmp_path"

  if [[ "$os" == "darwin" ]]; then
    actual=$(shasum -a 256 "$tmp_path" | cut -d' ' -f1)
  else
    actual=$(sha256sum "$tmp_path" | cut -d' ' -f1)
  fi

  if [[ "$actual" != "$checksum" ]]; then
    echo "Error: checksum mismatch" >&2; rm -f "$tmp_path"; exit 1
  fi

  mv "$tmp_path" "$binary_path"
fi

chmod +x "$binary_path"

# ── Symlink (with fallback for Windows DrvFs) ─────────────────────────────────

current_link="$BIN_DIR/claude-current"
if "$IS_WSL" && is_windows_fs "$BIN_DIR"; then
  # Test symlink support on this filesystem
  if ln -sfn test "$BIN_DIR/.symlink_test" 2>/dev/null; then
    rm -f "$BIN_DIR/.symlink_test"
    ln -sfn "$(basename "$binary_path")" "$current_link"
  else
    # DrvFs without metadata — copy instead
    cp -f "$binary_path" "$current_link"
    chmod +x "$current_link"
  fi
else
  ln -sfn "$(basename "$binary_path")" "$current_link"
fi

# ── Launcher ──────────────────────────────────────────────────────────────────

cat > "$LAUNCHER_PATH" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_CONFIG_DIR="$SCRIPT_DIR/.claude"
exec "$SCRIPT_DIR/bin/claude-current" "$@"
EOF2
chmod +x "$LAUNCHER_PATH"

# ── Cleanup ───────────────────────────────────────────────────────────────────

rm -rf "$DOWNLOAD_DIR"

# ── Done ──────────────────────────────────────────────────────────────────────

echo "✔ Done"
echo "  Binary  : $binary_path"
echo "  Launcher: $LAUNCHER_PATH"
echo "  Config  : $INSTALL_DIR/.claude/  (created on first run)"
echo ""
echo "Run: $LAUNCHER_PATH --help"
