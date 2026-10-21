#!/usr/bin/env python3
"""Serve only the installer to the build server and the local host."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

INSTALLER = Path(__file__).with_name("client-install.sh")
ALLOWED_CLIENTS = {"10.10.10.206", "172.16.14.233"}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.client_address[0] not in ALLOWED_CLIENTS:
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
    ThreadingHTTPServer(("172.16.14.233", 8089), Handler).serve_forever()
