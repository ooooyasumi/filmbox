#!/usr/bin/env python3
"""Synthetic, read-only loopback fixture for transfer progress and traffic tests."""
import base64, http.server, json, threading, time, urllib.parse, sys
SIZE = 4 * 1024 * 1024
AUTH = 'Basic ' + base64.b64encode(b'filmbox:transfer-fixture').decode()
STATE = {'gets': 0, 'active': 0, 'maximum': 0, 'bytes': 0,
         'requests': 0, 'propfinds': 0, 'auth_failures': 0, 'expired': False, 'unavailable': False}
LOCK = threading.Lock()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def authorized(self):
        with LOCK:
            STATE['requests'] += 1
            rejected = (self.headers.get('Authorization') != AUTH
                        or (STATE['expired'] and self.path.startswith('/dav/')))
            unavailable = STATE['unavailable'] and self.path.startswith('/dav/')
            if rejected: STATE['auth_failures'] += 1
        if rejected: self.send_error(401); return False
        if unavailable: self.send_error(503); return False
        return True
    def do_PROPFIND(self):
        if not self.authorized(): return
        with LOCK: STATE['propfinds'] += 1
        body = b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>'
        self.send_response(207); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path in ['/stats', '/control/expired', '/control/online', '/control/unavailable', '/control/available']:
            with LOCK:
                if self.path == '/control/expired': STATE['expired'] = True
                elif self.path == '/control/online': STATE['expired'] = False
                elif self.path == '/control/unavailable': STATE['unavailable'] = True
                elif self.path == '/control/available': STATE['unavailable'] = False
                body = json.dumps(STATE).encode()
            self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body); return
        if not self.authorized(): return
        if self.path == '/dav/no-access.png': self.send_error(403); return
        first,last = 0,SIZE-1
        if r := self.headers.get('Range'):
            start,end = r.removeprefix('bytes=').split('-'); first = int(start); last = min(last,int(end) if end else last)
        with LOCK: STATE['gets'] += 1; STATE['active'] += 1; STATE['maximum'] = max(STATE['maximum'],STATE['active'])
        try:
            self.send_response(206 if self.headers.get('Range') else 200)
            self.send_header('Content-Type','application/octet-stream'); self.send_header('Content-Length',str(last-first+1)); self.send_header('Accept-Ranges','bytes')
            if self.headers.get('Range'): self.send_header('Content-Range',f'bytes {first}-{last}/{SIZE}')
            self.end_headers()
            remaining = last-first+1
            while remaining:
                data = b'x' * min(32768,remaining)
                self.wfile.write(data); self.wfile.flush()
                with LOCK: STATE['bytes'] += len(data)
                remaining -= len(data)
                if remaining: time.sleep(.01)
        except (BrokenPipeError,ConnectionResetError): pass
        finally:
            with LOCK: STATE['active'] -= 1
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(f'http://127.0.0.1:{server.server_port}',flush=True)
server.serve_forever()
