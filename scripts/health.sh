#!/bin/bash
set -euo pipefail
source "${RK_VPN_RUNTIME:-/etc/rk-vpn-proxy/runtime.env}"
state_dir=${RK_VPN_STATE_DIR:-/var/lib/rk-vpn-proxy}
firewall_state=${RK_VPN_FIREWALL_STATE:-/run/rk-vpn-proxy-firewall}
log_change() {
    local value=$1
    local previous=''
    [[ ! -f "$state_dir/status" ]] || previous=$(cat "$state_dir/status")
    if [[ "$value" != "$previous" ]]; then
        printf '%s\n' "$value" > "$state_dir/status"
        printf '%s\n' "$value"
    fi
}
vpn_up=0 route_ok=0 firewall_enforced=0 proxy_reachable=0
ip -4 address show dev "$VPN_INTERFACE" 2>/dev/null | grep -q 'inet ' && vpn_up=1
# Evaluate the same UID policy routing as Squid, not the health account's
# main-table route (which may legitimately use a different default).
proxy_uid=$(id -u rk-vpn-proxy)
ip -4 route get "$DNS_CHECK_ADDRESS" uid "$proxy_uid" 2>/dev/null | grep -Fq "dev $VPN_INTERFACE " && route_ok=1
check_firewall() {
    local checked now
    firewall_enforced=0
    checked=$(cat "$firewall_state/enforced" 2>/dev/null || true)
    now=$(date +%s)
    if [[ "$checked" =~ ^[0-9]+$ ]] && (( now - checked >= 0 && now - checked <= 3 )); then
        firewall_enforced=1
    fi
}
check_firewall
report() {
    log_change "VPN_UP=$vpn_up VPN_ROUTE_OK=$route_ok PROXY_REACHABLE=$proxy_reachable FIREWALL_ENFORCED=$firewall_enforced${1:+ $1}"
}
if [[ "$vpn_up$route_ok$firewall_enforced" != 111 ]]; then
    report
    exit 1
fi
if ! exit_ip=$(curl --silent --show-error --fail --noproxy '' \
    --proxy "http://127.0.0.1:$HEALTH_PORT" --connect-timeout 15 --max-time 30 \
    https://api.ipify.org); then
    report 'HTTPS probe failed.'
    exit 1
fi
if [[ ! "$exit_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    report 'Invalid public IP response.'
    exit 1
fi
if [[ -f "$state_dir/exit-ip" ]]; then
    previous_ip=$(cat "$state_dir/exit-ip")
    if [[ "$previous_ip" != "$exit_ip" ]]; then
        printf 'EXIT IP CHANGED: %s -> %s\n' "$previous_ip" "$exit_ip"
    fi
fi
printf '%s\n' "$exit_ip" > "$state_dir/exit-ip"
proxy_reachable=1
check_firewall
report "EXIT_IP=$exit_ip"
[[ "$firewall_enforced" == 1 ]]
