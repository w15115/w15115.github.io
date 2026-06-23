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

# Repo CONFIG private của bạn (chỉ cần "owner/name" cho gh).
CONFIG_REPO="${CONFIG_REPO:-w15115/claude}"
BRANCH="${BRANCH:-main}"
DEST="${DEST:-$HOME/.claude-workspace}"

log()  { printf '\033[0;36m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "Cần cài git trước."

# ----------------------------------------------------------------------------
# 1. Đảm bảo có `gh`
# ----------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  log "Chưa có GitHub CLI (gh) — đang thử cài..."
  if   command -v apt-get >/dev/null 2>&1; then
    # cài gh theo hướng dẫn chính thức (cần sudo)
    (type -p wget >/dev/null || sudo apt-get install -y wget) \
      && sudo mkdir -p -m 755 /etc/apt/keyrings \
      && wget -nv -O- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
      && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
      && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
      && sudo apt-get update && sudo apt-get install -y gh
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y 'dnf-command(config-manager)' \
      && sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo \
      && sudo dnf install -y gh
  elif command -v brew >/dev/null 2>&1; then
    brew install gh
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm github-cli
  else
    die "Không tự cài được gh. Hãy cài thủ công: https://cli.github.com  rồi chạy lại."
  fi
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
# Repo đã clone xong ở trên -> báo install.sh đừng clone lại.
DEST="$DEST" BRANCH="$BRANCH" SKIP_CLONE=1 bash "$DEST/install.sh"

log "Xong! Đã đăng nhập bằng trình duyệt và áp dụng cấu hình Claude."
