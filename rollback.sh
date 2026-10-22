#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec 9>/run/lock/rk-vpn-proxy-deploy.lock
flock -n 9 || { echo 'Another deployment or rollback is running.' >&2; exit 1; }
original=/var/lib/rk-vpn-proxy-deploy/original
# Remove both the dedicated nftables table and the second-layer policy routing.
# firewall.sh --cleanup works without the deployed runtime.env (it identifies
# rules by the proxy UID), so this also runs after restore removed /etc.
cleanup_firewall() {
    bash "$source_dir/scripts/firewall.sh" --cleanup
    if nft list table inet rk_vpn_proxy >/dev/null 2>&1; then
        nft delete table inet rk_vpn_proxy
    fi
}
if [[ -f "$original/state.json" ]]; then
    LC_ALL=C python3 -B "$source_dir/scripts/deployment.py" restore "$original"
    mv -- "$original" "${original%/*}/restored-$(date +%Y%m%d-%H%M%S)-$$"
    cleanup_firewall
    echo 'Restored files, service state, proxy firewall and owned UFW rules from before the first managed deployment.'
    echo 'Packages, system users, logs and client settings retained.'
    exit 0
fi
# Older installations have no baseline; stop safely without guessing prior state.
python3 -B "$source_dir/scripts/deployment.py" stop
systemctl disable rk-vpn-proxy-installer.service rk-vpn-proxy-health.timer rk-vpn-proxy.service rk-vpn-proxy-firewall.service
LC_ALL=C python3 -B "$source_dir/scripts/deployment.py" ufw-clear
cleanup_firewall
echo 'Proxy and monitoring disabled. Configurations and logs retained for review.'
echo 'No deployment baseline exists; the original distribution Squid state is unknown and was not changed.'
echo 'On clients, remove the rk-vpn-proxy startup block or restore the backed-up startup files.'
echo 'In the client terminal, disable the proxy with:'
echo 'unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY'
