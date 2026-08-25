#!/usr/bin/env bash
##############################################
#  emby-reverse-proxy-go 一键安装脚本
#  功能: 安装依赖 -> 拉取上游源码编译 -> systemd 服务 -> nginx 前端
#        可选绑定域名并自动申请 Let's Encrypt 证书
#
#  用法:
#    bash install.sh                          # 全程交互式
#    bash install.sh --domain emby.example.com
#    bash install.sh --domain emby.example.com --email me@example.com -y
#    bash install.sh --no-domain -y           # 不用域名，纯 HTTP(IP 访问)
#
#  可选环境变量:
#    BACKEND_PORT=8080   反代监听端口(默认 8080)
#    GOPROXY_URL=...     Go 模块代理(默认 goproxy.cn)
##############################################
set -euo pipefail

BASE="/opt/emby-reverse-proxy-go"
SRC="$BASE/src"
BACKEND_PORT="${BACKEND_PORT:-8080}"
UPSTREAM_REPO="https://github.com/Gsy-allen/emby-reverse-proxy-go"
GOPROXY_URL="${GOPROXY_URL:-https://goproxy.cn,direct}"
GO_MIRROR="https://mirrors.aliyun.com/golang"
GO_FALLBACK_VER="go1.24.5"

DOMAIN=""
EMAIL=""
ASSUME_YES=0
NO_DOMAIN=0

C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_N="\033[0m"
ok()   { echo -e "${C_G}[OK]${C_N} $*"; }
warn() { echo -e "${C_Y}[提示]${C_N} $*"; }
err()  { echo -e "${C_R}[失败]${C_N} $*"; }

usage() {
    sed -n '2,20p' "$0" | sed 's/^#//;s/^ //'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain)  DOMAIN="$2"; shift 2 ;;
        --email)      EMAIL="$2"; shift 2 ;;
        -p|--port)    BACKEND_PORT="$2"; shift 2 ;;
        -y|--yes)     ASSUME_YES=1; shift ;;
        --no-domain)  NO_DOMAIN=1; shift ;;
        -h|--help)    usage ;;
        *) err "未知参数: $1"; usage ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { err "请用 root 运行: sudo bash $0"; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/deploy/emby.sh" ] || { err "请在仓库目录内运行(找不到 deploy/ 目录)"; exit 1; }

confirm() {
    [ "$ASSUME_YES" = "1" ] && return 0
    read -rp "$1 [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]]
}

public_ip() {
    curl -s -m 8 https://api.ipify.org 2>/dev/null \
        || curl -s -m 8 https://ipinfo.io/ip 2>/dev/null \
        || hostname -I | awk '{print $1}'
}

# 检测本机全部公网地址(IPv4 + IPv6)，空格分隔
public_ips() {
    local ips="" a
    a=$(curl -s -m 8 -4 https://api.ipify.org 2>/dev/null) && [ -n "$a" ] && ips="$ips $a"
    a=$(curl -s -m 8 -6 https://api64.ipify.org 2>/dev/null) && [ -n "$a" ] && ips="$ips $a"
    for a in $ips; do echo "${a// /}"; done | sort -u | tr '\n' ' '
}

echo -e "${C_B}==============================================${C_N}"
echo -e "${C_B}   emby-reverse-proxy-go 一键安装${C_N}"
echo -e "${C_B}==============================================${C_N}"

# ---------- 1/7 检测环境并安装系统依赖 ----------
echo "== 1/7 检测环境并安装系统依赖 =="
PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then PKG_MGR="apt";
elif command -v dnf >/dev/null 2>&1; then PKG_MGR="dnf";
elif command -v yum >/dev/null 2>&1; then PKG_MGR="yum";
fi

pkg_install() {
    case "$PKG_MGR" in
        apt) export DEBIAN_FRONTEND=noninteractive
             apt-get update -qq >/dev/null 2>&1 || true
             apt-get install -y -qq "$@" >/dev/null ;;
        dnf) dnf install -y -q "$@" >/dev/null ;;
        yum) yum install -y -q "$@" >/dev/null ;;
    esac
}

ensure_cmds() {
    local miss="" c still=""
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
    done
    miss="${miss# }"
    [ -z "$miss" ] && return 0
    echo "缺少依赖:$miss ，尝试通过 $PKG_MGR 安装..."
    case "$PKG_MGR" in
        apt) pkg_install $miss ;;
        dnf|yum)
            pkg_install epel-release >/dev/null 2>&1 || true
            pkg_install $miss || true
            ;;
        *)   err "未识别的包管理器(支持 apt/dnf/yum)，请手动安装:$miss 后重新运行"; return 1 ;;
    esac
    for c in $miss; do
        command -v "$c" >/dev/null 2>&1 || still="$still $c"
    done
    if [ -n "$still" ]; then
        err "以下依赖未能自动安装:${still} —— 请手动安装后重新运行本脚本"
        return 1
    fi
}

ensure_cmds git curl tar nginx || exit 1
ok "环境检测通过(PKG: ${PKG_MGR:-手动}, git/curl/tar/nginx 就绪)"


