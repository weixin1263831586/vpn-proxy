#!/bin/bash
# Validate the HTTP CONNECT tunnel and TLS independently from the target's HTTP status.
set -euo pipefail
proxy=${1:-http://172.16.14.233:7897}
failed=0
for url in https://www.google.com https://dl.google.com https://storage.googleapis.com https://android.googlesource.com https://github.com; do
    if result=$(curl --silent --show-error --noproxy '' --proxy "$proxy" \
        --connect-timeout 5 --max-time 30 --head --output /dev/null \
        --write-out '%{http_connect} %{http_code} %{ssl_verify_result}' "$url"); then
        read -r connect code tls <<<"$result"
        printf '%s CONNECT=%s HTTP=%s TLS_VERIFY=%s\n' "$url" "$connect" "$code" "$tls"
        if [[ "$connect" != 200 || "$tls" != 0 || ! "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
            failed=1
        fi
    else
        printf 'FAIL: %s - curl request failed\n' "$url" >&2
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
