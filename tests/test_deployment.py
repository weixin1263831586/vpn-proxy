"""Exercise deployment recovery with filesystem snapshots and simulated system tools."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import os
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = spec_from_file_location("deployment", ROOT / "scripts/deployment.py")
DEPLOY = module_from_spec(SPEC)
SPEC.loader.exec_module(DEPLOY)


class DeploymentRecovery(unittest.TestCase):
    def test_snapshot_restores_partial_deployment_and_leaves_unrelated_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config"
            config.mkdir()
            (config / "runtime.env").write_text("original")
            (config / "runtime.env").chmod(0o640)
            (config / "link").symlink_to("runtime.env")
            new_file = root / "previously-absent"
            saved_rule = ["allow", "from", "192.168.1.0/24", "to", "any", "port", "7897",
                          "proto", "tcp", "comment", "rk-vpn-proxy"]
            changed_rule = saved_rule.copy()
            changed_rule[2] = "192.168.2.0/24"
            admin_rule = ["allow", "22/tcp", "comment", "administrator"]
            rules = [saved_rule, admin_rule]
            active = {name: name in ("rk-vpn-proxy.service", "rk-vpn-proxy-health.timer")
                      for name in DEPLOY.SERVICES + ["squid.service"]}
            enabled = {name: "disabled" for name in active}
            enabled["squid.service"] = "masked"
            calls = []
            fail_restart = False

            def fake_run(*args, check=True):
                calls.append(args)
                code, output = 0, ""
                if args[0] == "systemctl":
                    action, name = args[1], args[-1]
                    if action == "is-enabled":
                        output = enabled[name]
                    elif action == "is-active":
                        code = 0 if active[name] else 3
                    elif action in ("start", "stop"):
                        if fail_restart and action == "start" and name == "rk-vpn-proxy-health.timer":
                            raise RuntimeError("timer restart failed")
                        active[name] = action == "start"
                    elif action in ("enable", "disable", "mask", "unmask"):
                        enabled[name] = {"enable": "enabled", "disable": "disabled",
                                         "mask": "masked", "unmask": "disabled"}[action]
                elif args[0] == "ufw":
                    if args[1:3] == ("--force", "delete"):
                        rules.remove(list(args[3:]))
                    else:
                        rules.append(list(args[1:]))
                elif args[0] == "nft":
                    output = "table inet rk_vpn_proxy {}\n"
                return subprocess.CompletedProcess(args, code, output, "")

            with patch.object(DEPLOY, "FILES", [str(config), str(new_file)]), \
                 patch.object(DEPLOY, "run", side_effect=fake_run), \
                 patch.object(DEPLOY, "ufw_rules", side_effect=lambda: rules.copy()), \
                 patch.object(DEPLOY.shutil, "which", return_value="tool"), \
                 patch.object(DEPLOY.subprocess, "run") as nft_load:
                snapshot = root / "snapshot"
                DEPLOY.snapshot(snapshot)
                (config / "runtime.env").write_text("partially deployed")
                new_file.write_text("new")
                rules[:] = [changed_rule, admin_rule]
                enabled["rk-vpn-proxy.service"] = "enabled"
                DEPLOY.restore(snapshot)
                self.assertEqual((config / "runtime.env").read_text(), "original")
                self.assertEqual((config / "runtime.env").stat().st_mode & 0o777, 0o640)
                self.assertEqual((config / "link").readlink(), Path("runtime.env"))
                self.assertFalse(new_file.exists())
                self.assertTrue(active["rk-vpn-proxy.service"])
                self.assertEqual(enabled["rk-vpn-proxy.service"], "disabled")
                self.assertEqual(enabled["squid.service"], "masked")
                self.assertEqual(rules, [admin_rule, saved_rule])
                self.assertIn("delete table inet rk_vpn_proxy", nft_load.call_args.kwargs["input"])
                stop = calls.index(("systemctl", "stop", "rk-vpn-proxy.service"))
                restore_rule = calls.index(("ufw", *saved_rule))
                self.assertLess(stop, restore_rule)
                # Failure after the proxy has restarted must stop it again.
                fail_restart = True
                with self.assertRaisesRegex(RuntimeError, "timer restart failed"):
                    DEPLOY.restore(snapshot)
                self.assertFalse(active["rk-vpn-proxy.service"])
                self.assertTrue((snapshot / "state.json").exists())

    def test_ufw_failure_aborts_recovery_with_proxy_stopped(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "state.json").write_text('{"ufw": [], "files": [], "services": {}, "nft": null}')
            with patch.object(DEPLOY, "stop_services") as stop, \
                 patch.object(DEPLOY, "run"), \
                 patch.object(DEPLOY, "reconcile_ufw", side_effect=RuntimeError("ufw failed")):
                with self.assertRaisesRegex(RuntimeError, "ufw failed"):
                    DEPLOY.restore(root)
                self.assertEqual(stop.call_count, 2)

    def test_existing_admin_ufw_rule_is_never_claimed(self):
        rule = ["allow", "from", "192.168.5.0/24", "to", "any", "port", "7897", "proto", "tcp"]
        with patch.object(DEPLOY, "ufw_rules", return_value=[rule + ["comment", "administrator"]]), \
             patch.object(DEPLOY, "run") as command:
            DEPLOY.reconcile_ufw([rule + ["comment", "rk-vpn-proxy"]])
            command.assert_not_called()

    def test_cannot_remove_firewall_if_proxy_stop_fails(self):
        def fake_run(*args, **kwargs):
            return subprocess.CompletedProcess(args, 0, "", "")
        with patch.object(DEPLOY, "run", side_effect=fake_run):
            with self.assertRaisesRegex(RuntimeError, "Proxy still active"):
                DEPLOY.stop_services()


class PolicyRoutingRecovery(unittest.TestCase):
    @staticmethod
    def fake_run_factory(state, fail_del=False):
        def fake_run(*args, check=True):
            code, output = 0, ""
            if args[0] == "id":
                output = "149"
            elif args[0] == "ip":
                family = args[1].lstrip("-")
                words = list(args[2:])
                if words[:2] == ["rule", "show"]:
                    output = "\n".join(state[f"rules{family}"]) + ("\n" if state[f"rules{family}"] else "")
                elif words[:2] == ["rule", "add"]:
                    state[f"rules{family}"].append(f"{words[3]}: {' '.join(words[4:])}")
                elif words[:2] == ["rule", "del"]:
                    pref, rest = words[3], " ".join(words[4:])
                    new = [line for line in state[f"rules{family}"]
                           if not (line.split(":", 1)[0] == pref and
                                   (not rest or line.split(":", 1)[1].strip() == rest))]
                    if fail_del and len(new) != len(state[f"rules{family}"]):
                        code = 2
                    else:
                        state[f"rules{family}"] = new
                elif words[:2] == ["route", "show"]:
                    output = "\n".join(state[f"routes{family}"]) + ("\n" if state[f"routes{family}"] else "")
                elif words[:2] == ["route", "add"]:
                    state[f"routes{family}"].append(" ".join(words[2:-2]))
                elif words[:2] == ["route", "del"]:
                    line = " ".join(words[2:-2])
                    state[f"routes{family}"] = [entry for entry in state[f"routes{family}"] if entry != line]
            return subprocess.CompletedProcess(args, code, output, "")
        return fake_run

    def apply_patches(self, state, fail_del=False):
        run_patch = patch.object(DEPLOY, "run", side_effect=self.fake_run_factory(state, fail_del))
        which_patch = patch.object(DEPLOY.shutil, "which", return_value="ip")
        return run_patch, which_patch

    def test_restore_purges_owned_rules_and_keeps_foreign_state(self):
        state = {
            "rules4": ["90: uidrange 149-149 to 10.0.0.0/8 lookup main",
                       "95: from all lookup 50",
                       "100: uidrange 149-149 lookup 240"],
            "routes4": ["default via 203.0.113.1 dev ppp0 metric 100",
                        "unreachable default metric 200",
                        "10.99.0.0/16 via 192.0.2.1"],
            "rules6": ["91: uidrange 149-149 lookup 240"],
            "routes6": ["unreachable default dev lo metric 200 pref medium"],
        }
        run, which = self.apply_patches(state)
        with run, which:
            snapshotted = DEPLOY.snapshot_policy_routing()
            self.assertEqual(snapshotted["rules"], [
                {"family": 4, "pref": 90, "rule": "uidrange 149-149 to 10.0.0.0/8 lookup main"},
                {"family": 4, "pref": 100, "rule": "uidrange 149-149 lookup 240"},
                {"family": 6, "pref": 91, "rule": "uidrange 149-149 lookup 240"}])
            self.assertEqual(snapshotted["routes"], [
                {"family": 4, "route": "default via 203.0.113.1 dev ppp0 metric 100"},
                {"family": 4, "route": "unreachable default metric 200"},
                {"family": 4, "route": "10.99.0.0/16 via 192.0.2.1"},
                {"family": 6, "route": "unreachable default dev lo metric 200 pref medium"}])
            DEPLOY.restore_policy_routing({"rules": [], "routes": []})
        self.assertEqual(state["rules4"], ["95: from all lookup 50"])
        self.assertEqual(state["routes4"], ["10.99.0.0/16 via 192.0.2.1"])
        self.assertEqual(state["rules6"], [])
        self.assertEqual(state["routes6"], [])

    def test_restore_reinstates_snapshotted_policy_routing(self):
        state = {"rules4": [], "routes4": [], "rules6": [], "routes6": []}
        saved = {"rules": [{"family": 4, "pref": 88, "rule": "uidrange 149-149 to 10.0.0.0/8 lookup main"}],
                 "routes": [{"family": 6, "route": "unreachable default metric 200"}]}
        run, which = self.apply_patches(state)
        with run, which:
            DEPLOY.restore_policy_routing(saved)
        self.assertEqual(state["rules4"], ["88: uidrange 149-149 to 10.0.0.0/8 lookup main"])
        self.assertEqual(state["routes6"], ["unreachable default metric 200"])

    def test_restore_fails_loudly_when_owned_rules_survive(self):
        state = {"rules4": ["100: uidrange 149-149 lookup 240"], "routes4": [],
                 "rules6": [], "routes6": []}
        run, which = self.apply_patches(state, fail_del=True)
        with run, which:
            with self.assertRaisesRegex(RuntimeError, "did not return to the snapshot state"):
                DEPLOY.restore_policy_routing({"rules": [], "routes": []})

    def test_similar_uid_ranges_and_table_numbers_are_not_owned(self):
        foreign = ["80: from all uidrange 149-1490 lookup main",
                   "81: from all uidrange 149-149 lookup 2400"]
        state = {"rules4": foreign.copy(), "routes4": [], "rules6": [], "routes6": []}
        run, which = self.apply_patches(state)
        with run, which:
            self.assertEqual(DEPLOY.snapshot_policy_routing()["rules"], [])
            DEPLOY.restore_policy_routing({"rules": [], "routes": []})
        self.assertEqual(state["rules4"], foreign)

    def test_restore_fails_when_snapshot_route_cannot_be_added(self):
        state = {"rules4": [], "routes4": [], "rules6": [], "routes6": []}
        saved = {"rules": [], "routes": [{"family": 4, "route": "unreachable default metric 200"}]}
        command = self.fake_run_factory(state)

        def fail_add(*args, **kwargs):
            if args[:4] == ("ip", "-4", "route", "add"):
                return subprocess.CompletedProcess(args, 2, "", "injected failure")
            return command(*args, **kwargs)

        with patch.object(DEPLOY, "run", side_effect=fail_add), \
             patch.object(DEPLOY.shutil, "which", return_value="ip"):
            with self.assertRaisesRegex(RuntimeError, "missing snapshot routes"):
                DEPLOY.restore_policy_routing(saved)


class HealthState(unittest.TestCase):
    def test_health_separates_firewall_vpn_and_proxy_and_checks_marker_freshness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            identity = root / "bin/id"
            identity.write_text('#!/bin/bash\necho 149\n')
            identity.chmod(0o755)
            ip = root / "bin/ip"
            ip.write_text('#!/bin/bash\nif [[ "$*" == *address* ]]; then\n'
                          '  [[ ${TEST_VPN_DOWN:-0} == 0 ]] && echo "inet 203.0.113.2/24"\n'
                          'elif [[ "$*" == *"uid 149"* ]]; then\n'
                          '  echo "8.8.8.8 dev tun-test src 203.0.113.2"\n'
                          'else echo "8.8.8.8 dev eth0 src 192.0.2.2"; fi\n')
            curl = root / "bin/curl"
            curl.write_text('#!/bin/bash\ntouch "$RK_VPN_STATE_DIR/probed"\n'
                            'if [[ ${TEST_LOSE_FIREWALL:-0} == 1 ]]; then rm -f "$RK_VPN_FIREWALL_STATE/enforced"; fi\n'
                            'echo 203.0.113.9\n')
            ip.chmod(0o755)
            curl.chmod(0o755)
            runtime = root / "runtime.env"
            runtime.write_text('VPN_INTERFACE=tun-test\nDNS_CHECK_ADDRESS=8.8.8.8\nHEALTH_PORT=17897\n')
            for label, age, overrides, expected in (
                    ("missing", None, {}, (1, 0, 0)),
                    ("stale", 10, {}, (1, 0, 0)),
                    ("up", 0, {}, (1, 1, 1)),
                    ("vpn-down", 0, {"TEST_VPN_DOWN": "1"}, (0, 0, 1)),
                    ("lost-during-probe", 0, {"TEST_LOSE_FIREWALL": "1"}, (1, 1, 0))):
                with self.subTest(label=label):
                    state = root / label
                    state.mkdir()
                    firewall = state / "firewall"
                    firewall.mkdir()
                    if age is not None:
                        (firewall / "enforced").write_text(str(int(time.time()) - age))
                    environment = dict(os.environ, PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                                       RK_VPN_RUNTIME=str(runtime), RK_VPN_STATE_DIR=str(state),
                                       RK_VPN_FIREWALL_STATE=str(firewall), **overrides)
                    result = subprocess.run(["bash", str(ROOT / "scripts/health.sh")],
                                            env=environment, text=True, capture_output=True)
                    vpn, proxy, enforced = expected
                    self.assertEqual(result.returncode, 0 if expected == (1, 1, 1) else 1,
                                     result.stdout + result.stderr)
                    status = (state / "status").read_text()
                    for key, value in (("VPN_UP", vpn), ("PROXY_REACHABLE", proxy),
                                       ("FIREWALL_ENFORCED", enforced)):
                        self.assertIn(f"{key}={value}", status)
                    self.assertEqual((state / "probed").exists(), bool(proxy))


if __name__ == "__main__":
    unittest.main()
