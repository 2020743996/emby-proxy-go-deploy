#!/usr/bin/env bash
##############################################
#  emby-reverse-proxy-go 交互式管理脚本 (由 install.sh 安装)
#  用法: emby            进入交互菜单
#        emby start|stop|restart|status|logs|update|config|usage
#  安装位置: /usr/local/bin/emby
##############################################

BASE_DIR="/opt/emby-reverse-proxy-go"
SRC_DIR="$BASE_DIR/src"
BIN="$BASE_DIR/emby-proxy"
ENV_FILE="$BASE_DIR/emby-proxy.env"
SERVICE="emby-proxy"
PUB_ENTRANCE="__PUB_ENTRANCE__"   # 对外入口，由 install.sh 写入

C_G="\033[32m"; C_Y="\033[33m"; C_R="\033[31m"; C_B="\033[36m"; C_N="\033[0m"
msg_ok()   { echo -e "${C_G}[OK]${C_N} $*"; }
msg_warn() { echo -e "${C_Y}[提示]${C_N} $*"; }
msg_err()  { echo -e "${C_R}[失败]${C_N} $*"; }

get_env() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }

health_url() {
    local addr host port
    addr=$(get_env LISTEN_ADDR); [ -z "$addr" ] && addr=":8080"
    host="${addr%:*}"; port="${addr##*:}"
    case "$host" in ""|"0.0.0.0"|"::") host="127.0.0.1" ;; esac
    echo "http://$host:$port/health"
}

svc_start()   { systemctl start "$SERVICE"   && msg_ok "服务已启动" || msg_err "启动失败，请查看日志"; }
svc_stop()    { systemctl stop "$SERVICE"    && msg_ok "服务已停止" || msg_err "停止失败"; }
svc_restart() { systemctl restart "$SERVICE" && msg_ok "服务已重启" || msg_err "重启失败，请查看日志"; }

svc_status() {
    echo -e "${C_B}===== systemd 服务状态 =====${C_N}"
    systemctl status "$SERVICE" --no-pager -l | sed -n '1,12p'
    echo ""
    echo -e "${C_B}===== 健康检查 ($(health_url)) =====${C_N}"
    local body code
    body=$(curl -s -m 5 -w "\n%{http_code}" "$(health_url)" 2>/dev/null)
    code=$(echo "$body" | tail -1)
    if [ "$code" = "200" ] && echo "$body" | head -1 | grep -q ok; then
        msg_ok "代理进程正常 (HTTP $code, body=ok)"
    else
        msg_err "健康检查未通过 (code=$code)，服务可能未运行"
    fi
    if systemctl is-active --quiet nginx; then
        local pub_code
        pub_code=$(curl -s -o /dev/null -m 8 -w "%{http_code}" "$PUB_ENTRANCE/health" 2>/dev/null)
        if [ "$pub_code" = "200" ]; then
            msg_ok "对外入口正常 ($PUB_ENTRANCE)"
        else
            msg_warn "对外入口异常 ($PUB_ENTRANCE/health -> HTTP $pub_code)，请检查 nginx 或云安全组"
        fi
    else
        msg_err "nginx 未运行，对外入口不可用"
    fi
}

svc_logs() { journalctl -u "$SERVICE" -n 100 --no-pager; }
svc_tailf() { echo "实时日志中，按 Ctrl+C 返回..."; journalctl -u "$SERVICE" -f --no-pager; }

edit_config() {
    ${EDITOR:-nano} "$ENV_FILE"
    echo ""
    if confirm "配置可能已修改，是否立即重启服务使其生效?"; then svc_restart; svc_status; fi
}

show_config() {
    echo -e "${C_B}===== 当前配置 ($ENV_FILE) =====${C_N}"
    grep -vE '^\s*#|^\s*$' "$ENV_FILE"
}

confirm() {
    read -rp "$1 [y/N]: " a
    [[ "$a" =~ ^[Yy]$ ]]
}

