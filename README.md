# emby-proxy-go-deploy

通用 Emby 反向代理 [emby-reverse-proxy-go](https://github.com/Gsy-allen/emby-reverse-proxy-go) 的一键部署套件：

- 一键安装：自动装依赖、拉取上游源码编译、注册 systemd 服务、配置 nginx 前端
- 可选绑定自己的域名，**自动申请并续期 Let's Encrypt 证书**
- 自带交互式管理脚本 `emby`（启停/日志/改配置/测速/一键更新/卸载）
- 流媒体友好：nginx 关闭缓冲、WebSocket 转发、3600s 长超时、不限上传体积

## 架构

```
用户/Emby客户端 ──> nginx (80/443, TLS) ──> emby-proxy (127.0.0.1:8080) ──> 任意公网 Emby 上游
                    自动申请证书              Go 反代, systemd 托管          上游写在 URL 路径里
```

## 环境要求

- 支持 **Debian/Ubuntu (apt)** 与 **RHEL 系：CentOS / Rocky / Alma / Alibaba Cloud Linux 等 (dnf/yum)**
- 架构支持 x86_64 与 ARM64（其余架构需自行准备 Go 工具链）
- 需要 systemd；root 权限运行
- （可选）一个已解析到本机的域名，用于 HTTPS
- 脚本会自动检测并安装缺失的 git/curl/tar/nginx/certbot

## 一键安装

```bash
git clone https://github.com/2020743996/emby-proxy-go-deploy.git
cd emby-proxy-go-deploy

# 全程交互式(会询问是否绑定域名)
sudo bash install.sh

# 指定域名 + HTTPS(推荐, 先确保域名 A 记录已指向服务器)
sudo bash install.sh --domain emby.example.com --email me@example.com

# 不用域名，纯 HTTP 用 IP 访问
sudo bash install.sh --no-domain -y

# 自定义后端端口
sudo BACKEND_PORT=9090 bash install.sh -y
```

> 云服务器请提前在安全组放行 **80 和 443** 端口，否则证书申请和外部访问都会失败。

安装完成后入口即生效：

```
https://你的域名/{http|https}/{上游Emby域名}/{端口}/...
例如: https://emby.example.com/https/some-emby.com/443/
```

Emby 客户端里把"服务器地址"填成上面的入口 URL 即可。注意域名和端口都不能省略；访问根路径返回 400 属正常现象。

## 管理

```bash
emby            # 交互菜单
emby status     # 服务状态 + 本机/对外健康检查
emby logs       # 最近100行日志
emby update     # git pull + 重新编译 + 重启
emby usage      # 使用说明
```

菜单内还支持：设置出站代理(ALL_PROXY)、切换是否允许反代内网上游、测试某个上游连通性等。

## 常用路径

| 内容 | 位置 |
|---|---|
| 主程序 | `/opt/emby-reverse-proxy-go/emby-proxy` |
| 源码 | `/opt/emby-reverse-proxy-go/src` |
| 配置 | `/opt/emby-reverse-proxy-go/emby-proxy.env` |
| nginx 站点 | `/etc/nginx/sites-available/emby-proxy` |
| 证书 | `/etc/letsencrypt/live/<域名>/` (certbot.timer 自动续期) |

## 更新 / 卸载

```bash
emby update        # 更新反代本体
sudo bash uninstall.sh   # 卸载(保留证书, 程序与配置自动备份)
```

## FAQ

- **证书申请失败**：检查域名解析是否指向本机、安全组是否放行 80；修好后重跑 `install.sh` 即可（幂等，可反复执行）。
- **上游是内网 Emby**：编辑 `/opt/emby-reverse-proxy-go/emby-proxy.env` 把 `BLOCK_PRIVATE_TARGETS=false`，重启服务。
- **想换域名**：重新运行 `install.sh --domain 新域名`。
- **速度不理想**：优先排查客户端到本机的线路质量，以及 Emby 控制台是否将会话判定为转码。

## 致谢

核心程序：[Gsy-allen/emby-reverse-proxy-go](https://github.com/Gsy-allen/emby-reverse-proxy-go)

## 许可证

[MIT](LICENSE)
