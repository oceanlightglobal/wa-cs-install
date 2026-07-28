#!/usr/bin/env bash
# =============================================================================
#  WhatsApp AI 客服 —— 一键安装
#
#      curl -fsSL https://<你的域名>/install.sh | bash
#
#  这个脚本会自动完成：
#    1. 检查系统、安装 Docker
#    2. 探测本机公网 IP，生成一个免费的 HTTPS 网址（sslip.io）
#    3. 生成随机管理员密码和内部令牌
#    4. 拉起所有服务，等 HTTPS 证书签发好
#    5. 把后台地址和密码打印给你
#
#  可选参数：
#    --domain example.com      用你自己的域名（要先把 DNS A 记录指到这台服务器）
#    --email you@example.com   证书通知邮箱（建议填）
#    --dir /opt/wa-cs          安装目录，默认 /opt/wa-cs
# =============================================================================

set -euo pipefail

# --- 可被环境变量覆盖，方便你自己搭发行源 ---------------------------------
RELEASE_BASE="${RELEASE_BASE:-https://oceanlightglobal.github.io/wa-cs}"
APP_IMAGE="${APP_IMAGE:-ghcr.io/oceanlightglobal/wa-cs:latest}"
UPDATER_IMAGE="${UPDATER_IMAGE:-ghcr.io/oceanlightglobal/wa-cs-updater:latest}"
VERSION_MANIFEST_URL="${VERSION_MANIFEST_URL:-${RELEASE_BASE}/version.json}"

INSTALL_DIR="/opt/wa-cs"
DOMAIN=""
EMAIL=""
TZ_DEFAULT="Asia/Kuala_Lumpur"

# ---------------------------------------------------------------------------
# 输出小工具
# ---------------------------------------------------------------------------
BOLD='\033[1m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; DIM='\033[2m'; NC='\033[0m'
step()  { echo -e "\n${BOLD}▶ $*${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
warn()  { echo -e "  ${YELLOW}!${NC} $*"; }
fail()  { echo -e "\n${RED}✗ $*${NC}\n" >&2; exit 1; }
info()  { echo -e "  ${DIM}$*${NC}"; }

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email)  EMAIL="${2:-}";  shift 2 ;;
    --dir)    INSTALL_DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) fail "不认识的参数：$1" ;;
  esac
done

echo -e "${BOLD}"
echo "  ┌──────────────────────────────────────────┐"
echo "  │   WhatsApp AI 客服 · 安装程序             │"
echo "  └──────────────────────────────────────────┘"
echo -e "${NC}"

# ---------------------------------------------------------------------------
step "第 1 步 / 共 5 步：检查系统"
# ---------------------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || fail "请用 root 运行：\n    sudo bash -c \"\$(curl -fsSL ${RELEASE_BASE}/install.sh)\""

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  ok "系统：${PRETTY_NAME:-$ID}"
  case "$ID" in
    ubuntu|debian) ;;
    *) warn "这个脚本在 Ubuntu / Debian 上测试过，${ID} 可能需要你手动装 Docker" ;;
  esac
else
  warn "认不出系统版本，继续尝试"
fi

MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
if [[ "$MEM_MB" -gt 0 && "$MEM_MB" -lt 900 ]]; then
  warn "内存只有 ${MEM_MB}MB，建议至少 1GB（2GB 更稳）"
fi

for port in 80 443; do
  if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN; then
    fail "端口 $port 已被其他程序占用。HTTPS 证书申请需要这两个端口，请先停掉占用的程序。"
  fi
done
ok "端口 80 / 443 可用"

# ---------------------------------------------------------------------------
step "第 2 步 / 共 5 步：安装 Docker"
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker 已经装好了（$(docker --version | cut -d, -f1)）"
else
  info "正在安装，需要几分钟…"
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || fail "Docker 安装失败。请手动执行：curl -fsSL https://get.docker.com | sh"
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || fail "Docker Compose 插件不可用，请检查 Docker 安装"
  ok "Docker 安装完成"
fi

# ---------------------------------------------------------------------------
step "第 3 步 / 共 5 步：确定你的网址"
# ---------------------------------------------------------------------------
if [[ -n "$DOMAIN" ]]; then
  SITE_ADDRESS="$DOMAIN"
  ok "使用你的域名：${SITE_ADDRESS}"
  info "请确认这个域名的 DNS A 记录已经指向本机，否则证书签不下来"
