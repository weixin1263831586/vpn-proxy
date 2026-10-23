from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import tempfile
import threading
import unittest
import logging
import socket
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import ProxyHandler, build_opener

ROOT = Path(__file__).resolve().parents[1]
SPEC = spec_from_file_location("downloader", ROOT / "serve-installer.py")
DOWNLOADER = module_from_spec(SPEC)
SPEC.loader.exec_module(DOWNLOADER)


class InstallerDownloads(unittest.TestCase):
    def test_both_platforms_share_access_control_and_restrict_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory)
            for name in ("client-install.sh", "client-install.ps1"):
                (build / name).write_text(name)
            with patch.object(DOWNLOADER, "BUILD_DIRECTORY", build), \
                 patch.object(DOWNLOADER.Handler, "log_message"), \
                 DOWNLOADER.InstallerServer(("127.0.0.1", 0), DOWNLOADER.Handler) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                opener = build_opener(ProxyHandler({}))
                base = f"http://127.0.0.1:{server.server_port}"
                try:
                    for extension in ("sh", "ps1"):
                        with opener.open(f"{base}/install.{extension}") as response:
                            self.assertEqual(response.read().decode(), f"client-install.{extension}")
                    disabled = dict(DOWNLOADER.load_config(), installer_enabled=False)
                    with patch.object(DOWNLOADER, "load_config", return_value=disabled):
                        with self.assertRaises(HTTPError) as disabled_entry:
                            opener.open(f"{base}/install.sh")
                        with disabled_entry.exception:
                            self.assertEqual(disabled_entry.exception.code, 403)
                    with self.assertRaises(HTTPError) as denied_path:
                        opener.open(f"{base}/../config.json")
                    with denied_path.exception:
                        self.assertEqual(denied_path.exception.code, 404)
                    for failure in (ValueError("broken config"), OSError("unreadable config")):
                        with patch.object(DOWNLOADER, "load_config", side_effect=failure), \
                             self.assertLogs(level=logging.ERROR):
                            with self.assertRaises(HTTPError) as unavailable:
                                opener.open(f"{base}/install.sh")
                            with unavailable.exception:
                                self.assertEqual(unavailable.exception.code, 503)
                    (build / "client-install.ps1").unlink()
                    with self.assertLogs(level=logging.ERROR):
                        with self.assertRaises(HTTPError) as missing_file:
                            opener.open(f"{base}/install.ps1")
                    with missing_file.exception:
                        self.assertEqual(missing_file.exception.code, 503)
                    with patch.object(DOWNLOADER, "client_allowed", return_value=False):
                        for extension in ("sh", "ps1"):
                            with self.assertRaises(HTTPError) as denied_client:
                                opener.open(f"{base}/install.{extension}")
                            with denied_client.exception:
                                self.assertEqual(denied_client.exception.code, 403)
                finally:
                    server.shutdown()
                    thread.join()

    def test_idle_connections_are_bounded_and_slots_recover(self):
        started, finished = threading.Event(), threading.Event()

        class LimitedServer(DOWNLOADER.InstallerServer):
            max_connections = 1
            connection_timeout = 1

            def process_request_thread(self, request, address):
                started.set()
                try:
                    super().process_request_thread(request, address)
                finally:
                    finished.set()

        with patch.object(DOWNLOADER.Handler, "log_message"), \
             LimitedServer(("127.0.0.1", 0), DOWNLOADER.Handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                with socket.create_connection(server.server_address, timeout=3) as idle:
                    self.assertTrue(started.wait(3))
                    with socket.create_connection(server.server_address, timeout=3) as excess:
                        self.assertEqual(excess.recv(1), b"")
                    # The admitted idle connection must time out and release its slot.
                    self.assertEqual(idle.recv(1), b"")
                    self.assertTrue(finished.wait(3))
                opener = build_opener(ProxyHandler({}))
                with self.assertRaises(HTTPError) as response:
                    opener.open(f"http://127.0.0.1:{server.server_port}/missing", timeout=3)
                with response.exception:
                    self.assertEqual(response.exception.code, 404)
            finally:
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    unittest.main()
