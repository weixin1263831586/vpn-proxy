#!/bin/bash
# Real-system fault-injection drill for install/upgrade/rollback.
# Runs the actual install.sh against real apt, systemd and nftables and breaks
# things on purpose. Use ONLY on a disposable Ubuntu host (container, VM, CI
# runner): it stops and reinstalls the proxy deployment repeatedly.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo (on a disposable host).' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${DRILL_CONFIRM_DISPOSABLE:-} != 1 ]]; then
    echo 'This drill removes packages, rewrites APT sources and interrupts services.' >&2
    echo 'Run it ONLY on a disposable Ubuntu host and confirm with:' >&2
    echo '    DRILL_CONFIRM_DISPOSABLE=1 sudo -E bash tests/test-deployment-drill.sh' >&2
    exit 1
fi
if [[ -d /etc/rk-vpn-proxy ]] || compgen -G '/etc/systemd/system/rk-vpn-proxy-*' >/dev/null; then
    echo 'Refusing to run: this host already has an rk-vpn-proxy deployment.' >&2
    exit 1
fi
# install.sh refuses to migrate a running distribution Squid; stop it and wait.
for attempt in {1..20}; do
    systemctl is-active --quiet squid.service || break
    systemctl stop squid.service 2>/dev/null || true
    sleep 0.5
done
if systemctl is-active --quiet squid.service; then
    echo 'FAIL: could not stop the distribution squid before drilling.' >&2
    exit 1
