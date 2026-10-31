#!/bin/bash
# rk-vpn-proxy 客户端统计入口：优先用已部署副本，需要时自动同步并安装。
# 用法:
#   ./client-stats.sh            终端全屏实时面板（q 退出）
#   ./client-stats.sh web        浏览器弹框面板（服务方式，Ctrl-C 停止）
#   ./client-stats.sh list       单次文本报表
#   ./client-stats.sh json       单次 JSON 输出
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
deployed=/usr/local/libexec/rk-vpn-proxy-client-stats

mode=${1:-tui}
case "$mode" in
    tui|web|list|json) ;;
    *) echo "用法: $0 [tui|web|list|json]" >&2; exit 2 ;;
esac

sync () {
    # Refresh the deployed copy when running as root; otherwise prefer the
    # source tree so non-root users still get a working command.
    if [[ $EUID == 0 ]]; then
        if [[ ! -x "$deployed" ]] || ! cmp -s "$source_dir/scripts/client_stats.py" "$deployed"; then
            install -m0755 "$source_dir/scripts/client_stats.py" "$deployed"
        fi
        exec "$deployed" "$@"
    fi
    echo "提示: 未以 root 运行,使用源码副本（套接字与日志需要 root 才能完整统计）" >&2
    exec python3 "$source_dir/scripts/client_stats.py" "$@"
}

case "$mode" in
    tui)  sync --tui ;;
    web)  sync --serve ;;
    list) sync ;;
    json) sync --json ;;
esac
