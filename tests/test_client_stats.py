"""Client statistics aggregation: connections, access-log windows, ACL classes."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import client_stats as CS  # noqa: E402

SS_OUTPUT = """ESTAB 0 0 172.16.14.233:7897 10.0.0.15:52451 timer:(keepalive,1min56s,0)
ESTAB 0 0 172.16.14.233:7897 10.0.0.15:52452
ESTAB 0 0 172.16.14.233:7897 172.16.8.9:49130
ESTAB 0 0 172.16.14.233:7897 10.0.0.99:51000
ESTAB 0 0 172.16.14.233:17897 127.0.0.1:40000
ESTAB 0 0 172.16.14.233:22 198.51.100.7:55555
ESTAB 0 0 [::ffff:10.0.0.44]:7897 [::ffff:10.0.0.44]:53000
"""

# Some ss builds omit the timer column entirely (four columns without -p).
SS_OUTPUT_NO_TIMER = """ESTAB 0 0 172.16.14.233:7897 10.0.0.15:52451
ESTAB 0 0 192.168.61.87:45870 59.37.80.41:443
ESTAB 0 0 [::ffff:10.0.0.44]:7897 [::ffff:10.0.0.44]:53000
"""

NOW = 1_700_000_000.0
# rk_vpn logformat: epoch elapsed client code/status bytes method user uri
# Squid appends chronologically: oldest line first, newest last. The parser
# scans backwards and stops once entries fall out of the window.
LOG_LINES = "\n".join([
    f"{NOW - 3600:.3f} 10 198.51.100.7 TCP_MISS/200 64 GET - http://old.example/",
    f"{NOW - 40:.3f} 2 203.0.113.9 TCP_DENIED/403 0 GET - http://x.example/",
    f"{NOW - 30:.3f} 45 172.16.8.9 TCP_TUNNEL/200 1048576 CONNECT - repo.example:443",
    f"{NOW - 10:.3f} 900 10.0.0.15 TCP_MISS/503 0 GET hcq http://c.example/",
    f"{NOW - 2:.3f} 64 10.0.0.15 TCP_MISS/304 128 GET hcq http://b.example/",
    f"{NOW - 1:.3f} 120 10.0.0.15 TCP_MISS/200 512 GET hjf http://a.example/",
])

CONFIG = {"listen_host": "127.0.0.1", "advertise_host": "proxy.internal",
          "vpn_interface": "ppp0", "test_url": "https://www.google.com",
          "proxy_port": 7897, "health_port": 17897, "installer_port": 8089,
          "allowed_clients": ["10.0.0.0/8", "172.16.0.0/12"],
          "dns_nameservers": ["8.8.8.8"], "no_proxy": ["localhost"],
          "installer_enabled": False}


def fake_run(outputs):
    def run(args, **kwargs):
        command = " ".join(args[:2])
        if command.startswith("ss") or args[0] == "ss":
            return subprocess.CompletedProcess(args, 0, SS_OUTPUT, "")
        return subprocess.CompletedProcess(args, 0, outputs, "")
    return run


class ConnectionParsing(unittest.TestCase):
    def test_counts_proxy_port_peers_per_client(self):
        clients = CS.established_connections(7897, run=fake_run(""))
        self.assertEqual(clients, {"10.0.0.15": 2, "172.16.8.9": 1,
                                   "10.0.0.99": 1, "10.0.0.44": 1})

    def test_other_listen_ports_are_not_clients(self):
        self.assertEqual(CS.established_connections(17897, run=fake_run("")),
                         {"127.0.0.1": 1})
        self.assertEqual(CS.established_connections(22, run=fake_run("")),
                         {"198.51.100.7": 1})

    def test_ss_failure_raises(self):
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 1, "", "boom")
        with self.assertRaisesRegex(RuntimeError, "boom"):
            CS.established_connections(7897, run=run)

    def test_socket_collection_timeout_is_reported_as_unavailable(self):
        def run(args, **kwargs):
            self.assertEqual(kwargs.get("timeout"), 3)
            raise subprocess.TimeoutExpired(args, 3)
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "access.log"
            log.write_text("", encoding="utf-8")
            snapshot = CS.collect(CONFIG, log, 300, run=run, now=NOW)
        self.assertFalse(snapshot["sources"]["connections"])
        self.assertTrue(snapshot["sources"]["access_log"])

    def test_output_without_timer_column_is_parsed(self):
        def run(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, SS_OUTPUT_NO_TIMER, "")
        clients = CS.established_connections(7897, run=run)
        self.assertEqual(clients, {"10.0.0.15": 1, "10.0.0.44": 1})


class AccessLogParsing(unittest.TestCase):
    def test_window_totals_stop_at_the_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "access.log"
            log.write_text(LOG_LINES, encoding="utf-8")
            clients = CS.parse_access_log(log, NOW - 60)
        # Same IP with different ident users aggregates separately.
        self.assertEqual(clients[("10.0.0.15", "hcq")],
                         {"client": "10.0.0.15", "user": "hcq",
                          "requests": 2, "bytes": 128, "errors": 1, "last_seen": NOW - 2})
        self.assertEqual(clients[("10.0.0.15", "hjf")]["bytes"], 512)
        self.assertEqual(clients[("172.16.8.9", None)]["bytes"], 1048576)
        self.assertNotIn(("198.51.100.7", None), clients)
        self.assertIn(("203.0.113.9", None), clients)

    def test_non_numeric_byte_counts_are_counted_but_zero(self):
        lines = f"{NOW - 5:.3f} 10 10.0.0.1 TCP_MISS/200 - GET - http://a/"
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "access.log"
            log.write_text(lines, encoding="utf-8")
            clients = CS.parse_access_log(log, NOW - 60)
        self.assertEqual(clients[("10.0.0.1", None)]["bytes"], 0)
        self.assertEqual(clients[("10.0.0.1", None)]["requests"], 1)


class ReverseLogReader(unittest.TestCase):
    def test_crosses_block_boundaries_and_stops_at_old_entries(self):
        recent = f"{NOW - 2:.3f} 10 10.0.0.1 TCP_MISS/200 512 GET - https://new.example/"
        old = f"{NOW - 3600:.3f} 10 10.0.0.2 TCP_MISS/200 4096 GET - https://old.example/"
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "access.log"
            log.write_text(old + "\n" + ("bad row\n" * 12) + recent + "\n",
                           encoding="utf-8")
            lines = list(CS.reverse_log_lines(log, block_size=17))
            self.assertEqual(lines[0], recent)
            self.assertEqual(lines[-1], old)
            snapshot = CS.parse_access_log(log, NOW - 60)
            self.assertEqual(snapshot[("10.0.0.1", None)]["bytes"], 512)
            self.assertNotIn(("10.0.0.2", None), snapshot)

    def test_oversized_log_line_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "access.log"
            log.write_bytes(b"x" * (CS.MAX_LOG_LINE_SIZE + 1))
            with self.assertRaisesRegex(ValueError, "oversized line"):
                list(CS.reverse_log_lines(log))


class Snapshot(unittest.TestCase):
    def test_collect_classifies_connected_recent_and_unlisted(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "access.log"
            log.write_text(LOG_LINES, encoding="utf-8")
            with patch.object(CS, "established_connections",
                              return_value={"10.0.0.15": 2, "172.16.8.9": 1}):
                snapshot = CS.collect(CONFIG, log, 300, now=NOW)
        self.assertEqual([entry["client"] for entry in snapshot["connected"]],
                         ["10.0.0.15", "172.16.8.9"])
        self.assertEqual(snapshot["connected"][0]["network"], "10.0.0.0/8")
        by_key = {(entry["client"], entry["user"]): entry for entry in snapshot["recent"]}
        self.assertEqual(by_key[("203.0.113.9", None)]["network"], "outside ACL")
        self.assertEqual(snapshot["unlisted"], [by_key[("203.0.113.9", None)]])
        self.assertEqual(by_key[("10.0.0.15", "hcq")]["label"], "hcq@10.0.0.15")
        self.assertEqual(snapshot["sources"], {"connections": True, "access_log": True})

    def test_unavailable_sources_degrade_to_empty_sections(self):
        with patch.object(CS, "established_connections",
                          side_effect=RuntimeError("no ss")):
            snapshot = CS.collect(CONFIG, "/does-not-exist/access.log", 300, now=NOW,
                                  run=lambda *a, **k: subprocess.CompletedProcess(a[0], 1, "", "x"))
        self.assertEqual(snapshot["connected"], [])
        self.assertEqual(snapshot["recent"], [])
        self.assertEqual(snapshot["sources"], {"connections": False, "access_log": False})
        text = CS.render(snapshot, "/dev/null")
        self.assertIn("run as root", text)

    def test_render_marks_denied_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "access.log"
            log.write_text(LOG_LINES, encoding="utf-8")
            with patch.object(CS, "established_connections", return_value={}):
                snapshot = CS.collect(CONFIG, log, 300, now=NOW)
        text = CS.render(snapshot, "/dev/null")
        self.assertIn("Sources outside allowed_clients (denied): 203.0.113.9 (1)", text)
        self.assertIn("Summary: 0 connected", text)


class Main(unittest.TestCase):
    def test_json_output_is_valid_and_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "access.log"
            recent = time.time() - 5
            log.write_text("\n".join((
                f"{recent:.3f} 120 10.0.0.15 TCP_MISS/200 512 GET http://a.example/",
                f"{recent - 2:.3f} 45 203.0.113.9 TCP_DENIED/403 0 GET http://x.example/")))
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/client_stats.py"),
                 "--json", "--log", str(log),
                 "--config", str(self.write_config(directory)), "--window", "60"],
                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = json.loads(result.stdout)
        self.assertEqual(snapshot["proxy_port"], 7897)
        self.assertEqual(snapshot["window_seconds"], 60)
        self.assertIsInstance(snapshot["connected"], list)
        self.assertTrue(snapshot["recent"])
        self.assertIn("sources", snapshot)

    @staticmethod
    def write_config(directory):
        path = Path(directory) / "config.json"
        path.write_text(json.dumps(CONFIG))
        return path


class Dashboard(unittest.TestCase):
    """End-to-end test of --serve against a real loopback HTTP server."""

    def start_server(self, directory, port):
        log = Path(directory) / "access.log"
        log.write_text("\n".join((
            f"{time.time() - 5:.3f} 120 10.0.0.15 TCP_MISS/200 512 GET http://a.example/",
            f"{time.time() - 7:.3f} 45 203.0.113.9 TCP_DENIED/403 0 GET http://x.example/")))
        return subprocess.Popen(
            [sys.executable, str(ROOT / "scripts/client_stats.py"),
             "--serve", "--bind", "127.0.0.1", "--port", str(port),
             "--log", str(log), "--config", str(Main.write_config(directory)),
             "--window", "60"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)

    def test_dashboard_serves_html_and_fresh_json(self):
        import urllib.request
        with tempfile.TemporaryDirectory() as directory:
            port = 18731
            server = self.start_server(directory, port)
            try:
                page = api = None
                for _ in range(50):
                    try:
                        with urllib.request.urlopen(
                                f"http://127.0.0.1:{port}/", timeout=2) as response:
                            page = response.read().decode()
                        with urllib.request.urlopen(
                                f"http://127.0.0.1:{port}/api/stats", timeout=2) as response:
                            api = json.loads(response.read().decode())
                        # The first response may be "尚未采集" while the worker
                        # thread gathers the initial snapshot. Do not call
                        # that a ready statistics service.
                        if "proxy_port" in api and api.get("sources"):
                            break
                    except Exception:
                        pass
                    time.sleep(0.2)
                self.assertIsNotNone(page, "dashboard did not start")
                self.assertIsNotNone(api, "api did not answer")
                # The dialog-style UI: single page, centered <dialog>, auto refresh.
                self.assertIn("<dialog", page)
                self.assertIn("setInterval(refresh, 5000)", page)
                self.assertIn("/api/stats", page)
                self.assertEqual(api["proxy_port"], 7897)
                self.assertTrue(api["recent"])
                clients = {entry["client"] for entry in api["recent"]}
                self.assertIn("10.0.0.15", clients)
                self.assertIn("203.0.113.9", clients)
            finally:
                server.terminate()
                server.wait(timeout=10)

    def test_rebinding_host_is_rejected(self):
        import urllib.error
        import urllib.request
        with tempfile.TemporaryDirectory() as directory:
            port = 18733
            server = self.start_server(directory, port)
            try:
                for _ in range(50):
                    try:
                        urllib.request.urlopen(
                            f"http://127.0.0.1:{port}/", timeout=2)
                        break
                    except Exception:
                        time.sleep(0.2)
                request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/api/stats",
                    headers={"Host": "attacker.example"})
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(request, timeout=2)
                self.assertEqual(caught.exception.code, 403)
            finally:
                server.terminate()
                server.wait(timeout=10)

    def test_non_loopback_bind_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([
                sys.executable, str(ROOT / "scripts/client_stats.py"),
                "--serve", "--bind", "0.0.0.0", "--port", "0",
                "--config", str(Main.write_config(directory)),
            ], capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("127.0.0.1", result.stderr)

    def test_unknown_paths_are_rejected(self):
        import urllib.error
        import urllib.request
        with tempfile.TemporaryDirectory() as directory:
            port = 18732
            server = self.start_server(directory, port)
            try:
                code = None
                for _ in range(50):
                    try:
                        urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=2)
                        break
                    except Exception:
                        time.sleep(0.2)
                try:
                    urllib.request.urlopen(f"http://127.0.0.1:{port}/etc/passwd", timeout=2)
                except urllib.error.HTTPError as error:
                    code = error.code
                self.assertEqual(code, 404)
            finally:
                server.terminate()
                server.wait(timeout=10)


class Tui(unittest.TestCase):
    snapshot = {
        "time": NOW, "proxy_port": 7897, "window_seconds": 300,
        "connected": [{"client": "10.0.0.15", "connections": 2, "network": "10.0.0.0/8"}],
        "recent": [
            {"client": "10.0.0.15", "requests": 3, "bytes": 640, "errors": 1, "last_seen": NOW - 1,
             "network": "10.0.0.0/8"},
            {"client": "203.0.113.9", "requests": 1, "bytes": 0, "errors": 1, "last_seen": NOW - 40,
             "network": "outside ACL"}],
        "unlisted": [{"client": "203.0.113.9", "requests": 1}],
        "sources": {"connections": True, "access_log": True},
    }

    def test_tui_shows_summary_card_tables_and_denied_sources(self):
        rendered = CS.tui_lines(self.snapshot, 110)
        texts = [text for _, text in rendered]
        styles = [style for style, _ in rendered]
        self.assertIn("title", styles)
        # Summary card counts every section.
        card = next(text for style, text in rendered if style == "card")
        for needle in ("接入 1", "活跃 2", "请求 4", "错误 2"):
            self.assertIn(needle, card)
        # Both section headers are present.
        self.assertTrue(any("当前接入" in text for text in texts))
        self.assertTrue(any("秒活跃" in text for text in texts))
        # Table rows carry client, traffic and activity dots.
        rows = [text for style, text in rendered if style == "row"]
        self.assertTrue(any("10.0.0.15" in row and "640" in row for row in rows))
        self.assertTrue(any("●●" in row for row in rows))
        # Denied sources surface as a red warning.
        self.assertTrue(any("白名单外被拒来源" in text for text in texts))

    def test_collect_error_shows_failure_inside_card(self):
        lines = CS.tui_lines({"time": NOW, "collect_error": "ss failed"}, 80)
        self.assertTrue(any("ss failed" in text for _, text in lines))

    def test_empty_state_shows_placeholders(self):
        snapshot = {"time": NOW, "proxy_port": 7897, "window_seconds": 300,
                    "connected": [], "recent": [], "unlisted": [],
                    "sources": {"connections": True, "access_log": True}}
        texts = [text for _, text in CS.tui_lines(snapshot, 80)]
        self.assertTrue(any("暂无客户端接入" in text for text in texts))
        self.assertTrue(any("时间窗内无请求" in text for text in texts))

    def test_long_lines_are_truncated_to_width(self):
        for style, text in CS.tui_lines(self.snapshot, 40):
            self.assertLessEqual(len(text), 41)  # width + 1 for the border column


if __name__ == "__main__":
    unittest.main()
