# 编译服务器 VPN HTTP 代理

目标路径：`10.10.10.206 → 172.16.14.233:7897 → ppp0 → 互联网`。

## 一键安装

在编译服务器 `10.10.10.206` 的 Bash 终端执行：

```bash
source <(curl --noproxy '*' -fsSL http://172.16.14.233:8089/install.sh)
```

脚本会先检查新代理连通性，备份旧配置，安装当前用户的代理环境，加载到当前终端，
并自动执行 `curl -I https://www.google.com`（附带连接及总超时）。新终端也会自动生效。
下载时绕过旧代理。重复执行不会重复添加启动配置。
如使用 `curl ... | bash`，环境仅在安装子进程和后续新终端生效，当前终端需另行 source 环境文件。

## 部署结果（2026-10-21）

两端已完成部署。编译服务器 `hcq` 用户的新登录及交互式 Bash 均自动加载
`~/.config/rk-vpn-proxy/env.sh`，原启动文件备份在
`~/.config/rk-vpn-proxy/backups/` 下的时间戳目录。

代理端口已由 3128 迁移至 7897；一键安装已在实际服务器及独立测试 HOME 中验证，
包括首次安装、重复安装、当前终端和新登录/交互式终端加载。

已从编译服务器验证 Google、Android 下载服务、Android 源码站和 GitHub 的 HTTPS 隧道及证书；
通过代理执行 Android manifest 和 GitHub Git 仓库的 `git ls-remote` 均成功。
实际公网出口为 `103.197.30.140`。
本机隔离网络测试已验证 VPN 掉线阻断及恢复，未断开真实 VPN。

已经打开的编译终端执行 `. ~/.config/rk-vpn-proxy/env.sh` 后生效。

## 本机服务

Squid 使用独立用户 `rk-vpn-proxy`，配置位于 `/etc/rk-vpn-proxy/squid.conf`。
仅监听 `172.16.14.233:7897` 和用于本机健康检查的 `127.0.0.1:17897`。
`127.0.0.1:7897` 已有其他程序，保留该程序的监听。
内网监听只允许 `10.10.10.206`；私网目标和 80/443 以外的端口会被拒绝。

独立 nftables 表 `inet rk_vpn_proxy` 只限制代理用户的出站流量：
允许向客户端回复、Squid 本机 UDP IPC，以及经 `ppp0` 的请求；其他出站流量全部拒绝。
DNS 直接发送给 `8.8.8.8` / `1.1.1.1`，同样受 VPN 出口限制。
VPN 掉线后不能借用普通网卡出口，恢复 `ppp0` 及其路由后自动恢复新请求。
VPN 客户端自身的重连由原有 VPN 连接配置负责。

每分钟检查一次实际 HTTPS 出口，VPN 状态及公网 IP 变化写入 systemd journal。

```bash
systemctl status rk-vpn-proxy.service
journalctl -u rk-vpn-proxy-health.service -n 30 --no-pager
sudo tail -f /var/log/rk-vpn-proxy/access.log
sudo nft list table inet rk_vpn_proxy
```

原发行版的 `squid.service` 已屏蔽，避免它使用默认配置启动其他监听。
代理访问日志由 `/etc/logrotate.d/rk-vpn-proxy` 每天轮转，保留 7 份。

## 编译服务器配置

使用上方 curl 一键命令即可，无需 SSH 密钥和 sudo。
安装脚本先验证 Google 的 HTTPS 隧道，成功后才备份并修改该用户的 `.bashrc` / `.profile`，
若已有 `.bash_profile` / `.bash_login` 则同步补充实际登录入口。
已打开的编译终端需执行：

```bash
. ~/.config/rk-vpn-proxy/env.sh
curl -I https://www.google.com
```

`no_proxy` 保留已有条目并补充文档中已知的内网主机；其他内部服务需按实际域名/IP 补充。
已有 Git、APT、Java 等工具若显式指定了旧代理，需要另外检查相应配置。
既有进程、其他用户和 systemd 构建任务不会自动继承用户 shell 的环境变量。

## 验证与维护

```bash
# 本机真实站点与 TLS 验证
bash /home/hcq/vpn-proxy/check-client.sh http://127.0.0.1:17897

# 在独立网络命名空间模拟 VPN 掉线与恢复，不断开真实 VPN
sudo bash /home/hcq/vpn-proxy/test-killswitch.sh

# 重新部署本机服务
sudo bash /home/hcq/vpn-proxy/install.sh

# 停用本机服务和专用防火墙，保留配置/日志
sudo bash /home/hcq/vpn-proxy/rollback.sh
```

下载服务由用户级 `rk-vpn-proxy-installer.service` 管理，随用户管理器启动（本机已启用 linger）。
服务只提供 `/install.sh`，只接受编译服务器及本机来源，不提供目录浏览或其他文件。

```bash
systemctl --user status rk-vpn-proxy-installer.service
journalctl --user -u rk-vpn-proxy-installer.service -n 20 --no-pager
```

修改客户端环境模板后，执行 `python3 /home/hcq/vpn-proxy/build-installer.py` 重新生成独立安装脚本，下载服务无需重启。
初次部署下载服务时，将同目录的 `rk-vpn-proxy-installer.service` 安装至 `~/.config/systemd/user/`，
再执行 `systemctl --user daemon-reload` 和 `systemctl --user enable --now rk-vpn-proxy-installer.service`。

回退客户端时，删除 `.bashrc` / `.profile` 中的 `rk-vpn-proxy environment` 块（或使用备份恢复），在新终端设置旧 Windows 代理：

```bash
export http_proxy=http://172.16.14.66:7897
export https_proxy="$http_proxy" HTTP_PROXY="$http_proxy" HTTPS_PROXY="$http_proxy"
```

规则依据：[Squid DNS 配置](https://www.squid-cache.org/Doc/config/dns_nameservers/)、
[nftables 用户匹配](https://wiki.nftables.org/wiki-nftables/index.php/Matching_packet_metainformation)。