# ---------- 2/7 Go 工具链 ----------
echo "== 2/7 检查 Go 工具链 (需 >= 1.24) =="
go_ok() { /usr/local/go/bin/go version 2>/dev/null | grep -qE "go1\.(2[4-9]|[3-9][0-9])\."; }
if ! go_ok; then
    case "$(uname -m)" in
        x86_64)        GO_ARCH="amd64" ;;
        aarch64|arm64) GO_ARCH="arm64" ;;
        *) err "不支持的 CPU 架构: $(uname -m)"; exit 1 ;;
    esac
    GO_TGZ=$(curl -fsSL "$GO_MIRROR/" | grep -oE "go1\.24\.[0-9]+\.linux-${GO_ARCH}\.tar\.gz" | sort -V | tail -1 || true)
    [ -z "$GO_TGZ" ] && GO_TGZ="${GO_FALLBACK_VER}.linux-${GO_ARCH}.tar.gz"
    BASE_URL="$GO_MIRROR"
    if ! curl -fsIL -m 10 "$BASE_URL/$GO_TGZ" >/dev/null; then
        BASE_URL="https://go.dev/dl"
    fi
    echo "下载 $GO_TGZ ..."
    curl -fsSL -o /tmp/go.tgz "$BASE_URL/$GO_TGZ"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf /tmp/go.tgz
    rm -f /tmp/go.tgz
fi
ln -sf /usr/local/go/bin/go /usr/local/bin/go
export PATH="/usr/local/go/bin:$PATH"
ok "Go $(go version | awk '{print $3}')"

# ---------- 3/7 上游源码 ----------
echo "== 3/7 获取上游源码 =="
mkdir -p "$BASE"
if [ -d "$SRC/.git" ]; then
    git config --global --add safe.directory "$SRC" 2>/dev/null || true
    git -C "$SRC" pull --rebase --autostash >/dev/null 2>&1 && ok "源码已更新" || warn "源码更新失败，使用现有版本继续"
else
    rm -rf "$SRC"
    git clone --depth 1 "$UPSTREAM_REPO" "$SRC"
    ok "源码克隆完成"
fi

# ---------- 4/7 编译 ----------
echo "== 4/7 编译 emby-proxy =="
cd "$SRC"
GOPROXY="$GOPROXY_URL" go build -buildvcs=false -trimpath -ldflags "-s -w" -o "$BASE/emby-proxy.new" .
mv "$BASE/emby-proxy.new" "$BASE/emby-proxy"
chmod +x "$BASE/emby-proxy"
ok "编译完成: $(ls -lh "$BASE/emby-proxy" | awk '{print $5}')"

# ---------- 5/7 配置与 systemd 服务 ----------
echo "== 5/7 写入配置并注册 systemd 服务 =="
sed "s/__BACKEND_PORT__/$BACKEND_PORT/g" "$SCRIPT_DIR/deploy/emby-proxy.env.template" > "$BASE/emby-proxy.env"
chmod 600 "$BASE/emby-proxy.env"
cp "$SCRIPT_DIR/deploy/emby-proxy.service" /etc/systemd/system/emby-proxy.service
systemctl daemon-reload
systemctl enable emby-proxy >/dev/null 2>&1
if systemctl is-active --quiet emby-proxy; then
    systemctl restart emby-proxy
else
    systemctl start emby-proxy
fi
sleep 1
systemctl is-active --quiet emby-proxy && ok "服务运行中 (127.0.0.1:$BACKEND_PORT)" || { err "服务未能启动，查看: journalctl -u emby-proxy -n 50"; exit 1; }

# ---------- 6/7 域名与 HTTPS ----------
USE_HTTPS=0
if [ "$NO_DOMAIN" != "1" ] && [ -t 0 ] && [ "$ASSUME_YES" != "1" ] && [ -z "$DOMAIN" ]; then
    read -rp "是否绑定域名并自动申请 HTTPS 证书? [y/N]: " a
    if [[ "$a" =~ ^[Yy]$ ]]; then
        read -rp "输入域名 (如 emby.example.com): " DOMAIN
    fi
elif [ -z "$DOMAIN" ]; then
    USE_HTTPS=0
fi

NGINX_CONF_SRC=""
ENTRANCE=""
if [ -n "$DOMAIN" ]; then
    echo "== 6/7 域名 $DOMAIN 与 HTTPS 证书 =="
    MY_LIST=$(public_ips); [ -z "${MY_LIST// /}" ] && MY_LIST="$(public_ip) "
    RESOLVED=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    MATCHED=""
    for r in $RESOLVED; do
        for m in $MY_LIST; do
            [ "$r" = "$m" ] && MATCHED="$r"
        done
    done
    if [ -n "$MATCHED" ]; then
        ok "DNS 解析正常: $DOMAIN -> 已匹配本机地址 ($MATCHED)"
        [ -n "$(echo "$RESOLVED" | grep ':')" ] && [ -z "$(echo "$MY_LIST" | grep ':')" ] && \
            warn "域名含 AAAA(IPv6) 记录，但本机似乎没有可用的 IPv6 出口 —— 建议删除 AAAA 记录或开通 IPv6，否则部分客户端会解析到 v6 而连不上"
    else
        warn "域名解析 [$RESOLVED] 与本机公网地址 [${MY_LIST}] 不一致"
        warn "若 DNS 尚未生效, Let's Encrypt HTTP 验证会失败"
        confirm "仍要继续尝试申请证书吗?" || { warn "已跳过 HTTPS, 将以纯 HTTP 模式安装"; DOMAIN=""; }
    fi
