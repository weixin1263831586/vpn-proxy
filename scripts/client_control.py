#!/usr/bin/env python3
"""Persist per-client Squid deny ACLs without restarting the proxy.

Only root can change the installed config. The client-address argument must
be an exact configured, non-loopback IP: no ranges, shell metacharacters,
unit names or arbitrary commands are accepted.
"""
from __future__ import annotations

import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

CONFIGFILE = Path("/etc/rk-vpn-proxy/config.json")
SQUIDFILE = Path("/etc/rk-vpn-proxy/squid.conf")
STATEFILE = Path("/etc/rk-vpn-proxy/disabled_clients.json")
DEPLOY_LOCK = Path("/run/lock/rk-vpn-proxy-deploy.lock")
SQUID = "/usr/sbin/squid"
SYSTEMCTL = "/usr/bin/systemctl"
SERVICE = "rk-vpn-proxy.service"
BEGIN = "# rk-vpn-client-control BEGIN"
END = "# rk-vpn-client-control END"
DUMMY = "0.0.0.0/32"
MAX_CLIENTS = 256


def ip_value(value: str) -> str:
    address = ipaddress.ip_address(value)
    if value != str(address) or address.is_loopback or address.is_unspecified:
        raise ValueError("An exact non-loopback client IP is required")
    return str(address)


def allowed(ip: str, config: dict) -> bool:
    address = ipaddress.ip_address(ip)
    networks = config.get("allowed_clients")
    if not isinstance(networks, list):
        return False
    return any(address in ipaddress.ip_network(net, strict=False)
               for net in networks)


def read_disabled(path: Path | None = None) -> set[str]:
    # Resolve the installed path at call time; also permits an isolated
    # temporary directory in regression tests and future relocations.
    path = path if path is not None else STATEFILE
    if not path.exists():
        return set()
    if path.is_symlink() or path.stat().st_size > 32768:
        raise ValueError("Invalid disabled-client state file")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if (not isinstance(payload, dict) or payload.get("version") != 1
            or not isinstance(payload.get("disabled_clients"), list)):
        raise ValueError("Invalid disabled-client state format")
    entries = payload["disabled_clients"]
    if len(entries) > MAX_CLIENTS or len(set(map(str, entries))) != len(entries):
        raise ValueError("Invalid disabled-client state size or duplicates")
    if not all(isinstance(ip, str) for ip in entries):
        raise ValueError("Disabled-client entries must be IP addresses")
    result = {ip_value(ip) for ip in entries}
    return result


def make_acl(config_text: str, disabled: set[str]) -> str:
    if len(disabled) > MAX_CLIENTS:
        raise ValueError("Too many disabled client addresses")
    if config_text.count(BEGIN) != 1 or config_text.count(END) != 1:
        raise ValueError("Installed Squid config lacks a unique managed ACL block")
    pattern = re.compile(re.escape(BEGIN) + r"\n[\s\S]*?\n" + re.escape(END))
    addresses = sorted(disabled, key=lambda ip: (ipaddress.ip_address(ip).version,
                                                  int(ipaddress.ip_address(ip))))
    rule = "acl disabled_clients src " + " ".join([DUMMY, *addresses])
    next_text, replacements = pattern.subn(BEGIN + "\n" + rule + "\n" + END,
                                            config_text)
    if replacements != 1 or "http_access deny disabled_clients" not in next_text:
        raise ValueError("Missing deny-before-allow Squid ACL rule")
    return next_text


def atomic_write(path: Path, text: str, mode: int = 0o644) -> None:
    if path.is_symlink():
        raise ValueError("Refusing to replace a symlink")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8",
                                         dir=path.parent, prefix=".rk-client-",
                                         delete=False) as handle:
            temporary = Path(handle.name)
            os.fchmod(handle.fileno(), mode)
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def run(*argv: str) -> None:
    subprocess.run(argv, check=True, capture_output=True, text=True, timeout=20)


def validate_and_reload() -> None:
    run(SQUID, "-n", "rkvpnproxy", "-k", "parse", "-f", str(SQUIDFILE))
    # When the proxy is stopped, keep the policy on disk for its next start.
    result = subprocess.run([SYSTEMCTL, "is-active", "--quiet", SERVICE],
                            capture_output=True, check=False, timeout=4)
    if result.returncode == 0:
        run(SYSTEMCTL, "reload", SERVICE)


def set_access(action: str, client: str) -> dict:
    if action not in {"enable", "disable"}:
        raise ValueError("Unsupported client access action")
    client = ip_value(client)
    if not CONFIGFILE.is_file() or not SQUIDFILE.is_file():
        raise ValueError("vpn-proxy must be installed before client control")
    config = json.loads(CONFIGFILE.read_text(encoding="utf-8"))
    if not isinstance(config, dict) or not allowed(client, config):
        raise ValueError("Client does not belong to an authorized network")

    with DEPLOY_LOCK.open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        old = read_disabled()
        updated = set(old)
        if action == "disable":
            updated.add(client)
        else:
            updated.discard(client)
        if len(updated) > MAX_CLIENTS:
            raise ValueError("Too many disabled client addresses")
        current = SQUIDFILE.read_text(encoding="utf-8")
        target = make_acl(current, updated)
        if updated == old and target == current:
            return {"action": action, "client": client,
                    "disabled": client in updated, "changed": False}

        atomic_write(SQUIDFILE, target)
        try:
            validate_and_reload()
            atomic_write(STATEFILE, json.dumps({
                "version": 1, "disabled_clients": sorted(updated)
            }, ensure_ascii=True, indent=2) + "\n", mode=0o644)
        except Exception:
            atomic_write(SQUIDFILE, current)
            try:
                validate_and_reload()
            except Exception:
                # Fail clearly: never report a successful client toggle.
                print("WARNING: Squid rollback reload also failed", file=sys.stderr)
            raise
        return {"action": action, "client": client,
                "disabled": client in updated, "changed": True}


def sync_from_state() -> None:
    if not SQUIDFILE.is_file():
        raise ValueError("Missing installed squid.conf")
    current = SQUIDFILE.read_text(encoding="utf-8")
    updated = make_acl(current, read_disabled())
    if updated != current:
        atomic_write(SQUIDFILE, updated)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("disable", "enable", "sync"))
    parser.add_argument("client", nargs="?")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Root privileges are required")
    if args.action == "sync":
        if args.client is not None:
            parser.error("sync does not accept a client address")
        sync_from_state()
    else:
        if args.client is None:
            parser.error("Client IP is required")
        result = set_access(args.action, args.client)
        print(json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        # Do not expose privileged command stderr to a remote web caller.
        print(f"Client control failed: {type(exc).__name__}", file=sys.stderr)
        raise SystemExit(1)
