#!/usr/bin/env python3
"""Snapshot deployment files/services and reconcile only project-owned UFW rules."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from configuration import load_config

SERVICES = ["rk-vpn-proxy-installer.service", "rk-vpn-proxy-health.timer",
            "rk-vpn-proxy-health.service", "rk-vpn-proxy.service", "rk-vpn-proxy-firewall.service"]
FILES = ["/etc/rk-vpn-proxy", "/usr/local/lib/rk-vpn-proxy",
         "/usr/local/libexec/rk-vpn-proxy-firewall", "/usr/local/libexec/rk-vpn-proxy-health",
         "/etc/logrotate.d/rk-vpn-proxy"] + ["/etc/systemd/system/" + name for name in SERVICES]
TAGS = {"rk-vpn-proxy", "rk-vpn-installer"}


def run(*args, check=True):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise RuntimeError(f"{shlex.join(args)}: {result.stderr.strip() or result.stdout.strip() or result.returncode}")
    return result


def ufw_rules():
    if not shutil.which("ufw"):
        return []
    return [shlex.split(line)[1:] for line in run("ufw", "show", "added").stdout.splitlines()
            if line.startswith("ufw ")]


def owned(rule):
    return "comment" in rule and rule[rule.index("comment") + 1:] in [[tag] for tag in TAGS]


def reconcile_ufw(desired):
    current = ufw_rules()
    for rule in current:
        if owned(rule) and rule not in desired:
            run("ufw", "--force", "delete", *rule)
    for rule in desired:
        # Do not relabel an equivalent rule owned by the administrator.
        selectors = rule[:rule.index("comment")]
        if rule not in current and not any(
                entry[:entry.index("comment")] == selectors if "comment" in entry else entry == selectors
                for entry in current if not owned(entry)):
            run("ufw", *rule)


def sync_ufw(config_path):
    if not shutil.which("ufw"):
        return
    config = load_config(config_path)
    # Remove obsolete project rules even while UFW is disabled.
    active = "Status: active" in run("ufw", "status").stdout
    desired = []
    if active:
        destination = "any" if config["listen_host"] == "0.0.0.0" else config["listen_host"]
        for network in config["allowed_clients"]:
            network = ipaddress.ip_network(network)
            source = str(network.network_address) if network.prefixlen == network.max_prefixlen else str(network)
            for port, tag in ((config["proxy_port"], "rk-vpn-proxy"),
                              (config["installer_port"], "rk-vpn-installer")):
                desired.append(["allow", "from", source, "to", destination, "port", str(port),
                                "proto", "tcp", "comment", tag])
    reconcile_ufw(desired)


def copy_path(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_symlink():
        destination.symlink_to(source.readlink())
    elif source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    else:
        shutil.copy2(source, destination)
    # copy2/copytree preserve modes but not ownership. Snapshots are root-only.
    for original in [source] + (list(source.rglob("*")) if source.is_dir() and not source.is_symlink() else []):
        copied = destination if original == source else destination / original.relative_to(source)
        info = original.lstat()
        if os.geteuid() == 0:
            os.chown(copied, info.st_uid, info.st_gid, follow_symlinks=False)


def remove_path(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def snapshot(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    state = {"files": [], "services": {}, "ufw": [rule for rule in ufw_rules() if owned(rule)]}
    for filename in FILES:
        path = Path(filename)
        present = path.exists() or path.is_symlink()
        state["files"].append([filename, present])
        if present:
            copy_path(path, directory / "files" / filename.lstrip("/"))
    for name in SERVICES + ["squid.service"]:
        state["services"][name] = {
            "enabled": run("systemctl", "is-enabled", name, check=False).stdout.strip(),
            "active": run("systemctl", "is-active", "--quiet", name, check=False).returncode == 0,
        }
    state["nft"] = None
    if shutil.which("nft"):
        table = run("nft", "list", "table", "inet", "rk_vpn_proxy", check=False)
        if table.returncode == 0:
            state["nft"] = table.stdout
    (directory / "state.json").write_text(json.dumps(state, indent=2), encoding="utf-8")


def stop_services():
    for name in SERVICES:
        run("systemctl", "stop", name, check=False)
    if run("systemctl", "is-active", "--quiet", "rk-vpn-proxy.service", check=False).returncode == 0:
        raise RuntimeError("Proxy still active; refusing to remove its protection")


def restore(directory):
    state = json.loads((directory / "state.json").read_text(encoding="utf-8"))
    try:
        restore_state(directory, state)
    except Exception:
        # A failure while restarting an old service must not leave a partially
        # restored proxy running. Keep the snapshot for manual recovery.
        stop_services()
        raise


def restore_state(directory, state):
    stop_services()
    for name in SERVICES:
        run("systemctl", "disable", name, check=False)
    # Restore UFW before services, so a failure leaves the proxy stopped.
    reconcile_ufw(state["ufw"])
    for filename, present in state["files"]:
        path = Path(filename)
        remove_path(path)
        if present:
            copy_path(directory / "files" / filename.lstrip("/"), path)
    if shutil.which("nft"):
        existing = run("nft", "list", "table", "inet", "rk_vpn_proxy", check=False).returncode == 0
        rules = ("delete table inet rk_vpn_proxy\n" if existing else "") + (state["nft"] or "")
        if rules:
            subprocess.run(["nft", "-f", "-"], input=rules, text=True, check=True)
    run("systemctl", "daemon-reload")
    for name, saved in state["services"].items():
        enabled = saved["enabled"]
        # Do not create a new mask for services absent before deployment.
        run("systemctl", "unmask", name)
        if enabled in ("masked", "masked-runtime"):
            args = ["systemctl", "mask"]
            if enabled == "masked-runtime":
                args.append("--runtime")
            run(*args, name)
        elif enabled in ("enabled", "enabled-runtime"):
            args = ["systemctl", "enable"]
            if enabled == "enabled-runtime":
                args.append("--runtime")
            run(*args, name)
        elif enabled not in ("not-found", "", "static"):
            run("systemctl", "disable", name)
        elif enabled in ("not-found", ""):
            run("systemctl", "disable", name, check=False)
    for name in reversed(SERVICES):
        if state["services"][name]["active"]:
            run("systemctl", "start", name)
    if state["services"]["squid.service"]["active"]:
        run("systemctl", "start", "squid.service")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("snapshot", "restore", "ufw-sync", "ufw-clear", "stop"))
    parser.add_argument("path", nargs="?", type=Path)
    args = parser.parse_args()
    if args.action in ("snapshot", "restore", "ufw-sync") and args.path is None:
        parser.error("This action requires a path")
    if args.action == "snapshot":
        snapshot(args.path)
    elif args.action == "restore":
        restore(args.path)
    elif args.action == "ufw-sync":
        sync_ufw(args.path)
    elif args.action == "ufw-clear":
        reconcile_ufw([])
    else:
        stop_services()


if __name__ == "__main__":
    main()
