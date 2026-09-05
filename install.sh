#!/usr/bin/env bash
# emby-reverse-proxy-go 一键安装: 依赖 -> 编译 -> systemd -> nginx -> 可选域名+自动HTTPS证书
# 用法: bash install.sh [-d 域名] [-y]   完整帮助: bash install.sh -h
set -euo pipefail

BASE="/opt/emby-reverse-proxy-go"; SRC="$BASE/src"
BACKEND_PORT="${BACKEND_PORT:-8080}"
GOPROXY_URL="${GOPROXY_URL:-https://goproxy.cn,direct}"
GO_MIRROR="https://mirrors.aliyun.com/golang"
DOMAIN=""; EMAIL=""; ASSUME_YES=0

C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_N="\033[0m"
ok()   { echo -e "${C_G}[OK]${C_N} $*"; }
warn() { echo -e "${C_Y}[提示]${C_N} $*"; }
err()  { echo -e "${C_R}[失败]${C_N} $*"; }
ask()  { [ "$ASSUME_YES" = 1 ] && return 0; read -rp "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]; }

usage() {
    cat <<'EOF'
用法: bash install.sh [参数]
  -d, --domain <域名>  绑定域名并自动申请 HTTPS 证书 (需已解析到本机)
      --email <邮箱>   Let's Encrypt 联系邮箱 (默认 admin@<域名>)
  -y                   跳过交互确认 (不带 --domain 时默认纯 HTTP)
  -h, --help           显示本帮助
环境变量: BACKEND_PORT=8080 (反代端口)  GOPROXY_URL=... (Go模块代理)
示例: bash install.sh -d emby.example.com -y
EOF
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--domain) DOMAIN="$2"; shift ;;
        --email)     EMAIL="$2"; shift ;;
        -y)          ASSUME_YES=1 ;;
        -h|--help)   usage ;;
        *) err "未知参数: $1"; usage ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { err "请用 root 运行"; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/deploy/emby.sh" ] || { err "请在仓库目录内运行 (找不到 deploy/)"; exit 1; }

# 本机全部公网地址 (IPv4+IPv6)，空格分隔
pub_ips() {
    { curl -s -m 8 -4 https://api.ipify.org; curl -s -m 8 -6 https://api64.ipify.org; hostname -I; } \
        | tr ' ' '\n' | grep -E '^[0-9a-fA-F:.]+$' | sort -u | tr '\n' ' '
}

# 按需安装缺失命令 (自动识别 apt/dnf/yum)
PM=""; command -v apt-get >/dev/null && PM=apt-get; command -v dnf >/dev/null && PM=dnf; command -v yum >/dev/null && PM=yum
install_pkg() {
    local miss="" left="" c
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
    [ -n "$miss" ] || return 0
    [ -z "$PM" ] && { err "未识别的包管理器, 请手动安装:$miss"; exit 1; }
    [ "$PM" = apt-get ] && apt-get update -qq >/dev/null 2>&1 || true
    [ "$PM" != apt-get ] && "$PM" install -y -q epel-release >/dev/null 2>&1 || true
    export DEBIAN_FRONTEND=noninteractive
    "$PM" install -y -q $miss >/dev/null || true
    for c in $miss; do command -v "$c" >/dev/null 2>&1 || left="$left $c"; done
    [ -n "$left" ] && { err "依赖安装失败: $left —— 请手动安装后重跑"; exit 1; }
}

install_pkg git curl tar nginx

echo -e "${C_B}== 准备 Go 工具链 (需 >= 1.24) ==${C_N}"
if ! /usr/local/go/bin/go version 2>/dev/null | grep -qE 'go1\.(2[4-9]|[3-9][0-9])\.'; then
    case "$(uname -m)" in
        x86_64) A=amd64 ;; aarch64|arm64) A=arm64 ;; *) err "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
    TGZ=$(curl -fsSL "$GO_MIRROR/" | grep -oE "go1\.24\.[0-9]+\.linux-$A\.tar\.gz" | sort -V | tail -1 || echo go1.24.5.linux-$A.tar.gz)
    curl -fsSL -o /tmp/go.tgz "$GO_MIRROR/$TGZ" 2>/dev/null || curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/$TGZ"
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
fi
export PATH="/usr/local/go/bin:$PATH"; ok "Go $(go version | awk '{print $3}')"

