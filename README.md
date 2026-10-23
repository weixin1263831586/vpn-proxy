# VPN HTTP 代理

让其他电脑的浏览器、curl、Git 等应用，通过一台已连接 VPN 的 Ubuntu 主机访问外网。服务端使用 Squid，按客户端 IP/CIDR 白名单授权，并用 nftables 和策略路由限制代理出口；支持 Linux Bash 和 Windows PowerShell 客户端。

项目不负责建立或重连 VPN，只转发使用代理的 HTTP/HTTPS 应用流量。HTTPS 使用 CONNECT 隧道，不解密目标站点的 TLS。

## 当前配置

以下为仓库 [config.json](config.json) 的配置，实际运行状态以已部署服务为准：

| 用途 | 地址 / 配置 |
| --- | --- |
| HTTP 代理 | `http://172.16.14.233:7897` |
| 本机健康检查代理 | `http://127.0.0.1:17897`，仅回环监听 |
| Linux 安装器 | `http://172.16.14.233:8089/install.sh` |
| Windows 安装器 | `http://172.16.14.233:8089/install.ps1` |
| VPN 接口 | `ppp0` |
| 客户端白名单 | `10.10.10.206/32`、`172.16.14.66/32` |

下载服务与代理共用客户端白名单。`installer_enabled` 缺省为 false，本仓库配置显式设为 true。

## 部署与重启

代理服务器需要支持 apt、systemd 的 Ubuntu，已连接 VPN，并具备到客户端的回程路由。首次部署前安装基础依赖：

```bash
sudo apt-get update
sudo apt-get install -y python3 curl iproute2 util-linux
```

在项目目录编辑 `config.json`：

| 字段 | 按实际环境设置 |
| --- | --- |
| `listen_host` | 服务器本机的 IPv4 监听地址 |
| `advertise_host` | 客户端能访问的服务器 IP 或域名 |
| `vpn_interface` | 已建立连接的 VPN 接口 |
| `allowed_clients` | 获准接入的客户端 IP/CIDR |
| `no_proxy` | 客户端需要直连的内网地址或域名 |

