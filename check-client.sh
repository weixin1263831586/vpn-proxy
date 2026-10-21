#!/bin/bash
set -euo pipefail
proxy=${1:-http://172.16.14.233:7897}
for url in https://www.google.com https://dl.google.com https://storage.googleapis.com https://android.googlesource.com https://github.com; do
    curl --silent --show-error --noproxy '' --proxy "$proxy" \
        --connect-timeout 5 --max-time 30 --head --output /dev/null \
        --write-out "$url CONNECT=%{http_connect} HTTP=%{http_code} TLS_VERIFY=%{ssl_verify_result}\n" "$url"
done
printf 'Proxy exit IP: '
curl --silent --show-error --fail --noproxy '' --proxy "$proxy" \
    --connect-timeout 5 --max-time 20 https://api.ipify.org
printf '\n'
