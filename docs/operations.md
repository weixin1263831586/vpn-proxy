# 操作说明

原理、架构和限制见 [README](../README.md)。

## 部署服务端

适用于提供 apt、systemd 和 nftables 的 Ubuntu 环境。主机需已建立 VPN，具备到客户端的回程路由，并能经 VPN 访问外网。运行脚本前应具备 Bash、Python 3、curl、iproute2 和 sudo/root 权限；隔离网络测试还使用 util-linux 的命名空间工具。

项目可放在任意目录。先编辑 [config.json](../config.json)：

| 字段 | 含义 |
| --- | --- |
| `listen_host` | 本机 IPv4 监听地址 |
| `advertise_host` | 客户端连接的代理 IPv4 地址或 DNS 名称 |
| `proxy_port` | HTTP 代理端口 |
| `health_port` | 回环健康检查端口 |
| `installer_port` | 安装脚本下载端口 |
| `vpn_interface` | 允许代理使用的 VPN 出站接口 |
| `allowed_clients` | 允许访问代理及下载服务的来源 CIDR 列表 |
| `allow_public_clients` | 可选，默认 false；公网来源需显式开启，仍拒绝 /0 |
| `dns_nameservers` | Squid 使用的 IPv4 DNS 服务器 |
| `test_url` | 客户端安装时验证的 HTTPS 地址 |
| `no_proxy` | 合并进客户端 `no_proxy` 的默认条目 |

当前默认白名单为 RFC1918 内网：`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`。这允许整个 RFC1918 来源范围，应根据实际授权网络收窄；配置没有硬编码某台客户端。公网来源需显式开启，默认拒绝。

```bash
cd /path/to/vpn-proxy
sudo bash install.sh
```

安装器检查发行版 `squid.service` 是否正在运行；发现已有服务时退出，由管理员先处理迁移。Squid 和 nftables 分别检查并按需安装。安装器先校验并暂存配置，再保存部署快照，按需安装依赖、创建账户。暂存的 Squid/nftables 配置通过校验后，停止旧服务、替换运行文件、启用防火墙守护与代理，通过 HTTPS 检查后同步 UFW、启动下载与监控。部署和回滚共用互斥锁。普通失败自动尝试恢复本次部署前状态。

部署记录位于 `/var/lib/rk-vpn-proxy-deploy/`（0700）：`transactions/` 保留每次尝试的快照，`original/` 保存第一次成功托管部署之前的基线。升级旧部署时，这份基线就是升级前的版本。软件包、新增系统账户、运行日志不回退；磁盘故障、断电或 SIGKILL 需人工恢复。

UFW 活跃时同步来源和两个端口。更新配置会清理旧规则；注释 `rk-vpn-proxy`、`rk-vpn-installer` 是项目保留标记，历史同标记规则也会纳入管理。已有相同选择条件的管理员规则不改归属，其他规则保留。UFW 关闭时只移除旧项目规则，不自动启用 UFW。

项目没有配置带宽或下载速率限制，实际吞吐量取决于 VPN、代理主机网络、目标站点及并发负载。

修改项目配置或程序后重新部署，安装器会更新运行副本和相关服务：

```bash
sudo bash install.sh
```

也支持 `sudo bash install.sh /path/to/config.json`。应修改配置源文件后重新部署，不直接修改 `build/` 下的生成文件。下载服务以 `rk-vpn-installer` 用户运行，程序路径固定在 `/usr/local/lib/rk-vpn-proxy/`，不依赖部署者的用户名、家目录或源码位置。

## 配置客户端

### Linux / Bash

在需要代理的机器上，用实际使用的用户打开 Bash，执行：

```bash
source <(curl --noproxy '*' -fsSL http://172.16.14.233:8089/install.sh)
```

该命令中的主机和端口应与实际下载服务一致。安装器先验证代理的 CONNECT 隧道和目标 HTTPS 响应，成功后备份该用户配置，写入环境文件并加载，最后执行 Google HEAD 测试。连接超时为 20 秒，单次请求最长 45 秒，临时错误最多重试 2 次。

需要覆盖代理地址时，传入第一个参数：

```bash
source <(curl --noproxy '*' -fsSL http://172.16.14.233:8089/install.sh) http://proxy.example.internal:7897
```

也支持 `RK_VPN_PROXY_URL`、`RK_VPN_TEST_URL`、`RK_VPN_NO_PROXY`。例如指定额外的内网绕过地址：

```bash
RK_VPN_NO_PROXY=git.internal,redmine.internal source <(curl --noproxy '*' -fsSL http://172.16.14.233:8089/install.sh)
```

