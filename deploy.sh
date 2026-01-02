#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# 基础路径
# ==================================================
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==================================================
# 读取配置
# ==================================================
CONFIG_FILE="$BASE_DIR/config.env"
[[ -f "$CONFIG_FILE" ]] || { echo "❌ 缺少 config.env"; exit 1; }
source "$CONFIG_FILE"

# ==================================================
# 工具函数
# ==================================================
die(){ echo -e "\033[31m❌ $1\033[0m"; exit 1; }
info(){ echo -e "\033[36m▶ $1\033[0m"; }

# ==================================================
# 基础校验
# ==================================================
[[ $EUID -eq 0 ]] || die "请使用 root 运行"
[[ -n "${DOMAIN:-}" ]] || die "DOMAIN 未配置"
[[ -n "${USERS:-}" ]] || die "USERS 未配置"
[[ "$WS_PATH" =~ ^/ ]] || die "WS_PATH 必须以 / 开头"

command -v docker >/dev/null || die "未检测到 docker，请先安装 docker"
command -v jq >/dev/null || die "缺少 jq，请先安装 jq"
command -v sqlite3 >/dev/null || die "缺少 sqlite3，请先安装 sqlite3"

DC="docker compose"

# ==================================================
# 目录结构
# ==================================================
info "准备目录结构"
mkdir -p \
  "$BASE_DIR/v2ray" \
  "$BASE_DIR/subscriptions" \
  "$BASE_DIR/npm/data" \
  "$BASE_DIR/npm/letsencrypt" \
  "$BASE_DIR/halo" \
  "$BASE_DIR/kvrocks" \
  "$BASE_DIR/lunatv"

# ==================================================
# UUID（幂等）
# ==================================================
USERS_FILE="$BASE_DIR/v2ray/users.json"

if [[ -f "$USERS_FILE" ]]; then
  info "复用已有 UUID"
  mapfile -t UUIDS < <(jq -r '.[]' "$USERS_FILE")
else
  info "首次生成 UUID"
  UUIDS=()
  for ((i=1;i<=USERS;i++)); do
    UUIDS+=("$(uuidgen)")
  done
  printf '%s\n' "${UUIDS[@]}" | jq -R . | jq -s . > "$USERS_FILE"
fi

# ==================================================
# LunaTV 密码（幂等）
# ==================================================
LUNATV_PASS_FILE="$BASE_DIR/lunatv/password"

if [[ -f "$LUNATV_PASS_FILE" ]]; then
  LUNATV_PASS="$(cat "$LUNATV_PASS_FILE")"
else
  LUNATV_PASS="$(openssl rand -hex 6)"
  echo "$LUNATV_PASS" > "$LUNATV_PASS_FILE"
fi

# ==================================================
# V2Ray 配置
# ==================================================
info "生成 V2Ray 配置"

CLIENTS_JSON=$(printf '        {"id":"%s"},\n' "${UUIDS[@]}" | sed '$ s/,$//')

cat > "$BASE_DIR/v2ray/config.json" <<EOF
{
  "inbounds":[{
    "port":10000,
    "protocol":"vless",
    "settings":{
      "clients":[
$CLIENTS_JSON
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

# ==================================================
# Docker Compose
# ==================================================
info "生成 docker-compose.yml"

cat > "$BASE_DIR/docker-compose.yml" <<EOF
version: "3.8"
services:
  npm:
    image: jc21/nginx-proxy-manager:latest
    ports:
      - "${NPM_HTTP_PORT}:80"
      - "${NPM_HTTPS_PORT}:443"
      - "${NPM_ADMIN_PORT}:81"
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

  kvrocks:
    image: apache/kvrocks
    volumes:
      - ./kvrocks:/var/lib/kvrocks
    restart: unless-stopped

  lunatv:
    image: ghcr.io/szemeng76/lunatv:latest
    environment:
      - USERNAME=$LUNATV_USER
      - PASSWORD=$LUNATV_PASS
      - KVROCKS_URL=redis://kvrocks:6666
    restart: always
EOF

# ==================================================
# 启动服务
# ==================================================
info "启动 Docker 服务"
$DC up -d

# ==================================================
# NPM SQLite 反代写入（幂等）
# ==================================================
info "写入 NPM 反代规则"

$DC stop npm

DB="$BASE_DIR/npm/data/database.sqlite"
[[ -f "$DB" ]] || die "NPM 数据库未生成，请等待 npm 容器初始化后再运行一次 deploy.sh"

sqlite3 "$DB" <<EOF
INSERT OR IGNORE INTO proxy_host
(domain_names, forward_host, forward_port, enabled, access_list_id)
VALUES
('["$DOMAIN"]', 'halo', 8090, 1, 0);

INSERT OR IGNORE INTO proxy_host_location
(proxy_host_id, path, forward_host, forward_port)
SELECT id, '$WS_PATH', 'v2ray', 10000
FROM proxy_host WHERE domain_names='["$DOMAIN"]';

INSERT OR IGNORE INTO proxy_host_location
(proxy_host_id, path, forward_host, forward_port)
SELECT id, '/tv', 'lunatv', 3000
FROM proxy_host WHERE domain_names='["$DOMAIN"]';
EOF

$DC start npm

# ==================================================
# VLESS 输出
# ==================================================
info "生成 VLESS 链接"

ENC_PATH="$(echo "$WS_PATH" | sed 's/\//%2F/g')"
> "$BASE_DIR/subscriptions/vless.txt"

for i in "${!UUIDS[@]}"; do
  echo "vless://${UUIDS[$i]}@$DOMAIN:443?encryption=none&type=ws&path=$ENC_PATH&security=tls&sni=$DOMAIN#${NAME}-$((i+1))" \
    >> "$BASE_DIR/subscriptions/vless.txt"
done

base64 -w0 "$BASE_DIR/subscriptions/vless.txt" > "$BASE_DIR/subscriptions/vless-sub.txt"

# ==================================================
# 完成
# ==================================================
echo ""
echo "================ 部署完成 ================"
echo "NPM 管理面板: http://$DOMAIN:$NPM_ADMIN_PORT"
echo "LunaTV 用户名: $LUNATV_USER"
echo "LunaTV 密码:   $LUNATV_PASS"
echo "订阅文件:     subscriptions/vless-sub.txt"
echo "=========================================="
