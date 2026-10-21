#!/usr/bin/env python3
"""Render deployment and client files from one validated configuration."""
import argparse
from pathlib import Path
import shlex
from configuration import load_config, proxy_url

ROOT = Path(__file__).resolve().parent


def render(config):
    installer = (ROOT / "templates/client-install.sh.in").read_text()
    for key, value in {
        "PROXY_URL": shlex.quote(proxy_url(config)),
        "TEST_URL": shlex.quote(config["test_url"]),
        "NO_PROXY": shlex.quote(",".join(config["no_proxy"])),
    }.items():
        installer = installer.replace("@@" + key + "@@", value)
    squid = (ROOT / "templates/squid.conf.in").read_text()
    for key in ("listen_host", "proxy_port", "health_port", "allowed_clients", "dns_nameservers"):
        value = config[key]
        if isinstance(value, list):
            value = " ".join(value)
        squid = squid.replace("@@" + key.upper() + "@@", str(value))
    runtime = {
        "VPN_INTERFACE": config["vpn_interface"],
        "PROXY_BIND_ADDRESS": config["listen_host"],
        "PROXY_PORT": config["proxy_port"],
        "HEALTH_PORT": config["health_port"],
        "INSTALLER_PORT": config["installer_port"],
        "DNS_CHECK_ADDRESS": config["dns_nameservers"][0],
        "PROXY_TEST_URL": config["test_url"],
    }
    runtime_text = "".join(f"{key}={shlex.quote(str(value))}\n" for key, value in runtime.items())
    return {"client-install.sh": installer, "squid.conf": squid, "runtime.env": runtime_text}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", help="Deployment JSON configuration")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build")
    args = parser.parse_args()
    outputs = render(load_config(args.config))
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name, content in outputs.items():
        destination = args.output_dir / name
        temporary = destination.with_suffix(destination.suffix + ".tmp")
        temporary.write_text(content)
        temporary.replace(destination)


if __name__ == "__main__":
    main()
