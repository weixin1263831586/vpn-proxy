"""Unit tests for individual Squid ACL enables/disables."""
import importlib.util
import ipaddress
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("client_control", ROOT / "scripts/client_control.py")
CC = importlib.util.module_from_spec(spec)
spec.loader.exec_module(CC)

SAMPLE = """acl allowed_clients src 172.16.0.0/16
# rk-vpn-client-control BEGIN
acl disabled_clients src 0.0.0.0/32
# rk-vpn-client-control END
http_access deny disabled_clients
http_access allow allowed_clients
"""


class ClientControl(unittest.TestCase):
    def test_exact_ip_and_allowlist(self):
        self.assertEqual(CC.ip_value("172.16.14.66"), "172.16.14.66")
        for bad in ("127.0.0.1", "172.16.0.0/16", "1.2.3.4; rm -rf /",
                    "0.0.0.0", "172.16.014.66"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                CC.ip_value(bad)
        self.assertTrue(CC.allowed("172.16.14.66", {"allowed_clients": ["172.16.0.0/16"]}))
        self.assertFalse(CC.allowed("10.10.10.10", {"allowed_clients": ["172.16.0.0/16"]}))

    def test_denies_precede_allow_with_correct_ip(self):
        applied = CC.make_acl(SAMPLE, {"172.16.14.66", "172.16.14.68"})
        self.assertIn("acl disabled_clients src 0.0.0.0/32 172.16.14.66 172.16.14.68", applied)
        self.assertLess(applied.index("http_access deny disabled_clients"),
                        applied.index("http_access allow allowed_clients"))
        self.assertEqual(CC.make_acl(applied, set()), SAMPLE)
        with self.assertRaises(ValueError):
            CC.make_acl("acl allowed_clients src 172.16.0.0/16", set())

    def test_persisted_disable_can_be_enabled_after_disconnect(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / "config.json"
            squid = home / "squid.conf"
            disabled = home / "disabled_clients.json"
            lock = home / "lock"
            config.write_text(json.dumps({"allowed_clients": ["172.16.0.0/16"]}))
            squid.write_text(SAMPLE)
            with patch.object(CC, "CONFIGFILE", config), patch.object(CC, "SQUIDFILE", squid), \
                    patch.object(CC, "STATEFILE", disabled), patch.object(CC, "DEPLOY_LOCK", lock), \
                    patch.object(CC, "validate_and_reload") as reload:
                result = CC.set_access("disable", "172.16.14.66")
                self.assertTrue(result["disabled"])
                self.assertIn("172.16.14.66", squid.read_text())
                self.assertEqual(CC.read_disabled(), {"172.16.14.66"})
                self.assertFalse(CC.set_access("enable", "172.16.14.66")["disabled"])
                self.assertEqual(CC.read_disabled(), set())
                self.assertEqual(squid.read_text(), SAMPLE)
                self.assertEqual(reload.call_count, 2)

    def test_reload_failure_rolls_back_acl_and_state(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            config = home / "config.json"
            squid = home / "squid.conf"
            disabled = home / "disabled_clients.json"
            lock = home / "lock"
            config.write_text(json.dumps({"allowed_clients": ["10.0.0.0/8"]}))
            squid.write_text(SAMPLE)
            with patch.object(CC, "CONFIGFILE", config), patch.object(CC, "SQUIDFILE", squid), \
                    patch.object(CC, "STATEFILE", disabled), patch.object(CC, "DEPLOY_LOCK", lock), \
                    patch.object(CC, "validate_and_reload", side_effect=[RuntimeError("fail"), None]):
                with self.assertRaises(RuntimeError):
                    CC.set_access("disable", "10.10.10.10")
                self.assertEqual(squid.read_text(), SAMPLE)
                self.assertFalse(disabled.exists())

    def test_state_rejects_duplicates_invalid_addresses_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "clients.json"
            path.write_text('{"version":1,"disabled_clients":["10.0.0.2","10.0.0.2"]}')
            with self.assertRaises(ValueError):
                CC.read_disabled(path)
            path.write_text('{"version":1,"disabled_clients":["not-an-ip"]}')
            with self.assertRaises(ValueError):
                CC.read_disabled(path)
            link = Path(directory) / "alias.json"
            link.symlink_to(path)
            with self.assertRaises(ValueError):
                CC.read_disabled(link)


if __name__ == "__main__":
    unittest.main()
