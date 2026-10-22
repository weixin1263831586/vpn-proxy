#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_path=${1:-"$source_dir/config.json"}
for tool in python3 ip curl systemctl runuser flock; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
exec 9>/run/lock/rk-vpn-proxy-deploy.lock
flock -n 9 || { echo 'Another deployment or rollback is running.' >&2; exit 1; }
build_dir=$(mktemp -d)
trap 'rm -rf -- "$build_dir"' EXIT
cp -- "$config_path" "$build_dir/config.json"
config_path="$build_dir/config.json"
python3 -B "$source_dir/build-installer.py" --config "$config_path" --output-dir "$build_dir"
source "$build_dir/runtime.env"
if [[ "$PROXY_BIND_ADDRESS" != 0.0.0.0 ]]; then
    ip -4 address show | grep -Fq "$PROXY_BIND_ADDRESS/" || {
        echo "Configured listen address is not on this host: $PROXY_BIND_ADDRESS" >&2; exit 1;
    }
fi
# Refuse conflicts before creating accounts or changing package/service state.
if systemctl is-active --quiet squid.service; then
    echo 'squid.service is active. Stop/migrate it explicitly before installing the dedicated proxy.' >&2
    exit 1
fi
if [[ -n ${SUDO_USER:-} && "$SUDO_USER" != root ]] &&
    runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$(id -u "$SUDO_USER")" \
        systemctl --user is-active --quiet rk-vpn-proxy-installer.service 2>/dev/null; then
    echo 'A user installer service is active; disable it explicitly before migration.' >&2
    exit 1
fi
deploy_state=/var/lib/rk-vpn-proxy-deploy
install -d -m 0700 "$deploy_state" "$deploy_state/transactions"
transaction="$deploy_state/transactions/$(date +%Y%m%d-%H%M%S)-$$"
python3 -B "$source_dir/scripts/deployment.py" snapshot "$transaction"
restore_failed_install() {
    local result=$?
    trap - ERR INT TERM
    echo "Installation failed; restoring previous deployment from $transaction" >&2
    if ! python3 -B "$source_dir/scripts/deployment.py" restore "$transaction"; then
        echo "RESTORE FAILED: proxy must remain stopped. Inspect $transaction and system services." >&2
    fi
    exit "$result"
}
trap restore_failed_install ERR
trap 'false' INT TERM
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
command -v nft >/dev/null 2>&1 || { echo 'Missing nft binary after installation.' >&2; false; }
command -v squid >/dev/null 2>&1 || { echo 'Missing squid binary after installation.' >&2; false; }
install -d -o rk-vpn-proxy -g rk-vpn-proxy -m 0750 /var/log/rk-vpn-proxy /run/rk-vpn-proxy
# Validate staged configuration before replacing the installed files.
runuser -u rk-vpn-proxy -- squid -k parse -f /dev/stdin < "$build_dir/squid.conf"
RK_VPN_RUNTIME="$build_dir/runtime.env" bash "$source_dir/scripts/firewall.sh" --validate
python3 -B "$source_dir/scripts/deployment.py" stop
install -d -m 0755 /etc/rk-vpn-proxy /usr/local/libexec
install -m 0644 "$build_dir/squid.conf" /etc/rk-vpn-proxy/squid.conf
install -m 0644 "$config_path" /etc/rk-vpn-proxy/config.json
install -m 0644 "$build_dir/runtime.env" /etc/rk-vpn-proxy/runtime.env
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
systemctl enable rk-vpn-proxy-firewall.service rk-vpn-proxy.service rk-vpn-proxy-health.timer
if [[ "$INSTALLER_ENABLED" == 1 ]]; then
    systemctl enable rk-vpn-proxy-installer.service
else
    systemctl disable rk-vpn-proxy-installer.service 2>/dev/null || true
fi
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
[[ $ready == 1 ]] || { echo 'Proxy failed the HTTPS readiness check.' >&2; false; }
LC_ALL=C python3 -B "$source_dir/scripts/deployment.py" ufw-sync "$config_path"
if [[ "$INSTALLER_ENABLED" == 1 ]]; then
    systemctl restart rk-vpn-proxy-installer.service
    installer_host=$PROXY_BIND_ADDRESS
    [[ "$installer_host" != 0.0.0.0 ]] || installer_host=127.0.0.1
    download_ready=0
    for attempt in {1..5}; do
        # Use a loopback source so restrictive client ACLs need no host-IP exception.
        if curl --silent --fail --noproxy '*' --interface 127.0.0.1 --max-time 3 \
            "http://$installer_host:$INSTALLER_PORT/install.sh" -o "$build_dir/download-check" &&
            cmp -s "$build_dir/download-check" "$build_dir/client-install.sh"; then
            download_ready=1
            break
        fi
        sleep 1
    done
    [[ $download_ready == 1 ]] || { echo 'Installer failed the download readiness check.' >&2; false; }
else
    systemctl stop rk-vpn-proxy-installer.service 2>/dev/null || true
    echo 'HTTP installer entry point disabled (installer_enabled=false).'
fi
systemctl restart rk-vpn-proxy-health.timer
# The deployment verdict is the proxy HTTPS and installer readiness checks above.
# The first health probe only records state; an external IP service outage must
# not roll back a deployment that already passed acceptance.
if ! systemctl start rk-vpn-proxy-health.service; then
    echo 'Warning: first health probe failed; deployment checks already passed. See journalctl -u rk-vpn-proxy-health.service.' >&2
fi
systemctl --no-pager --full status rk-vpn-proxy.service
if [[ ! -d "$deploy_state/original" ]]; then
    cp -a -- "$transaction" "$deploy_state/original.tmp.$$"
    mv -- "$deploy_state/original.tmp.$$" "$deploy_state/original"
fi
trap - ERR INT TERM
printf 'Installed listener: http://%s:%s (client networks from /etc/rk-vpn-proxy/config.json)\n' "$PROXY_BIND_ADDRESS" "$PROXY_PORT"