HTTPS 代理探测要求 CONNECT 成功且目标返回 2xx 或 3xx。探测失败不会覆盖持久配置。环境文件为 `~/.config/rk-vpn-proxy/env.sh`（0600），配置及备份目录为 0700。生成的环境脚本仅在 Bash 中加载，避免影响使用 `.profile` 的 POSIX Shell。备份位于同目录的 `backups/`。安装器在 `.bashrc`、`.profile` 和已存在的优先登录入口中添加加载块，重复执行不会重复添加。

使用 `source` 可让当前终端生效；`curl ... | bash` 只在安装子进程及后续新终端生效。已有终端也可手动加载：

```bash
source ~/.config/rk-vpn-proxy/env.sh
curl -I https://www.google.com
```

默认 `no_proxy` 包含 RFC1918 CIDR，保留用户原条目。不同应用对 CIDR 的支持不同；内网域名可能需要显式列入 `no_proxy`，否则 Squid 拒绝私网目标会返回 403。Windows 系统代理的绕过列表不自动转换 CIDR，应添加具体内网域名/IP。Git、Java、APT 等应用若另有显式代理配置，应按该应用的实际配置方式处理。

推荐使用 SSH 获取同一个安装脚本。核对 SSH 主机密钥，按实际账户执行：

```bash
source <(ssh -o StrictHostKeyChecking=ask proxy_user@172.16.14.233 'cat /usr/local/lib/rk-vpn-proxy/build/client-install.sh')
```

### Windows / PowerShell

Windows 直接使用同一台 Ubuntu 主机的 HTTP 代理，无需在 Windows 安装 Squid 或公司 VPN 客户端。客户端需要能连接代理和下载端口，并在来源网段白名单内。

脚本使用 Windows PowerShell 5.1 语法，也可在 PowerShell 7 执行；需要系统提供 `curl.exe`。普通用户权限即可配置当前用户。

如果当前提示符是 `C:\Users\hcq>`，先执行 `powershell -NoProfile`，进入提示符以 `PS` 开头的 PowerShell。

有 `ssh.exe` 和代理主机登录权限时，推荐核对主机密钥后通过 SSH 获取安装器（替换实际账号）：

```powershell
$proxyScript = ssh.exe proxy_user@172.16.14.233 'cat /usr/local/lib/rk-vpn-proxy/build/client-install.ps1'
if ($LASTEXITCODE -ne 0) { throw "Installer download failed" }; & ([scriptblock]::Create(($proxyScript -join "`n"))) -SystemProxy
```

信任内网 HTTP 下载链路时，也可执行下面两行，包含终端环境及 Windows 用户代理（供遵循系统代理的浏览器/应用使用）：

```powershell
$proxyScript = curl.exe --noproxy "*" -fsSL http://172.16.14.233:8089/install.ps1
if ($LASTEXITCODE -ne 0) { throw "Installer download failed" }; & ([scriptblock]::Create(($proxyScript -join "`n"))) -SystemProxy
```

只需要 curl/Git 等终端工具时去掉 `-SystemProxy`。可以通过 `-ProxyUrl`、`-TestUrl`、`-NoProxy` 覆盖默认参数，也支持与 Bash 一致的 `RK_VPN_*` 环境变量。

安装流程先通过显式代理验证 CONNECT、TLS 及目标的 2xx/3xx 响应。成功后将 `http_proxy`、`https_proxy`、`no_proxy` 写入当前进程及当前用户环境，清除当前用户的 `all_proxy`，最后自动执行 `curl.exe -I` 测试。

Windows 环境变量名不区分大小写。当前 PowerShell 会立即生效；持久配置供新启动的应用继承，已运行的终端、IDE 等可能需要完全退出后重开。Windows PowerShell 5.1 中的 `curl` 可能是命令别名，文档统一使用 `curl.exe`。

`-SystemProxy` 额外配置 HKCU 的 Windows 用户代理，保存并移除当前 PAC URL，通知 WinINet 刷新。它不配置计算机级 WinHTTP 代理，也不转发全系统 TCP/UDP。Windows 绕过列表保留原条目并合并具体地址，`no_proxy` 中的 CIDR 不自动转换成 Windows 绕过规则。

若 Clash Verge 等程序正在接管 Windows 系统代理，应先停止其接管，避免再次覆盖本项目设置。浏览器有独立代理配置或受到策略管理时，需按该应用实际设置处理。

首次修改前的环境变量及所需的 Windows 用户代理设置备份到 `%LOCALAPPDATA%\rk-vpn-proxy\backup.json`。重复安装保留原备份；恢复时执行：

```powershell
$proxyScript = curl.exe --noproxy "*" -fsSL http://172.16.14.233:8089/install.ps1
if ($LASTEXITCODE -ne 0) { throw "Installer download failed" }; & ([scriptblock]::Create(($proxyScript -join "`n"))) -Uninstall
```

恢复后备份归档到同目录的 `restored-*.json`。HTTP 获取代码的信任边界与 Linux 安装方式相同，也可通过 SSH 读取 `/usr/local/lib/rk-vpn-proxy/build/client-install.ps1` 后执行。

接口连通性可以先独立测试：

```powershell
Test-NetConnection 172.16.14.233 -Port 7897
curl.exe --proxy http://172.16.14.233:7897 -I https://www.google.com
```

Windows 注册表、环境变量持久化与备份恢复测试位于 `tests/test-windows.ps1`，CI 分别用 Windows PowerShell 5.1 和 PowerShell 7 执行。本地 Linux 上的 PowerShell 检查仅验证脚本语法，不能替代 Windows 实机验证。

参考：[Microsoft 环境变量说明](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables)、[Windows curl 说明](https://learn.microsoft.com/windows/curl/)、[WinINet Internet 选项](https://learn.microsoft.com/en-us/windows/win32/wininet/setting-and-retrieving-internet-options)。

## 运行维护

```bash
# 代理、防火墙和监控定时器
systemctl status rk-vpn-proxy.service rk-vpn-proxy-firewall.service rk-vpn-proxy-health.timer