set_outbound_proxy() {
    echo -e "当前出站代理 ALL_PROXY: ${C_Y}$(get_env ALL_PROXY || echo 未设置)${C_N}"
    echo "1) 设置 ALL_PROXY (如 socks5://127.0.0.1:1080 或 http://127.0.0.1:7890)"
    echo "2) 清除 ALL_PROXY"
    read -rp "选择: " c
    sed -i '/^ALL_PROXY=/d' "$ENV_FILE"
    case "$c" in
        1) read -rp "输入代理地址: " p
           [ -z "$p" ] && return 0
           echo "ALL_PROXY=$p" >> "$ENV_FILE"; msg_ok "已写入";;
        2) msg_ok "已清除";;
        *) return 0;;
    esac
    confirm "立即重启服务生效?" && svc_restart
}

toggle_private_targets() {
    local cur new warn=""
    cur=$(get_env BLOCK_PRIVATE_TARGETS); cur=${cur:-true}
    echo -e "当前 BLOCK_PRIVATE_TARGETS = ${C_Y}$cur${C_N}"
    echo "true  = 禁止反代内网/localhost 上游(更安全)"
    echo "false = 允许反代内网 Emby (例如 http://192.168.x.x:8096)"
    if [ "$cur" = "true" ]; then
        new="false"; warn="注意：关闭后允许把内网地址作为反代目标"
    else
        new="true"
    fi
    [ -n "$warn" ] && msg_warn "$warn"
    confirm "切换为 $new ?" || return 0
    sed -i "s/^BLOCK_PRIVATE_TARGETS=.*/BLOCK_PRIVATE_TARGETS=$new/" "$ENV_FILE"
    msg_ok "已改为 $new"
    confirm "立即重启服务生效?" && svc_restart
}

test_upstream() {
    read -rp "上游协议 http/https [https]: " scheme
    scheme=${scheme:-https}
    read -rp "上游域名或IP (如 emby.example.com): " domain
    [ -z "$domain" ] && { msg_err "域名为空"; return 1; }
    read -rp "上游端口 [443]: " port
    port=${port:-443}
    local url="$PUB_ENTRANCE/$scheme/$domain/$port/"
    echo -e "访问地址: ${C_B}$url${C_N}"
    local t0 t1 code size
    t0=$(date +%s)
    code=$(curl -sL -o /tmp/emby_proxy_test.html -m 30 -w "%{http_code}" "$url" 2>/dev/null)
    t1=$(date +%s)
    size=$(wc -c < /tmp/emby_proxy_test.html 2>/dev/null || echo 0)
    if [ "$code" = "200" ]; then
        msg_ok "测试通过 (HTTP 200, 耗时 $((t1-t0))s, 返回 $size 字节)"
        grep -qiE "<title>(.*)</title>" /tmp/emby_proxy_test.html && \
            echo -e "页面标题: ${C_B}$(grep -oiE '<title>.*</title>' /tmp/emby_proxy_test.html | head -1 | sed 's/<[^>]*>//g')${C_N}"
    else
        msg_err "HTTP $code —— 检查上游地址是否正确、服务器能否访问该上游(可尝试设置出站代理)"
    fi
    rm -f /tmp/emby_proxy_test.html
}

do_update() {
    export PATH="/usr/local/go/bin:$PATH"
    export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
    command -v go >/dev/null || { msg_err "未找到 go，无法在服务器上编译更新"; return 1; }
    echo -e "当前版本: $(cd "$SRC_DIR" && git rev-parse --short HEAD 2>/dev/null) ($(cd "$SRC_DIR" && git log -1 --format=%cs 2>/dev/null))"
    cd "$SRC_DIR" || return 1
    echo "正在拉取最新代码..."
    if ! git pull --rebase --autostash 2>&1; then
        msg_err "git pull 失败(服务器可能无法访问 GitHub)"
        msg_warn "备选：本地构建二进制后上传覆盖 $BIN 再重启"
        return 1
    fi
    echo "正在编译..."
    if go build -buildvcs=false -trimpath -ldflags "-s -w" -o "$BIN.new" . ; then
        systemctl stop "$SERVICE"
        mv "$BIN.new" "$BIN"
        chmod +x "$BIN"
        svc_restart
        msg_ok "更新完成: $(git rev-parse --short HEAD)"
    else
        msg_err "编译失败，保留旧版本"
        rm -f "$BIN.new"
        return 1
    fi
}

