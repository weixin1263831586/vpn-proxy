#!/bin/bash
# Run in Bash: source <(curl --noproxy '*' -fsSL http://172.16.14.233:8089/install.sh)
# Sourcing loads the proxy into the current terminal; piping to Bash configures
# future terminals and runs the test in that child shell.
_rk_vpn_install() {
    if bash <<'RK_VPN_INSTALL_BODY'
set -euo pipefail
ip -4 address show | grep -q '10.10.10.206/' || {
    echo 'This installer is intended for build server 10.10.10.206.' >&2
    exit 1
}
command -v curl >/dev/null
proxy=http://172.16.14.233:7897
echo "Checking proxy: $proxy"
# A failed probe leaves the current persistent settings untouched.
probe=$(curl --silent --show-error --fail --noproxy '' --proxy "$proxy" \
    --connect-timeout 5 --max-time 30 --head --output /dev/null \
    --write-out '%{http_connect} %{http_code}' https://www.google.com)
[[ "$probe" == '200 200' ]] || {
    printf 'Google proxy check failed: %s\n' "$probe" >&2
    exit 1
}
client_dir="$HOME/.config/rk-vpn-proxy"
mkdir -p "$client_dir/backups"
backup_dir=$(mktemp -d "$client_dir/backups/$(date +%Y%m%d-%H%M%S).XXXXXX")
for file in "$client_dir/env.sh" "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login"; do
    [[ ! -f "$file" ]] || cp -p "$file" "$backup_dir/$(basename "$file")"
done
temporary_env=$(mktemp "$client_dir/.env.XXXXXX")
trap 'rm -- "$temporary_env" 2>/dev/null || true' EXIT
cat > "$temporary_env" <<'RK_VPN_ENVIRONMENT'
# Source this file on 10.10.10.206: . ~/.config/rk-vpn-proxy/env.sh
unset ALL_PROXY all_proxy
export http_proxy=http://172.16.14.233:7897
export https_proxy="$http_proxy"
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$http_proxy"
# Explicit hosts work with older clients that do not support CIDR in no_proxy.
no_proxy=${no_proxy:-${NO_PROXY:-}}
for _vpn_proxy_host in localhost 127.0.0.1 ::1 10.10.10.206 10.10.10.4 10.10.10.29 172.16.14.233 172.16.14.66; do
    case ",$no_proxy," in
        *",$_vpn_proxy_host,"*) ;;
        *) no_proxy="${no_proxy:+$no_proxy,}$_vpn_proxy_host" ;;
    esac
done
unset _vpn_proxy_host
export no_proxy
export NO_PROXY="$no_proxy"
RK_VPN_ENVIRONMENT
chmod 0644 "$temporary_env"
mv -- "$temporary_env" "$client_dir/env.sh"
trap - EXIT
startup_files=(.bashrc .profile)
if [[ -f "$HOME/.bash_profile" ]]; then
    startup_files+=(.bash_profile)
elif [[ -f "$HOME/.bash_login" ]]; then
    startup_files+=(.bash_login)
fi
for startup in "${startup_files[@]}"; do
    target="$HOME/$startup"
    if ! grep -qF '# rk-vpn-proxy environment' "$target" 2>/dev/null; then
        cat >> "$target" <<'RK_VPN_STARTUP'

# rk-vpn-proxy environment
if [ -r "$HOME/.config/rk-vpn-proxy/env.sh" ]; then
    . "$HOME/.config/rk-vpn-proxy/env.sh"
fi
RK_VPN_STARTUP
    fi
done
printf 'Installed proxy: %s\nBackups: %s\n' "$proxy" "$backup_dir"
RK_VPN_INSTALL_BODY
    then
        source "$HOME/.config/rk-vpn-proxy/env.sh" || return
        unset -f _rk_vpn_install
        printf '\nTesting: curl -I https://www.google.com\n'
        curl -I --connect-timeout 5 --max-time 30 https://www.google.com
    else
        unset -f _rk_vpn_install
        echo 'Installation failed; check proxy connectivity and the error above.' >&2
        return 1
    fi
}
_rk_vpn_install
