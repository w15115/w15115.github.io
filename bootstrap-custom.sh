#!/usr/bin/env bash
set -euo pipefail

ROOT_NAME="claude-code"

usage() {
  cat <<'USAGE'
Usage: bootstrap-custom.sh [BASE_DIR] [stable|latest|VERSION]

  Creates a '<BASE_DIR>/claude-code/' root directory and installs everything there.

Examples:
  ./bootstrap-custom.sh                          # installs to $PWD/claude-code/
  ./bootstrap-custom.sh /opt                     # installs to /opt/claude-code/
  ./bootstrap-custom.sh ~/tools latest           # installs to ~/tools/claude-code/
  ./bootstrap-custom.sh ~/tools 2.1.177          # installs specific version

Layout after install:
  <BASE_DIR>/claude-code/
    bin/          <- actual Claude binaries
    downloads/    <- temporary download cache
    claude        <- launcher script
USAGE
}

is_version() {
  [[ "$1" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?)$ ]]
}

BASE_DIR="${1:-$PWD}"
TARGET="${2:-stable}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -eq 1 ]] && is_version "$1"; then
  BASE_DIR="$PWD"
  TARGET="$1"
fi

if ! is_version "$TARGET"; then
  echo "Usage: $0 [BASE_DIR] [stable|latest|VERSION]" >&2
  exit 1
fi

BASE_DIR="${BASE_DIR/#\~/$HOME}"
INSTALL_DIR="$BASE_DIR/$ROOT_NAME"
BIN_DIR="$INSTALL_DIR/bin"
DOWNLOAD_DIR="$INSTALL_DIR/downloads"
LAUNCHER_PATH="$INSTALL_DIR/claude"
DOWNLOAD_BASE_URL="https://downloads.claude.ai/claude-code-releases"

echo "Install root: $INSTALL_DIR"
mkdir -p "$BIN_DIR" "$DOWNLOAD_DIR"

DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  echo "Either curl or wget is required but neither is installed" >&2
  exit 1
fi

HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
  HAS_JQ=true
fi

download_file() {
  local url="$1"
  local output="${2:-}"
  if [[ "$DOWNLOADER" == "curl" ]]; then
    if [[ -n "$output" ]]; then
      curl -fsSL -o "$output" "$url"
    else
      curl -fsSL "$url"
    fi
  else
    if [[ -n "$output" ]]; then
      wget -q -O "$output" "$url"
    else
      wget -q -O - "$url"
    fi
  fi
}

get_checksum_from_manifest() {
  local json="$1"
  local platform="$2"
  json=$(echo "$json" | tr -d '\n\r\t' | sed 's/ \+/ /g')
  if [[ $json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

case "$(uname -s)" in
  Darwin) os="darwin" ;;
  Linux) os="linux" ;;
  MINGW*|MSYS*|CYGWIN*) echo "Windows is not supported by this script. See https://code.claude.com/docs for installation options." >&2; exit 1 ;;
  *) echo "Unsupported operating system: $(uname -s)." >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch="x64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [[ "$os" == "darwin" && "$arch" == "x64" ]]; then
  if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
    arch="arm64"
  fi
fi

if [[ "$os" == "linux" ]]; then
  if [[ -f /lib/libc.musl-x86_64.so.1 || -f /lib/libc.musl-aarch64.so.1 ]] || ldd /bin/ls 2>&1 | grep -q musl; then
    platform="linux-${arch}-musl"
  else
    platform="linux-${arch}"
  fi
else
  platform="${os}-${arch}"
fi

resolve_version() {
  case "$TARGET" in
    stable|latest) download_file "$DOWNLOAD_BASE_URL/$TARGET" ;;
    *) printf '%s' "$TARGET" ;;
  esac
}

version="$(resolve_version)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  echo "Failed to get a valid version from downloads.claude.ai." >&2
  exit 1
fi

manifest_json="$(download_file "$DOWNLOAD_BASE_URL/$version/manifest.json")"
if [[ "$HAS_JQ" == true ]]; then
  checksum=$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].checksum // empty")
else
  checksum=$(get_checksum_from_manifest "$manifest_json" "$platform")
fi

if [[ -z "$checksum" || ! "$checksum" =~ ^[a-f0-9]{64}$ ]]; then
  echo "Platform $platform not found in manifest" >&2
  exit 1
fi

binary_path="$BIN_DIR/claude-$version-$platform"
tmp_path="$DOWNLOAD_DIR/claude-$version-$platform.download"

echo "Downloading Claude Code $version for $platform ..."
download_file "$DOWNLOAD_BASE_URL/$version/$platform/claude" "$tmp_path"

if [[ "$os" == "darwin" ]]; then
  actual=$(shasum -a 256 "$tmp_path" | cut -d' ' -f1)
else
  actual=$(sha256sum "$tmp_path" | cut -d' ' -f1)
fi

if [[ "$actual" != "$checksum" ]]; then
  echo "Checksum verification failed" >&2
  rm -f "$tmp_path"
  exit 1
fi

mv "$tmp_path" "$binary_path"
chmod +x "$binary_path"
ln -sfn "$(basename "$binary_path")" "$BIN_DIR/claude-current"

cat > "$LAUNCHER_PATH" <<EOF2
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_CONFIG_DIR="\$SCRIPT_DIR/.claude"
exec "\$SCRIPT_DIR/bin/claude-current" "\$@"
EOF2
chmod +x "$LAUNCHER_PATH"

echo ""
echo "✔ Claude Code downloaded successfully"
echo "  Version : $version"
echo "  Root    : $INSTALL_DIR"
echo "  Binary  : $binary_path"
echo "  Launcher: $LAUNCHER_PATH"
echo ""
echo "Run: $LAUNCHER_PATH --help"
