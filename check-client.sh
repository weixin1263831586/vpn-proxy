#!/bin/bash
# Validate the HTTP CONNECT tunnel and TLS independently from the target's HTTP status.
set -euo pipefail
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Explicit positional/environment overrides retain their exact semantics.
proxy=""
if [[ $# -gt 0 ]]; then
    proxy=$1
elif [[ -v RK_VPN_PROXY_URL && -n "$RK_VPN_PROXY_URL" ]]; then
    proxy=$RK_VPN_PROXY_URL
fi
if [[ -z "$proxy" ]]; then
    # The public listener is ACL-restricted; on the proxy host the
    # designated loopback health listener is the correct test path.
    read -r advertised_proxy local_proxy listen_host < <(
        cd "$source_dir" &&
        python3 -c 'from configuration import load_config, proxy_url; c=load_config(); print(proxy_url(c), "http://127.0.0.1:%d" % c["health_port"], c["listen_host"])'
    )
    proxy=$advertised_proxy
    if command -v ip >/dev/null 2>&1 &&
       ip -4 route get "$listen_host" 2>/dev/null | grep '^local ' >/dev/null; then
        proxy=$local_proxy
        echo "INFO: local server detected; checking loopback health listener $proxy"
    fi
fi
retries=2
if [[ -v RK_VPN_CHECK_RETRIES ]]; then
    case "$RK_VPN_CHECK_RETRIES" in
        1|2|3) retries=$RK_VPN_CHECK_RETRIES ;;
        *) echo "RK_VPN_CHECK_RETRIES must be 1, 2 or 3" >&2; exit 2 ;;
    esac
fi
failed=0
for url in https://www.google.com https://dl.google.com https://storage.googleapis.com https://android.googlesource.com https://github.com; do
    result=''
    curl_exit=0
    for (( attempt=1; attempt<=retries; attempt++ )); do
        if result=$(curl --silent --show-error --noproxy '' --proxy "$proxy" \
            --connect-timeout 5 --max-time 30 --head --output /dev/null \
            --write-out '%{http_connect} %{http_code} %{ssl_verify_result}' "$url"); then
            curl_exit=0
            break
        else
            curl_exit=$?
            if (( attempt < retries )); then
                echo "WARN: $url transport error (curl=$curl_exit), retry $((attempt+1))/$retries" >&2
                sleep 1
            fi
        fi
    done
    if (( curl_exit == 0 )); then
        read -r connect code tls <<<"$result"
        printf '%s CONNECT=%s HTTP=%s TLS_VERIFY=%s\n' "$url" "$connect" "$code" "$tls"
        if [[ "$connect" != 200 || "$tls" != 0 || ! "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
            failed=1
        fi
    else
        printf 'FAIL: %s - curl request failed (exit %s after %s attempts)\n' "$url" "$curl_exit" "$retries" >&2
        failed=1
    fi
done
printf 'Proxy exit IP: '
if ! curl --silent --show-error --fail --noproxy '' --proxy "$proxy" \
    --connect-timeout 5 --max-time 20 https://api.ipify.org; then
    failed=1
fi
printf '\n'
if ((failed != 0)); then
    echo 'FAIL: one or more proxy connectivity checks failed.' >&2
    exit 1
fi
echo 'PASS: all proxy CONNECT/TLS checks completed.'
