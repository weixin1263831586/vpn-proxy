import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from configuration import client_allowed, load_config
from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parents[1]
SPEC = spec_from_file_location("builder", ROOT / "build-installer.py")
BUILDER = module_from_spec(SPEC)
SPEC.loader.exec_module(BUILDER)


class GeneralDeploymentTests(unittest.TestCase):
    def test_private_networks_and_public_denial(self):
        config = load_config()
        # The shipped default explicitly authorizes only the known compile servers.
        for address in ("10.10.10.206", "172.16.14.66"):
            self.assertTrue(client_allowed(address, config))
        for address in ("10.10.10.207", "172.16.14.67", "192.168.8.20", "203.0.113.8"):
            self.assertFalse(client_allowed(address, config))
        config["allowed_clients"] = ["192.168.8.0/24"]
        self.assertTrue(client_allowed("192.168.8.70", config))
        self.assertFalse(client_allowed("192.168.9.70", config))
        self.assertFalse(client_allowed("10.2.3.4", config))

    def test_all_outputs_follow_alternate_deployment(self):
        config = load_config()
        config.update(listen_host="192.168.50.1", advertise_host="vpn.example.test",
                      proxy_port=8765, health_port=18765, installer_port=8090,
                      vpn_interface="tun8", allowed_clients=["192.168.50.0/24"],
                      installer_enabled=False,
                      no_proxy=["localhost", "127.0.0.1", "::1", "198.18.0.0/15"])
        outputs = BUILDER.render(config)
        self.assertIn("http_port 192.168.50.1:8765", outputs["squid.conf"])
        self.assertIn("acl allowed_clients src 192.168.50.0/24", outputs["squid.conf"])
        self.assertIn("http://vpn.example.test:8765", outputs["client-install.sh"])
        self.assertIn("http://vpn.example.test:8765", outputs["client-install.ps1"])
        self.assertIn("198.18.0.0/15", outputs["client-install.sh"])
        self.assertIn("VPN_INTERFACE=tun8", outputs["runtime.env"])
        self.assertIn("INSTALLER_ENABLED=0", outputs["runtime.env"])
        self.assertIn("ALLOWED_CLIENTS=192.168.50.0/24", outputs["runtime.env"])
        for content in outputs.values():
            self.assertNotIn("10.10.10.206", content)
            self.assertNotIn("172.16.14.233", content)
            self.assertNotIn("@@", content)

    def test_windows_literals_escape_single_quotes(self):
        config = load_config()
        config["test_url"] = "https://example.test/it's-here"
        config["no_proxy"] = ["one'entry.internal"]
        output = BUILDER.render(config)["client-install.ps1"]
        self.assertIn("'https://example.test/it''s-here'", output)
        self.assertIn("'one''entry.internal'", output)

    def test_invalid_config_fails_before_rendering(self):
        for updates in ({"proxy_port": 70000}, {"allowed_clients": ["invalid"]},
                        {"vpn_interface": 'tun0"; reject'}, {"proxy_port": 8089},
                        {"allowed_clients": ["0.0.0.0/0"], "allow_public_clients": True},
                        {"allowed_clients": ["::/0"]}, {"allowed_clients": ["8.8.8.8/32"]},
                        {"allow_public_clients": "true"}, {"installer_enabled": "true"},
                        {"allowed_clients": ["8.8.8.8/32"], "allow_public_clients": True},
                        {"allowed_clients": ["2606:4700:4700::1111/128"], "allow_public_clients": True}):
            config = copy.deepcopy(load_config())
            config.update(updates)
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "config.json"
                path.write_text(json.dumps(config))
                with self.assertRaises(ValueError):
                    load_config(path)

    def test_public_clients_need_explicit_opt_in(self):
        config = load_config()
        config.update(allowed_clients=["203.0.113.7/32"], allow_public_clients=True)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config))
            self.assertEqual(load_config(path)["allowed_clients"], ["203.0.113.7/32"])

    def test_config_rejects_wrong_types_and_invalid_test_urls(self):
        for updates in ({"no_proxy": "localhost"}, {"allowed_clients": {}},
                        {"dns_nameservers": [134744072]}, {"listen_host": 123},
                        {"proxy_port": None}, {"test_url": "https://example.org:bad"},
                        {"test_url": "https://example.org:0"},
                        {"test_url": "https://example.org/\npath"},
                        {"test_url": "https://user:secret@example.org"}):
            with self.subTest(updates=updates), tempfile.TemporaryDirectory() as directory:
                config = load_config()
                config.update(updates)
                path = Path(directory) / "config.json"
                path.write_text(json.dumps(config))
                with self.assertRaises(ValueError):
                    load_config(path)

    def test_duplicate_client_networks_are_normalized(self):
        with tempfile.TemporaryDirectory() as directory:
            config = load_config()
            config["allowed_clients"] = ["10.1.2.3/24", "10.1.2.0/24", "10.2.0.1"]
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config))
            self.assertEqual(load_config(path)["allowed_clients"], ["10.1.2.0/24", "10.2.0.1/32"])

    def test_installer_entry_defaults_to_disabled(self):
        config = load_config()
        self.assertTrue(config["installer_enabled"])  # this repository explicitly opts in
        del config["installer_enabled"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text(json.dumps(config))
            loaded = load_config(path)
            self.assertFalse(loaded["installer_enabled"])
            self.assertIn("INSTALLER_ENABLED=0", BUILDER.render(loaded)["runtime.env"])

    def test_installer_arbitrary_user_home_override_and_idempotency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            curl = root / "bin/curl"
            curl.write_text('#!/bin/bash\ncase " $* " in *" --write-out "*) printf "200 200 0";; *) printf "HTTP/2 200\\n";; esac\n')
            curl.chmod(0o755)
            installer = root / "install.sh"
            installer.write_text(BUILDER.render(load_config())["client-install.sh"])
            for username in ("alice", "bob"):
                home = root / username
                home.mkdir()
                (home / ".bash_profile").write_text("# existing login settings\n")
                env = dict(os.environ, HOME=str(home), PATH=f"{root / 'bin'}:{os.environ['PATH']}",
                           no_proxy="existing.internal", RK_VPN_NO_PROXY="new.internal")
                result = subprocess.run(
                    ["bash", "-c", 'source "$1" "$2" && source "$1" "$2" && '
                     'test "$http_proxy" = "$2" && test "$https_proxy" = "$2" && '
                     'test "$no_proxy" = "existing.internal,localhost,127.0.0.1,::1,other.example,new.internal"',
                     "test", str(installer), "http://other.example:8765"],
                    env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for filename in (".bashrc", ".profile", ".bash_profile"):
                    self.assertEqual((home / filename).read_text().count("# rk-vpn-proxy environment"), 1)
                self.assertEqual(len(list((home / ".config/rk-vpn-proxy/backups").iterdir())), 2)
                client_dir = home / ".config/rk-vpn-proxy"
                self.assertEqual(client_dir.stat().st_mode & 0o777, 0o700)
                self.assertEqual((client_dir / "env.sh").stat().st_mode & 0o777, 0o600)
                # A POSIX login shell must not evaluate the Bash environment body.
                posix = subprocess.run(["dash", "-c", '. "$HOME/.profile"'],
                                       env=env, capture_output=True, text=True)
                self.assertEqual(posix.returncode, 0, posix.stderr)
                self.assertEqual(posix.stderr, "")

    def test_installer_rejects_failed_tls_before_changing_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            home = root / "home"
            home.mkdir()
            startup = home / ".bashrc"
            startup.write_text("# original settings\n")
            curl = root / "bin/curl"
            # curl may exit successfully with insecure verification enabled
            # in the user's curlrc; the certificate result must still be checked.
            curl.write_text('#!/bin/bash\nprintf "200 200 60"\n')
            curl.chmod(0o755)
            installer = root / "install.sh"
            installer.write_text(BUILDER.render(load_config())["client-install.sh"])
            env = dict(os.environ, HOME=str(home), PATH=f"{root / 'bin'}:{os.environ['PATH']}")
            result = subprocess.run(["bash", str(installer)], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("HTTPS proxy check failed", result.stderr)
            self.assertEqual(startup.read_text(), "# original settings\n")
            self.assertFalse((home / ".config/rk-vpn-proxy").exists())


if __name__ == "__main__":
    unittest.main()
