#!/usr/bin/env bash
set -euo pipefail

# ================= 基础 =================
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE_DIR"

# ================= 读取配置 =================
source "$BASE_DIR/config.env"

# ================= 工具函数 =================
die(){ echo -e "\033[31m❌ $1\033[0m"; exit 1; }
info(){ echo -e "\033[36m▶ $1\033[0m"; }

# ================= 校验 =================
[[ $EUID -eq 0 ]] || die "请用 root 运行"
[[ -n "${DOMAIN:-}" ]] || die "config.env 中未配置 DOMAIN"
[[ -n "${WS_PATH:-}" ]] || die "config.env 中未配置 WS_PATH"
[[ "$WS_PATH" =~ ^/ ]] || die "WS_PATH 必须以 / 开头"

DC="docker compose"

# ================= Docker 检查 =================
if ! command -v docker >/dev/null 2>&1; then
  die "Docker 未安装，请先手动安装并配置镜像加速"
fi

# ================= 依赖 =================
apt-get update -y >/dev/null
apt-get install -y jq sqlite3 openssl >/dev/null

# ================= 目录 =================
info "初始化目录结构"
mkdir -p \
  v2ray \
  subscriptions \
  npm/data \
  npm/letsencrypt \
  halo \
  kvrocks

# ================= UUID（幂等） =================
USERS_FILE="v2ray/users.json"
UUIDS=()

if [[ -f "$USERS_FILE" ]]; then
  info "复用已有 UUID"
  mapfile -t UUIDS < <(jq -r '.[]' "$USERS_FILE")
else
  info "首次生成 UUID"
  for ((i=1;i<=USERS;i++)); do
    UUIDS+=("$(uuidgen)")
  done
  printf '%s\n' "${UUIDS[@]}" | jq -R . | jq -s . > "$USERS_FILE"
fi

# ================= V2Ray 配置 =================
info "写入 V2Ray 配置"
cat > v2ray/config.json <<EOF
{
  "inbounds": [{
    "port": 10000,
    "protocol": "vless",
    "settings": {
      "clients": [
$(printf '        {"id":"%s"},\n' "${UUIDS[@]}" | sed '$ s/,$//')
      ],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": { "path": "$WS_PATH" }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# ================= LunaTV 密码（幂等） =================
if [[ ! -f lunatv/.env ]]; then
  info "生成 LunaTV 初始密码"
  mkdir -p lunatv
  echo "LUNATV_PASSWORD=$(openssl rand -hex 6)" > lunatv/.env
fi
source lunatv/.env

# ================= Docker Compose =================
info "生成 docker-compose.yml"
cat > docker-compose.yml <<EOF
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
      - HALO_EXTERNAL_URL=https://${DOMAIN}
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
    restart: always

  lunatv:
    image: ghcr.io/szemeng76/lunatv:latest
    environment:
      - USERNAME=${LUNATV_USER}
      - PASSWORD=${LUNATV_PASSWORD}
      - NEXT_PUBLIC_STORAGE_TYPE=kvrocks
      - KVROCKS_URL=redis://kvrocks:6666
      - SITE_BASE=https://${DOMAIN}/tv
    depends_on:
      - kvrocks
    restart: always
EOF

# ================= 启动 =================
info "启动 Docker 服务"
$DC up -d

# ================= NPM SQLite 反代写入 =================
info "写入 NPM 反代规则（SQLite）"
$DC stop npm

DB="npm/data/database.sqlite"
[[ -f "$DB" ]] || die "NPM 数据库不存在，npm 未正确启动"

sqlite3 "$DB" <<EOF
INSERT OR IGNORE INTO proxy_host
(id, domain_names, forward_host, forward_port, enabled)
VALUES
(1, '["${DOMAIN}"]', 'halo', 8090, 1);

INSERT OR IGNORE INTO proxy_host_location
(proxy_host_id, path, forward_host, forward_port)
VALUES
(1, '${WS_PATH}', 'v2ray', 10000),
(1, '/tv', 'lunatv', 3000);
EOF

$DC start npm

# ================= VLESS 输出 =================
info "生成 VLESS 订阅"
ENC_PATH="$(echo "$WS_PATH" | sed 's/\//%2F/g')"
> subscriptions/vless.txt

for i in "${!UUIDS[@]}"; do
  echo "vless://${UUIDS[$i]}@${DOMAIN}:443?encryption=none&type=ws&path=${ENC_PATH}&security=tls&sni=${DOMAIN}#${NAME}-$((i+1))" \
    >> subscriptions/vless.txt
done

base64 -w0 subscriptions/vless.txt > subscriptions/vless-sub.txt

# ================= 完成 =================
echo ""
echo "================= 部署完成 ================="
echo "NPM 管理面板: http://${DOMAIN}:${NPM_ADMIN_PORT}"
echo "LunaTV 用户名: ${LUNATV_USER}"
echo "LunaTV 密码:   ${LUNATV_PASSWORD}"
echo ""
echo "VLESS 订阅文件:"
echo "  ${BASE_DIR}/subscriptions/vless-sub.txt"
echo "==========================================="
