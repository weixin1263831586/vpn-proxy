#!/bin/bash
set -euo pipefail
runtime=${RK_VPN_RUNTIME:-/etc/rk-vpn-proxy/runtime.env}
mode=${1:---apply}
# --cleanup/--cleanup-routing must work during rollback, after restore already
# removed the deployed runtime.env; every other mode requires it. --precheck
# also runs before the proxy system user exists.
if [[ -f "$runtime" ]]; then
    source "$runtime"
elif [[ "$mode" != --cleanup && "$mode" != --cleanup-routing && "$mode" != --precheck ]]; then
    echo "Missing runtime environment: $runtime" >&2; exit 1;
fi
state_dir=${RK_VPN_FIREWALL_STATE:-/run/rk-vpn-proxy-firewall}
routing_table=${RK_VPN_ROUTING_TABLE:-240}
# Proof that a managed deployment owns the routing resources: install.sh
# creates the deployed marker once the deployment passed its readiness
# checks; an existing /etc/rk-vpn-proxy/runtime.env proves an earlier
# managed install (upgrades). --precheck needs this to distinguish this
# project's own leftover routes from a foreign service that happens to
# use the same table and route signatures.
deploy_state=${RK_VPN_DEPLOY_STATE:-/var/lib/rk-vpn-proxy-deploy}
deployment_recorded() { [[ -f "$deploy_state/deployed" || -f "$runtime" ]]; }
VPN_INTERFACE=${VPN_INTERFACE:-}
# Lowest candidate preference for the per-client return rules. Preferences are
# allocated dynamically, skipping every preference already in use, so a large
# allowed_clients list can never collide with the catch-all egress rule below
# it or with rules owned by other subsystems.
rule_pref_start=90
proxy_uid=$(id -u rk-vpn-proxy 2>/dev/null || true)
uid_selector=${proxy_uid:+"uidrange $proxy_uid-$proxy_uid"}
# Addresses used to verify the effective route of the proxy UID. They must
# never be listed in ALLOWED_CLIENTS, so only the catch-all egress rule can
# answer the probe. Override per environment for tests and air-gapped hosts.
route_probe_v4=${RK_VPN_ROUTE_PROBE_V4:-8.8.8.8}
route_probe_v6=${RK_VPN_ROUTE_PROBE_V6:-2606:4700:4700::1111}
# Fail-closed proxy supervision: the deployed --watch unit sets
# RK_VPN_MANAGE_PROXY=1 so a broken protection stops the proxy until both
# layers verify clean again. Ad-hoc interactive runs stay read-only.
manage_proxy=0
if [[ ${RK_VPN_MANAGE_PROXY:-0} == 1 ]] && command -v systemctl >/dev/null 2>&1; then
    manage_proxy=1
fi
proxy_unit=${RK_VPN_PROXY_UNIT:-rk-vpn-proxy.service}
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
    # "unreachable default dev lo metric 200 pref medium". The VPN default
    # must additionally reference the configured VPN interface: an unrelated
    # service that mirrors the metric-100 signature through its own device is
    # foreign and must never be deleted or claimed (the precheck refuses it).
    # Without a runtime environment (late rollback after /etc was removed)
    # the interface is unknown, so the legacy signature alone is used.
    local line=$1
    if [[ "$line" == "unreachable default"* && " $line " == *" metric 200 "* ]]; then
        return 0
    fi
    if [[ -z "$VPN_INTERFACE" || " $line " == *" dev $VPN_INTERFACE "* ]] &&
        [[ "$line" == "default "* && " $line " == *" metric 100 "* ]]; then
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

route_get_uid() {
    # The kernel's answer for the proxy UID: every rule with a lower
    # preference is consulted first, so this reflects what Squid's traffic
    # would actually do regardless of which service owns which rule.
    ip "-$1" route get "$2" uid "$proxy_uid" 2>/dev/null
}

