#!/bin/bash
set -euo pipefail
source "${RK_VPN_RUNTIME:-/etc/rk-vpn-proxy/runtime.env}"
state_dir=${RK_VPN_FIREWALL_STATE:-/run/rk-vpn-proxy-firewall}
mode=${1:---apply}
current_rules() { nft --stateless --numeric list table inet rk_vpn_proxy; }
check_rules() {
    local actual expected
    expected=$(cat "$state_dir/expected.nft") || return 1
    actual=$(current_rules 2>/dev/null) || return 1
    [[ -n "$expected" && "$actual" == "$expected" ]]
}
if [[ "$mode" == --check ]]; then
    check_rules
    exit
fi
[[ "$mode" == --apply || "$mode" == --watch || "$mode" == --validate ]] || { echo 'Use --apply, --watch, --check or --validate.' >&2; exit 2; }
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
[[ "$mode" != --validate ]] || exit 0
nft --file "$rules"
if [[ "$mode" == --watch ]]; then
    install -d -m 0755 "$state_dir"
    current_rules > "$state_dir/expected.nft"
    chmod 0644 "$state_dir/expected.nft"
    cleanup_watch() { rm -f "$state_dir/enforced" "$state_dir/.enforced.tmp"; }
    mark_enforced() {
        date +%s > "$state_dir/.enforced.tmp"
        mv -f "$state_dir/.enforced.tmp" "$state_dir/enforced"
    }
    trap 'cleanup_watch; rm -f "$rules"' EXIT
    trap 'exit 0' TERM INT
    mark_enforced
    [[ -z ${NOTIFY_SOCKET:-} ]] || systemd-notify --ready
    while sleep 1; do
        if ! check_rules; then
            echo 'FIREWALL_ENFORCED=0: proxy firewall missing or changed; stopping protected proxy.' >&2
            exit 1
        fi
        mark_enforced
    done
fi
