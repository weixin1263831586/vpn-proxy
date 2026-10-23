#!/bin/bash
# Exercise real iproute2 formatting and nftables in a private network namespace.
# Unprivileged use needs user namespaces; root needs only network namespaces.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
    if [[ $EUID == 0 ]]; then
        exec unshare --net -- bash "$0" --inside
    fi
    exec unshare --user --map-root-user --net -- bash "$0" --inside
fi
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || {
    echo 'Refusing to test in the host network namespace.' >&2; exit 1;
}
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/firewall"
# UID 0 is mapped inside both privileged and unprivileged test namespaces.
# Only identity lookup is substituted; ip and nft operate on the real kernel.
printf '#!/bin/bash\necho 0\n' > "$test_dir/bin/id"
chmod +x "$test_dir/bin/id"
export PATH="$test_dir/bin:$PATH"
export RK_VPN_RUNTIME="$test_dir/runtime.env"
export RK_VPN_FIREWALL_STATE="$test_dir/firewall"
cat > "$RK_VPN_RUNTIME" <<'ENV'
VPN_INTERFACE=vpn0
PROXY_PORT=17890
HEALTH_PORT=17891
ALLOWED_CLIENTS='10.10.10.206/32 fd00::1/128 fd01::/32'
ENV
ip link set lo up
ip link add vpn0 type dummy
ip address add 203.0.113.2/24 dev vpn0
ip link set vpn0 up
ip route add default dev vpn0
fw() { bash "$source_dir/scripts/firewall.sh" "$@"; }
RK_VPN_WATCH_ITERATIONS=1 fw --watch
fw --check
ip -4 rule show | grep -F 'to 10.10.10.206 uidrange 0-0 lookup main'
ip -6 rule show | grep -F 'to fd00::1 uidrange 0-0 lookup main'
ip -6 rule show | grep -F 'to fd01::/32 uidrange 0-0 lookup main'
# IPv6 rules must be checked against their own egress preference. Moving the
# catch-all before its clients must fail even if the IPv4 ordering is valid.
ipv6_pref=$(ip -6 rule show | awk '/uidrange 0-0 lookup 240/ {sub(":", "", $1); print $1}')
ip -6 rule del pref "$ipv6_pref" uidrange 0-0 lookup 240
ip -6 rule add pref 89 uidrange 0-0 lookup 240
if fw --check; then echo 'FAIL: IPv6 client ordering accepted' >&2; exit 1; fi
ip -6 rule del pref 89 uidrange 0-0 lookup 240
ip -6 rule add pref "$ipv6_pref" uidrange 0-0 lookup 240
fw --check
# A missing VPN interface must leave an unreachable route, never main-table
# fallback. Use the same UID route lookup as the health probe.
ip route get 8.8.8.8 uid 0 | grep -F 'dev vpn0 table 240'
ip link delete vpn0
fw --check
if ip route get 8.8.8.8 uid 0; then echo 'FAIL: missing VPN allowed routing' >&2; exit 1; fi
# A foreign rule with a lower preference can answer before the egress rule
# is ever consulted; the effective-route check must catch it in the kernel's
# own answer, not in rule listings.
ip link add wan0 type dummy
ip address add 198.51.100.2/24 dev wan0
ip link set wan0 up
ip route add default via 198.51.100.1 dev wan0 metric 10
ip rule add pref 50 lookup main
if ip route get 8.8.8.8 uid 0 | grep -qF 'dev wan0'; then :; else
    echo 'FAIL: fixture does not reproduce the preemption.' >&2; exit 1
fi
if fw --check; then echo 'FAIL: foreign preemption accepted' >&2; exit 1; fi
ip rule del pref 50 lookup main
ip route del default via 198.51.100.1 dev wan0 metric 10
ip link delete wan0
fw --check
fw --cleanup
if ip -4 rule show | grep -qF 'uidrange 0-0'; then exit 1; fi
if ip -6 rule show | grep -qF 'uidrange 0-0'; then exit 1; fi
if nft list table inet rk_vpn_proxy 2>/dev/null; then exit 1; fi
echo 'PASS: real kernel host selectors, per-family ordering, VPN fallback and cleanup.'
