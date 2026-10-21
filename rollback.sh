#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
systemctl disable --now rk-vpn-proxy-health.timer rk-vpn-proxy.service rk-vpn-proxy-firewall.service
systemctl stop rk-vpn-proxy-health.service || true
# Stop all protected processes before removing the dedicated firewall table.
if nft list table inet rk_vpn_proxy >/dev/null 2>&1; then
    nft delete table inet rk_vpn_proxy
fi
echo 'Proxy and monitoring disabled. Configurations and logs retained for review.'
echo 'To restore the Windows proxy on the build server:'
echo 'export http_proxy=http://172.16.14.66:7897 https_proxy=http://172.16.14.66:7897 HTTP_PROXY=http://172.16.14.66:7897 HTTPS_PROXY=http://172.16.14.66:7897'
