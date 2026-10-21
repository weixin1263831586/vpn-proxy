#!/usr/bin/env python3
"""Serve the installer to client networks selected in the shared config."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import logging
from configuration import client_allowed, load_config

BUILD_DIRECTORY = Path(__file__).parent / "build"
INSTALLERS = {
    "/install.sh": ("client-install.sh", "text/x-shellscript; charset=utf-8"),
    "/install.ps1": ("client-install.ps1", "text/plain; charset=utf-8"),
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            allowed = client_allowed(self.client_address[0], load_config())
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
    ThreadingHTTPServer((config["listen_host"], config["installer_port"]), Handler).serve_forever()
