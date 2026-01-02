#!/usr/bin/env bash
set -euo pipefail

REPO="kumacoolgo/halo_v3"
BIN="/usr/local/bin/halo-vps-deploy"
TMP="/tmp/halo-vps-deploy"

die(){ echo -e "\033[31m❌ $*\033[0m" >&2; exit 1; }
info(){ echo -e "\033[36m▶ $*\033[0m"; }

ARGS="$*"

mkdir -p "$TMP"
cd "$TMP"

download_deploy() {
  for url in \
    "https://cdn.jsdelivr.net/gh/${REPO}@main/deploy.sh" 
  do
    info "尝试下载 deploy.sh: $url"
    if curl -fsSL \
      --connect-timeout 5 \
      --max-time 10 \
      "$url" -o deploy.sh
    then
      info "✔ 成功从该地址下载 deploy.sh"
      return 0
    else
      info "✖ 该地址不可用，尝试下一个"
    fi
  done
  die "无法从任何镜像下载 deploy.sh"
}

info "下载 deploy.sh"
download_deploy

chmod +x deploy.sh

info "安装到 $BIN"
cp deploy.sh "$BIN"
chmod +x "$BIN"

info "开始执行部署"
exec "$BIN" $ARGS
