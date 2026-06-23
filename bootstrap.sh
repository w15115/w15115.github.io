#!/usr/bin/env bash
#
# Claude Workspace BOOTSTRAP (đặt file này ở nơi PUBLIC: 1 repo/gist công khai).
# Nó KHÔNG chứa bí mật gì. Việc của nó:
#   1. Cài GitHub CLI `gh` nếu máy chưa có.
#   2. Đăng nhập GitHub bằng TRÌNH DUYỆT (gh auth login --web) — không cần dán token.
#   3. Dùng credential của gh để clone repo CONFIG private rồi chạy install.sh trong đó.
#
# Dùng:
#   curl -fsSL https://<public-host>/bootstrap.sh | bash
#
# Tuỳ chọn (env): CONFIG_REPO, BRANCH, MODE, DEST  — xem install.sh.
#
set -euo pipefail

# Profile: tham số đầu tiên ($1) hoặc env PROFILE; mặc định "default".
#   curl ... | bash -s -- work     -> cài profile "work"
PROFILE="${1:-${PROFILE:-default}}"

# Repo CONFIG private của bạn (chỉ cần "owner/name" cho gh).
CONFIG_REPO="${CONFIG_REPO:-w15115/claude}"
BRANCH="${BRANCH:-main}"
# Mỗi profile có repo clone riêng để không xung đột.
if [ "$PROFILE" = "default" ]; then
  DEST="${DEST:-$HOME/.claude-workspace}"
else
  DEST="${DEST:-$HOME/.claude-profiles/$PROFILE/.workspace}"
fi

log()  { printf '\033[0;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "Cần cài git trước."

# ----------------------------------------------------------------------------
# 1. Đảm bảo có `gh`
# ----------------------------------------------------------------------------
# Cài gh KHÔNG cần sudo: tải binary release chính thức về ~/.local/bin.
# Đây là cách bền nhất (không đụng /usr, không cần mật khẩu).
install_gh_nosudo() {
  local bindir="$HOME/.local/bin"
  local arch ghos asset url ver tmp
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    armv6l|armv7l) arch="armv6" ;;
    *) warn "Kiến trúc $(uname -m) chưa hỗ trợ tải binary."; return 1 ;;
  esac
  case "$(uname -s)" in
    Linux) ghos="linux" ;;
    Darwin) ghos="macOS" ;;
    *) warn "OS $(uname -s) chưa hỗ trợ tải binary."; return 1 ;;
  esac
  # Lấy version mới nhất từ GitHub API (không cần auth cho public release).
  ver="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
        | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$ver" ] || { warn "Không lấy được version gh mới nhất."; return 1; }
  if [ "$ghos" = "macOS" ]; then
    asset="gh_${ver}_macOS_${arch}.zip"
  else
    asset="gh_${ver}_linux_${arch}.tar.gz"
  fi
  url="https://github.com/cli/cli/releases/download/v${ver}/${asset}"
  tmp="$(mktemp -d)"
  log "Tải gh v${ver} ($asset) về $bindir (không cần sudo)..."
  curl -fsSL "$url" -o "$tmp/$asset" || { warn "Tải gh thất bại."; return 1; }
  mkdir -p "$bindir"
  if [ "$ghos" = "macOS" ]; then
    (cd "$tmp" && unzip -q "$asset")
  else
    tar -xzf "$tmp/$asset" -C "$tmp"
  fi
  cp "$tmp"/gh_*/bin/gh "$bindir/gh"
  chmod +x "$bindir/gh"
  rm -rf "$tmp"
  export PATH="$bindir:$PATH"
}

if ! command -v gh >/dev/null 2>&1; then
  log "Chưa có GitHub CLI (gh) — đang cài (ưu tiên không cần sudo)..."
  install_gh_nosudo || {
    warn "Cài không-sudo thất bại; thử package manager (có thể hỏi sudo)..."
    if   command -v brew >/dev/null 2>&1; then brew install gh
    elif command -v apt-get >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo apt-get update && sudo apt-get install -y gh
    else
      die "Không cài được gh tự động. Cài thủ công: https://cli.github.com  rồi chạy lại."
    fi
  }
fi
command -v gh >/dev/null 2>&1 || die "Cài gh không thành công."

# ----------------------------------------------------------------------------
# 2. Đăng nhập GitHub qua trình duyệt (nếu chưa đăng nhập)
# ----------------------------------------------------------------------------
if ! gh auth status >/dev/null 2>&1; then
  log "Mở trang đăng nhập GitHub. Làm theo mã hiển thị trên màn hình..."
  # --web: device flow, in mã + URL https://github.com/login/device.
  # Nếu môi trường không mở được trình duyệt, gh vẫn IN ra URL+mã để bạn tự mở.
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth status >/dev/null 2>&1 || die "Vẫn chưa đăng nhập được GitHub."

# Cho git dùng credential của gh.
gh auth setup-git >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# 3. Clone repo config private rồi chạy install.sh bên trong
# ----------------------------------------------------------------------------
log "Clone repo cấu hình $CONFIG_REPO ..."
if [ -d "$DEST/.git" ]; then
  git -C "$DEST" fetch --quiet origin "$BRANCH"
  git -C "$DEST" reset --hard --quiet "origin/$BRANCH"
else
  gh repo clone "$CONFIG_REPO" "$DEST" -- --branch "$BRANCH" --quiet
fi

[ -f "$DEST/install.sh" ] || die "Repo không có install.sh."

log "Chạy install.sh ..."
# Repo đã clone xong ở trên -> báo install.sh đừng clone lại. Truyền profile qua $1.
DEST="$DEST" BRANCH="$BRANCH" SKIP_CLONE=1 bash "$DEST/install.sh" "$PROFILE"

log "Xong! Đã đăng nhập bằng trình duyệt và áp dụng cấu hình Claude."
