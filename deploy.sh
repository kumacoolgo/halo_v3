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

DC="docker compose"

# ================= Docker =================
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | bash
  systemctl enable --now docker
fi

# ================= 目录 =================
mkdir -p \
  v2ray \
  subscriptions \
  npm/data \
  npm/letsencrypt \
  halo \
  kvrocks

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
version: "3.8"
services:
  npm:
    image: jc21/nginx-proxy-manager
    ports: ["$NPM_HTTP_PORT:80","$NPM_HTTPS_PORT:443","$NPM_ADMIN_PORT:81"]
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

  v2ray:
    image: v2fly/v2fly-core
    volumes:
      - ./v2ray:/etc/v2ray
    command: run -c /etc/v2ray/config.json

  kvrocks:
    image: apache/kvrocks
    volumes:
      - ./kvrocks:/var/lib/kvrocks

  lunatv:
    image: ghcr.io/szemeng76/lunatv:latest
    environment:
      - USERNAME=$LUNATV_USER
      - PASSWORD=$(openssl rand -hex 6)
      - KVROCKS_URL=redis://kvrocks:6666
EOF

$DC up -d

# ================= NPM SQLite 写入 =================
info "写入 NPM 反代规则"
$DC stop npm

DB="npm/data/database.sqlite"

sqlite3 "$DB" <<EOF
INSERT OR IGNORE INTO proxy_host
(id, domain_names, forward_host, forward_port, enabled)
VALUES
(1, '["$DOMAIN"]', 'halo', 8090, 1);

INSERT OR IGNORE INTO proxy_host_location
(proxy_host_id, path, forward_host, forward_port)
VALUES
(1, '$WS_PATH', 'v2ray', 10000),
(1, '/tv', 'lunatv', 3000);
EOF

$DC start npm

# ================= VLESS 输出 =================
ENC_PATH="$(echo "$WS_PATH" | sed 's/\//%2F/g')"
> subscriptions/vless.txt

for i in "${!UUIDS[@]}"; do
  echo "vless://${UUIDS[$i]}@$DOMAIN:443?type=ws&path=$ENC_PATH&security=tls#${NAME}-$((i+1))" \
    >> subscriptions/vless.txt
done

base64 -w0 subscriptions/vless.txt > subscriptions/vless-sub.txt

echo ""
echo "================ 完成 ================"
echo "NPM: http://$DOMAIN:$NPM_ADMIN_PORT"
echo "订阅文件: subscriptions/vless-sub.txt"
echo "====================================="
