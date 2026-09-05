#!/usr/bin/env bash
# emby-reverse-proxy-go 卸载脚本 (保留证书与备份)
set -euo pipefail

BASE="/opt/emby-reverse-proxy-go"
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }

read -rp "确认卸载 emby-reverse-proxy-go? 输入 yes 继续: " a
[ "$a" = "yes" ] || { echo "已取消"; exit 0; }

systemctl disable --now emby-proxy 2>/dev/null || true
rm -f /etc/systemd/system/emby-proxy.service
rm -f /etc/nginx/sites-enabled/emby-proxy
rm -f /usr/local/bin/emby
# 恢复安装前备份的 nginx 默认站点(如有)
[ -f /etc/nginx/sites-available/default.bak.emby-install ] && \
    ln -sf /etc/nginx/sites-available/default.bak.emby-install /etc/nginx/sites-enabled/default
systemctl daemon-reload
systemctl reload-or-restart nginx 2>/dev/null || true

if [ -d "$BASE" ]; then
    BAK="$BASE.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$BASE" "$BAK" && echo "程序与配置已备份: $BAK"
fi

echo "卸载完成。Let's Encrypt 证书保留在 /etc/letsencrypt/ (如需删除: certbot delete -d <域名>)"
