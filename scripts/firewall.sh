#!/bin/bash
set -euo pipefail
runtime=${RK_VPN_RUNTIME:-/etc/rk-vpn-proxy/runtime.env}
mode=${1:---apply}
# --cleanup/--cleanup-routing must work during rollback, after restore already
# removed the deployed runtime.env; every other mode requires it. --precheck
# also runs before the proxy system user exists.
if [[ "$mode" != --cleanup && "$mode" != --cleanup-routing && "$mode" != --precheck ]]; then
    [[ -f "$runtime" ]] || { echo "Missing runtime environment: $runtime" >&2; exit 1; }
    source "$runtime"
fi
state_dir=${RK_VPN_FIREWALL_STATE:-/run/rk-vpn-proxy-firewall}
routing_table=${RK_VPN_ROUTING_TABLE:-240}
# Lowest candidate preference for the per-client return rules. Preferences are
# allocated dynamically, skipping every preference already in use, so a large
# allowed_clients list can never collide with the catch-all egress rule below
# it or with rules owned by other subsystems.
rule_pref_start=90
proxy_uid=$(id -u rk-vpn-proxy 2>/dev/null || true)
uid_selector=${proxy_uid:+"uidrange $proxy_uid-$proxy_uid"}
if [[ -z "$proxy_uid" && "$mode" != --cleanup && "$mode" != --cleanup-routing && "$mode" != --precheck ]]; then
    echo 'Missing rk-vpn-proxy system user.' >&2
    exit 1
fi

current_rules() { nft --stateless --numeric list table inet rk_vpn_proxy; }
check_rules() {
    local actual expected
    expected=$(cat "$state_dir/expected.nft") || return 1
    actual=$(current_rules 2>/dev/null) || return 1
    [[ -n "$expected" && "$actual" == "$expected" ]]
}

# Second, nftables-independent egress constraint: a dedicated routing table
# that only offers the VPN device as default egress with an unreachable
# fallback. Deleting the nftables table alone therefore cannot redirect the
# proxy through an ordinary interface. Allowed client networks keep using the
# main table so replies follow the administrator's (possibly dynamic) routes.
# The same lookup is installed for IPv6 with no client exceptions, so a host
# with global IPv6 connectivity still cannot leak around the IPv4 rules.
# Resources are identified by exact ownership signatures (proxy UID plus
# lookup action, mirrored metric-100 default, metric-200 unreachable) instead
# of by table number alone, and --precheck refuses an install when table 240
# or its lookup rules are already used by anything else.

family_rules() { ip "-$1" rule show 2>/dev/null || true; }
family_available() { ip "-$1" rule show >/dev/null 2>&1; }
owned_rules() {
    [[ -n "$uid_selector" ]] || return 0
    family_rules "$1" | grep -F " $uid_selector " || true
}

client_networks_for_family() {
    local family=$1 network
    for network in ${ALLOWED_CLIENTS:-}; do
        # ip rule show omits the full prefix for host selectors.
        if [[ "$network" == *:* ]]; then
            network=${network%/128}
            if [[ "$family" == 6 ]]; then printf '%s\n' "$network"; fi
        else
            network=${network%/32}
            if [[ "$family" == 4 ]]; then printf '%s\n' "$network"; fi
        fi
    done
}

owned_route() {
    # Routes this project writes: the mirrored metric-100 VPN default and the
    # metric-200 unreachable fallback. IPv6 listings render the fallback as
    # "unreachable default dev lo metric 200 pref medium".
    local line=$1
    if [[ "$line" == "unreachable default"* && " $line " == *" metric 200 "* ]]; then
        return 0
    fi
    if [[ "$line" == "default "* && " $line " == *" metric 100 "* ]]; then
        return 0
    fi
    return 1
}

purge_table_routes() {
    # Remove only the routes this project writes; keep and report anything
    # else that ended up in the table.
    local family=$1 line
    while read -r line; do
        [[ -z "$line" ]] && continue
        if owned_route "$line"; then
            ip -"$family" route del $line table "$routing_table" 2>/dev/null || true
        else
            echo "firewall.sh: keeping foreign route '$line' in table $routing_table" >&2
        fi
    done < <(ip -"$family" route show table "$routing_table" 2>/dev/null || true)
}

purge_policy_routing() {
    local family attempt pass_clean line pref rest
    for family in 4 6; do
        for attempt in 1 2 3; do
            pass_clean=1
            while read -r line; do
                [[ -z "$line" ]] && continue
                pref=${line%%:*}
                rest=${line#*:}
                case " $rest " in
                    *" lookup $routing_table "*|*" lookup main "*)
                        pass_clean=0
                        ip -"$family" rule del pref "$pref" $rest 2>/dev/null || true ;;
                esac
            done < <(owned_rules "$family")
            if (( pass_clean )); then break; fi
        done
        purge_table_routes "$family"
    done
}

