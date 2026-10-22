#!/bin/bash
# A completely isolated fake VPN/fallback network; never disconnect the real VPN.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${1:-} != --inside ]]; then
    id rk-vpn-proxy >/dev/null 2>&1 || useradd --system --user-group --no-create-home rk-vpn-proxy
    exec unshare --net -- bash "$0" --inside "${1:-}"
fi
[[ $(readlink /proc/self/ns/net) != "$(readlink /proc/1/ns/net)" ]] || {
    echo 'Refusing to test in the host network namespace.' >&2; exit 1;
}
server_pid=''
http_pid=''
guard_pid=''
proxy_pid=''
leak_pid=''
systemd_test=${2:-}
guard_unit="rk-vpn-test-$$-guard.service"
proxy_unit="rk-vpn-test-$$-proxy.service"
test_dir=$(mktemp -d)
chmod 0755 "$test_dir"
VPN_INTERFACE=rk-test-vpn
fallback_interface=rk-test-lan
cleanup() {
    if [[ "$systemd_test" == --systemd ]]; then
        systemctl stop "$proxy_unit" "$guard_unit" 2>/dev/null || true
        systemctl reset-failed "$proxy_unit" "$guard_unit" 2>/dev/null || true
    fi
    if [[ -n "$proxy_pid" ]]; then
        kill "$proxy_pid" 2>/dev/null || true
        wait "$proxy_pid" 2>/dev/null || true
    fi
    if [[ -n "$guard_pid" ]]; then
        kill "$guard_pid" 2>/dev/null || true
        wait "$guard_pid" 2>/dev/null || true
    fi
    if [[ -n "$leak_pid" ]]; then
        kill "$leak_pid" 2>/dev/null || true
        wait "$leak_pid" 2>/dev/null || true
    fi
    [[ -z "$http_pid" ]] || kill "$http_pid" 2>/dev/null || true
    [[ -z "$server_pid" ]] || kill "$server_pid" 2>/dev/null || true
    rm -rf -- "$test_dir"
}
trap cleanup EXIT
python3 -B - "$source_dir" "$test_dir" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from configuration import load_config
config = load_config()
config.update(listen_host="127.0.0.2", advertise_host="127.0.0.2", vpn_interface="rk-test-vpn",
              allowed_clients=["127.0.0.0/8"] + [f"10.60.{i}.0/24" for i in range(10)])
Path(sys.argv[2], "config.json").write_text(json.dumps(config))
PY
python3 -B "$source_dir/build-installer.py" --config "$test_dir/config.json" --output-dir "$test_dir/build"
export RK_VPN_RUNTIME="$test_dir/build/runtime.env"
export RK_VPN_FIREWALL_STATE="$test_dir/firewall"
source "$RK_VPN_RUNTIME"
# Place runtime paths in the fixture; never write the deployed Squid configuration/logs.
sed -i "s|/var/log/rk-vpn-proxy|$test_dir/logs|g; s|/run/rk-vpn-proxy|$test_dir/logs|g" "$test_dir/build/squid.conf"
install -d -o rk-vpn-proxy -g rk-vpn-proxy -m 0750 "$test_dir/logs"
runuser -u rk-vpn-proxy -- squid -k parse -f "$test_dir/build/squid.conf"
unshare --net -- sleep 600 &
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
ip -6 address add fd00:198:51:100::2/64 dev "$fallback_interface"
ip link set "$VPN_INTERFACE" up
ip link set "$fallback_interface" up
nsenter -t "$server_pid" -n ip address add 203.0.113.1/24 dev vpn-peer
nsenter -t "$server_pid" -n ip address add 198.51.100.1/24 dev lan-peer
nsenter -t "$server_pid" -n ip address add 1.1.1.1/32 dev lo
nsenter -t "$server_pid" -n ip -6 address add fd00:198:51:100::1/64 dev lan-peer
nsenter -t "$server_pid" -n ip link set vpn-peer up
nsenter -t "$server_pid" -n ip link set lan-peer up
ip route add default via 203.0.113.1 dev "$VPN_INTERFACE" metric 50
ip route add default via 198.51.100.1 dev "$fallback_interface" metric 100
ip -6 route add default via fd00:198:51:100::1 dev "$fallback_interface"
nsenter -t "$server_pid" -n python3 -m http.server 80 --bind 0.0.0.0 --directory /tmp >/dev/null 2>&1 &
http_pid=$!
start_guard() {
    if [[ "$systemd_test" == --systemd ]]; then
        systemd-run --quiet --unit="$guard_unit" --property=Type=notify --property=NotifyAccess=all \
            --property="NetworkNamespacePath=/proc/$$/ns/net" --property=TimeoutStartSec=15s \
            /usr/bin/env "RK_VPN_RUNTIME=$RK_VPN_RUNTIME" "RK_VPN_FIREWALL_STATE=$RK_VPN_FIREWALL_STATE" \
            /bin/bash "$source_dir/scripts/firewall.sh" --watch
    else
        bash "$source_dir/scripts/firewall.sh" --watch > "$test_dir/guard.log" 2>&1 &
        guard_pid=$!
    fi
}
start_guard
for attempt in {1..50}; do
    [[ -f "$RK_VPN_FIREWALL_STATE/enforced" ]] && break
    if [[ -n "$guard_pid" ]]; then kill -0 "$guard_pid" || { cat "$test_dir/guard.log"; exit 1; }; fi
    sleep 0.1
