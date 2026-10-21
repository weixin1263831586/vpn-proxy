#!/usr/bin/env python3
"""Serve the installer to client networks selected in the shared config."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from configuration import client_allowed, load_config

INSTALLER = Path(__file__).parent / "build/client-install.sh"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if not client_allowed(self.client_address[0], load_config()):
            self.send_error(403)
            return
        if self.path != "/install.sh":
            self.send_error(404)
            return
        data = INSTALLER.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/x-shellscript; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    config = load_config()
    ThreadingHTTPServer((config["listen_host"], config["installer_port"]), Handler).serve_forever()
