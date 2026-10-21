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
        for address in ("10.2.3.4", "172.20.8.9", "192.168.8.20"):
            self.assertTrue(client_allowed(address, config))
        self.assertFalse(client_allowed("203.0.113.8", config))
        config["allowed_clients"] = ["192.168.8.0/24"]
        self.assertTrue(client_allowed("192.168.8.70", config))
        self.assertFalse(client_allowed("192.168.9.70", config))
        self.assertFalse(client_allowed("10.2.3.4", config))

    def test_all_outputs_follow_alternate_deployment(self):
        config = load_config()
        config.update(listen_host="192.168.50.1", advertise_host="vpn.example.test",
                      proxy_port=8765, health_port=18765, installer_port=8090,
                      vpn_interface="tun8", allowed_clients=["192.168.50.0/24"])
        outputs = BUILDER.render(config)
        self.assertIn("http_port 192.168.50.1:8765", outputs["squid.conf"])
        self.assertIn("acl allowed_clients src 192.168.50.0/24", outputs["squid.conf"])
        self.assertIn("http://vpn.example.test:8765", outputs["client-install.sh"])
        self.assertIn("VPN_INTERFACE=tun8", outputs["runtime.env"])
        for content in outputs.values():
            self.assertNotIn("10.10.10.206", content)
            self.assertNotIn("172.16.14.233", content)
            self.assertNotIn("@@", content)

    def test_invalid_config_fails_before_rendering(self):
        for updates in ({"proxy_port": 70000}, {"allowed_clients": ["invalid"]},
                        {"vpn_interface": 'tun0"; reject'}, {"proxy_port": 8089}):
            config = copy.deepcopy(load_config())
            config.update(updates)
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "config.json"
                path.write_text(json.dumps(config))
                with self.assertRaises(ValueError):
                    load_config(path)

    def test_installer_arbitrary_user_home_override_and_idempotency(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bin").mkdir()
            curl = root / "bin/curl"
            curl.write_text('#!/bin/bash\ncase " $* " in *" --write-out "*) printf "200 200";; *) printf "HTTP/2 200\\n";; esac\n')
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


if __name__ == "__main__":
    unittest.main()
