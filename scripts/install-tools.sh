#!/usr/bin/env bash
# Install the two tools localhost2cloud needs.
#
# Installs cloudflared (the tunnel) and caddy (the single-origin gateway).
# Prefers the platform package manager, falls back to the official release
# binary. Safe to re-run; skips anything already installed.
#
# Usage:
#   ./install-tools.sh [--dir /usr/local/bin]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./common.sh
. "$SCRIPT_DIR/common.sh"

DEST_DIR='/usr/local/bin'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) DEST_DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

need_sudo=''
[ -w "$DEST_DIR" ] || need_sudo='sudo'

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) arch='amd64' ;;
  aarch64|arm64) arch='arm64' ;;
  *) die "Unsupported architecture: $arch" ;;
esac

say() { step "$*"; }

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    ok "already installed: $(command -v cloudflared)"
    return 0
  fi
  say "cloudflared"
  case "$os" in
    darwin)
      if command -v brew >/dev/null 2>&1; then
        ok "installing via brew"
        brew install cloudflared && return 0
      fi
      ;;
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        ok "installing via apt (Cloudflare repo)"
        $need_sudo mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg \
          | $need_sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
        echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' \
          | $need_sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
        $need_sudo apt-get update -qq && $need_sudo apt-get install -y cloudflared && return 0
      fi
      ;;
  esac
  ok "downloading release binary"
  $need_sudo curl -fsSL \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${os}-${arch}" \
    -o "$DEST_DIR/cloudflared" && $need_sudo chmod +x "$DEST_DIR/cloudflared" \
    && ok "$DEST_DIR/cloudflared"
}

install_caddy() {
  if command -v caddy >/dev/null 2>&1; then
    ok "already installed: $(command -v caddy)"
    return 0
  fi
  say "caddy"
  if command -v brew >/dev/null 2>&1; then
    ok "installing via brew"
    brew install caddy && return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    ok "installing via apt (Caddy repo)"
    $need_sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | $need_sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | $need_sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    $need_sudo apt-get update -qq && $need_sudo apt-get install -y caddy && return 0
  fi
  if command -v dnf >/dev/null 2>&1; then
    ok "installing via dnf copr"
    $need_sudo dnf install -y 'dnf-command(copr)' && $need_sudo dnf copr enable -y @caddy/caddy \
      && $need_sudo dnf install -y caddy && return 0
  fi
  ok "downloading release binary"
  # Caddy ships as a tarball containing the binary plus README/LICENSE.
  local tmp; tmp="$(mktemp -d)"
  curl -fsSL "https://caddyserver.com/api/download?os=${os}&arch=${arch}" -o "$tmp/caddy" \
    && $need_sudo install -m 0755 "$tmp/caddy" "$DEST_DIR/caddy" \
    && rm -rf "$tmp" && ok "$DEST_DIR/caddy"
}

install_cloudflared || die "cloudflared install failed"
install_caddy || die "caddy install failed"

printf '\n'
printf '%sDone. If a tool landed outside PATH, start.sh also accepts --caddy / --cloudflared paths.%s\n' \
  "$C_GREEN" "$C_RESET"
