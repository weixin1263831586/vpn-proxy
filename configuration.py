"""Shared, validated deployment configuration for the proxy and downloader."""
import ipaddress
import json
import os
from pathlib import Path
import re
from urllib.parse import urlsplit


def load_config(path=None):
    path = path or os.environ.get("RK_VPN_PROXY_CONFIG") or Path(__file__).with_name("config.json")
    config = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    ipaddress.IPv4Address(config["listen_host"])
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", config["advertise_host"]):
        raise ValueError("advertise_host must be an IPv4 address or hostname")
    for key in ("proxy_port", "health_port", "installer_port"):
        if type(config[key]) is not int or not 1 <= config[key] <= 65535:
            raise ValueError(f"Invalid {key}")
    if len({config[key] for key in ("proxy_port", "health_port", "installer_port")}) != 3:
        raise ValueError("Proxy, health and installer ports must differ")
    if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", config["vpn_interface"]):
        raise ValueError("Invalid VPN interface name")
    networks = [ipaddress.ip_network(value, strict=False) for value in config["allowed_clients"]]
    if not networks:
        raise ValueError("Configure at least one allowed client network")
    if type(config.get("allow_public_clients", False)) is not bool:
        raise ValueError("allow_public_clients must be a boolean")
    private_ranges = [ipaddress.ip_network(value) for value in (
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "fc00::/7", "::1/128")]
    for network in networks:
        if network.prefixlen == 0:
            raise ValueError("Unrestricted client networks are forbidden")
        if not config.get("allow_public_clients", False) and not any(
                network.version == private.version and network.subnet_of(private)
                for private in private_ranges):
            raise ValueError("Public client networks require allow_public_clients=true")
    config["allowed_clients"] = [str(network) for network in networks]
    for address in config["dns_nameservers"]:
        ipaddress.IPv4Address(address)
    if not config["dns_nameservers"]:
        raise ValueError("Configure at least one DNS nameserver")
    url = urlsplit(config["test_url"])
    if url.scheme != "https" or not url.hostname:
        raise ValueError("test_url must be an HTTPS URL")
    if any(not isinstance(host, str) or any(char.isspace() for char in host) or "," in host
           for host in config["no_proxy"]):
        raise ValueError("no_proxy must contain individual hosts or networks")
    return config


def proxy_url(config):
    return f"http://{config['advertise_host']}:{config['proxy_port']}"


def client_allowed(address, config):
    address = ipaddress.ip_address(address)
    return address.is_loopback or any(
        address in ipaddress.ip_network(network) for network in config["allowed_clients"]
    )
