#!/bin/bash
set -euo pipefail
source /etc/rk-vpn-proxy/runtime.env
proxy_uid=$(id -u rk-vpn-proxy)
rules=$(mktemp)
trap 'rm -f "$rules"' EXIT
# Delete and recreate in one atomic nft transaction; do not flush other rules.
if nft list table inet rk_vpn_proxy >/dev/null 2>&1; then
    echo 'delete table inet rk_vpn_proxy' >> "$rules"
fi
cat >> "$rules" <<EOF
table inet rk_vpn_proxy {
    chain output {
        type filter hook output priority 10; policy accept;
        meta skuid $proxy_uid jump proxy_egress
    }
    chain proxy_egress {
        ct direction reply tcp sport { $PROXY_PORT, $HEALTH_PORT } counter accept comment "proxy responses to clients"
        oifname "lo" ip daddr 127.0.0.1 udp dport 1024-65535 counter accept comment "Squid helper IPC"
        oifname "lo" ip6 daddr ::1 udp dport 1024-65535 counter accept comment "Squid helper IPC IPv6"
        oifname "$VPN_INTERFACE" counter accept comment "VPN egress including DNS"
        counter reject with icmpx type admin-prohibited comment "block VPN fallback"
    }
}
EOF
nft --check --file "$rules"
nft --file "$rules"