echo -e "${C_B}== 获取上游源码并编译 (无更新则跳过) ==${C_N}"
mkdir -p "$BASE"; TH=""
# 上游源码地址链: 直连优先,失败走国内加速镜像
SRC_URLS="https://codeload.github.com/Gsy-allen/emby-reverse-proxy-go/tar.gz/refs/heads/master
https://ghfast.top/https://codeload.github.com/Gsy-allen/emby-reverse-proxy-go/tar.gz/refs/heads/master
https://gh-proxy.com/https://codeload.github.com/Gsy-allen/emby-reverse-proxy-go/tar.gz/refs/heads/master"
fetch_upstream() {
    local u
    rm -f /tmp/upstream-src.tgz
    for u in $SRC_URLS; do
        curl -fsSL -m 120 --connect-timeout 8 -o /tmp/upstream-src.tgz "$u" 2>/dev/null && [ -s /tmp/upstream-src.tgz ] && return 0
        warn "源获取失败, 换下一个: $u"
    done
    return 1
}
if [ -d "$SRC/.git" ]; then
    git config --global --add safe.directory "$SRC" 2>/dev/null || true
    git -C "$SRC" pull --rebase --autostash >/dev/null 2>&1 || warn "git 更新失败, 尝试镜像下载"
fi
if ! git -C "$SRC" rev-parse HEAD >/dev/null 2>&1; then
    # 无 git 仓库(镜像 tarball 模式)：始终取最新版, 下载失败时回退本地已有源码
    if fetch_upstream; then
        rm -rf "$SRC"; mkdir -p "$SRC"
        tar -xzf /tmp/upstream-src.tgz -C "$SRC" --strip-components=1
        ok "源码已就位"
    elif [ -f "$SRC/handler.go" ]; then
        warn "上游下载失败, 使用本地已有源码继续"
    else
        err "上游源码所有渠道均失败 —— 可手动下载解压到 $SRC 后重跑本脚本"; exit 1
    fi
fi
TH=$(cd "$SRC" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum | awk '{print $1}')
if [ -x "$BASE/emby-proxy" ] && [ "$TH" = "$(cat "$BASE/.src_hash" 2>/dev/null || echo none)" ]; then
    ok "代码无更新，跳过编译"
else
    (cd "$SRC" && GOPROXY="$GOPROXY_URL" go build -buildvcs=false -trimpath -ldflags "-s -w" -o "$BASE/emby-proxy.new" .)
    mv "$BASE/emby-proxy.new" "$BASE/emby-proxy" && chmod +x "$BASE/emby-proxy"
    echo "$TH" > "$BASE/.src_hash"
    ok "编译完成 ($(ls -lh "$BASE/emby-proxy" | awk '{print $5}'))"
fi

echo -e "${C_B}== 写入配置并启动 systemd 服务 ==${C_N}"
sed "s/__BACKEND_PORT__/$BACKEND_PORT/g" "$SCRIPT_DIR/deploy/emby-proxy.env.template" > "$BASE/emby-proxy.env"
chmod 600 "$BASE/emby-proxy.env"
cp "$SCRIPT_DIR/deploy/emby-proxy.service" /etc/systemd/system/
systemctl daemon-reload && systemctl enable emby-proxy >/dev/null 2>&1 || true
systemctl restart emby-proxy; sleep 1
systemctl is-active --quiet emby-proxy || { err "服务启动失败: journalctl -u emby-proxy -n 50"; exit 1; }
ok "服务运行中 (127.0.0.1:$BACKEND_PORT)"

# 域名(可选)：交互时直接输入域名，留空 = 纯 HTTP
if [ -z "$DOMAIN" ] && [ -t 0 ] && [ "$ASSUME_YES" != 1 ]; then
    read -rp "绑定域名并申请 HTTPS 证书? 输入域名(留空则纯HTTP): " DOMAIN
fi

