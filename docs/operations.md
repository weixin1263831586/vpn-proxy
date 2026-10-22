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

默认白名单只显式授权当前已知的编译服务器：`10.10.10.206/32`、`172.16.14.66/32`。新增客户端时应修改 `allowed_clients` 显式列出其地址或网段，不要直接放开整个 RFC1918。公网来源需显式开启，默认拒绝；`0.0.0.0/0`、`::/0` 始终被拒绝。若确需支持多个办公网段，使用类似下面的部署示例（不是默认策略，仍应按实际授权范围收窄）：

```json
"allowed_clients": ["10.10.10.0/24", "172.16.14.0/24"]
```

代理与安装脚本下载服务目前共用这一份来源白名单；需要更细的区分时应单独评估。

```bash
cd /path/to/vpn-proxy
sudo bash install.sh
```

安装器检查发行版 `squid.service` 是否正在运行；发现已有服务时退出，由管理员先处理迁移。Squid 和 nftables 分别检查并按需安装。安装器先校验并暂存配置，再保存部署快照，按需安装依赖、创建账户。暂存的 Squid/nftables 配置通过校验后，停止旧服务、替换运行文件、启用防火墙守护与代理，通过 HTTPS 检查后同步 UFW、启动下载与监控。部署和回滚共用互斥锁。普通失败自动尝试恢复本次部署前状态。

部署验收以上面的代理 HTTPS 就绪检查和下载服务检查为准；安装结束时启动一次健康检查，其结果只作记录和告警，失败不会回滚已经通过验收的部署（例如出口 IP 查询服务偶发不可用不应撤销正常部署）。后续运行状态由健康定时器周期性探测。

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
tmp=$(mktemp)
if curl --noproxy '*' -fsSL http://172.16.14.233:8089/install.sh -o "$tmp"; then
    source "$tmp"
    result=$?
else
    echo '下载安装脚本失败' >&2
    result=1
fi
rm -f -- "$tmp"
test "$result" -eq 0
```

先下载到临时文件并确认成功，再加载执行。下载失败时整段命令返回非零，不会把下载子进程的退出码误判为安装成功，也便于保留错误信息和记录安装日志。该命令中的主机和端口应与实际下载服务一致。安装器先验证代理的 CONNECT 隧道和目标 HTTPS 响应，成功后备份该用户配置，写入环境文件并加载，最后执行 Google HEAD 测试。连接超时为 20 秒，单次请求最长 45 秒，临时错误最多重试 2 次。

需要覆盖代理地址时，把上面代码块中的 `source` 行改为传入第一个参数：

```bash
source "$tmp" http://proxy.example.internal:7897
```

也支持 `RK_VPN_PROXY_URL`、`RK_VPN_TEST_URL`、`RK_VPN_NO_PROXY`。例如指定额外的内网绕过地址，先导出变量，再执行上面的安装代码块：

```bash
export RK_VPN_NO_PROXY=git.internal,redmine.internal
```

HTTPS 代理探测要求 CONNECT 成功且目标返回 2xx 或 3xx。探测失败不会覆盖持久配置。环境文件为 `~/.config/rk-vpn-proxy/env.sh`（0600），配置及备份目录为 0700。生成的环境脚本仅在 Bash 中加载，避免影响使用 `.profile` 的 POSIX Shell。备份位于同目录的 `backups/`。安装器在 `.bashrc`、`.profile` 和已存在的优先登录入口中添加加载块，重复执行不会重复添加。

使用 `source` 可让当前终端生效。不希望影响当前终端时，也可以把下载好的临时文件交给子 Shell 执行（`bash "$tmp"`），只对安装子进程及后续新终端生效；不要使用 `curl ... | bash`，管道会掩盖下载失败的退出码。已有终端也可手动加载：

```bash
source ~/.config/rk-vpn-proxy/env.sh
curl -I https://www.google.com
```

默认 `no_proxy` 包含回环地址和 RFC1918 CIDR，保留用户原条目。注意 **curl 7.86.0 之前的版本不支持 NO_PROXY 中的 CIDR 写法**（如 Ubuntu 22.04 自带的 7.81.0），这些网段条目在旧客户端上不生效，访问内网 Git/Gerrit/Redmine 等服务会意外经过代理，并被 Squid 的私网目标 ACL 拒绝（403 ERR_ACCESS_DENIED）。旧版 curl 客户端应把实际内网服务的主机名或 IP 通过 `RK_VPN_NO_PROXY` 或配置文件显式加入 `no_proxy`，并先在客户端验证：

```bash
curl --version | head -1
# 替换为真实内网地址；Trying 后是代理地址说明仍会经过代理，是目标地址则已绕过
curl -v -I --max-time 10 http://10.10.10.4/ 2>&1 | grep -E 'Uses proxy|Trying'
```

Windows 系统代理的绕过列表不自动转换 CIDR，应添加具体内网域名/IP。Git、Java、APT 等应用若另有显式代理配置，应按该应用的实际配置方式处理。

推荐使用 SSH 获取同一个安装脚本。核对 SSH 主机密钥，按实际账户执行。下载失败时同样返回非零：

```bash
tmp=$(mktemp)
if ssh -o StrictHostKeyChecking=ask proxy_user@172.16.14.233 'cat /usr/local/lib/rk-vpn-proxy/build/client-install.sh' > "$tmp"; then
    source "$tmp"
    result=$?
