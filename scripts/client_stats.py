#!/usr/bin/env python3
"""Summarize the clients currently using the deployed rk-vpn-proxy.

Two read-only sources, no traffic is generated:
- `ss` established TCP sockets on the proxy port: who is connected right now
  and how many connections each client holds.
- the Squid access log: per-client requests, bytes, errors and last activity
  inside a recent time window, including denied sources outside the ACL.

Run as root on the deployed host (unprivileged users cannot see other
processes' sockets or read the proxy logs). Never sends any packet.

`--serve` additionally runs a dialog-style web dashboard: a single page that
pops the client statistics up in a centered overlay and refreshes itself. It
binds to the loopback address only; reach it through an SSH tunnel
(`ssh -L 17898:127.0.0.1:17898 host`) and open http://127.0.0.1:17898/.
"""
import argparse
import datetime
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
# The deployed copy lives in /usr/local/libexec; its configuration module
# is installed under /usr/local/lib/rk-vpn-proxy.
_deployed_lib = Path("/usr/local/lib/rk-vpn-proxy")
if _deployed_lib.is_dir():
    sys.path.append(str(_deployed_lib))
from configuration import load_config

DEFAULT_LOG = "/var/log/rk-vpn-proxy/access.log"
DEPLOYED_CONFIG = "/etc/rk-vpn-proxy/config.json"


def established_connections(proxy_port, run=subprocess.run):
    """Count established TCP peers per client address for one listen port."""
    result = run(["ss", "-Htno", "state", "established"],
                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    clients: dict = {}
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "ss failed")
    for line in result.stdout.splitlines():
        columns = line.split()
        if len(columns) < 4:
            continue
        # Layout: Recv-Q Send-Q Local Peer [Timer...]; with -H the header is
        # gone and the process column only appears with -p. Locate the local
        # endpoint by its host:port shape instead of a fixed column index,
        # because the timer column may be absent.
        try:
            local_index = next(
                index for index, value in enumerate(columns[2:5], start=2)
                if ":" in value and listen_port(value).isdigit())
        except StopIteration:
            continue
        if int(listen_port(columns[local_index])) != proxy_port:
            continue
        peer = columns[local_index + 1]
        address = peer_address(peer)
        if address is not None:
            clients[address] = clients.get(address, 0) + 1
    return clients


def listen_port(endpoint):
    """Local end of a socket, e.g. "172.16.14.233:7897" -> 7897."""
    if endpoint.startswith("["):
        return endpoint.rsplit("]:", 1)[-1]
    return endpoint.rsplit(":", 1)[-1]


def peer_address(endpoint):
    """Client end of a socket; v4-mapped IPv6 is folded back to IPv4."""
    if endpoint.startswith("["):
        address = endpoint[1:].rsplit("]", 1)[0]
    else:
        address = endpoint.rsplit(":", 1)[0]
    if address.startswith("::ffff:") and address.count(".") == 3:
        address = address[len("::ffff:"):]
    try:
        ipaddress.ip_address(address)
    except ValueError:
        return None
    return address


def parse_access_log(path, since, run=subprocess.run):
    """Per-client totals from the rk_vpn access log, newest first.

    Line layout: <epoch> <elapsed_ms> <client> <code>/<status> <bytes>
    <method> <user> <uri> — the user field is "-" unless ident lookup or
    authentication fills it. Entries older than `since` stop the scan; the
    log is rotated daily, so the newest lines are always near the end.
    """
    result = run(["cat", str(path)], stdout=subprocess.PIPE,
                 stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"cannot read {path}")
    clients: dict = {}
    for line in reversed(result.stdout.splitlines()):
        fields = line.split()
        if len(fields) < 5:
            continue
        try:
            stamp = float(fields[0])
        except ValueError:
            continue
        if stamp < since:
            break
        client, status, raw_bytes = fields[2], fields[3], fields[4]
        user = fields[6] if len(fields) > 6 and fields[6] not in ("-", "") else None
        key = (client, user)
        entry = clients.setdefault(key, {"client": client, "user": user,
                                         "requests": 0, "bytes": 0,
                                         "errors": 0, "last_seen": 0.0})
        entry["requests"] += 1
        entry["bytes"] += int(raw_bytes) if raw_bytes.isdigit() else 0
        code = status.rsplit("/", 1)[-1]
        if not code.startswith(("2", "3")):
            entry["errors"] += 1
        entry["last_seen"] = max(entry["last_seen"], stamp)
    return clients


