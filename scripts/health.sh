#!/bin/bash
set -euo pipefail
source /etc/rk-vpn-proxy/runtime.env
state_dir=/var/lib/rk-vpn-proxy
log_change() {
    local value=$1
    local previous=''
    [[ ! -f "$state_dir/status" ]] || previous=$(cat "$state_dir/status")
    if [[ "$value" != "$previous" ]]; then
        printf '%s\n' "$value" > "$state_dir/status"
        printf '%s\n' "$value"
    fi
}
if ! ip -4 address show dev "$VPN_INTERFACE" 2>/dev/null | grep -q 'inet '; then
    log_change "VPN DOWN: $VPN_INTERFACE has no IPv4 address; proxy fallback is blocked."
    exit 1
fi
if ! ip -4 route get "$DNS_CHECK_ADDRESS" | grep -q "dev $VPN_INTERFACE "; then
    log_change "VPN ROUTE WARNING: public DNS route is not $VPN_INTERFACE; proxy fallback is blocked."
    exit 1
fi
if ! exit_ip=$(curl --silent --show-error --fail --noproxy '' \
    --proxy "http://127.0.0.1:$HEALTH_PORT" --connect-timeout 15 --max-time 30 \
    https://api.ipify.org); then
    log_change 'VPN PROBE FAILED: HTTPS request through the proxy failed.'
    exit 1
fi
if [[ ! "$exit_ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    log_change 'VPN PROBE FAILED: invalid public IP response.'
    exit 1
fi
if [[ -f "$state_dir/exit-ip" ]]; then
    previous_ip=$(cat "$state_dir/exit-ip")
    if [[ "$previous_ip" != "$exit_ip" ]]; then
        printf 'EXIT IP CHANGED: %s -> %s\n' "$previous_ip" "$exit_ip"
    fi
fi
printf '%s\n' "$exit_ip" > "$state_dir/exit-ip"
log_change "VPN OK: proxy public exit IP $exit_ip"