# 健康检查结果和日志
systemctl status rk-vpn-proxy-health.service
systemctl show rk-vpn-proxy-health.service -p Result -p ExecMainStatus
journalctl -u rk-vpn-proxy-health.service -n 30 --no-pager

# 安装脚本下载服务
systemctl status rk-vpn-proxy-installer.service

# 代理访问日志及出站规则
sudo tail -f /var/log/rk-vpn-proxy/access.log
sudo nft list table inet rk_vpn_proxy
```

健康检查是 oneshot 服务，成功执行完毕后显示 inactive 属正常情况，可结合 `Result`、`ExecMainStatus` 和 journal 判断最近执行结果。

代理日志位于 `/var/log/rk-vpn-proxy/`，每天轮转并保留 7 份。发行版的默认 Squid 单元在安装 Squid 包时被屏蔽，专用代理由 `rk-vpn-proxy.service` 管理。

需要重新加载出站规则及代理时：

```bash
sudo systemctl restart rk-vpn-proxy-firewall.service rk-vpn-proxy.service
```

### 验证

```bash
python3 -m unittest discover -s tests -v
bash check-client.sh
sudo bash tests/test-killswitch.sh --systemd
```

`check-client.sh` 可传入代理 URL，分别检查 Google、Android 下载/源码站和 GitHub 的 CONNECT、TLS 验证和 HTTP 响应，并汇总退出状态。目标网站返回 400、403 等有效 HTTP 响应不直接视为代理失败；安装器的单个测试 URL 则要求 2xx/3xx。

`tests/test-killswitch.sh` 使用源码和临时配置，在独立网络命名空间启动真实 Squid，模拟 VPN 正常、掉线、恢复及专用规则损坏。`--systemd` 额外创建临时测试单元验证守护失败后实际代理被停止，结束时清理单元和临时文件。测试无需预先部署，首次测试可能创建代理系统用户；不会修改正式配置或操作真实 VPN。

GitHub Actions 运行语法、回归、生成一致性、Linux 隔离集成及 Windows PowerShell 5.1/7 检查。部署恢复测试用临时文件和模拟系统命令注入故障；不等同于真实 apt/UFW/systemd 全流程安装验收。

### 停用与回滚

```bash
sudo bash rollback.sh
```

有 `original/` 基线时，回滚先停止项目服务，再恢复原文件、项目 UFW 规则、专用 nftables 表及服务启用/运行状态（包括发行版 Squid 的屏蔽状态），成功后归档基线。恢复途中失败会保持代理停用并报错。没有基线的旧安装只停用项目服务、清理专用表和项目 UFW 规则，不猜测安装前的发行版服务状态。软件包、账户、日志及客户端配置保留。

需要人工恢复某次失败安装时，可先检查对应快照，再以 root 执行（不要与部署并行）：

```bash
sudo flock /run/lock/rk-vpn-proxy-deploy.lock python3 -B scripts/deployment.py restore /var/lib/rk-vpn-proxy-deploy/transactions/实际快照目录
```

客户端可恢复备份，或删除启动文件中的 `rk-vpn-proxy environment` 加载块，并在当前终端执行：

```bash
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
```