else
    echo '下载安装脚本失败' >&2
    result=1
fi
rm -f -- "$tmp"
test "$result" -eq 0
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

`tests/test-killswitch.sh` 使用源码和临时配置，在独立网络命名空间启动真实 Squid，模拟 VPN 正常、掉线、恢复及专用规则损坏。`--systemd` 额外创建临时测试单元验证守护失败后实际代理被停止，并以高频请求测量从删除专用规则到代理真正停止期间经备用网卡转发的请求数：删除前基线为零，停止后不再有请求，窗口内的实际转发数打印在 PASS 行中。结束时清理单元和临时文件。测试无需预先部署，首次测试可能创建代理系统用户；不会修改正式配置或操作真实 VPN。

`tests/test-deployment-drill.sh` 在真实 Ubuntu 系统（容器、VM 或 CI 运行器）上执行部署故障注入演练。脚本拒绝在已有 rk-vpn-proxy 部署的主机上运行，只能用于一次性环境。覆盖场景：

| 注入的故障 | 验证结果 |
| --- | --- |
| 安装新版本时 Squid 配置错误 | 原服务自动恢复并保持可用 |
| 安装期间 apt 下载失败 | 不残留半成品部署，安装前状态保持一致（含 `squid.service` 屏蔽状态；注意 `apt-get remove squid` 自身会留下屏蔽） |
| 安装中途 SIGTERM | 自动恢复上一个部署 |
| 安装中途 SIGKILL（模拟断电） | 依据事务快照人工恢复成功 |
| 完整回滚 | 文件、服务、专用 nftables 表及项目 UFW 规则全部移除 |

可选环境变量：`DRILL_TEST_URL`、`DRILL_DNS`、`DRILL_UFW=1`（演练 UFW 活跃时的规则同步与回滚清理）。Docker 示例：

```bash
docker run --privileged -d --name vpn-proxy-drill ubuntu:24.04 /sbin/init
docker exec vpn-proxy-drill bash -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y squid nftables curl iproute2 ufw'
docker cp . vpn-proxy-drill:/opt/vpn-proxy
docker exec vpn-proxy-drill bash -c 'DRILL_UFW=1 bash /opt/vpn-proxy/tests/test-deployment-drill.sh'
docker rm -f vpn-proxy-drill
```

GitHub Actions 运行语法、回归、生成一致性、Linux 隔离集成及 Windows PowerShell 5.1/7 检查，并在一次性运行器上执行上述真实部署演练（UFW 活跃路径需本地带 `DRILL_UFW=1` 演练）。基于 Mock 的部署恢复测试仍保留，用于快速回归。

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
