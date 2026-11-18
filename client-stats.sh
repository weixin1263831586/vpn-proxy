#!/bin/bash
# rk-vpn-proxy 客户端统计入口：始终从工作区源码运行，不更改运行中的部署。
# 用法:
#   ./client-stats.sh            终端全屏实时面板（q 退出）
#   ./client-stats.sh web        浏览器弹框面板（服务方式，Ctrl-C 停止）
#   ./client-stats.sh list       单次文本报表
#   ./client-stats.sh json       单次 JSON 输出
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mode=${1:-tui}
case "$mode" in
    tui|web|list|json) ;;
    *) echo "用法: $0 [tui|web|list|json]" >&2; exit 2 ;;
esac

# Never overwrite /usr/local/libexec from a CLI statistics invocation.
# Deployed systemd processes are only updated by the transactional install.sh.
# The source copy will read /etc/rk-vpn-proxy/config.json when installed.
case "$mode" in
    tui)  exec python3 "$source_dir/scripts/client_stats.py" --tui ;;
    web)  exec python3 "$source_dir/scripts/client_stats.py" --serve ;;
    list) exec python3 "$source_dir/scripts/client_stats.py" ;;
    json) exec python3 "$source_dir/scripts/client_stats.py" --json ;;
esac
