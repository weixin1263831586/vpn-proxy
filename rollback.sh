#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
systemctl disable --now rk-vpn-proxy-installer.service rk-vpn-proxy-health.timer rk-vpn-proxy.service rk-vpn-proxy-firewall.service
systemctl stop rk-vpn-proxy-health.service || true
# Stop all protected processes before removing the dedicated firewall table.
if nft list table inet rk_vpn_proxy >/dev/null 2>&1; then
    nft delete table inet rk_vpn_proxy
fi
echo 'Proxy and monitoring disabled. Configurations and logs retained for review.'
echo 'On clients, remove the rk-vpn-proxy startup block or restore the backed-up startup files.'
echo 'In the client terminal, disable the proxy with:'
echo 'unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY'
