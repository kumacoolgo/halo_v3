#!/usr/bin/env bash
set -euo pipefail

REPO="你的GitHub用户名/halo-v3"   # ←←← 改这里
BIN="/usr/local/bin/halo-vps-deploy"
TMP="/tmp/halo-vps-deploy"

die(){ echo -e "\033[31m❌ $*\033[0m" >&2; exit 1; }
info(){ echo -e "\033[36m▶ $*\033[0m"; }

ARGS="$*"

mkdir -p "$TMP"
cd "$TMP"

info "下载 deploy.sh"
curl -fsSL \
  "https://raw.githubusercontent.com/${REPO}/main/deploy.sh" \
  -o deploy.sh || die "无法下载 deploy.sh"

chmod +x deploy.sh

info "安装到 $BIN"
cp deploy.sh "$BIN"
chmod +x "$BIN"

info "开始部署..."
exec "$BIN" $ARGS
