#!/usr/bin/env python3
"""Slow, synthetic WebDAV originals; records actual socket cancellation."""
import base64
import http.server
import json
import struct
import threading
import time
import zlib


def chunk(kind, value):
    return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value))


# Uncompressed PNG keeps a valid, visibly larger original in flight long enough
# to exercise the real URLSession -> helper proxy -> WebDAV cancellation path.
ROW = b'\x00' + bytes((70, 120, 180)) * 1600
PHOTO = (b'\x89PNG\r\n\x1a\n'
         + chunk(b'IHDR', struct.pack('>IIBBBBB', 1600, 1000, 8, 2, 0, 0, 0))
         + chunk(b'IDAT', zlib.compress(ROW * 1000, level=0)) + chunk(b'IEND', b''))
AUTH = 'Basic ' + base64.b64encode(b'filmbox:focused-download-fixture').decode()
STATE = {'size': len(PHOTO), 'files': {}}
LOCK = threading.Lock()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def authorized(self):
        if self.headers.get('Authorization') == AUTH:
            return True
        self.send_error(401)
        return False

    def do_PROPFIND(self):
        if not self.authorized():
            return
        body = (b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/</d:href>'
                b'<d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype>'
                b'</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>'
                b'</d:response></d:multistatus>')
        self.send_response(207)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/stats':
            with LOCK:
                body = json.dumps(STATE).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if not self.authorized():
            return
        if not self.path.startswith('/dav/') or not self.path.endswith('.png'):
            self.send_error(404)
            return
        name = self.path.rsplit('/', 1)[-1]
        with LOCK:
            records = STATE['files'].setdefault(name, [])
            record = {'bytes': 0, 'closed': False, 'complete': False}
            records.append(record)
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'image/png')
            self.send_header('Content-Length', str(len(PHOTO)))
            self.end_headers()
            for offset in range(0, len(PHOTO), 32768):
                body = PHOTO[offset:offset + 32768]
                self.wfile.write(body)
                self.wfile.flush()
                with LOCK:
                    record['bytes'] += len(body)
                if offset + len(body) < len(PHOTO):
                    time.sleep(.02)
            with LOCK:
                record['complete'] = True
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with LOCK:
                record['closed'] = True


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(f'http://127.0.0.1:{server.server_port}', flush=True)
server.serve_forever()