fi

if [ -n "$DOMAIN" ]; then
    if ! command -v certbot >/dev/null 2>&1; then
        echo "安装 certbot..."
        ensure_cmds certbot || { err "certbot 安装失败，无法自动申请证书"; confirm "回退为纯 HTTP 模式继续安装?" || exit 1; DOMAIN=""; }
    fi
fi

if [ -n "$DOMAIN" ]; then
    CERT_EMAIL="${EMAIL:-admin@$DOMAIN}"
    if certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos \
         --keep-until-expiring --no-eff-email -m "$CERT_EMAIL"; then
        ok "证书就绪 (/etc/letsencrypt/live/$DOMAIN/)"
    else
        err "证书申请失败 —— 常见原因: DNS 未解析到本机 / 云安全组未放行 80 端口"
        confirm "回退为纯 HTTP 模式继续安装?" || exit 1
        DOMAIN=""
    fi
fi

if [ -n "$DOMAIN" ]; then
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    printf '#!/bin/bash\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    sed -e "s/__DOMAIN__/$DOMAIN/g" -e "s/__BACKEND_PORT__/$BACKEND_PORT/g" \
        "$SCRIPT_DIR/deploy/nginx-https.conf.template" > "$SCRIPT_DIR/deploy/.emby-proxy.nginx.conf"
    ENTRANCE="https://$DOMAIN"
    USE_HTTPS=1
else
    sed "s/__BACKEND_PORT__/$BACKEND_PORT/g" \
        "$SCRIPT_DIR/deploy/nginx-http.conf.template" > "$SCRIPT_DIR/deploy/.emby-proxy.nginx.conf"
    MY_IP=$(public_ip); ENTRANCE="http://${MY_IP:-本机IP}:80"
    warn "纯 HTTP 模式, 入口: $ENTRANCE (之后想加域名可重新运行本脚本)"
fi

echo "== 7/7 配置 nginx 并安装管理脚本 =="
systemctl enable --now nginx >/dev/null 2>&1 || true
if [ -f /etc/nginx/sites-available/default ] && [ ! -f /etc/nginx/sites-available/default.bak.emby-install ]; then
    cp -a /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak.emby-install
    warn "原默认站点已备份为 default.bak.emby-install"
fi
cp "$SCRIPT_DIR/deploy/.emby-proxy.nginx.conf" /etc/nginx/sites-available/emby-proxy
rm -f "$SCRIPT_DIR/deploy/.emby-proxy.nginx.conf"
rm -f /etc/nginx/conf.d/ws-map.conf   # 清理旧版部署残留(map 已内联到站点文件)
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/emby-proxy
ln -sf /etc/nginx/sites-available/emby-proxy /etc/nginx/sites-enabled/emby-proxy
nginx -t
systemctl reload-or-restart nginx
ok "nginx 配置完成"

sed -e "s|__PUB_ENTRANCE__|$ENTRANCE|" "$SCRIPT_DIR/deploy/emby.sh" > /usr/local/bin/emby
chmod 755 /usr/local/bin/emby
ok "管理脚本已安装: 运行 emby 进入菜单"

# ---------- 验证 ----------
sleep 1
LOCAL_HEALTH=$(curl -s -m 5 "http://127.0.0.1:$BACKEND_PORT/health" 2>/dev/null || echo FAIL)
PUB_HEALTH=$(curl -s -o /dev/null -m 10 -w "%{http_code}" "$ENTRANCE/health" 2>/dev/null || echo FAIL)

echo ""
echo -e "${C_B}==============================================${C_N}"
echo -e "${C_B}                安装完成${C_N}"
echo -e "${C_B}==============================================${C_N}"
echo -e " 反代服务 : 127.0.0.1:$BACKEND_PORT  本机健康检查: ${LOCAL_HEALTH:-FAIL}"
echo -e " 对外入口 : $ENTRANCE  (health -> HTTP $PUB_HEALTH)"
if [ "$USE_HTTPS" = "1" ]; then
    echo -e " HTTPS    : 已启用, 证书自动续期(certbot.timer)"
fi
echo -e " 使用方式 : $ENTRANCE/{http|https}/{上游域名}/{端口}/"
echo -e "            例如 $ENTRANCE/https/emby.example.com/443/"
echo -e " 管理     : 输入 emby 进入交互菜单"
echo -e "${C_B}==============================================${C_N}"

if [ "$LOCAL_HEALTH" != "ok" ] || [ "$PUB_HEALTH" != "200" ]; then
    warn "部分检查未通过, 请执行 emby status 或 journalctl -u emby-proxy -n 50 排查"
    exit 2
fi