check_effective_route() {
    # Final truth for the second layer: resolve the effective route for the
    # proxy UID exactly as its packets would be routed. A foreign rule at a
    # lower preference that reaches the main table wins before our egress
    # rule is ever consulted; existence and ordering checks cannot see that,
    # but the route lookup exposes it. The probe addresses are not allowed
    # client networks, so only the catch-all egress rule may answer: through
    # the VPN device while it is up, or not at all (unreachable fallback)
    # while it is down. Failure is fail-closed.
    local family probe route
    for family in 4 6; do
        family_available "$family" || continue
        probe=$route_probe_v4
        [[ "$family" == 6 ]] && probe=$route_probe_v6
        route=$(route_get_uid "$family" "$probe") || continue
        if [[ "$route" != *" dev $VPN_INTERFACE"* ]]; then
            echo "firewall.sh: proxy UID route to $probe bypasses $VPN_INTERFACE: $route" >&2
            return 1
        fi
    done
}

precheck_policy_routing() {
    # Read-only deployment gate: refuse when the routing table or its lookup
    # rules are already used by anything this project does not own, instead
    # of deleting foreign state and re-creating it. Routes matching this
    # project's signature are only accepted with a deployment record: on a
    # first install they would equally belong to another service that copies
    # the signature, so without proof of ownership the install is refused.
    local family line rest problems=0 owned_seen=0
    for family in 4 6; do
        family_available "$family" || continue
        owned_seen=0
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
            if owned_route "$line"; then
                owned_seen=1
            else
                echo "firewall.sh: routing table $routing_table contains a foreign route: $line" >&2
                problems=1
            fi
        done < <(ip -"$family" route show table "$routing_table" 2>/dev/null || true)
        if (( owned_seen )) && ! deployment_recorded; then
            echo "firewall.sh: routing table $routing_table contains routes with this project's signature but no managed deployment is recorded; refusing to claim them." >&2
            problems=1
        fi
    done
    (( ! problems ))
}

if [[ "$mode" == --check ]]; then
    # Read-only verification of both layers; used before the proxy starts.
    # The effective-route check must also pass: a foreign rule that routes
    # the proxy UID before our egress rule is exactly what this catches.
    check_rules
    check_policy_routing
    check_effective_route
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
    proxy_paused=0
    iterations=${RK_VPN_WATCH_ITERATIONS:-0}
    while sleep 1; do
        if ! check_rules; then
            echo 'FIREWALL_ENFORCED=0: proxy firewall missing or changed; stopping protected proxy.' >&2
            if (( manage_proxy )); then
                systemctl stop "$proxy_unit" >/dev/null 2>&1 || true
            fi
            exit 1
        fi
        # Route repair commands tolerate transient failure, so the health
        # marker is refreshed only after re-verifying the actual rules,
        # preference order, fallback routes and the kernel-resolved effective
        # route. A VPN outage alone stays healthy with just the unreachable
        # fallback, but a missing protection layer is fail-closed: the proxy
        # is stopped until the layer verifies clean again.
        ensure_policy_routing
        if check_policy_routing && check_effective_route; then
            mark_enforced
            if (( manage_proxy && proxy_paused )); then
                proxy_paused=0
                if ! systemctl start "$proxy_unit" >/dev/null 2>&1; then
                    echo 'failed to restart the protected proxy after recovery.' >&2
                fi
            fi
        else
            clear_enforced
            echo 'FIREWALL_ENFORCED=0: policy routing incomplete after repair attempt.' >&2
            if (( manage_proxy )); then
                proxy_paused=1
                echo 'fail-closed: protection layer is incomplete; stopping the proxy until routing verifies again.' >&2
                systemctl stop "$proxy_unit" >/dev/null 2>&1 || true
            fi
        fi
        if (( iterations > 0 )); then
            iterations=$(( iterations - 1 ))
            if (( iterations == 0 )); then break; fi
        fi
    done
fi
