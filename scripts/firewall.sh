#!/bin/bash
set -euo pipefail
runtime=${RK_VPN_RUNTIME:-/etc/rk-vpn-proxy/runtime.env}
mode=${1:---apply}
# --cleanup must work during rollback, after restore already removed the
# deployed runtime.env; every other mode requires it.
if [[ "$mode" != --cleanup ]]; then
    [[ -f "$runtime" ]] || { echo "Missing runtime environment: $runtime" >&2; exit 1; }
    source "$runtime"
fi
state_dir=${RK_VPN_FIREWALL_STATE:-/run/rk-vpn-proxy-firewall}
routing_table=${RK_VPN_ROUTING_TABLE:-240}
client_rule_pref=90
base_rule_pref=100
mode=${1:---apply}
current_rules() { nft --stateless --numeric list table inet rk_vpn_proxy; }
check_rules() {
    local actual expected
    expected=$(cat "$state_dir/expected.nft") || return 1
    actual=$(current_rules 2>/dev/null) || return 1
    [[ -n "$expected" && "$actual" == "$expected" ]]
}
proxy_uid=$(id -u rk-vpn-proxy)
uid_selector="uidrange $proxy_uid-$proxy_uid"

# Second, nftables-independent egress constraint: a dedicated routing table
# that only offers the VPN device as default egress with an unreachable
# fallback. Deleting the nftables table alone therefore cannot redirect the
# proxy through an ordinary interface. Allowed client networks keep using the
# main table so replies follow the administrator's (possibly dynamic) routes.

purge_policy_routing() {
    while read -r pref rest; do
        ip rule del pref "${pref%:}" $rest 2>/dev/null || break
    done < <(ip rule show | grep -F "$uid_selector" || true)
    ip route flush table "$routing_table" 2>/dev/null || true
}

ensure_policy_routing() {
    # Loopback and local destinations resolve via the local table (priority 0)
    # before these rules apply. Missing pieces are re-added idempotently so a
    # recreated VPN interface (e.g. pppd reconnect) regains its route. The VPN
    # default route mirrors the administrator's main-table default for that
    # interface: a gateway route where one exists, a device route for
    # point-to-point links.
    local vpn_default gateway
    vpn_default=$(ip -4 route show default dev "$VPN_INTERFACE" 2>/dev/null | grep -m1 ' via ' || true)
    [[ -n "$vpn_default" ]] || vpn_default=$(ip -4 route show default dev "$VPN_INTERFACE" 2>/dev/null | head -1)
    if [[ -n "$vpn_default" ]]; then
        gateway=${vpn_default#* via }
        gateway=${gateway%% *}
        if [[ -n "$gateway" && "$gateway" != "$vpn_default" ]]; then
            ip route replace default via "$gateway" dev "$VPN_INTERFACE" metric 100 table "$routing_table" 2>/dev/null || true
        else
            ip route replace default dev "$VPN_INTERFACE" metric 100 table "$routing_table" 2>/dev/null || true
        fi
    fi
    ip route replace unreachable default metric 200 table "$routing_table" 2>/dev/null || true
    if ! ip rule show | grep -F "$uid_selector" | grep -qF "lookup $routing_table"; then
        ip rule add pref "$base_rule_pref" $uid_selector lookup "$routing_table" 2>/dev/null || true
    fi
    local index=0 network
    for network in ${ALLOWED_CLIENTS:-}; do
        index=$((index + 1))
        if ! ip rule show | grep -F "$uid_selector" | grep -qF "to $network lookup main"; then
            ip rule add pref "$((client_rule_pref + index))" $uid_selector to "$network" lookup main 2>/dev/null || true
        fi
    done
}

check_policy_routing() {
    ip rule show | grep -F "$uid_selector" | grep -qF "lookup $routing_table" &&
        ip route show table "$routing_table" | grep -qF "unreachable" &&
        { ! ip link show dev "$VPN_INTERFACE" >/dev/null 2>&1 ||
          ip route show table "$routing_table" | grep -qF "dev $VPN_INTERFACE"; }
}

if [[ "$mode" == --check ]]; then
    # Read-only verification of both layers; used before the proxy starts.
    check_rules
    check_policy_routing
    exit
fi
[[ "$mode" == --apply || "$mode" == --watch || "$mode" == --validate || "$mode" == --cleanup ]] || {
    echo 'Use --apply, --watch, --check, --validate or --cleanup.' >&2; exit 2;
}

if [[ "$mode" == --cleanup ]]; then
    purge_policy_routing
    if nft list table inet rk_vpn_proxy >/dev/null 2>&1; then
        nft delete table inet rk_vpn_proxy
    fi
    exit 0
fi

if [[ "$mode" == --apply || "$mode" == --watch ]]; then
    # --validate only parses the staged nftables ruleset and must never touch
    # the live policy routing of a running deployment.
    purge_policy_routing
    ensure_policy_routing
    check_policy_routing
fi

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
        ensure_policy_routing
        mark_enforced
    done
fi