完整字段见[操作说明](docs/operations.md#部署服务端)。编辑后部署：

```bash
cd /home/hcq/vpn-proxy  # 按实际源码位置调整
sudo bash install.sh
```

安装器按需安装 Squid/nftables，更新系统目录中的运行副本、重启并检查服务；普通失败会尝试恢复部署前状态。已有发行版 `squid.service` 正在运行时，须先处理迁移。

**修改源码或配置后重新运行 `install.sh`；仅重启不会更新运行副本。** 重启已安装版本及查看日志：

```bash
sudo systemctl restart rk-vpn-proxy-firewall.service rk-vpn-proxy.service
systemctl status rk-vpn-proxy-firewall.service rk-vpn-proxy.service --no-pager
sudo journalctl -u rk-vpn-proxy.service -u rk-vpn-proxy-firewall.service -n 50 --no-pager
```

启用了下载服务时，可单独执行 `sudo systemctl restart rk-vpn-proxy-installer.service`。

### 在其他主机部署新代理服务器

从当前主机同步工作区（两端需有 rsync），替换实际账号和目标地址：

```bash
rsync -av \
  --exclude='.git/' --exclude='build/' --exclude='__pycache__/' \
  --exclude='validation/' --exclude='vpn.txt' \
  /home/hcq/vpn-proxy/ proxy_user@NEW_HOST:~/vpn-proxy/
ssh proxy_user@NEW_HOST
```

在目标 Ubuntu 主机连接好 VPN，安装上述基础依赖后执行：

```bash
cd ~/vpn-proxy
nano config.json
sudo bash install.sh
```

将监听地址、发布地址、VPN 接口、白名单和内网绕过条目改为新环境的实际值。

## 其他电脑使用本机代理

客户端无需安装 VPN 客户端，但必须能访问代理主机的 `7897` 端口。先在服务器的 `config.json` 中添加客户端 IP，保留已有条目；例如新增 `192.168.1.100`（以下为字段片段）：

```json
"allowed_clients": ["10.10.10.206/32", "172.16.14.66/32", "192.168.1.100/32"]
```

替换为实际客户端 IP，然后在服务器项目目录运行 `sudo bash install.sh`。公网客户端需显式设置 `allow_public_clients: true`；始终禁止 `0.0.0.0/0` 和 `::/0`。

### 临时使用

Linux / Bash 在客户端终端执行：

```bash
export http_proxy=http://172.16.14.233:7897
export https_proxy="$http_proxy"
unset all_proxy ALL_PROXY
curl --noproxy '' --proxy "$http_proxy" --connect-timeout 10 --max-time 30 -I https://www.google.com
```

Windows 浏览器可在“设置 → 网络和 Internet → 代理 → 手动设置代理”中填写地址 `172.16.14.233`、端口 `7897`。PowerShell 终端可另行配置：

```powershell
$env:http_proxy = 'http://172.16.14.233:7897'
$env:https_proxy = $env:http_proxy
Remove-Item Env:all_proxy -ErrorAction SilentlyContinue
curl.exe --noproxy "localhost,127.0.0.1" --proxy $env:http_proxy --connect-timeout 10 --max-time 30 -I https://www.google.com
```

终端变量只影响当前终端及其启动的程序。测试代理时不要用 `--noproxy "*"`，它会绕过代理。

### 持久安装

推荐通过核对主机密钥后的 SSH 获取安装器，步骤见[客户端配置](docs/operations.md#配置客户端)。信任内网 HTTP 下载链路时，也可使用以下方式（需开放并能访问 `8089` 端口）。

Linux：在客户端 Bash 中以实际使用代理的用户执行，下载成功后加载安装器：

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

Windows：在 PowerShell 中执行（CMD 用户先输入 `powershell -NoProfile`）：

```powershell
$proxyScript = curl.exe --noproxy "*" -fsSL http://172.16.14.233:8089/install.ps1
if ($LASTEXITCODE -ne 0) { throw "Installer download failed" }; & ([scriptblock]::Create(($proxyScript -join "`n"))) -SystemProxy
```

Bash 安装器配置当前终端和后续 Bash；Windows 安装器配置当前进程和用户环境，`-SystemProxy` 额外设置 Windows 用户代理。两者先验证代理连通性再写入配置，并保留恢复备份；安装后自动测试。已运行的其他终端或应用可能需要重开。

`no_proxy` 保留已有条目并合并配置中的内网地址。旧版 curl 可能不支持 CIDR 绕过，应显式添加实际内网 IP/域名；备份恢复、SSH 安装和参数覆盖见[操作说明](docs/operations.md)。

## 出口保护与限制

- Squid 以独立用户运行；nftables 允许客户端连接回复、本机 helper 通信及 VPN 接口出站，拒绝其他出口。DNS 查询也由该用户发出。
- 策略路由为代理 UID 设置 VPN 默认路由和不可达兜底；客户端白名单网段例外，沿用 main 表回程路由。守护进程持续核对规则、修复路由；nftables 规则异常或守护进程退出时，systemd 联动停止代理。
- VPN 掉线时阻断代理流量；接口和路由恢复后新请求可恢复，已断开的下载需重试。保护依赖实际路由和规则状态，隔离测试的零泄漏结果仅覆盖指定故障与测试流量。
- 访问控制基于来源 IP，没有账号密码认证。目标仅允许 80/443，CONNECT 仅允许 443，并拒绝配置列出的私网、回环和链路本地等地址。
- 当前服务端按 IPv4 监听和部署；IPv6 策略路由用于出站保护，不代表提供完整 IPv6 客户端支持。
- 项目不提供全系统隧道、UDP 转发、VPN 自动重连或多节点切换。HTTP 安装下载无传输完整性保护，应仅在可信链路使用。

路由表、规则优先级、健康状态及故障边界见[架构说明](docs/architecture.md)；部署恢复和日常维护见[操作说明](docs/operations.md#运行维护)。

## 验证与源码

```bash
python3 -B -m unittest discover -s tests -v
bash tests/test_policy_routing.sh
bash tests/test_policy_routing_kernel.sh
sudo bash tests/test-killswitch.sh --systemd
```

内核路由测试需要用户命名空间权限，也可加 sudo 执行；systemd 集成测试在隔离网络中验证真实 Squid 转发、VPN 掉线/恢复及保护规则故障。CI 另有 Windows PowerShell 5.1/7 测试和一次性环境部署演练，详见[验证说明](docs/operations.md#验证)。

核心源码：配置校验 [configuration.py](configuration.py)、生成器 [build-installer.py](build-installer.py)、客户端与 Squid 模板 [templates/](templates/)、防火墙与部署恢复 [scripts/](scripts/)、服务单元 [systemd/](systemd/)。`build/` 是生成目录；运行 `python3 build-installer.py` 可重建，正式服务使用系统目录中的副本。