done
bash "$source_dir/scripts/firewall.sh" --check
# 11 client networks must keep distinct preferences strictly before the
# catch-all egress rule (fixed preferences collided from the 10th client on).
proxy_uid=$(id -u rk-vpn-proxy)
base_pref=$(ip rule show | grep -F "uidrange $proxy_uid-$proxy_uid lookup 240" | cut -d: -f1)
[[ -n "$base_pref" ]] || { echo 'FAIL: no egress policy rule present.' >&2; exit 1; }
client_prefs=$(ip rule show | grep -F "uidrange $proxy_uid-$proxy_uid" | grep -F 'lookup main' | cut -d: -f1)
[[ $(wc -l <<<"$client_prefs") -eq 11 ]] || { echo "FAIL: expected 11 client rules, got $(wc -l <<<"$client_prefs")." >&2; exit 1; }
for pref in $client_prefs; do
    (( pref < base_pref )) || { echo "FAIL: client rule pref $pref not before egress rule pref $base_pref." >&2; exit 1; }
done
[[ $(sort -n <<<"$client_prefs" | uniq | wc -l) -eq 11 ]] || { echo 'FAIL: duplicate client rule preferences.' >&2; exit 1; }
# The second layer covers IPv6 too: with a fallback IPv6 default route in
# place, the proxy UID must have no IPv6 egress at all.
ip -6 rule show | grep -F "uidrange $proxy_uid-$proxy_uid lookup 240" >/dev/null
ip -6 route show table 240 | grep -F 'unreachable default' >/dev/null
ip -6 route get 2001:db8::1 | grep -F "dev $fallback_interface" >/dev/null
if runuser -u rk-vpn-proxy -- ip -6 route get 2001:db8::1 >/dev/null 2>&1; then
    echo 'FAIL: proxy UID can route IPv6 egress through the fallback.' >&2
    exit 1
fi
echo 'PASS: 11 client rules keep distinct ordered preferences; IPv6 egress is unreachable for the proxy UID.'
if [[ "$systemd_test" == --systemd ]]; then
    systemd-run --quiet --unit="$proxy_unit" --property="BindsTo=$guard_unit" --property="After=$guard_unit" \
        --property=User=rk-vpn-proxy --property=Restart=always \
        --property="NetworkNamespacePath=/proc/$$/ns/net" \
        /usr/sbin/squid -N -n rkvpntest -f "$test_dir/build/squid.conf"
else
    runuser -u rk-vpn-proxy -- squid -N -n rkvpntest -f "$test_dir/build/squid.conf" > "$test_dir/squid.log" 2>&1 &
    proxy_pid=$!
fi
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
proxy_probe() {
    curl --silent --show-error --fail --noproxy '' --proxy "http://127.0.0.1:$HEALTH_PORT" \
        --max-time 5 http://1.1.1.1/ -o /dev/null
}
proxy_ready=0
for attempt in {1..50}; do
    if proxy_probe 2>/dev/null; then proxy_ready=1; break; fi
    sleep 0.1