next_free_pref() {
    # Print the first rule preference >= $2 that no existing rule of this
    # family uses, ours or foreign.
    local family=$1 start=$2 line pref candidate taken
    local -a used=()
    while read -r line; do
        pref=${line%%:*}
        if [[ "$pref" =~ ^[0-9]+$ ]]; then used+=("$pref"); fi
    done < <(family_rules "$family")
    for (( candidate = start; candidate <= 4294967294; candidate++ )); do
        taken=0
        for pref in "${used[@]}"; do
            if [[ "$pref" == "$candidate" ]]; then taken=1; break; fi
        done
        if (( ! taken )); then echo "$candidate"; return 0; fi
    done
    return 1
}

mirror_vpn_default() {
    # The VPN default route mirrors the administrator's main-table default
    # for that interface: a gateway route where one exists, a device route
    # for point-to-point links.
    local family=$1 gateway line
    line=$(ip "-$family" route show default dev "$VPN_INTERFACE" 2>/dev/null | grep -m1 ' via ' || true)
    if [[ -z "$line" ]]; then
        line=$(ip "-$family" route show default dev "$VPN_INTERFACE" 2>/dev/null | head -1 || true)
    fi
    if [[ -n "$line" ]]; then
        gateway=${line#* via }
        gateway=${gateway%% *}
        if [[ -n "$gateway" && "$gateway" != "$line" ]]; then
            ip "-$family" route replace default via "$gateway" dev "$VPN_INTERFACE" metric 100 table "$routing_table" 2>/dev/null || true
        else
            ip "-$family" route replace default dev "$VPN_INTERFACE" metric 100 table "$routing_table" 2>/dev/null || true
        fi
    fi
}

ensure_uid_rules() {
    # Desired per-family rules: one return rule per allowed client network
    # (uidrange UID to NET lookup main) plus the catch-all egress rule
    # (uidrange UID lookup TABLE). Client preferences are allocated in
    # increasing order and the catch-all is kept strictly behind the last
    # client rule, otherwise the catch-all would steal client replies into
    # the VPN-only table. Return rules for networks that were removed from
    # the configuration are dropped again.
    local family=$1 network line pref rest client_pref base_pref='' max_client=0 target start
    local -a missing_clients=()
    while read -r line; do
        [[ -z "$line" ]] && continue
        pref=${line%%:*}
        rest=${line#*:}
        # iproute2 prints selectors in canonical order: from, to, uidrange.
        case "$rest" in
            *"$uid_selector lookup $routing_table")
                if [[ -z "$base_pref" ]]; then base_pref=$pref; fi ;;
            *" to "*" $uid_selector lookup main")
                network=${rest#*" to "}
                network=${network%% *}
                if ! client_networks_for_family "$family" | grep -qxF "$network"; then
                    ip -"$family" rule del pref "$pref" $rest 2>/dev/null || true
                elif [[ "$pref" -gt "$max_client" ]]; then
                    max_client=$pref
                fi ;;
        esac
    done < <(owned_rules "$family")
    while read -r network; do
        [[ -z "$network" ]] && continue
        if ! owned_rules "$family" | grep -qF "to $network $uid_selector lookup main"; then
            missing_clients+=("$network")
        fi
    done < <(client_networks_for_family "$family")
    for network in "${missing_clients[@]}"; do
        client_pref=$(next_free_pref "$family" "$rule_pref_start") || return 1
        if [[ "$client_pref" -gt "$max_client" ]]; then max_client=$client_pref; fi
        ip -"$family" rule add pref "$client_pref" $uid_selector to "$network" lookup main 2>/dev/null || true
    done
    if [[ -n "$base_pref" && "$base_pref" -le "$max_client" ]]; then
        # The client list grew past the catch-all rule; move it last. Only
        # reachable when the configuration changed under a running daemon.
        echo "firewall.sh: relocating egress rule pref $base_pref behind client rules" >&2
        ip -"$family" rule del pref "$base_pref" $uid_selector lookup "$routing_table" 2>/dev/null || true
        base_pref=''
    fi
    if [[ -z "$base_pref" ]]; then
        start=$(( max_client > rule_pref_start ? max_client : rule_pref_start ))
        target=$(next_free_pref "$family" $(( start + 1 ))) || return 1
        ip -"$family" rule add pref "$target" $uid_selector lookup "$routing_table" 2>/dev/null || true
    fi
}

ensure_policy_routing() {
    mirror_vpn_default 4
    ip route replace unreachable default metric 200 table "$routing_table" 2>/dev/null || true
    if family_available 6; then
        mirror_vpn_default 6
        ip -6 route replace unreachable default metric 200 table "$routing_table" 2>/dev/null || true
    fi
    ensure_uid_rules 4
    if family_available 6; then ensure_uid_rules 6; fi
}

check_policy_routing() {
    # Verify the actual rules, their preference order and the fallback
    # routes. Every owned rule must match the configuration exactly: exactly
    # one egress rule, no return rules for retired networks, no unknown
    # rule using the proxy UID. A VPN default route must be mirrored into
    # the table; while the VPN is down, only the unreachable fallback is
    # required (fail-closed).
    local family network line pref rest base_pref base_count mirrored
    for family in 4 6; do
        if ! family_available "$family"; then
            [[ "$family" == 6 ]] && continue
            return 1
        fi
        base_pref=''
        base_count=0
        while read -r line; do
            [[ -z "$line" ]] && continue
            pref=${line%%:*}
            rest=${line#*:}
            case "$rest" in
                *"$uid_selector lookup $routing_table")
                    base_count=$(( base_count + 1 ))
                    if [[ -z "$base_pref" ]]; then base_pref=$pref; fi ;;
                *" to "*" $uid_selector lookup main")
                    network=${rest#*" to "}
                    network=${network%% *}
                    client_networks_for_family "$family" | grep -qxF "$network" || return 1 ;;
                *) return 1 ;;
            esac
        done < <(owned_rules "$family")
        [[ "$base_count" == 1 ]] || return 1
        [[ -n "$base_pref" ]] || return 1
        ip -"$family" route show table "$routing_table" 2>/dev/null | grep -qF 'unreachable default' || return 1
        while read -r network; do
            [[ -z "$network" ]] && continue
            line=$(owned_rules "$family" | grep -F "to $network $uid_selector lookup main") || return 1
            pref=${line%%:*}
            [[ "$pref" -lt "$base_pref" ]] || return 1
        done < <(client_networks_for_family "$family")
        mirrored=$(ip -"$family" route show default dev "$VPN_INTERFACE" 2>/dev/null || true)
        if [[ -n "$mirrored" ]]; then
            ip -"$family" route show table "$routing_table" | grep -qF "dev $VPN_INTERFACE" || return 1
        fi
    done
}

