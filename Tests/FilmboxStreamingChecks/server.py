"""A gated, authenticated loopback source; never accesses production files."""
import http.server
import json
import pathlib
import re
import threading
import time
import urllib.parse


class MediaServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self, file):
        self.file = pathlib.Path(file)
        self.length = self.file.stat().st_size
        self.gate = self.length // 5
        self.bytes = self.active = self.requests = self.aborted = 0
        self.lock = threading.Condition()
        super().__init__(("127.0.0.1", 0), Handler)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            pass  # Players close speculative range requests when seeking/stopping.

    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.media(head=True)

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path in ("/control", "/stats"):
            with self.server.lock:
                if parsed.path == "/control":
                    mode = urllib.parse.parse_qs(parsed.query).get("mode", [""])[0]
                    self.server.gate = self.server.length if mode == "open" else self.server.length // 5
                    self.server.lock.notify_all()
                body = json.dumps({"bytes": self.server.bytes, "length": self.server.length,
                    "active": self.server.active, "requests": self.server.requests, "aborted": self.server.aborted}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.media()

    def media(self, head=False):
        if self.path != "/video.mp4" or self.headers.get("Authorization") != "Bearer synthetic-stream-check":
            self.send_error(403)
            return
        total = self.server.length
        start, end = 0, total - 1
        value = self.headers.get("Range")
        if value:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
            if not match:
                self.send_error(416)
                return
            if match[1]:
                start = int(match[1])
                end = min(end, int(match[2])) if match[2] else end
            elif match[2]:
                start = max(0, total - int(match[2]))
            if start >= total or end < start:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{total}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
        self.send_response(206 if value else 200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if value:
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
        self.end_headers()
        if head:
            return
        with self.server.lock:
            self.server.active += 1
            self.server.requests += 1
        try:
            time.sleep(0.35)
            with self.server.file.open("rb") as file:
                file.seek(start)
                cursor = start
                while cursor <= end:
                    with self.server.lock:
                        while cursor >= self.server.gate:
                            self.server.lock.wait(timeout=0.1)
                        allowed = min(32768, end - cursor + 1, self.server.gate - cursor)
                    data = file.read(allowed)
                    if not data:
                        break
                    self.wfile.write(data)
                    self.wfile.flush()
                    cursor += len(data)
                    with self.server.lock:
                        self.server.bytes += len(data)
                    time.sleep(0.002)
        except (OSError, ConnectionError):
            with self.server.lock:
                self.server.aborted += 1
        finally:
            with self.server.lock:
                self.server.active -= 1
