#!/usr/bin/env python3
"""Serve the installer to client networks selected in the shared config."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import logging
import threading
from configuration import client_allowed, load_config

BUILD_DIRECTORY = Path(__file__).parent / "build"
INSTALLERS = {
    "/install.sh": ("client-install.sh", "text/x-shellscript; charset=utf-8"),
    "/install.ps1": ("client-install.ps1", "text/plain; charset=utf-8"),
}


class InstallerServer(ThreadingHTTPServer):
    """Bound concurrent connections, including clients that never send headers."""

    max_connections = 32
    connection_timeout = 10

    def __init__(self, *args, **kwargs):
        self.connection_slots = threading.BoundedSemaphore(self.max_connections)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.connection_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            request.settimeout(self.connection_timeout)
            super().process_request(request, client_address)
        except Exception:
            self.connection_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.connection_slots.release()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            config = load_config()
            allowed = config["installer_enabled"] and client_allowed(self.client_address[0], config)
        except (OSError, ValueError, KeyError, TypeError):
            logging.exception("Cannot load installer access policy")
            self.send_error(503, "Installer configuration unavailable")
            return
        if not allowed:
            self.send_error(403)
            return
        if self.path not in INSTALLERS:
            self.send_error(404)
            return
        name, content_type = INSTALLERS[self.path]
        try:
            data = (BUILD_DIRECTORY / name).read_bytes()
        except OSError:
            logging.exception("Cannot read installer %s", name)
            self.send_error(503, "Installer file unavailable")
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    config = load_config()
    InstallerServer((config["listen_host"], config["installer_port"]), Handler).serve_forever()
