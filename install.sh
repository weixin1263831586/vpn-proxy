#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_path=${1:-"$source_dir/config.json"}
build_dir="$source_dir/build"
python3 -B "$source_dir/build-installer.py" --config "$config_path"
source "$build_dir/runtime.env"
if [[ "$PROXY_BIND_ADDRESS" != 0.0.0.0 ]]; then
    ip -4 address show | grep -Fq "$PROXY_BIND_ADDRESS/" || {
        echo "Configured listen address is not on this host: $PROXY_BIND_ADDRESS" >&2; exit 1;
    }
fi
if ! id rk-vpn-proxy >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin rk-vpn-proxy
fi
if ! id rk-vpn-health >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin rk-vpn-health
fi
if ! id rk-vpn-installer >/dev/null 2>&1; then
    useradd --system --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin rk-vpn-installer
fi
# Refuse to silently disrupt an existing distribution Squid deployment.
if systemctl is-active --quiet squid.service; then
    echo 'squid.service is active. Stop/migrate it explicitly before installing the dedicated proxy.' >&2
    exit 1
fi
# An already installed Squid binary does not guarantee nft is installed.
missing=()
command -v squid >/dev/null 2>&1 || missing+=(squid)
command -v nft >/dev/null 2>&1 || missing+=(nftables)
if (("${#missing[@]}" > 0)); then
    # Prevent the distribution's default wildcard listener during package installation.
    if [[ " ${missing[*]} " == *" squid "* ]]; then
        systemctl mask squid.service
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi
command -v nft >/dev/null 2>&1 || { echo 'Missing nft binary after installation.' >&2; exit 1; }
command -v squid >/dev/null 2>&1 || { echo 'Missing squid binary after installation.' >&2; exit 1; }
install -d -m 0755 /etc/rk-vpn-proxy /usr/local/libexec
backup_stamp=$(date +%Y%m%d-%H%M%S)
for name in squid.conf config.json runtime.env; do
    if [[ -f "/etc/rk-vpn-proxy/$name" ]]; then
        cp -a "/etc/rk-vpn-proxy/$name" "/etc/rk-vpn-proxy/$name.bak.$backup_stamp"
    fi
done
install -m 0644 "$build_dir/squid.conf" /etc/rk-vpn-proxy/squid.conf
if [[ $(readlink -f "$config_path") != /etc/rk-vpn-proxy/config.json ]]; then
    install -m 0644 "$config_path" /etc/rk-vpn-proxy/config.json
fi
install -m 0644 "$build_dir/runtime.env" /etc/rk-vpn-proxy/runtime.env
install -d -o rk-vpn-proxy -g rk-vpn-proxy -m 0750 /var/log/rk-vpn-proxy /run/rk-vpn-proxy
install -m 0755 "$source_dir/scripts/firewall.sh" /usr/local/libexec/rk-vpn-proxy-firewall
install -m 0755 "$source_dir/scripts/health.sh" /usr/local/libexec/rk-vpn-proxy-health
install -d -m 0755 /usr/local/lib/rk-vpn-proxy/build
install -m 0644 "$source_dir/serve-installer.py" "$source_dir/configuration.py" /usr/local/lib/rk-vpn-proxy/
install -m 0644 "$build_dir/client-install.sh" "$build_dir/client-install.ps1" /usr/local/lib/rk-vpn-proxy/build/
for name in rk-vpn-proxy-firewall.service rk-vpn-proxy.service rk-vpn-proxy-health.service rk-vpn-proxy-health.timer rk-vpn-proxy-installer.service; do
    install -m 0644 "$source_dir/systemd/$name" "/etc/systemd/system/$name"
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
# Migrate a pre-existing user download unit before binding the system listener.
if [[ -n ${SUDO_USER:-} && "$SUDO_USER" != root ]]; then
    runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$SUDO_USER")" \
        systemctl --user disable --now rk-vpn-proxy-installer.service >/dev/null 2>&1 || true
fi
systemctl enable rk-vpn-proxy-firewall.service rk-vpn-proxy.service rk-vpn-proxy-health.timer rk-vpn-proxy-installer.service
systemctl restart rk-vpn-proxy-firewall.service
systemctl restart rk-vpn-proxy.service
ready=0
for attempt in {1..10}; do
    if curl --silent --fail --noproxy '' --proxy "http://127.0.0.1:$HEALTH_PORT" \
        --connect-timeout 5 --max-time 15 --head "$PROXY_TEST_URL" >/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
[[ $ready == 1 ]] || { echo 'Proxy failed the Google HTTPS readiness check.' >&2; exit 1; }
if command -v ufw >/dev/null && LC_ALL=C ufw status | grep -q '^Status: active'; then
    mapfile -t allowed_networks < <(python3 -c 'import json,sys; print(*json.load(open(sys.argv[1]))["allowed_clients"], sep="\n")' "$config_path")
    for network in "${allowed_networks[@]}"; do
        ufw allow from "$network" to "$PROXY_BIND_ADDRESS" port "$PROXY_PORT" proto tcp comment 'rk-vpn-proxy'
        ufw allow from "$network" to "$PROXY_BIND_ADDRESS" port "$INSTALLER_PORT" proto tcp comment 'rk-vpn-installer'
    done
fi
systemctl restart rk-vpn-proxy-installer.service
systemctl restart rk-vpn-proxy-health.timer
systemctl start rk-vpn-proxy-health.service
systemctl --no-pager --full status rk-vpn-proxy.service
printf 'Installed listener: http://%s:%s (client networks from %s)\n' "$PROXY_BIND_ADDRESS" "$PROXY_PORT" "$config_path"
