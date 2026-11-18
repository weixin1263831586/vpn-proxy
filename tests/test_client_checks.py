import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ClientConnectivityChecks(unittest.TestCase):
    def test_tunnel_tls_and_origin_status_are_distinct(self):
        cases = (
            ("origin HTTP 403", "200 403 0", "0", "0", 0),
            ("TLS verification failed", "200 200 60", "0", "0", 1),
            ("CONNECT denied", "403 200 0", "0", "0", 1),
            ("no HTTP response", "200 000 0", "0", "0", 1),
            ("curl transport failure", "200 200 0", "28", "0", 1),
            ("exit IP probe failure", "200 200 0", "0", "7", 1),
        )
        for label, metrics, curl_exit, ip_exit, expected in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                curl = root / "curl"
                curl.write_text('''#!/bin/bash
printf 'request\\n' >> "$REQUEST_LOG"
if [[ "$*" == *api.ipify.org* ]]; then
    printf '198.51.100.42'
    exit "$IP_EXIT"
fi
printf '%s' "$METRICS"
exit "$CURL_EXIT"
''')
                curl.chmod(0o755)
                env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}", METRICS=metrics,
                           CURL_EXIT=curl_exit, IP_EXIT=ip_exit, REQUEST_LOG=str(root / "requests"), RK_VPN_CHECK_RETRIES="1")
                result = subprocess.run(["bash", str(ROOT / "check-client.sh"), "http://test.invalid:7897"],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(len((root / "requests").read_text().splitlines()), 6)


    def test_default_proxy_selection_and_explicit_override(self):
        import json
        cases = (
            ("server", "local", None, "http://127.0.0.1:17897"),
            ("remote", "remote", None, "http://192.0.2.100:7897"),
            ("override", "local", "http://explicit.invalid:8888", "http://explicit.invalid:8888"),
        )
        for label, route, override, expected in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                config = json.loads((ROOT / "config.json").read_text())
                config.update(listen_host="192.0.2.100", advertise_host="192.0.2.100",
                              health_port=17897)
                conf = root / "config.json"
                conf.write_text(json.dumps(config))
                ip = root / "ip"
                ip.write_text('#!/bin/bash\nif [[ "$ROUTE_KIND" == local ]]; then '
                              "echo 'local 192.0.2.100 dev lo src 192.0.2.100'; "
                              "else echo '192.0.2.100 via 192.0.2.1 dev eth0'; fi\n")
                ip.chmod(0o755)
                curl = root / "curl"
                curl.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$REQUEST_LOG"\n'
                                'if [[ "$*" == *api.ipify.org* ]]; then echo 198.51.100.42; '
                                "else echo '200 200 0'; fi\n")
                curl.chmod(0o755)
                env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                           ROUTE_KIND=route, REQUEST_LOG=str(root / "requests"),
                           RK_VPN_PROXY_CONFIG=str(conf), RK_VPN_PROXY_URL="",
                           RK_VPN_CHECK_RETRIES="1")
                command = ["bash", str(ROOT / "check-client.sh")]
                if override:
                    command.append(override)
                result = subprocess.run(command, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                requests = (root / "requests").read_text().splitlines()
                self.assertEqual(len(requests), 6)
                self.assertTrue(all("--proxy " + expected in request for request in requests))

    def test_network_timeout_is_retried_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / "curl"
            curl.write_text('#!/bin/bash\nprintf "request\\n" >> "$REQUEST_LOG"\n'
                            'if [[ "$*" == *"www.google.com"* && ! -f "$RETRY_FLAG" ]]; then '
                            'touch "$RETRY_FLAG"; exit 28; fi\n'
                            'if [[ "$*" == *api.ipify.org* ]]; then echo 198.51.100.42; '
                            "else echo '200 200 0'; fi\n")
            curl.chmod(0o755)
            env = dict(os.environ, PATH=f"{root}:{os.environ['PATH']}",
                       REQUEST_LOG=str(root / "requests"), RETRY_FLAG=str(root / "retry"),
                       RK_VPN_CHECK_RETRIES="2")
            result = subprocess.run(["bash", str(ROOT / "check-client.sh"),
                                     "http://test.invalid:7897"], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("WARN:", result.stderr)
            self.assertEqual(len((root / "requests").read_text().splitlines()), 7)

if __name__ == "__main__":
    unittest.main()