do_uninstall() {
    msg_warn "将删除 emby-reverse-proxy-go 的服务、程序与 nginx 站点(源码与配置会备份到 $BASE_DIR.bak.*)"
    read -rp "确认卸载? 输入 yes 继续: " a
    [[ "$a" == "yes" ]] || { msg_warn "已取消"; return 0; }
    systemctl disable --now "$SERVICE" 2>/dev/null
    rm -f /etc/systemd/system/emby-proxy.service
    rm -f /etc/nginx/sites-enabled/emby-proxy /etc/nginx/sites-enabled/default
    cp -a "$BASE_DIR" "$BASE_DIR.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    systemctl daemon-reload && systemctl reload-or-restart nginx
    msg_ok "已卸载，备份目录见 $BASE_DIR.bak.*"
}

show_usage() {
    cat <<EOF

==================== 使用说明 ====================
本机部署的是通用 Emby 反向代理。上游 Emby 地址直接写在 URL 路径中：

  格式:
    \${入口}/{http|https}/{上游域名}/{上游端口}/...

  本机入口:
    $PUB_ENTRANCE

  示例:
    $PUB_ENTRANCE/https/emby.example.com/443/
    $PUB_ENTRANCE/http/public-emby.example.net/8096/
    API : $PUB_ENTRANCE/http/x.x.x.x/8096/emby/Items?api_key=xxxx
    Web : $PUB_ENTRANCE/http/x.x.x.x/8096/web/index.html

  注意:
  * 域名和端口都不能省略(即使 80/443 也要写)
  * 根路径 / 返回 400 是正常现象；/health 应返回 ok
  * Emby 客户端里把服务器地址填成上面的入口 URL 即可
==================================================

EOF
}

show_menu() {
    clear 2>/dev/null
    local running="$(systemctl is-active $SERVICE 2>/dev/null)"
    [ "$running" = "active" ] && st="${C_G}运行中${C_N}" || st="${C_R}${running:-unknown}${C_N}"
    echo -e "${C_B}==============================================${C_N}"
    echo -e "${C_B}      emby-reverse-proxy-go 管理脚本${C_N}"
    echo -e "${C_B}==============================================${C_N}"
    echo -e " 服务状态: $(echo -e "$st")   入口: $PUB_ENTRANCE"
    echo -e "----------------------------------------------"
    echo -e "  1) 启动服务          2) 停止服务         3) 重启服务"
    echo -e "  4) 运行状态/健康检查 5) 实时日志         6) 最近100行日志"
    echo -e "  7) 编辑配置文件      8) 查看当前配置     9) 设置出站代理(ALL_PROXY)"
    echo -e " 10) 切换是否禁止内网上游                  11) 测试反代某上游 Emby"
    echo -e " 12) 更新程序(git pull+编译+重启)          13) 使用说明"
    echo -e " 14) 卸载               0) 退出"
    echo -e "${C_B}----------------------------------------------${C_N}"
}

menu_loop() {
    while true; do
        show_menu
        read -rp "请选择: " choice
        case "$choice" in
            1) svc_start ;;
            2) svc_stop ;;
            3) svc_restart ;;
            4) svc_status ;;
            5) svc_tailf ;;
            6) svc_logs ;;
            7) edit_config ;;
            8) show_config ;;
            9) set_outbound_proxy ;;
            10) toggle_private_targets ;;
            11) test_upstream ;;
            12) do_update ;;
            13) show_usage ;;
            14) do_uninstall ;;
            0) exit 0 ;;
            *) msg_warn "无效选择" ;;
        esac
        echo ""
        read -rp "按回车返回菜单..." _
    done
}

case "$1" in
    start)    svc_start ;;
    stop)     svc_stop ;;
    restart)  svc_restart ;;
    status)   svc_status ;;
    logs)     svc_logs ;;
    tailf)    svc_tailf ;;
    config)   show_config ;;
    test)     test_upstream ;;
    update)   do_update ;;
    usage)    show_usage ;;
    "")       menu_loop ;;
    *)        echo "用法: emby [start|stop|restart|status|logs|tailf|config|test|update|usage]"; exit 1 ;;
esac
