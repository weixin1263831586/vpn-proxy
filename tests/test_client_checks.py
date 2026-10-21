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
                           CURL_EXIT=curl_exit, IP_EXIT=ip_exit, REQUEST_LOG=str(root / "requests"))
                result = subprocess.run(["bash", str(ROOT / "check-client.sh"), "http://test.invalid:7897"],
                                        env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(len((root / "requests").read_text().splitlines()), 6)


if __name__ == "__main__":
    unittest.main()
