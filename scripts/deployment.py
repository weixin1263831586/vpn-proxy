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
ROUTING_TABLE = os.environ.get("RK_VPN_ROUTING_TABLE", "240")
POLICY_LOOKUPS = (f"lookup {ROUTING_TABLE}", "lookup main")
PROXY_USER = "rk-vpn-proxy"


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
            ports = [(config["proxy_port"], "rk-vpn-proxy")]
            if config["installer_enabled"]:
                ports.append((config["installer_port"], "rk-vpn-installer"))
            for port, tag in ports:
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


def owned_policy_route(line):
    # Exact routes the firewall script writes into the routing table: the
    # mirrored metric-100 VPN default and the metric-200 unreachable fallback
    # (IPv6 listings add "dev lo" and "pref medium" around the metric).
    if line.startswith("unreachable default") and f" metric 200 " in f" {line} ":
        return True
    return line.startswith("default ") and f" metric 100 " in f" {line} "


def policy_rules(family):
    result = run("ip", f"-{family}", "rule", "show", check=False)
    if result.returncode:
        return []
    rules = []
    for line in result.stdout.splitlines():
        pref, _, rest = line.partition(":")
        if pref.isdigit():
            rules.append((int(pref), rest.strip()))
    return rules


def policy_routes(family):
    result = run("ip", f"-{family}", "route", "show", "table", ROUTING_TABLE, check=False)
    if result.returncode:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def snapshot_policy_routing():
    """Record the policy-routing state so a failed first install restores it."""
    state = {"rules": [], "routes": []}
    uid = run("id", "-u", PROXY_USER, check=False)
    selector = f"uidrange {uid.stdout.strip()}-{uid.stdout.strip()}" if uid.returncode == 0 and uid.stdout.strip() else None
    if selector is None or not shutil.which("ip"):
        return state
    for family in (4, 6):
        for pref, rest in policy_rules(family):
            if selector in rest and any(f" {lookup}" in f" {rest}" for lookup in POLICY_LOOKUPS):
                state["rules"].append({"family": family, "pref": pref, "rule": rest})
        for route in policy_routes(family):
            state["routes"].append({"family": family, "route": route})
    return state


def restore_policy_routing(saved):
    """Remove what this deployment added to policy routing and reinstate the
    snapshot, then verify the result: only project-owned rules may vanish."""
    uid = run("id", "-u", PROXY_USER, check=False)
    selector = f"uidrange {uid.stdout.strip()}-{uid.stdout.strip()}" if uid.returncode == 0 and uid.stdout.strip() else None
    if selector is None or not shutil.which("ip"):
        return
    saved_rules = {(entry["family"], entry["pref"], entry["rule"]) for entry in saved["rules"]}
    saved_routes = {(entry["family"], entry["route"]) for entry in saved["routes"]}
    for family in (4, 6):
        for _ in range(3):
            doomed = [(pref, rest) for pref, rest in policy_rules(family)
                      if selector in rest and any(f" {lookup}" in f" {rest}" for lookup in POLICY_LOOKUPS)
                      and (family, pref, rest) not in saved_rules]
            if not doomed:
                break
            for pref, rest in doomed:
                run("ip", f"-{family}", "rule", "del", "pref", str(pref), *shlex.split(rest), check=False)
        for route in policy_routes(family):
            if owned_policy_route(route) and (family, route) not in saved_routes:
                run("ip", f"-{family}", "route", "del", *shlex.split(route),
                    "table", ROUTING_TABLE, check=False)

    def current_policy():
        rules = {(family, pref, rest) for family in (4, 6)
                 for pref, rest in policy_rules(family) if selector in rest}
        routes = {(family, route) for family in (4, 6) for route in policy_routes(family)}
        return rules, routes

    rules, routes = current_policy()
    for family, pref, rest in sorted(saved_rules - rules):
        run("ip", f"-{family}", "rule", "add", "pref", str(pref), *shlex.split(rest), check=False)
    for family, route in sorted(saved_routes - routes):
        run("ip", f"-{family}", "route", "add", *shlex.split(route),
            "table", ROUTING_TABLE, check=False)
    rules, routes = current_policy()
    ours_rules = {entry for entry in rules
                  if any(f" {lookup}" in f" {entry[2]}" for lookup in POLICY_LOOKUPS)}
    if ours_rules != saved_rules:
        raise RuntimeError(f"policy-routing rules did not return to the snapshot state: "
                           f"leftover={sorted(ours_rules - saved_rules)} missing={sorted(saved_rules - ours_rules)}")
    leftover_routes = {entry for entry in routes
                       if owned_policy_route(entry[1]) and entry not in saved_routes}
    if leftover_routes:
        raise RuntimeError(f"routing table {ROUTING_TABLE} still contains project routes "
                           f"after restore: {sorted(leftover_routes)}")


def snapshot(directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    state = {"files": [], "services": {}, "ufw": [rule for rule in ufw_rules() if owned(rule)],
             "policy_routing": snapshot_policy_routing()}
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
    # Snapshots from older versions have no policy-routing section; they can
    # only predate the feature, so restoring means removing what it adds.
    restore_policy_routing(state.get("policy_routing") or {"rules": [], "routes": []})
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
