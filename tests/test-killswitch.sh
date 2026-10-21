#!/bin/bash
# A completely isolated fake VPN/fallback network; never disconnect the real VPN.
set -euo pipefail
source /etc/rk-vpn-proxy/runtime.env
fallback_interface=rk-test-lan
[[ "$VPN_INTERFACE" != "$fallback_interface" ]] || fallback_interface=rk-test-lan2
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
if [[ ${1:-} != --inside ]]; then
    exec unshare --net -- bash "$0" --inside
fi
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || {
    echo 'Refusing to test in the host network namespace.' >&2; exit 1;
}
server_pid=''
http_pid=''
cleanup() {
    [[ -z "$http_pid" ]] || kill "$http_pid" 2>/dev/null || true
    [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
unshare --net -- sleep 120 &
server_pid=$!
for attempt in {1..50}; do
    [[ $(readlink "/proc/$server_pid/ns/net") != "$(readlink /proc/self/ns/net)" ]] && break
    sleep 0.02
done
ip link set lo up
nsenter -t "$server_pid" -n ip link set lo up
ip link add "$VPN_INTERFACE" type veth peer name vpn-peer
ip link add "$fallback_interface" type veth peer name lan-peer
ip link set vpn-peer netns "$server_pid"
ip link set lan-peer netns "$server_pid"
ip address add 203.0.113.2/24 dev "$VPN_INTERFACE"
ip address add 198.51.100.2/24 dev "$fallback_interface"
ip link set "$VPN_INTERFACE" up
ip link set "$fallback_interface" up
nsenter -t "$server_pid" -n ip address add 203.0.113.1/24 dev vpn-peer
nsenter -t "$server_pid" -n ip address add 198.51.100.1/24 dev lan-peer
nsenter -t "$server_pid" -n ip address add 1.1.1.1/32 dev lo
nsenter -t "$server_pid" -n ip link set vpn-peer up
nsenter -t "$server_pid" -n ip link set lan-peer up
ip route add default via 203.0.113.1 dev "$VPN_INTERFACE" metric 50
ip route add default via 198.51.100.1 dev "$fallback_interface" metric 100
nsenter -t "$server_pid" -n python3 -m http.server 80 --bind 0.0.0.0 --directory /tmp >/dev/null 2>&1 &
http_pid=$!
/usr/local/libexec/rk-vpn-proxy-firewall
probe() {
    runuser -u rk-vpn-proxy -- curl --silent --show-error --fail \
        --noproxy '*' --max-time 3 http://1.1.1.1/ -o /dev/null
}
for attempt in {1..30}; do
    if probe 2>/dev/null; then break; fi
    sleep 0.1
done
probe
printf "PASS: proxy UID reaches the test endpoint through %s.\n" "$VPN_INTERFACE"
ip link set "$VPN_INTERFACE" down
ip route get 1.1.1.1 | grep -F "dev $fallback_interface"
# A different UID can still use the ordinary fallback route.
curl --silent --fail --noproxy '*' --max-time 3 http://1.1.1.1/ -o /dev/null
if probe 2>/dev/null; then
    echo 'FAIL: proxy UID used the LAN fallback.' >&2; exit 1
fi
echo 'PASS: VPN down blocks the proxy UID while other users retain LAN connectivity.'
ip link set "$VPN_INTERFACE" up
ip route replace default via 203.0.113.1 dev "$VPN_INTERFACE" metric 50
probe
printf "PASS: proxy traffic recovers automatically when %s returns.\n" "$VPN_INTERFACE"
nft list table inet rk_vpn_proxy
