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
