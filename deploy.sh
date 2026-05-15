#!/usr/bin/env bash
# Kiro-Go VPS deployment script
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Junyao227/Kiro-Go/main/deploy.sh | bash
#   # or after git clone:
#   bash deploy.sh
#
# Options (env vars):
#   ADMIN_PASSWORD   admin panel password (required, no default)
#   PORT             service port (default: 8080)
#   INSTALL_DIR      install directory (default: /opt/kiro-go)
#   GO_VERSION       Go version to install if missing (default: 1.21.13)
#   USE_SYSTEMD      register as systemd service (default: 1)
#   REPO_URL         git repo URL (default: https://github.com/Junyao227/Kiro-Go.git)
#   BRANCH           git branch (default: main)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Junyao227/Kiro-Go.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/kiro-go}"
GO_VERSION="${GO_VERSION:-1.21.13}"
PORT="${PORT:-8080}"
USE_SYSTEMD="${USE_SYSTEMD:-1}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"

C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_RED='\033[0;31m'
C_RESET='\033[0m'

log()  { echo -e "${C_GREEN}[+]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[x]${C_RESET} $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      err "this script needs root or sudo"
      exit 1
    fi
  else
    SUDO=""
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l) echo "armv6l" ;;
    *) err "unsupported arch: $(uname -m)"; exit 1 ;;
  esac
}

ensure_packages() {
  log "checking required packages (git, curl, ca-certificates, tar)"
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y git curl ca-certificates tar
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y git curl ca-certificates tar
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y git curl ca-certificates tar
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache git curl ca-certificates tar bash
  else
    warn "unknown package manager — make sure git/curl/tar are installed"
  fi
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    local ver
    ver="$(go version | awk '{print $3}' | sed 's/^go//')"
    log "found Go $ver"
    # crude version check: 1.21+
    local major minor
    major="$(echo "$ver" | cut -d. -f1)"
    minor="$(echo "$ver" | cut -d. -f2)"
    if [[ "$major" -gt 1 || ( "$major" -eq 1 && "$minor" -ge 21 ) ]]; then
      return 0
    fi
    warn "Go $ver is below 1.21, will install Go $GO_VERSION"
  else
    log "Go not found, installing $GO_VERSION"
  fi

  local arch
  arch="$(detect_arch)"
  local tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
  local url="https://go.dev/dl/${tarball}"

  log "downloading $url"
  curl -fsSL -o "/tmp/${tarball}" "$url"

  log "installing Go to /usr/local/go"
  $SUDO rm -rf /usr/local/go
  $SUDO tar -C /usr/local -xzf "/tmp/${tarball}"
  rm -f "/tmp/${tarball}"

  if [[ ":$PATH:" != *":/usr/local/go/bin:"* ]]; then
    export PATH="$PATH:/usr/local/go/bin"
  fi
  if ! grep -qs '/usr/local/go/bin' /etc/profile.d/go.sh 2>/dev/null; then
    echo 'export PATH=$PATH:/usr/local/go/bin' | $SUDO tee /etc/profile.d/go.sh >/dev/null
    $SUDO chmod 644 /etc/profile.d/go.sh
  fi

  go version
}

clone_or_update() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "updating existing repo at $INSTALL_DIR"
    $SUDO git -C "$INSTALL_DIR" fetch --depth=1 origin "$BRANCH"
    $SUDO git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH"
  else
    log "cloning $REPO_URL into $INSTALL_DIR"
    $SUDO mkdir -p "$(dirname "$INSTALL_DIR")"
    $SUDO git clone --depth=1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
  fi
}

build_binary() {
  log "building kiro-go binary"
  cd "$INSTALL_DIR"
  $SUDO env PATH="$PATH" CGO_ENABLED=0 go build -ldflags="-s -w" -o kiro-go .
  $SUDO mkdir -p "$INSTALL_DIR/data"
  $SUDO chmod 750 "$INSTALL_DIR/data"
}

install_systemd() {
  local pwd_value="${ADMIN_PASSWORD}"
  if [[ -z "$pwd_value" ]]; then
    warn "ADMIN_PASSWORD not set — generating a random one"
    pwd_value="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
    echo "    generated admin password: $pwd_value"
    echo "    keep it safe, you can change it later in the admin panel"
  fi

  local unit_file=/etc/systemd/system/kiro-go.service
  log "writing systemd unit $unit_file"
  $SUDO tee "$unit_file" >/dev/null <<EOF
[Unit]
Description=Kiro-Go API Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/kiro-go
Environment=ADMIN_PASSWORD=${pwd_value}
Environment=LOG_LEVEL=info
Environment=CONFIG_PATH=${INSTALL_DIR}/data/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  $SUDO chmod 600 "$unit_file"
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable kiro-go >/dev/null 2>&1 || true
  $SUDO systemctl restart kiro-go
  sleep 2
  $SUDO systemctl --no-pager --full status kiro-go || true
}

print_summary() {
  local ip
  ip="$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || echo 'YOUR_VPS_IP')"
  cat <<EOF

------------------------------------------------------------
Kiro-Go deployed successfully.

  Install dir : ${INSTALL_DIR}
  Service     : systemctl status kiro-go
  Logs        : journalctl -u kiro-go -f
  Admin panel : http://${ip}:${PORT}/admin
  Claude API  : http://${ip}:${PORT}/v1/messages
  OpenAI API  : http://${ip}:${PORT}/v1/chat/completions

Open the admin panel, log in, and add your Kiro accounts.
Strongly recommended: enable API key auth in Settings
before exposing this port to the public internet.

To update later:
  cd ${INSTALL_DIR} && git pull && go build -o kiro-go . && sudo systemctl restart kiro-go
------------------------------------------------------------
EOF
}

main() {
  require_root
  ensure_packages
  ensure_go
  clone_or_update
  build_binary
  if [[ "$USE_SYSTEMD" == "1" ]]; then
    install_systemd
  else
    log "USE_SYSTEMD=0, skipping systemd setup"
    log "to start manually: cd ${INSTALL_DIR} && ADMIN_PASSWORD=xxx ./kiro-go"
  fi
  print_summary
}

main "$@"