fi
drill_dir=$(mktemp -d /tmp/rk-vpn-drill.XXXXXX)
cleanup() {
    rm -rf -- /tmp/rk-vpn-drill-last
    cp -a -- "$drill_dir" /tmp/rk-vpn-drill-last 2>/dev/null || true
    rm -rf -- "$drill_dir"
}
trap cleanup EXIT
trap 'echo "DRILL FAILED at line $LINENO: $BASH_COMMAND" >&2; exit 1' ERR
PROXY_PORT=17901
TEST_URL=${DRILL_TEST_URL:-https://www.google.com}
DRILL_DNS=${DRILL_DNS:-8.8.8.8}
default_iface=$(ip -4 route show default | awk '{print $5; exit}')
[[ -n "$default_iface" ]] || { echo 'No default IPv4 route found.' >&2; exit 1; }
for tool in python3 ip curl systemctl runuser flock apt-get nft; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
write_config() {
    cat > "$1" <<EOF
{
  "listen_host": "127.0.0.1",
  "advertise_host": "127.0.0.1",
  "proxy_port": $PROXY_PORT,
  "health_port": 17902,
  "installer_port": 17903,
  "vpn_interface": "$default_iface",
  "allowed_clients": ["127.0.0.0/8"],
  "installer_enabled": $3,
  "dns_nameservers": ["$DRILL_DNS"],
  "test_url": "$TEST_URL",
  "no_proxy": ["localhost", "127.0.0.1", "::1"$2]
}
EOF
}
write_config "$drill_dir/config1.json" '' true
write_config "$drill_dir/config2.json" ', "drill.invalid"' true
write_config "$drill_dir/config3.json" ', "drill.disabled"' false
forward_ok() {
    curl --silent --fail --noproxy '' --proxy "http://127.0.0.1:$PROXY_PORT" \
        --connect-timeout 5 --max-time 20 --head "$TEST_URL" -o /dev/null
}
wait_healthy() {
    local label=$1
    for attempt in $(seq 1 90); do
        if systemctl is-active --quiet rk-vpn-proxy.service && forward_ok; then
            echo "PASS: $label"
            return 0
        fi
        sleep 1
    done
    echo "FAIL: $label (proxy not healthy)" >&2
    journalctl -u rk-vpn-proxy.service -u rk-vpn-proxy-firewall.service -n 30 --no-pager >&2 || true
    return 1
}
run_install() {
    local config=$1 log=$2
    bash "$source_dir/install.sh" "$config" > "$log" 2>&1
}

echo "== Scenario C: package download failure on a fresh host leaves nothing behind =="
apt-get remove -y squid nftables >/dev/null 2>&1 || true
systemctl daemon-reload
mkdir -p "$drill_dir/apt-backup"
cp -a /etc/apt/sources.list.d "$drill_dir/apt-backup/" 2>/dev/null || true
cp -a /etc/apt/sources.list "$drill_dir/apt-backup/" 2>/dev/null || true
rm -rf /etc/apt/sources.list.d /etc/apt/sources.list
echo 'deb http://127.0.0.1:1/ubuntu nonexistent main' > /etc/apt/sources.list
# apt's squid postrm masks squid.service on removal; the drill only requires the
# failed install to leave the pre-install state untouched.
mask_before=$(readlink /etc/systemd/system/squid.service 2>/dev/null || echo absent)
if run_install "$drill_dir/config1.json" "$drill_dir/install-c.log"; then
    echo 'FAIL: install succeeded despite broken apt.' >&2; exit 1
fi
grep -F 'Installation failed; restoring' "$drill_dir/install-c.log" >/dev/null || {
    echo 'FAIL: failure did not trigger restore.' >&2; exit 1;
}
[[ ! -e /etc/rk-vpn-proxy && ! -e /usr/local/libexec/rk-vpn-proxy-firewall ]]
compgen -G '/etc/systemd/system/rk-vpn-proxy-*' >/dev/null && {
    echo 'FAIL: unit files left behind.' >&2; exit 1;
}
mask_after=$(readlink /etc/systemd/system/squid.service 2>/dev/null || echo absent)
if [[ "$mask_after" != "$mask_before" ]]; then
    echo "FAIL: squid.service mask state changed: '$mask_before' -> '$mask_after'" >&2
    exit 1
fi
if systemctl is-active --quiet squid.service; then
    echo 'FAIL: distribution squid started during failed install.' >&2; exit 1
fi
echo 'PASS: broken apt fails cleanly with no partial deployment.'
rm -f /etc/apt/sources.list
cp -a "$drill_dir/apt-backup/sources.list.d" /etc/apt/ 2>/dev/null || true
cp -a "$drill_dir/apt-backup/sources.list" /etc/apt/ 2>/dev/null || true
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y squid nftables
systemctl stop squid.service 2>/dev/null || true

echo "== Scenario C2: a foreign default route in table 240 blocks the first install =="
# Another service already mirrors this project's signature inside the table.
# Without a deployment record the precheck must refuse to claim it, and the
# route must survive the failed install untouched.
ip route add default dev "$default_iface" metric 100 table 240
if run_install "$drill_dir/config1.json" "$drill_dir/install-c2.log"; then
    echo 'FAIL: install claimed foreign routing resources.' >&2; exit 1
fi
grep -F 'no managed deployment is recorded' "$drill_dir/install-c2.log" >/dev/null || {
    echo 'FAIL: refusal reason missing from the install log.' >&2; exit 1;
}
ip route show table 240 | grep -F 'metric 100' >/dev/null || {
    echo 'FAIL: the foreign route was removed by the refused install.' >&2; exit 1;
}
ip route del default dev "$default_iface" metric 100 table 240
if ip route show table 240 | grep -qF 'metric 100'; then
    echo 'FAIL: fixture cleanup left a table 240 route.' >&2; exit 1
fi
echo 'PASS: first install refuses a copied metric-100 default and keeps it intact.'

echo "== Scenario A: real baseline deployment =="
if [[ ${DRILL_UFW:-0} == 1 ]] && command -v ufw >/dev/null; then
    ufw --force enable >/dev/null
fi
run_install "$drill_dir/config1.json" "$drill_dir/install-a.log"
wait_healthy 'fresh deployment installs and forwards traffic.'
nft list table inet rk_vpn_proxy >/dev/null
ip rule show | grep -F "lookup 240" >/dev/null
ip route show table 240 | grep -F "unreachable" >/dev/null
ip -6 rule show | grep -F 'uidrange' | grep -F "lookup 240" >/dev/null
ip -6 route show table 240 | grep -F 'unreachable' >/dev/null
systemctl is-active --quiet rk-vpn-proxy-installer.service
echo 'PASS: nftables and policy-routing constraints installed for IPv4 and IPv6; HTTP installer enabled.'
cp /etc/rk-vpn-proxy/config.json "$drill_dir/baseline-config.json"
cp /etc/rk-vpn-proxy/squid.conf "$drill_dir/baseline-squid.conf"
if [[ ${DRILL_UFW:-0} == 1 ]] && command -v ufw >/dev/null; then
    ufw show added | grep -F 'rk-vpn-proxy' >/dev/null
    echo 'PASS: project UFW rules added with ownership comments.'
fi

echo "== Scenario B: upgrade with a broken Squid config restores the running service =="
cp "$source_dir/templates/squid.conf.in" "$drill_dir/squid.conf.in.orig"
printf '\nthis_directive_does_not_exist on\n' >> "$source_dir/templates/squid.conf.in"
restore_template() { mv -f -- "$drill_dir/squid.conf.in.orig" "$source_dir/templates/squid.conf.in"; }
if run_install "$drill_dir/config2.json" "$drill_dir/install-b.log"; then
    restore_template
    echo 'FAIL: install accepted a broken Squid config.' >&2; exit 1
fi
restore_template
grep -F 'Installation failed; restoring' "$drill_dir/install-b.log" >/dev/null
cmp -s /etc/rk-vpn-proxy/config.json "$drill_dir/baseline-config.json"
cmp -s /etc/rk-vpn-proxy/squid.conf "$drill_dir/baseline-squid.conf"
wait_healthy 'service survives a failed upgrade with the original config.'
[[ -n $(ls -A /var/lib/rk-vpn-proxy-deploy/transactions 2>/dev/null) ]]

dropin=/etc/systemd/system/rk-vpn-proxy.service.d
write_dropin() {
    mkdir -p "$dropin"
    printf '[Service]\nExecStartPre=/bin/sleep 8\n' > "$dropin/zz-drill.conf"
    systemctl daemon-reload
}
clear_dropin() {
    rm -rf -- "$dropin"
    systemctl daemon-reload
}

echo "== Scenario D: SIGTERM mid-install triggers restore =="
write_dropin
bash "$source_dir/install.sh" "$drill_dir/config2.json" > "$drill_dir/install-d.log" 2>&1 &
install_pid=$!
for attempt in $(seq 1 300); do
    grep -qF 'drill.invalid' /etc/rk-vpn-proxy/config.json 2>/dev/null && break
    kill -0 "$install_pid" 2>/dev/null || break
    sleep 0.1
done
sleep 0.3
kill -TERM "$install_pid" 2>/dev/null || true
for attempt in $(seq 1 300); do
    kill -0 "$install_pid" 2>/dev/null || break
    sleep 0.1
done
wait "$install_pid" || true
grep -F 'Installation failed; restoring' "$drill_dir/install-d.log" >/dev/null
cmp -s /etc/rk-vpn-proxy/config.json "$drill_dir/baseline-config.json"
wait_healthy 'SIGTERM mid-install restores the previous deployment.'
clear_dropin
systemctl restart rk-vpn-proxy-firewall.service rk-vpn-proxy.service
wait_healthy 'services restart without the drill drop-in.'

echo "== Scenario E: SIGKILL mid-install is recovered from the transaction snapshot =="
write_dropin
bash "$source_dir/install.sh" "$drill_dir/config2.json" > "$drill_dir/install-e.log" 2>&1 &
install_pid=$!
for attempt in $(seq 1 300); do
    grep -qF 'drill.invalid' /etc/rk-vpn-proxy/config.json 2>/dev/null && break
    kill -0 "$install_pid" 2>/dev/null || break
    sleep 0.1
done
kill -9 "$install_pid" 2>/dev/null || true
sleep 12  # let orphaned systemctl calls finish; no automatic restore happens
latest=$(ls -1 /var/lib/rk-vpn-proxy-deploy/transactions | sort | tail -1)
[[ -f "/var/lib/rk-vpn-proxy-deploy/transactions/$latest/state.json" ]]
flock /run/lock/rk-vpn-proxy-deploy.lock \
    python3 -B "$source_dir/scripts/deployment.py" restore \
    "/var/lib/rk-vpn-proxy-deploy/transactions/$latest"
wait_healthy 'manual snapshot restore recovers after SIGKILL.'
clear_dropin
systemctl restart rk-vpn-proxy-firewall.service rk-vpn-proxy.service
wait_healthy 'services restart without the drill drop-in.'

echo "== Scenario G: disabling the HTTP installer entry point =="
run_install "$drill_dir/config3.json" "$drill_dir/install-g.log"
if systemctl is-active --quiet rk-vpn-proxy-installer.service; then
    echo 'FAIL: installer service still active after installer_enabled=false.' >&2; exit 1
fi
if systemctl is-enabled --quiet rk-vpn-proxy-installer.service; then
    echo 'FAIL: installer service still enabled after installer_enabled=false.' >&2; exit 1
fi
if [[ ${DRILL_UFW:-0} == 1 ]] && command -v ufw >/dev/null; then
    if ufw show added | grep -Fq 'rk-vpn-installer'; then
        echo 'FAIL: installer UFW rule left after installer_enabled=false.' >&2; exit 1
    fi
fi
wait_healthy 'proxy keeps working with the HTTP installer entry disabled.'
echo 'PASS: installer_enabled=false stops and disables the HTTP entry point.'

echo "== Scenario F: rollback removes the deployment =="
bash "$source_dir/rollback.sh" > "$drill_dir/rollback.log" 2>&1
[[ ! -e /etc/rk-vpn-proxy && ! -e /usr/local/libexec/rk-vpn-proxy-firewall ]]
compgen -G '/etc/systemd/system/rk-vpn-proxy-*' >/dev/null && {
    echo 'FAIL: unit files left after rollback.' >&2; exit 1;
}
if nft list table inet rk_vpn_proxy >/dev/null 2>&1; then
    echo 'FAIL: dedicated nftables table left after rollback.' >&2; exit 1
fi
if ip rule show | grep -Fq 'lookup 240'; then
    echo 'FAIL: policy routing rules left after rollback.' >&2; exit 1
fi
if ip rule show | grep -Fq 'uidrange'; then
    echo 'FAIL: proxy UID policy routing rules left after rollback.' >&2; exit 1
fi
if [[ -n $(ip route show table 240 2>/dev/null) ]]; then
    echo 'FAIL: policy routing table left after rollback.' >&2; exit 1
fi
if ip -6 rule show | grep -Fq 'uidrange'; then
    echo 'FAIL: IPv6 policy routing rules left after rollback.' >&2; exit 1
fi
if [[ -n $(ip -6 route show table 240 2>/dev/null) ]]; then
    echo 'FAIL: IPv6 policy routing table left after rollback.' >&2; exit 1
fi
for unit in rk-vpn-proxy.service rk-vpn-proxy-firewall.service rk-vpn-proxy-installer.service; do
    systemctl is-active --quiet "$unit" && {
        echo "FAIL: $unit still active after rollback." >&2; exit 1;
    }
done
if [[ ${DRILL_UFW:-0} == 1 ]] && command -v ufw >/dev/null; then
    if ufw show added | grep -Fq 'rk-vpn-proxy'; then
        echo 'FAIL: project UFW rules left after rollback.' >&2; exit 1
    fi
fi
echo 'PASS: rollback removes files, services, firewall and owned UFW rules.'

echo "== Scenario H: rollback restores a running legacy deployment =="
# Simulate an older generation of this project on the host: a proxy system
# user, a hand-managed nftables table and a Squid under the very unit name
# the managed installation reuses. The first managed install must snapshot
# it, and rollback must bring it back with its firewall intact instead of
# deleting the restored table.
cat > /etc/rk-legacy-squid.conf <<EOF
http_port 127.0.0.1:$PROXY_PORT
acl all_clients src all
http_access allow all_clients
cache deny all
access_log none
cache_log stdio:/dev/stderr
pid_filename none
coredump_dir /tmp
EOF
chmod 0644 /etc/rk-legacy-squid.conf
cat > /etc/systemd/system/rk-vpn-proxy.service <<'EOF'
[Unit]
Description=Legacy rk-vpn-proxy generation
After=network.target

[Service]
User=rk-vpn-proxy
ExecStart=/usr/sbin/squid -N -n rkvpnlegacy -f /etc/rk-legacy-squid.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF
nft -f - <<'EOF'
table inet rk_vpn_proxy {
    chain legacy_marker {
        counter comment "legacy generation marker"
    }
}
EOF
systemctl daemon-reload
systemctl enable --now rk-vpn-proxy.service
cp /etc/systemd/system/rk-vpn-proxy.service "$drill_dir/legacy-unit"
for attempt in $(seq 1 30); do
    forward_ok && break
    sleep 1
done
forward_ok
echo 'PASS: legacy proxy generation is running behind its own nftables table.'
run_install "$drill_dir/config1.json" "$drill_dir/install-h.log"
wait_healthy 'managed upgrade installs over the running legacy deployment.'
bash "$source_dir/rollback.sh" > "$drill_dir/rollback-h.log" 2>&1
cmp /etc/systemd/system/rk-vpn-proxy.service "$drill_dir/legacy-unit"
nft list table inet rk_vpn_proxy | grep -F 'legacy generation marker' >/dev/null
systemctl is-active --quiet rk-vpn-proxy.service
[[ ! -e /etc/rk-vpn-proxy ]]
if ip rule show | grep -Fq 'uidrange'; then
    echo 'FAIL: managed policy routing left after legacy rollback.' >&2; exit 1
fi
if [[ -n $(ip route show table 240 2>/dev/null) || -n $(ip -6 route show table 240 2>/dev/null) ]]; then
    echo 'FAIL: managed routing tables left after legacy rollback.' >&2; exit 1
fi
wait_healthy 'rollback restores the legacy proxy with its original firewall.'
echo 'PASS: rollback restores a running legacy proxy and keeps its firewall.'

echo "== Scenario H2: interrupted first install leaves no policy routing behind =="
systemctl disable --now rk-vpn-proxy.service >/dev/null 2>&1
rm -f /etc/systemd/system/rk-vpn-proxy.service /etc/rk-legacy-squid.conf
nft delete table inet rk_vpn_proxy
systemctl daemon-reload
bash "$source_dir/install.sh" "$drill_dir/config2.json" > "$drill_dir/install-h2.log" 2>&1 &
install_pid=$!
interrupted=0
for attempt in $(seq 1 600); do
    if systemctl is-active --quiet rk-vpn-proxy.service && ip rule show | grep -qF 'uidrange'; then
        kill -9 "$install_pid" 2>/dev/null || true
        interrupted=1
        break
    fi
    kill -0 "$install_pid" 2>/dev/null || break
    sleep 0.1
done
if [[ "$interrupted" != 1 ]]; then
    echo 'FAIL: could not interrupt the first install after services started.' >&2
    kill "$install_pid" 2>/dev/null || true
    exit 1
fi
wait "$install_pid" 2>/dev/null || true
sleep 3  # let orphaned systemctl calls finish
latest=$(ls -1 /var/lib/rk-vpn-proxy-deploy/transactions | sort | tail -1)
[[ -f "/var/lib/rk-vpn-proxy-deploy/transactions/$latest/state.json" ]]
flock /run/lock/rk-vpn-proxy-deploy.lock \
    python3 -B "$source_dir/scripts/deployment.py" restore \
    "/var/lib/rk-vpn-proxy-deploy/transactions/$latest"
[[ ! -e /etc/rk-vpn-proxy && ! -e /usr/local/libexec/rk-vpn-proxy-firewall ]]
compgen -G '/etc/systemd/system/rk-vpn-proxy-*' >/dev/null && {
    echo 'FAIL: unit files left behind.' >&2; exit 1;
}
if nft list table inet rk_vpn_proxy >/dev/null 2>&1; then
    echo 'FAIL: dedicated nftables table left after interrupted first install.' >&2; exit 1
fi
if ip rule show | grep -qF 'uidrange' || ip -6 rule show | grep -qF 'uidrange'; then
    echo 'FAIL: policy routing rules left after interrupted first install.' >&2; exit 1
fi
if [[ -n $(ip route show table 240 2>/dev/null) || -n $(ip -6 route show table 240 2>/dev/null) ]]; then
    echo 'FAIL: policy routing table left after interrupted first install.' >&2; exit 1
fi
for unit in rk-vpn-proxy.service rk-vpn-proxy-firewall.service; do
    systemctl is-active --quiet "$unit" && {
        echo "FAIL: $unit still active after restore." >&2; exit 1;
    }
done
echo 'PASS: interrupted first install restores a clean host with no policy-routing residue.'

echo 'ALL DRILL SCENARIOS PASSED'
