#!/usr/bin/env bash
set -euo pipefail

# ================= 基础配置 =================
BASE_DIR="/opt/halo-stack"

DOMAIN=""
WS_PATH="/connect"
NAME="halo"
USERS="3"
DRY_RUN=false
UNINSTALL=false

# ================= 工具函数 =================
die(){ echo -e "\033[31m❌ $1\033[0m"; exit 1; }
info(){ echo -e "\033[36m▶ $1\033[0m"; }
warn(){ echo -e "\033[33m⚠️ $1\033[0m"; }

run() {
  if $DRY_RUN; then
    echo "[dry-run] $*"
  else
    eval "$@"
  fi
}

# ================= 参数解析 =================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --ws-path) WS_PATH="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --users) USERS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    *) die "未知参数 $1" ;;
  esac
done

# ================= 基础校验 =================
[[ $EUID -eq 0 ]] || die "请用 root 运行"
[[ -n "$DOMAIN" ]] || die "--domain 必填"
[[ "$WS_PATH" =~ ^/ ]] || die "--ws-path 必须以 / 开头"

# ================= Docker 安装（稳定方案） =================
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    info "Docker 已安装，跳过"
    return
  fi

  info "使用镜像源安装 Docker（稳定方式）"

  run "apt-get update -y"
  run "apt-get install -y ca-certificates curl gnupg lsb-release"

  run "mkdir -p /etc/apt/keyrings"

  run "curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"

  run "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://mirrors.aliyun.com/docker-ce/linux/ubuntu \
    \$(lsb_release -cs) stable\" \
    > /etc/apt/sources.list.d/docker.list"

  run "apt-get update -y"

  run "apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin"

  run "systemctl enable docker"
  run "systemctl start docker"

  info "Docker 安装完成"
}

# ================= Docker Compose =================
DC_CMD="docker compose"

# ================= 卸载 =================
if $UNINSTALL; then
  cd "$BASE_DIR" 2>/dev/null || exit 0
  run "$DC_CMD down || true"
  run "rm -rf $BASE_DIR"
  echo "✅ 已卸载"
  exit 0
fi

# ================= 执行安装 =================
install_docker

info "安装系统依赖"
run "apt-get install -y ufw openssl sqlite3"

info "创建目录结构"
run "mkdir -p $BASE_DIR/{npm/data,npm/letsencrypt,halo,v2ray,lunatv,kvrocks,subscriptions}"
cd "$BASE_DIR"

# ================= VLESS 用户生成 =================
info "生成 VLESS 用户"
UUIDS=()
for ((i=1;i<=USERS;i++)); do
  UUIDS+=("$(cat /proc/sys/kernel/random/uuid)")
done

# ================= LunaTV 账号 =================
LUNATV_USER="admin"
LUNATV_PASS="$(openssl rand -hex 6)"

# ================= V2Ray 配置 =================
info "写入 V2Ray 配置"
{
  echo '{'
  echo ' "inbounds": [{'
  echo '  "port": 10000,'
  echo '  "protocol": "vless",'
  echo '  "settings": {'
  echo '   "clients": ['
  for ((i=0;i<${#UUIDS[@]};i++)); do
    [[ $i -gt 0 ]] && echo ','
    echo -n "    {\"id\":\"${UUIDS[$i]}\"}"
  done
  echo
  echo '   ], "decryption":"none"'
  echo '  },'
  echo '  "streamSettings": { "network":"ws","wsSettings":{"path":"'"$WS_PATH"'"}}'
  echo ' }],'
  echo ' "outbounds":[{"protocol":"freedom"}]'
  echo '}'
} > v2ray/config.json

# ================= Docker Compose =================
info "写入 docker-compose.yml"
cat > docker-compose.yml <<EOF
version: "3.8"
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
    restart: always
    networks: [proxy]

  halo:
    image: halohub/halo:2.22.4
    volumes:
      - ./halo:/root/.halo2
    environment:
      - HALO_EXTERNAL_URL=https://$DOMAIN
    expose: ["8090"]
    restart: always
    networks: [proxy]

  v2ray:
    image: v2fly/v2fly-core:latest
    volumes:
      - ./v2ray:/etc/v2ray
    command: run -c /etc/v2ray/config.json
    restart: always
    networks: [proxy]

  kvrocks:
    image: apache/kvrocks
    volumes:
      - ./kvrocks:/var/lib/kvrocks
    restart: unless-stopped
    networks: [proxy]

  lunatv:
    image: ghcr.io/szemeng76/lunatv:latest
    environment:
      - USERNAME=$LUNATV_USER
      - PASSWORD=$LUNATV_PASS
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://kvrocks:6666
      - SITE_BASE=https://$DOMAIN/tv
    expose: ["3000"]
    depends_on: [kvrocks]
    restart: always
    networks: [proxy]

networks:
  proxy:
    driver: bridge
EOF

# ================= 启动 =================
info "启动服务"
run "$DC_CMD up -d"

# ================= VLESS 输出 =================
info "生成 VLESS 链接"
ENC_PATH="$(printf "%s" "$WS_PATH" | sed 's/\//%2F/g')"

> vless.txt
for ((i=0;i<${#UUIDS[@]};i++)); do
  echo "vless://${UUIDS[$i]}@$DOMAIN:443?encryption=none&type=ws&path=$ENC_PATH&security=tls&sni=$DOMAIN#${NAME}-$((i+1))" >> vless.txt
done

base64 -w0 vless.txt > subscriptions/vless-sub.txt

# ================= 完成输出 =================
echo ""
echo "================ 部署完成 ================"
echo "NPM 管理面板: http://$DOMAIN:81"
echo "LunaTV 用户名: $LUNATV_USER"
echo "LunaTV 密码:   $LUNATV_PASS"
echo ""
echo "VLESS 链接:"
cat vless.txt
echo ""
echo "订阅文件:"
echo "$BASE_DIR/subscriptions/vless-sub.txt"
echo "=========================================="    restart: always
    networks: [proxy]

networks:
  proxy:
    driver: bridge
EOF

info "启动服务"
run "$DC_CMD up -d"

info "生成 VLESS 链接"
ENC_PATH="$(printf "%s" "$WS_PATH" | sed 's/\//%2F/g')"
> vless.txt
for ((i=0;i<${#UUIDS[@]};i++)); do
  echo "vless://${UUIDS[$i]}@$DOMAIN:443?encryption=none&type=ws&path=$ENC_PATH&security=tls&sni=$DOMAIN#${NAME}-$((i+1))" >> vless.txt
done
base64 -w0 vless.txt > subscriptions/vless-sub.txt

echo ""
echo "================ 部署完成 ================"
echo "NPM: http://$DOMAIN:81"
echo "LunaTV 用户名: $LUNATV_USER"
echo "LunaTV 密码:   $LUNATV_PASS"
echo ""
echo "VLESS 链接:"
cat vless.txt
echo ""
echo "订阅文件:"
echo "$BASE_DIR/subscriptions/vless-sub.txt"
echo "=========================================="