else
  PUBLIC_IP=""
  for svc in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
    PUBLIC_IP=$(curl -fsS --max-time 8 "$svc" 2>/dev/null | tr -d '[:space:]') && [[ -n "$PUBLIC_IP" ]] && break
  done
  [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "探测不到本机公网 IP。如果这台机器在 NAT 后面，请用 --domain 指定你自己的域名。"

  # sslip.io 会把 1-2-3-4.sslip.io 解析到 1.2.3.4，等于白送一个域名，
  # 这样客户不用买域名也能拿到合法的 HTTPS 证书。
  SITE_ADDRESS="${PUBLIC_IP//./-}.sslip.io"
  ok "公网 IP：${PUBLIC_IP}"
  ok "自动生成网址：${SITE_ADDRESS}"
  info "不需要买域名，这个地址由 sslip.io 免费提供并直接指向你的服务器"
fi

PUBLIC_URL="https://${SITE_ADDRESS}"

# ---------------------------------------------------------------------------
step "第 4 步 / 共 5 步：下载并配置"
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

for f in docker-compose.yml Caddyfile; do
  if [[ -f "$f" ]]; then
    cp "$f" "${f}.bak.$(date +%s)"
  fi
  curl -fsSL "${RELEASE_BASE}/${f}" -o "$f" || fail "下载 ${f} 失败，请检查网络或 RELEASE_BASE 设置"
done
ok "配置文件已下载到 ${INSTALL_DIR}"

rand() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
# 密码用容易念、不易看错的字符集（去掉 0/O/1/l/I），客户可能要电话报给你
randpw() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' | tr '0-9a-f' 'A-Za-z2-9' | head -c 14; }

if [[ -f .env ]]; then
  ok "检测到已有 .env，保留现有配置（不会覆盖你的密码和令牌）"
  # shellcheck disable=SC1091
  ADMIN_PASSWORD=$(grep -E '^INITIAL_ADMIN_PASSWORD=' .env | cut -d= -f2- || true)
  UPDATER_TOKEN=$(grep -E '^UPDATER_TOKEN=' .env | cut -d= -f2- || true)
  # 网址可能变了（换服务器 / 加域名），这两项要更新
  sed -i "s|^SITE_ADDRESS=.*|SITE_ADDRESS=${SITE_ADDRESS}|" .env
  sed -i "s|^PUBLIC_URL=.*|PUBLIC_URL=${PUBLIC_URL}|" .env
else
  ADMIN_PASSWORD=$(randpw)
  UPDATER_TOKEN=$(rand)
  HOST_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || echo "$TZ_DEFAULT")

  cat > .env <<EOF
# =============================================================================
#  由安装脚本自动生成 —— 一般不需要改
#  改完任何一项后运行：docker compose up -d
# =============================================================================

# 对外地址
SITE_ADDRESS=${SITE_ADDRESS}
PUBLIC_URL=${PUBLIC_URL}
ACME_EMAIL=${EMAIL}

# 时区（影响用量统计的「今天」怎么算）
TZ=${HOST_TZ:-$TZ_DEFAULT}

# 镜像
APP_IMAGE=${APP_IMAGE}
UPDATER_IMAGE=${UPDATER_IMAGE}
VERSION_MANIFEST_URL=${VERSION_MANIFEST_URL}

# 首次登录用的管理员密码（登录后请在向导第一步改掉）
INITIAL_ADMIN_PASSWORD=${ADMIN_PASSWORD}

# 内部令牌：应用调用 updater 时用，不要外泄
UPDATER_TOKEN=${UPDATER_TOKEN}

# AI 网关默认值（客户可以在后台改成任意 OpenAI 兼容接口）
DEFAULT_AI_BASE_URL=
DEFAULT_AI_API_KEY=
DEFAULT_AI_MODEL=gpt-4o-mini

LOG_LEVEL=info
EOF
  chmod 600 .env
  ok "已生成配置文件 .env"
fi

# INITIAL_ADMIN_PASSWORD 要传进 app 容器
if ! grep -q 'INITIAL_ADMIN_PASSWORD' docker-compose.yml; then
  warn "compose 文件里没有 INITIAL_ADMIN_PASSWORD，初始密码可能不会生效"
fi

# ---------------------------------------------------------------------------
step "第 5 步 / 共 5 步：启动服务"
# ---------------------------------------------------------------------------
info "正在拉取镜像，第一次可能要 2–5 分钟…"
docker compose pull 2>&1 | grep -Ei 'error|denied' && fail "镜像拉取失败，请检查网络" || true
docker compose up -d || fail "启动失败。请运行 'docker compose logs' 查看原因。"
ok "容器已启动"

info "等待服务就绪…"
READY=0
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "http://127.0.0.1/api/health" >/dev/null 2>&1 \
     || docker compose exec -T app wget -qO- http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
    READY=1; break
  fi
  sleep 2
done
[[ "$READY" -eq 1 ]] && ok "应用已就绪" || warn "应用还没响应，可能还在启动。稍后用 'docker compose logs app' 看看。"

info "等待 HTTPS 证书签发（首次约 10–60 秒）…"
TLS_OK=0
for i in $(seq 1 45); do
  if curl -fsS --max-time 5 "${PUBLIC_URL}/api/health" >/dev/null 2>&1; then
    TLS_OK=1; break
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
echo
echo "═══════════════════════════════════════════════════════════════"
if [[ "$TLS_OK" -eq 1 ]]; then
  echo -e "  ${GREEN}${BOLD}✅ 安装完成！${NC}"
else
  echo -e "  ${YELLOW}${BOLD}⚠️  服务已启动，但 HTTPS 证书还没好${NC}"
fi
echo "═══════════════════════════════════════════════════════════════"
echo
echo -e "    后台地址：  ${BOLD}${PUBLIC_URL}${NC}"
echo -e "    登录密码：  ${BOLD}${ADMIN_PASSWORD}${NC}"
echo
echo "    请打开上面的网址登录，跟着向导走完四步就能开始用。"
echo -e "    ${DIM}（第一步会让你把这个随机密码改成你自己的）${NC}"
echo

if [[ "$TLS_OK" -ne 1 ]]; then
  echo -e "  ${YELLOW}证书还没签发好，常见原因：${NC}"
  echo "    · 刚启动，再等 1 分钟刷新一次就好"
  echo "    · 服务器防火墙挡了 80/443 端口（云厂商的安全组也要放行）"
  echo "    · 用了自己的域名但 DNS 还没指过来"
  echo "    查看进度：cd ${INSTALL_DIR} && docker compose logs caddy"
  echo
fi

echo "  常用命令（都要先 cd ${INSTALL_DIR}）："
echo "    查看状态    docker compose ps"
echo "    查看日志    docker compose logs -f app"
echo "    重启        docker compose restart"
echo "    停止        docker compose down"
echo
echo "  这台服务器的配置和密码都在 ${INSTALL_DIR}/.env，请妥善保管。"
echo
