#!/bin/bash
# A completely isolated fake VPN/fallback network; never disconnect the real VPN.
set -euo pipefail
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
ip link add ppp0 type veth peer name vpn-peer
ip link add eno1 type veth peer name lan-peer
ip link set vpn-peer netns "$server_pid"
ip link set lan-peer netns "$server_pid"
ip address add 203.0.113.2/24 dev ppp0
ip address add 198.51.100.2/24 dev eno1
ip link set ppp0 up
ip link set eno1 up
nsenter -t "$server_pid" -n ip address add 203.0.113.1/24 dev vpn-peer
nsenter -t "$server_pid" -n ip address add 198.51.100.1/24 dev lan-peer
nsenter -t "$server_pid" -n ip address add 1.1.1.1/32 dev lo
nsenter -t "$server_pid" -n ip link set vpn-peer up
nsenter -t "$server_pid" -n ip link set lan-peer up
ip route add default via 203.0.113.1 dev ppp0 metric 50
ip route add default via 198.51.100.1 dev eno1 metric 100
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
echo 'PASS: proxy UID reaches the test endpoint through ppp0.'
ip link set ppp0 down
ip route get 1.1.1.1 | grep 'dev eno1'
# A different UID can still use the ordinary fallback route.
curl --silent --fail --noproxy '*' --max-time 3 http://1.1.1.1/ -o /dev/null
if probe 2>/dev/null; then
    echo 'FAIL: proxy UID used the LAN fallback.' >&2; exit 1
fi
echo 'PASS: VPN down blocks the proxy UID while other users retain LAN connectivity.'
ip link set ppp0 up
ip route replace default via 203.0.113.1 dev ppp0 metric 50
probe
echo 'PASS: proxy traffic recovers automatically when ppp0 returns.'
nft list table inet rk_vpn_proxy