def client_network(address, networks):
    """Canonical allowed_clients network covering the address, if any."""
    probe = ipaddress.ip_address(address)
    for network in networks:
        if probe.version == network.version and probe in network:
            return str(network)
    return None


def network_label(address):
    probe = ipaddress.ip_address(address)
    if probe.is_loopback:
        return "local (health)"
    return "outside ACL"


def client_label(entry):
    """Display form: user@ip when the ident user is known, plain IP else."""
    return f"{entry['user']}@{entry['client']}" if entry.get("user") else entry["client"]


def collect(config, log_path, window, run=subprocess.run, now=None):
    """Gather the full statistics snapshot as a plain dict."""
    proxy_port = config["proxy_port"]
    networks = [ipaddress.ip_network(value) for value in config["allowed_clients"]]
    if now is None:
        now = time.time()
    try:
        connected = established_connections(proxy_port, run)
    except (RuntimeError, FileNotFoundError):
        connected = None
    try:
        recent = parse_access_log(log_path, now - window, run)
    except (RuntimeError, FileNotFoundError):
        recent = None

    def decorate(address, extra):
        entry = dict(extra)
        entry["client"] = address
        entry["network"] = client_network(address, networks) or network_label(address)
        return entry

    def decorate_recent(stats):
        # stats already carries client + user (ident) for the (ip, user) key.
        entry = dict(stats)
        entry["network"] = client_network(entry["client"], networks) \
            or network_label(entry["client"])
        entry["label"] = client_label(entry)
        return entry

    connected_list = sorted(
        (decorate(address, {"connections": count})
         for address, count in (connected or {}).items()),
        key=lambda entry: (-entry["connections"], entry["client"]))
    recent_list = sorted(
        (decorate_recent(stats) for stats in (recent or {}).values()),
        key=lambda entry: (-entry["bytes"], client_label(entry)))
    return {
        "time": now,
        "proxy_port": proxy_port,
        "window_seconds": window,
        "connected": connected_list,
        "recent": recent_list,
        "unlisted": [entry for entry in recent_list
                     if entry["network"] == "outside ACL"],
        "sources": {
            "connections": connected is not None,
            "access_log": recent is not None,
        },
    }


def human_bytes(value):
    for unit in ("", "KiB", "MiB", "GiB", "TiB"):
        if value < 1024 or unit == "TiB":
            return f"{value:.0f} {unit}".strip()
        value /= 1024


def render(snapshot, log_path):
    stamp = datetime.datetime.fromtimestamp(
        snapshot["time"]).strftime("%Y-%m-%d %H:%M:%S")
    lines = [f"rk-vpn-proxy client statistics — {stamp}"]
    sources = snapshot["sources"]
    if not sources["connections"]:
        lines.append("connected sockets: unavailable (run as root)")
    if not sources["access_log"]:
        lines.append(f"access log: unavailable ({log_path})")
    lines.append("")
    lines.append(f"Currently connected on port {snapshot['proxy_port']}:")
    if snapshot["connected"]:
        lines.append(f"{'client':<40}{'conns':>6}  network")
        for entry in snapshot["connected"]:
            lines.append(f"{entry['client']:<40}{entry['connections']:>6}  {entry['network']}")
    else:
        lines.append("  (no established connections)")
    lines.append("")
    lines.append(f"Active in the last {snapshot['window_seconds']}s (access log):")
    if snapshot["recent"]:
        has_users = any(entry.get("user") for entry in snapshot["recent"])
        head = "user@client" if has_users else "client"
        lines.append(f"{head:<44}{'reqs':>6}{'bytes':>12}{'errors':>8}  last seen  network")
        for entry in snapshot["recent"]:
            seen = datetime.datetime.fromtimestamp(entry["last_seen"]).strftime("%H:%M:%S")
            lines.append(f"{client_label(entry):<44}{entry['requests']:>6}"
                         f"{human_bytes(entry['bytes']):>12}{entry['errors']:>8}  {seen}  {entry['network']}")
    else:
        lines.append("  (no requests in the window)")
    if snapshot["unlisted"]:
        lines.append("")
        denied = ", ".join(f"{client_label(entry)} ({entry['requests']})"
                           for entry in snapshot["unlisted"])
        lines.append(f"Sources outside allowed_clients (denied): {denied}")
    total_requests = sum(entry["requests"] for entry in snapshot["recent"])
    total_bytes = sum(entry["bytes"] for entry in snapshot["recent"])
    lines.append("")
    lines.append(f"Summary: {len(snapshot['connected'])} connected, "
                 f"{len(snapshot['recent'])} active clients, "
                 f"{total_requests} requests, {human_bytes(total_bytes)} in window.")
    return "\n".join(lines)


DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>rk-vpn-proxy 客户端</title>
<style>
:root { color-scheme: light dark; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center;
       font: 14px/1.5 system-ui, sans-serif;
       background: rgba(15, 18, 25, .55); }
dialog { border: 1px solid #8884; border-radius: 12px; padding: 0;
         width: min(920px, 94vw); max-height: 90vh;
         box-shadow: 0 18px 60px rgba(0, 0, 0, .45); }
dialog::backdrop { background: rgba(10, 12, 18, .45); }
header { display: flex; align-items: center; gap: 12px;
         padding: 12px 18px; border-bottom: 1px solid #8884; }
header h1 { font-size: 15px; margin: 0; flex: 1; }
header .meta { color: #888; font-size: 12px; }
main { padding: 12px 18px 16px; overflow: auto; }
h2 { font-size: 13px; margin: 14px 0 6px; color: #999; font-weight: 600; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: 4px 10px 4px 0; border-bottom: 1px solid #8882; }
th { font-size: 12px; color: #888; font-weight: 600; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; }
.badge { display: inline-block; padding: 0 8px; border-radius: 999px;
         font-size: 12px; background: #8882; }
.badge.off { background: #c6282833; color: #c62828; }
.badge.on { background: #2e7d3233; color: #2e7d32; }
.empty { color: #999; padding: 8px 0; }
.denied { color: #c62828; }
footer { display: flex; align-items: center; gap: 10px;
         padding: 10px 18px; border-top: 1px solid #8884; font-size: 12px; color: #888; }
footer .spacer { flex: 1; }
button { font: inherit; padding: 4px 14px; border-radius: 8px;
         border: 1px solid #8886; background: transparent; cursor: pointer; }
button:hover { background: #8882; }
.err { color: #c62828; }
</style>
</head>
<body>
<dialog open id="panel">
  <header>
    <h1>rk-vpn-proxy 客户端统计</h1>
    <span class="meta" id="updated"></span>
  </header>
  <main id="content"><p class="empty">加载中…</p></main>
  <footer>
    <span id="status" class="badge">自动刷新</span>
    <span>窗口 <span id="window"></span>s · 每 5 秒刷新</span>
    <span class="spacer"></span>
    <button onclick="document.getElementById('panel').close()">关闭</button>
  </footer>
</dialog>
<script>
const esc = s => String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const bytes = n => { for (const u of ['', 'KiB', 'MiB', 'GiB', 'TiB']) {
    if (n < 1024 || u === 'TiB') return n.toFixed(0) + ' ' + u; n /= 1024; } };
async function refresh() {
  try {
    const r = await fetch('/api/stats', {cache: 'no-store'});
    if (!r.ok) throw new Error('HTTP ' + r.status);
    render(await r.json());
    document.getElementById('status').className = 'badge on';
    document.getElementById('status').textContent = '正常';
  } catch (e) {
    document.getElementById('status').className = 'badge off';
    document.getElementById('status').textContent = '刷新失败';
  }
}
function render(s) {
  document.getElementById('updated').textContent =
      '更新于 ' + new Date(s.time * 1000).toLocaleTimeString();
  document.getElementById('window').textContent = s.window_seconds;
  const rows = (list, cols) => list.length ? list.map(e =>
      '<tr>' + cols.map(c => '<td' + (c.num ? ' class="num"' : '') + '>' +
          (c.render ? c.render(e[c.key]) : esc(e[c.key])) + '</td>').join('') + '</tr>').join('')
      : '<tr><td colspan="6" class="empty">（无）</td></tr>';
  const connCols = [
      {key: 'client'}, {key: 'connections', num: 1},
      {key: 'network'}];
  const hasUsers = s.recent.some(e => e.user);
  const logCols = [
      {key: hasUsers ? 'label' : 'client'},
      {key: 'requests', num: 1},
      {key: 'bytes', num: 1, render: bytes},
      {key: 'errors', num: 1},
      {key: 'last_seen', render: t => new Date(t * 1000).toLocaleTimeString()},
      {key: 'network'}];
  document.getElementById('content').innerHTML =
      '<h2>当前接入（端口 ' + s.proxy_port + '，共 ' + s.connected.length + ' 个客户端）</h2>' +
      '<table><thead><tr><th>客户端</th><th class="num">连接数</th><th>网段</th></tr></thead><tbody>' +
      rows(s.connected, connCols) + '</tbody></table>' +
      '<h2>最近 ' + s.window_seconds + ' 秒活跃（共 ' + s.recent.length + ' 个客户端）</h2>' +
      '<table><thead><tr><th>' + (hasUsers ? '客户端（用户@IP）' : '客户端') + '</th>' +
      '<th class="num">请求</th><th class="num">流量</th>' +
      '<th class="num">错误</th><th>最后活跃</th><th>网段</th></tr></thead><tbody>' +
      rows(s.recent, logCols) + '</tbody></table>' +
      (s.unlisted.length ? '<p class="denied">白名单外被拒来源：' +
          s.unlisted.map(e => esc(e.client) + '（' + e.requests + '）').join('、') + '</p>' : '');
}
refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
"""


def dashboard_handler(factory):
    """Build a request handler around a thread-safe snapshot factory."""

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            path = urlparse(self.path).path
            if path == "/api/stats":
                body = json.dumps(factory()).encode()
                content_type = "application/json"
            elif path == "/":
                body = DASHBOARD_HTML.encode()
                content_type = "text/html; charset=utf-8"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            # Same-origin dashboard only; never let proxies or other pages
            # read the client statistics.
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    return Handler


def tui_lines(snapshot, width=80, height=24):
    """Full-screen terminal dashboard content: list of (style, text).

    Styles: title/head/dim/row/ok/warn/err/card/blank. Pure function so
    tests can verify the layout without a terminal.
    """
    width = max(int(width) - 1, 20)
    connected = snapshot.get("connected") or []
    recent = snapshot.get("recent") or []
    unlisted = snapshot.get("unlisted") or []
    sources = snapshot.get("sources") or {"connections": True, "access_log": True}
    lines: list = []
    rule = "─" * (width - 2)

    # ── 标题栏 ──────────────────────────────────────────────────
    lines.append(("title", " ◆ rk-vpn-proxy 客户端统计"))
    data_age = max(int(time.time() - snapshot.get("time", time.time())), 0)
    lines.append(("dim", f"   数据更新于 {data_age} 秒前 · [q] 退出 · 每 3 秒采数"))
    lines.append(("dim", f" ┌{rule}┐"))
    if snapshot.get("collect_error"):
        lines.append(("err", f" │ ⚠ 采集失败: {snapshot['collect_error']}".ljust(width - 1) + "│"))
        lines.append(("dim", f" └{rule}┘"))
        return lines

    # ── 汇总卡片 ───────────────────────────────────────────────
    total_requests = sum(entry["requests"] for entry in recent)
    total_bytes = sum(entry["bytes"] for entry in recent)
    total_errors = sum(entry["errors"] for entry in recent)
    conn_mark = "●" if sources["connections"] else "○"
    log_mark = "●" if sources["access_log"] else "○"
    lines.append(("card", f" │   {conn_mark} 接入 {len(connected)}     {log_mark} 活跃 {len(recent)}     "
                          f"请求 {total_requests}     流量 {human_bytes(total_bytes)}     错误 {total_errors}"))
    if not sources["connections"]:
        lines.append(("warn", " │    ○ 套接字信息不可用（需要 root）"))
    if not sources["access_log"]:
        lines.append(("warn", " │    ○ 访问日志不可用"))
    lines.append(("dim", f" └{rule}┘"))

    def table(headers, rows):
        lines.append(("dim", "  " + "  ".join(label.center(w) for label, w in headers)))
        lines.append(("dim", "  " + "─".join("─" * w for _, w in headers)))
        for row in rows:
            lines.append(("row", "  " + "  ".join(
                value.rjust(w) if align == "r" else value.ljust(w)
                for value, (_, w), align in zip(row, headers, aligns))))

    # ── 当前接入 ───────────────────────────────────────────────
    lines.append(("blank", ""))
    lines.append(("head", " ▌当前接入"))
    if connected:
        aligns = "lrrl"
        headers = [("客户端", 38), ("连接数", 6), ("活跃", 5), ("网段", max(width - 58, 8))]
        rows = [(entry["client"], str(entry["connections"]),
                 "●" * min(entry["connections"], 5), entry["network"])
                for entry in connected]
        table(headers, rows)
    else:
        lines.append(("dim", "    （暂无客户端接入）"))

    # ── 活跃统计 ───────────────────────────────────────────────
    lines.append(("blank", ""))
    lines.append(("head", f" ▌最近 {snapshot['window_seconds']} 秒活跃"))
    if recent:
        has_users = any(entry.get("user") for entry in recent)
        aligns = "lrrrrl"
        label = "客户端" if not has_users else "客户端（用户@IP）"
        client_w = 30 if has_users else 36
        headers = [(label, client_w), ("请求", 6), ("流量", 10), ("错误", 5),
                   ("最后活跃", 10), ("网段", max(width - client_w - 40, 8))]
        rows = []
        for entry in recent:
            seen = datetime.datetime.fromtimestamp(entry["last_seen"]).strftime("%H:%M:%S")
            err = str(entry["errors"]) if entry["errors"] else "·"
            rows.append((client_label(entry), str(entry["requests"]),
                         human_bytes(entry["bytes"]), err, seen, entry["network"]))
        table(headers, rows)
    else:
        lines.append(("dim", "    （时间窗内无请求）"))
    if unlisted:
        denied = ", ".join(f"{entry['client']}×{entry['requests']}" for entry in unlisted)
        lines.append(("err", f" ⚠ 白名单外被拒来源: {denied}"))
    lines.append(("dim", " " + rule))
    # Never exceed the terminal width; the curses loop also clamps, but the
    # pure function keeps every line within bounds for direct consumers.
    return [(style, text[:width + 1]) for style, text in lines]


TUI_STYLES = {
    "title": 3,   # cyan
    "head": 4,    # yellow
    "dim": 0,
    "row": 0,
    "ok": 1,      # green
    "card": 3,    # cyan
    "warn": 4,
    "err": 2,     # red
}


def run_tui(config, log_path, window):
    """Full-screen live dashboard inside the current terminal."""
    import curses

    def draw(stdscr):
        curses.curs_set(0)
        stdscr.nodelay(True)
        stdscr.keypad(True)
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_GREEN, -1)
        curses.init_pair(2, curses.COLOR_RED, -1)
        curses.init_pair(3, curses.COLOR_CYAN, -1)
        curses.init_pair(4, curses.COLOR_YELLOW, -1)
        curses.init_pair(5, curses.COLOR_BLACK, curses.COLOR_CYAN)  # reversed title bar
        snapshot = {"time": time.time(), "collect_error": "采集中…"}
        next_refresh = 0.0
        while True:
            now = time.time()
            if stdscr.getch() in (ord("q"), ord("Q"), 27):
                return
            if now >= next_refresh:
                try:
                    snapshot = collect(config, log_path, window)
                except Exception as error:
                    snapshot = {"time": now, "collect_error": str(error)}
                next_refresh = now + 3
            height, width = stdscr.getmaxyx()
            stdscr.erase()
            rows = tui_lines(snapshot, width)
            # Title bar: brand on the left, real-time clock dead centre.
            # Both segments are ASCII, padded in cells, and the bar never
            # touches the right edge (the last column is a curses trap).
            stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            visible = max(width - 1, 1)
            brand = " rk-vpn-proxy client statistics"
            clock = f" {stamp} "
            bar = brand.ljust(visible)
            start = max((visible - len(clock)) // 2, len(brand))
            bar = bar[:start] + clock + bar[start + len(clock):]
            try:
                stdscr.addnstr(0, 0, bar, visible,
                               curses.color_pair(5) | curses.A_BOLD)
            except curses.error:
                pass
            if rows and rows[0][0] == "title":
                rows = rows[1:]
            top = 1
            for offset, (style, text) in enumerate(rows):
                if top + offset >= height - 1:
                    break
                pair = TUI_STYLES.get(style, 0)
                try:
                    stdscr.addnstr(top + offset, 1, text, max(width - 3, 1),
                                   curses.color_pair(pair) if pair else 0)
                except curses.error:
                    pass  # a clipped line must never kill the dashboard
            # Bottom hint bar: ASCII only, right edge never written.
            hint = " data every 3s | q quit"
            visible = max(width - 1, 1)
            cells = hint[:visible].ljust(visible)
            try:
                stdscr.addnstr(height - 1, 0, cells, visible, curses.color_pair(5))
            except curses.error:
                pass
            stdscr.refresh()
            time.sleep(0.2)

    curses.wrapper(draw)


def serve(config, log_path, window, bind, port):
    """Run the dashboard; snapshots are rendered off the accept loop."""
    state = {"error": "尚未采集"}
    lock = threading.Lock()

    def refresh_loop():
        while True:
            try:
                snapshot = collect(config, log_path, window)
            except Exception as error:  # keep the last good data visible
                with lock:
                    state.update({"error": str(error), "failed": True})
            else:
                with lock:
                    state.clear()
                    state.update(snapshot)
            time.sleep(5)

    threading.Thread(target=refresh_loop, daemon=True).start()

    def factory():
        with lock:
            return dict(state)

    server = ThreadingHTTPServer((bind, port), dashboard_handler(factory))
    print(f"client dashboard: http://{bind}:{port}/ (Ctrl-C to stop)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--window", type=int, default=300,
                        help="access-log window in seconds (default 300)")
    parser.add_argument("--json", action="store_true",
                        help="emit machine-readable JSON instead of text")
    parser.add_argument("--serve", action="store_true",
                        help="run the dialog-style web dashboard (loopback only)")
    parser.add_argument("--tui", action="store_true",
                        help="full-screen live dashboard inside this terminal")
    parser.add_argument("--bind", default="127.0.0.1",
                        help="dashboard bind address (default 127.0.0.1)")
    parser.add_argument("--port", type=int, default=None,
                        help="dashboard port (default STATS_PORT from runtime.env or 17898)")
    parser.add_argument("--config", help="config.json path override")
    parser.add_argument("--log", default=os.environ.get("RK_VPN_ACCESS_LOG", DEFAULT_LOG),
                        help="access log path override")
    args = parser.parse_args()
    if args.window <= 0:
        parser.error("--window must be positive")
    if args.config is None and not Path(__file__).with_name("config.json").is_file() \
            and Path(DEPLOYED_CONFIG).is_file():
        # The deployed copy has no config.json next to it; use the one the
        # installer maintains under /etc.
        args.config = DEPLOYED_CONFIG
    config = load_config(args.config)
    if args.tui:
        run_tui(config, args.log, args.window)
        return
    if args.serve:
        port = args.port
        if port is None:
            port = int(os.environ.get("STATS_PORT") or 0) or 17898
        serve(config, args.log, args.window, args.bind, port)
        return
    snapshot = collect(config, args.log, args.window)
    if args.json:
        print(json.dumps(snapshot, indent=2))
    else:
        print(render(snapshot, args.log))


if __name__ == "__main__":
    main()