done
[[ "$proxy_ready" == 1 ]] || { cat "$test_dir/squid.log"; exit 1; }
echo 'PASS: actual Squid startup and HTTP forwarding.'
ip link set "$VPN_INTERFACE" down
ip route get 1.1.1.1 | grep -F "dev $fallback_interface"
# A different UID can still use the ordinary fallback route.
curl --silent --fail --noproxy '*' --max-time 3 http://1.1.1.1/ -o /dev/null
if probe 2>/dev/null; then
    echo 'FAIL: proxy UID used the LAN fallback.' >&2; exit 1
fi
if proxy_probe 2>/dev/null; then
    echo 'FAIL: Squid used the LAN fallback.' >&2; exit 1
fi
echo 'PASS: VPN down blocks the proxy UID while other users retain LAN connectivity.'
ip link set "$VPN_INTERFACE" up
ip route replace default via 203.0.113.1 dev "$VPN_INTERFACE" metric 50
# The kernel drops device routes on link-down and does not restore them; wait
# for the watch daemon to re-add the VPN route in the policy routing table.
for attempt in {1..50}; do
    ip route show table 240 2>/dev/null | grep -qF "dev $VPN_INTERFACE" && break
    sleep 0.1
done
probe
proxy_probe
printf "PASS: proxy traffic recovers automatically when %s returns.\n" "$VPN_INTERFACE"
# Counters change during requests without invalidating the protection baseline.
sleep 1.2
bash "$source_dir/scripts/firewall.sh" --check
echo 'PASS: traffic counters do not trigger a false integrity failure.'
assert_guard_failed() {
    if [[ "$systemd_test" == --systemd ]]; then
        for attempt in {1..70}; do
            [[ $(systemctl show "$guard_unit" -p Result --value) == exit-code ]] &&
                ! systemctl is-active --quiet "$proxy_unit" && break
            sleep 0.1
        done
        [[ $(systemctl show "$guard_unit" -p Result --value) == exit-code ]]
        ! systemctl is-active --quiet "$proxy_unit"
        [[ ! -f "$RK_VPN_FIREWALL_STATE/enforced" ]]
        echo 'PASS: systemd BindsTo stops actual Squid after guard failure.'
        return
    fi
    for attempt in {1..50}; do
        kill -0 "$guard_pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$guard_pid" 2>/dev/null; then echo 'FAIL: guard did not detect changed rules.' >&2; exit 1; fi
    if wait "$guard_pid"; then echo 'FAIL: guard returned success after rule loss.' >&2; exit 1; fi
    guard_pid=''
    [[ ! -f "$RK_VPN_FIREWALL_STATE/enforced" ]]
}
nft flush chain inet rk_vpn_proxy proxy_egress
assert_guard_failed
echo 'PASS: modified rules fail the guard and clear FIREWALL_ENFORCED.'
if [[ "$systemd_test" == --systemd ]]; then
    systemctl start "$guard_unit" "$proxy_unit"
else
    start_guard
fi
for attempt in {1..50}; do
    [[ -f "$RK_VPN_FIREWALL_STATE/enforced" ]] && break
    sleep 0.1
