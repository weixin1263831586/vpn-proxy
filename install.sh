#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ip -4 address show | grep -q '172.16.14.233/' || {
    echo 'This installer is intended for 172.16.14.233.' >&2; exit 1;
}
if ! id rk-vpn-proxy >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin rk-vpn-proxy
fi
if ! command -v squid >/dev/null; then
    # Prevent the distribution's default, broad listener from starting on install.
    systemctl mask squid.service
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y squid nftables
fi
install -d -m 0755 /etc/rk-vpn-proxy /usr/local/libexec
if [[ -f /etc/rk-vpn-proxy/squid.conf ]]; then
    cp -a /etc/rk-vpn-proxy/squid.conf "/etc/rk-vpn-proxy/squid.conf.bak.$(date +%Y%m%d-%H%M%S)"
fi
install -m 0644 "$source_dir/squid.conf" /etc/rk-vpn-proxy/squid.conf
install -d -o rk-vpn-proxy -g rk-vpn-proxy -m 0750 /var/log/rk-vpn-proxy /run/rk-vpn-proxy
install -m 0755 "$source_dir/firewall.sh" /usr/local/libexec/rk-vpn-proxy-firewall
install -m 0755 "$source_dir/health.sh" /usr/local/libexec/rk-vpn-proxy-health
for name in rk-vpn-proxy-firewall.service rk-vpn-proxy.service rk-vpn-proxy-health.service rk-vpn-proxy-health.timer; do
    install -m 0644 "$source_dir/$name" "/etc/systemd/system/$name"
done
cat > /etc/logrotate.d/rk-vpn-proxy <<'EOF'
/var/log/rk-vpn-proxy/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    su rk-vpn-proxy rk-vpn-proxy
    create 0640 rk-vpn-proxy rk-vpn-proxy
    sharedscripts
    postrotate
        systemctl kill --signal=USR1 --kill-who=main rk-vpn-proxy.service >/dev/null 2>&1 || true
    endscript
}
EOF
runuser -u rk-vpn-proxy -- squid -k parse -f /etc/rk-vpn-proxy/squid.conf
systemctl daemon-reload
systemctl enable rk-vpn-proxy-firewall.service rk-vpn-proxy.service rk-vpn-proxy-health.timer
systemctl restart rk-vpn-proxy-firewall.service
systemctl restart rk-vpn-proxy.service
ready=0
for attempt in {1..10}; do
    if curl --silent --fail --noproxy '' --proxy http://127.0.0.1:17897 \
        --connect-timeout 2 --max-time 5 --head https://www.google.com >/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
[[ $ready == 1 ]] || { echo 'Proxy failed the Google HTTPS readiness check.' >&2; exit 1; }
if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
    ufw allow from 10.10.10.206 to 172.16.14.233 port 7897 proto tcp comment 'rk-vpn-proxy'
fi
systemctl restart rk-vpn-proxy-health.timer
systemctl start rk-vpn-proxy-health.service
systemctl --no-pager --full status rk-vpn-proxy.service
echo 'Installed: http://172.16.14.233:7897 (LAN ACL: 10.10.10.206 only)'