precheck_policy_routing() {
    # Read-only deployment gate: refuse when the routing table or its lookup
    # rules are already used by anything this project does not own, instead
    # of deleting foreign state and re-creating it.
    local family line rest problems=0
    for family in 4 6; do
        family_available "$family" || continue
        while read -r line; do
            [[ -z "$line" ]] && continue
            rest=${line#*:}
            if [[ -z "$uid_selector" || " $rest " != *" $uid_selector "* ]]; then
                if [[ " $rest " == *" lookup $routing_table "* ]]; then
                    echo "firewall.sh: routing table $routing_table is referenced by a rule this project does not own: $line" >&2
                    problems=1
                fi
                continue
            fi
            case " $rest " in
                *" lookup $routing_table "*|*" lookup main "*) ;;
                *)
                    echo "firewall.sh: unrecognised rule already uses the proxy UID: $line" >&2
                    problems=1 ;;
            esac
        done < <(family_rules "$family")
        while read -r line; do
            [[ -z "$line" ]] && continue
            if ! owned_route "$line"; then
                echo "firewall.sh: routing table $routing_table contains a foreign route: $line" >&2
                problems=1
            fi
        done < <(ip -"$family" route show table "$routing_table" 2>/dev/null || true)
    done
    (( ! problems ))
}

if [[ "$mode" == --check ]]; then
    # Read-only verification of both layers; used before the proxy starts.
    check_rules
    check_policy_routing
    exit
fi
[[ "$mode" == --apply || "$mode" == --watch || "$mode" == --validate || "$mode" == --cleanup || "$mode" == --cleanup-routing || "$mode" == --precheck ]] || {
    echo 'Use --apply, --watch, --check, --validate, --precheck, --cleanup or --cleanup-routing.' >&2; exit 2;
}

if [[ "$mode" == --precheck ]]; then
    precheck_policy_routing
    exit
fi
if [[ "$mode" == --cleanup || "$mode" == --cleanup-routing ]]; then
    purge_policy_routing
    if [[ "$mode" == --cleanup ]] && nft list table inet rk_vpn_proxy >/dev/null 2>&1; then
        nft delete table inet rk_vpn_proxy
    fi
    exit 0
fi

if [[ "$mode" == --validate ]]; then
    # --validate only parses the staged nftables ruleset and checks routing
    # resource ownership; it must never touch the live policy routing of a
    # running deployment.
    precheck_policy_routing
elif [[ "$mode" == --apply || "$mode" == --watch ]]; then
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
    clear_enforced() { rm -f "$state_dir/enforced"; }
    trap 'cleanup_watch; rm -f "$rules"' EXIT
    trap 'exit 0' TERM INT
    mark_enforced
    [[ -z ${NOTIFY_SOCKET:-} ]] || systemd-notify --ready
    iterations=${RK_VPN_WATCH_ITERATIONS:-0}
    while sleep 1; do
        if ! check_rules; then
            echo 'FIREWALL_ENFORCED=0: proxy firewall missing or changed; stopping protected proxy.' >&2
            exit 1
        fi
        # Route repair commands tolerate transient failure, so the health
        # marker is refreshed only after re-verifying the actual rules,
        # preference order and fallback routes. A persistently broken second
        # layer clears the marker while the daemon keeps repairing; a VPN
        # outage alone stays healthy with just the unreachable fallback.
        ensure_policy_routing
        if check_policy_routing; then
            mark_enforced
        else
            clear_enforced
            echo 'FIREWALL_ENFORCED=0: policy routing incomplete after repair attempt.' >&2
        fi
        if (( iterations > 0 )); then
            iterations=$(( iterations - 1 ))
            if (( iterations == 0 )); then break; fi
        fi
    done
fi