done
nft delete table inet rk_vpn_proxy
assert_guard_failed
echo 'PASS: missing firewall table fails the guard.'
if [[ "$systemd_test" == --systemd ]]; then
    # Zero-leak gates: with the second policy-routing layer in place, BOTH a
    # plain VPN loss and full deletion of the nftables table must forward zero
    # requests through the fallback interface. Any non-zero count fails CI.
    systemctl start "$guard_unit" "$proxy_unit"
    leak_ready=0
    for attempt in {1..50}; do
        if proxy_probe 2>/dev/null; then leak_ready=1; break; fi
        sleep 0.1
    done
    [[ "$leak_ready" == 1 ]] || { echo 'FAIL: proxy did not restart for the leak gates.' >&2; exit 1; }
    ip link set "$VPN_INTERFACE" down
    ip route get 1.1.1.1 | grep -F "dev $fallback_interface"
    blocked=0
    for attempt in {1..30}; do
        if ! proxy_probe 2>/dev/null; then blocked=1; break; fi
        sleep 0.1
    done
    [[ "$blocked" == 1 ]] || { echo 'FAIL: proxy forwarded via the fallback while rules were intact.' >&2; exit 1; }
    stop_probes="$test_dir/stop-probes"
    leak_log="$test_dir/leak-count"
    rm -f -- "$stop_probes" "$leak_log"
    : > "$leak_log"
    probe_leaks() {
        while [[ ! -f "$stop_probes" ]]; do
            if proxy_probe 2>/dev/null; then printf 'x\n' >> "$leak_log"; fi
            sleep 0.02
        done
    }
    probe_leaks &
    leak_pid=$!
    sleep 2
    if [[ -s "$leak_log" ]]; then
        echo "FAIL: gate 1 - VPN loss alone forwarded $(wc -l < "$leak_log") request(s) via the fallback interface." >&2
        exit 1
    fi
    echo 'PASS: gate 1 - VPN loss forwards zero requests via the fallback interface.'
    nft delete table inet rk_vpn_proxy
    for attempt in {1..100}; do
        systemctl is-active --quiet "$proxy_unit" || break
        sleep 0.05
    done
    if systemctl is-active --quiet "$proxy_unit"; then
        echo 'FAIL: proxy kept running after rule deletion.' >&2
        exit 1
    fi
    sleep 1
    touch "$stop_probes"
    wait "$leak_pid" 2>/dev/null || true
    leak_pid=''
    if [[ -s "$leak_log" ]]; then
        echo "FAIL: gate 2 - $(wc -l < "$leak_log") request(s) reached the fallback interface after nftables deletion; the policy-routing layer did not hold." >&2
        exit 1
    fi
    echo 'PASS: gate 2 - deleting the whole nftables table still forwards zero requests via the fallback interface.'
    if runuser -u rk-vpn-proxy -- ip -6 route get 2001:db8::1 >/dev/null 2>&1; then
        echo 'FAIL: IPv6 egress became reachable for the proxy UID after nftables deletion.' >&2
        exit 1
    fi
    echo 'PASS: IPv6 egress stays unreachable after nftables deletion.'
fi
# The watch daemon must restore deleted policy routing rules on its own.
ip link set "$VPN_INTERFACE" up
ip route replace default via 203.0.113.1 dev "$VPN_INTERFACE" metric 50
if [[ "$systemd_test" == --systemd ]]; then
    systemctl start "$guard_unit" "$proxy_unit"
else
    start_guard
fi
proxy_ready=0
for attempt in {1..50}; do
    if proxy_probe 2>/dev/null; then proxy_ready=1; break; fi
    sleep 0.1
done
[[ "$proxy_ready" == 1 ]] || { echo 'FAIL: proxy did not restart for the routing self-heal check.' >&2; exit 1; }
proxy_uid=$(id -u rk-vpn-proxy)
if ! ip rule del uidrange "$proxy_uid-$proxy_uid" lookup 240 2>/dev/null; then
    echo 'FAIL: expected a policy routing rule to delete.' >&2; exit 1
fi
sleep 2.5
if ! ip rule show | grep -F "uidrange $proxy_uid-$proxy_uid" | grep -qF 'lookup 240'; then
    echo 'FAIL: watch daemon did not restore the deleted policy routing rule.' >&2; exit 1
fi
bash "$source_dir/scripts/firewall.sh" --check
proxy_probe
echo 'PASS: watch daemon restores deleted policy routing rules.'

# A full VPN interface rebuild (gone, re-enumerated, new address and gateway)
# must keep the proxy blocked while the interface is missing and self-heal
# the mirrored default route afterwards.
ip link del "$VPN_INTERFACE"
sleep 1.5
if probe 2>/dev/null; then
    echo 'FAIL: proxy UID forwarded while the VPN interface was gone.' >&2; exit 1
fi
ip link add "$VPN_INTERFACE" type veth peer name vpn-peer
ip link set vpn-peer netns "$server_pid"
ip address add 203.0.114.2/24 dev "$VPN_INTERFACE"
ip link set "$VPN_INTERFACE" up
nsenter -t "$server_pid" -n ip address add 203.0.114.1/24 dev vpn-peer
nsenter -t "$server_pid" -n ip link set vpn-peer up
ip route add default via 203.0.114.1 dev "$VPN_INTERFACE" metric 50
for attempt in {1..50}; do
    ip route show table 240 2>/dev/null | grep -qF 'via 203.0.114.1' && break
    sleep 0.1
done
ip route show table 240 | grep -F 'via 203.0.114.1' || {
    echo 'FAIL: watch daemon did not mirror the rebuilt VPN default route.' >&2; exit 1;
}
bash "$source_dir/scripts/firewall.sh" --check
probe
proxy_probe
echo 'PASS: VPN interface rebuild with a new gateway stays blocked and self-heals.'