USE_HTTPS=0; TPL="nginx-http.conf.template"; ENTRANCE=""
if [ -n "$DOMAIN" ]; then
    echo -e "${C_B}== 域名 $DOMAIN : 校验DNS -> 申请证书 ==${C_N}"
    MINE=$(pub_ips); RES=$(getent hosts "$DOMAIN" | awk '{print $1}' | sort -u)
    MATCH=$(comm -12 <(echo "$MINE" | tr ' ' '\n' | sort) <(echo "$RES") | head -1)
    if [ -n "$MATCH" ]; then
        ok "DNS 已解析到本机 ($MATCH)"
    else
        warn "域名解析 [$RES] 与本机公网地址 [$MINE] 不一致"
        [ -n "$(echo "$RES" | grep ':')" ] && [ -z "$(echo "$MINE" | grep ':')" ] \
            && warn "域名有 AAAA 记录但本机无 IPv6 —— 建议删除 AAAA 或开通 v6, 否则部分客户端连不上"
        ask "DNS 可能未生效, 仍尝试申请证书?" || DOMAIN=""
    fi
    if [ -n "$DOMAIN" ]; then
        install_pkg certbot
        # nginx 插件可能不随主包安装(Debian: python3-certbot-nginx)，缺失则补装
        certbot plugins 2>/dev/null | grep -qE '^\s*\*?\s*nginx' || install_pkg python3-certbot-nginx || true
        WROOT=/var/www/html; [ -d /var/www/html ] || WROOT=/usr/share/nginx/html
        if certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos \
               --keep-until-expiring --no-eff-email -m "${EMAIL:-admin@$DOMAIN}"; then
            ok "证书就绪"
        elif certbot certonly --webroot -w "$WROOT" -d "$DOMAIN" --non-interactive --agree-tos \
               --keep-until-expiring --no-eff-email -m "${EMAIL:-admin@$DOMAIN}"; then
            ok "证书就绪 (webroot)"
        else
            err "证书申请失败(检查 DNS 与 80 端口放行)"
            ask "回退纯 HTTP 继续?" || exit 1
            DOMAIN=""
        fi
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        printf '#!/bin/bash\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
        TPL="nginx-https.conf.template"; ENTRANCE="https://$DOMAIN"; USE_HTTPS=1
    fi
fi

echo -e "${C_B}== 配置 nginx 入口并安装管理脚本 ==${C_N}"
systemctl enable --now nginx >/dev/null 2>&1 || true
[ -f /etc/nginx/sites-available/default ] && [ ! -f /etc/nginx/sites-available/default.bak.emby-install ] \
    && cp -a /etc/nginx/sites-available/default /etc/nginx/sites-available/default.bak.emby-install \
    && warn "原默认站点已备份为 default.bak.emby-install"
if [ -n "$DOMAIN" ]; then
    sed -e "s/__DOMAIN__/$DOMAIN/g" -e "s/__BACKEND_PORT__/$BACKEND_PORT/g" \
        "$SCRIPT_DIR/deploy/$TPL" > /tmp/emby-proxy.nginx.conf
else
    sed "s/__BACKEND_PORT__/$BACKEND_PORT/g" "$SCRIPT_DIR/deploy/$TPL" > /tmp/emby-proxy.nginx.conf
    ENTRANCE="http://$(pub_ips | grep -v ':' | awk '{print $1}')"
    [ "$ENTRANCE" = "http://" ] && ENTRANCE="http://SERVER_IP"
fi
cp /tmp/emby-proxy.nginx.conf /etc/nginx/sites-available/emby-proxy; rm -f /tmp/emby-proxy.nginx.conf
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/emby-proxy /etc/nginx/conf.d/ws-map.conf
ln -sf /etc/nginx/sites-available/emby-proxy /etc/nginx/sites-enabled/emby-proxy
nginx -t && systemctl reload-or-restart nginx
sed "s|__PUB_ENTRANCE__|$ENTRANCE|" "$SCRIPT_DIR/deploy/emby.sh" > /usr/local/bin/emby
chmod 755 /usr/local/bin/emby; ok "管理脚本已安装 (运行 emby 进入菜单)"

sleep 1
LH=$(curl -s -m 5 "http://127.0.0.1:$BACKEND_PORT/health" || true)
PH=$(curl -s -o /dev/null -m 10 -w "%{http_code}" "$ENTRANCE/health" 2>/dev/null || true)
echo ""
echo -e "${C_B}====== 安装完成 ======${C_N}"
echo -e " 反代服务 : 127.0.0.1:$BACKEND_PORT   健康检查: ${LH:-FAIL}"
echo -e " 对外入口 : $ENTRANCE (health -> HTTP $PH)"
[ "$USE_HTTPS" = 1 ] && echo -e " HTTPS    : 已启用, certbot.timer 自动续期"
echo -e " 使用格式 : $ENTRANCE/{http|https}/{上游域名}/{端口}/"
echo -e "            例如 $ENTRANCE/https/emby.example.com/443/"
[ "$LH" = "ok" ] && [ "$PH" = "200" ] || { warn "部分检查未通过: emby status 排查"; exit 2; }