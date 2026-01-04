#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ================= 读取配置 =================
source "$BASE_DIR/config.env"

# ================= 工具 =================
die(){ echo -e "\033[31m❌ $1\033[0m"; exit 1; }
info(){ echo -e "\033[36m▶ $1\033[0m"; }

[[ $EUID -eq 0 ]] || die "请用 root 运行"
[[ -n "$DOMAIN" ]] || die "DOMAIN 未配置"
[[ "$WS_PATH" =~ ^/ ]] || die "WS_PATH 必须以 / 开头"

DC="docker compose"

# ================= Docker（阿里云源） =================
if ! command -v docker >/dev/null; then
  info "安装 Docker（阿里云 mirrors）"

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://mirrors.aliyun.com/docker-ce/linux/ubuntu \
$(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  systemctl enable --now docker
fi

# ================= 工具依赖 =================
if ! command -v jq >/dev/null; then
  info "安装 jq"
  apt-get update -y
  apt-get install -y jq
fi

# ================= 目录 =================
mkdir -p \
  v2ray \
  subscriptions \
  npm/data \
  npm/letsencrypt \
  halo

# ================= UUID（幂等） =================
USERS_FILE="v2ray/users.json"

if [[ -f $USERS_FILE ]]; then
  info "复用已有 UUID"
  UUIDS=($(jq -r '.[]' "$USERS_FILE"))
else
  info "首次生成 UUID"
  UUIDS=()
  for ((i=1;i<=USERS;i++)); do
    UUIDS+=("$(uuidgen)")
  done
  printf '%s\n' "${UUIDS[@]}" | jq -R . | jq -s . > "$USERS_FILE"
fi

# ================= V2Ray =================
cat > v2ray/config.json <<EOF
{
  "inbounds":[{
    "port":10000,
    "protocol":"vless",
    "settings":{
      "clients":[
$(printf '        {"id":"%s"},\n' "${UUIDS[@]}" | sed '$ s/,$//')
      ],
      "decryption":"none"
    },
    "streamSettings":{
      "network":"ws",
      "wsSettings":{"path":"$WS_PATH"}
    }
  }],
  "outbounds":[{"protocol":"freedom"}]
}
EOF

# ================= Docker Compose =================
cat > docker-compose.yml <<EOF
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    ports:
      - "$NPM_HTTP_PORT:80"
      - "$NPM_HTTPS_PORT:443"
      - "$NPM_ADMIN_PORT:81"
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
    restart: always

  halo:
    image: halohub/halo:2.22.4
    volumes:
      - ./halo:/root/.halo2
    environment:
      - HALO_EXTERNAL_URL=https://$DOMAIN
    restart: always

  v2ray:
    image: v2fly/v2fly-core:latest
    volumes:
      - ./v2ray:/etc/v2ray
    command: run -c /etc/v2ray/config.json
    restart: always
EOF

# ================= 启动 =================
info "启动容器"
$DC up -d

# ================= VLESS 输出 =================
ENC_PATH="$(echo "$WS_PATH" | sed 's/\//%2F/g')"
> subscriptions/vless.txt

for i in "${!UUIDS[@]}"; do
  echo "vless://${UUIDS[$i]}@$DOMAIN:443?encryption=none&type=ws&path=$ENC_PATH&security=tls&sni=$DOMAIN#${NAME}-$((i+1))" \
    >> subscriptions/vless.txt
done

base64 -w0 subscriptions/vless.txt > subscriptions/vless-sub.txt

echo ""
echo "================ 部署完成 ================"
echo "NPM 面板: http://$DOMAIN:$NPM_ADMIN_PORT"
echo "Halo: https://$DOMAIN"
echo ""
echo "VLESS 链接:"
cat subscriptions/vless.txt
echo ""
echo "订阅文件:"
echo "$BASE_DIR/subscriptions/vless-sub.txt"
echo "=========================================="
