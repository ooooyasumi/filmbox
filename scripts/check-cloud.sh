#!/bin/bash
set -euo pipefail

FILMBOX_CHECK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_CHECK_ROOT"

"$FILMBOX_CHECK_ROOT/scripts/build-cloud-engine.sh"
swift build --target FilmboxCore
FILMBOX_CHECK_BINARY_DIR="$(swift build --show-bin-path)"
mkdir -p .build/FilmboxCloudChecks
swiftc -swift-version 6 -D DEBUG -parse-as-library \
    -I "$FILMBOX_CHECK_BINARY_DIR/Modules" \
    Sources/Filmbox/AppStore.swift \
    Sources/Filmbox/LocalPhotoRotation.swift \
    Sources/Filmbox/AppStoreCloud.swift \
    Sources/Filmbox/CloudGateway.swift \
    Sources/Filmbox/MediaLoadingText.swift Sources/Filmbox/CloudTransferCenter.swift \
    Sources/Filmbox/CloudMetadataUpdates.swift \
    Sources/Filmbox/CloudLibraryScanner.swift \
    Sources/Filmbox/CloudIndexStore.swift \
    Sources/Filmbox/CloudPreviewMetadata.swift \
    Sources/Filmbox/MediaAssetResolver.swift \
    Sources/Filmbox/MediaServices.swift \
    Sources/Filmbox/ThumbnailDecoder.swift \
    Tests/FilmboxCloudChecks/CheckRunner.swift \
    "$FILMBOX_CHECK_BINARY_DIR/FilmboxCore.build/"*.o \
    -o .build/FilmboxCloudChecks/FilmboxCloudChecks

FILMBOX_CHECK_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filmbox-cloud-check.XXXXXX")"
FILMBOX_CHECK_SERVER_PID=""
cleanup() {
    if [[ -n "$FILMBOX_CHECK_SERVER_PID" ]]; then
        kill "$FILMBOX_CHECK_SERVER_PID" 2>/dev/null || true
        wait "$FILMBOX_CHECK_SERVER_PID" 2>/dev/null || true
    fi
    rm -rf -- "$FILMBOX_CHECK_TEMP"
}
trap cleanup EXIT

# The mock listens only on loopback and contains synthetic media. It never
# accesses an existing account, catalogue, clipboard or user media directory.
python3 - "$FILMBOX_CHECK_TEMP/endpoint" <<'PY' &
import base64
import html
import http.server
import json
import pathlib
import sys
import struct
import threading
import time
import urllib.parse
import zlib

def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

PNG = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0))
       + png_chunk(b'IDAT', zlib.compress(b'\x00\x20\x60\xa0\x80\xa0\xc0' * 2)) + png_chunk(b'IEND', b''))
VIDEO = b'0123456789abcdefghijklmnopqrstuvwxyz'
FILES = {
    '/Cloud photo.png': PNG,
    '/Clip.mp4': VIDEO,
    '/Trips/Sunset #1.png': PNG,
    '/Trips-old/Neighbor.png': PNG,
    '/readme.txt': b'not media',
}
DIRECTORIES = {'/', '/Trips', '/Trips-old'}
STATE = {'offline': False, 'slow': False, 'gets': 0, 'ranges': 0, 'propfinds': 0, 'auth_failures': 0}
LOCK = threading.Lock()
AUTH = 'Basic ' + base64.b64encode(b'photos:filmbox-test-password').decode()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, status, data=b'', content_type='application/octet-stream', extra=None):
        self.send_response(status)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Content-Type', content_type)
        self.send_header('Connection', 'close')
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(data)

    def control(self, path):
        if not path.startswith('/control/'):
            return False
        with LOCK:
            if path == '/control/offline':
                STATE['offline'] = True
            elif path == '/control/online':
                STATE['offline'] = False
            elif path == '/control/slow':
                STATE['slow'] = True
            elif path == '/control/fast':
                STATE['slow'] = False
            result = dict(STATE)
        self.reply(200, json.dumps(result).encode(), 'application/json')
        return True

    def authorized(self):
        if self.headers.get('Authorization') != AUTH:
            with LOCK:
                STATE['auth_failures'] += 1
            self.reply(401, extra={'WWW-Authenticate': 'Basic realm="Synthetic Filmbox fixture"'})
            return False
        with LOCK:
            offline = STATE['offline']
        if offline:
            self.reply(503)
            return False
        return True

    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if not self.authorized():
            return
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        directory = path.removeprefix('/dav').rstrip('/') or '/'
        if directory not in DIRECTORIES:
            self.reply(404)
            return
        with LOCK:
            STATE['propfinds'] += 1
            slow = STATE['slow']
        if slow:
            time.sleep(0.2)
        entries = []
        for child in sorted(DIRECTORIES | set(FILES)):
            if child == directory or (str(pathlib.PurePosixPath(child).parent) != directory and child != '/'):
                continue
            if child == '/':
                continue
            is_directory = child in DIRECTORIES
            name = pathlib.PurePosixPath(child).name
            href = urllib.parse.quote('/dav' + child, safe='/') + ('/' if is_directory else '')
            resource = '<d:collection/>' if is_directory else ''
            size = 0 if is_directory else len(FILES[child])
            entries.append(f'<d:response><d:href>{html.escape(href)}</d:href><d:propstat><d:prop>'
                           f'<d:displayname>{html.escape(name)}</d:displayname><d:resourcetype>{resource}</d:resourcetype>'
                           f'<d:getcontentlength>{size}</d:getcontentlength>'
                           '<d:getlastmodified>Tue, 17 Jun 2025 08:30:00 GMT</d:getlastmodified>'
                           '<d:creationdate>2025-06-17T08:30:00Z</d:creationdate>'
                           '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>')
        self.reply(207, ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">' + ''.join(entries) + '</d:multistatus>').encode(), 'application/xml')

    def do_GET(self):
        path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
        if self.control(path):
            return
        if not self.authorized():
            return
        relative = path.removeprefix('/dav')
        with LOCK:
            STATE['gets'] += 1
        if relative == '/login-error.png':
            self.reply(200, b'<html>synthetic expired login</html>', 'text/html')
            return
        if relative not in FILES:
            self.reply(404)
            return
        data = FILES[relative]
        content_type = 'image/png' if relative.endswith('.png') else 'video/mp4'
        requested_range = self.headers.get('Range', '')
        if requested_range.startswith('bytes='):
            start, _, end = requested_range[6:].partition('-')
            start = int(start)
            end = min(len(data) - 1, int(end) if end else len(data) - 1)
            with LOCK:
                STATE['ranges'] += 1
            self.reply(206, data[start:end + 1], content_type,
                       {'Content-Range': f'bytes {start}-{end}/{len(data)}', 'Accept-Ranges': 'bytes'})
        else:
            self.reply(200, data, content_type, {'Accept-Ranges': 'bytes'})

    def do_HEAD(self):
        self.do_GET()

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(f'http://127.0.0.1:{server.server_address[1]}/dav')
server.serve_forever()
PY
FILMBOX_CHECK_SERVER_PID=$!
for ((FILMBOX_CHECK_ATTEMPT=0; FILMBOX_CHECK_ATTEMPT<100; FILMBOX_CHECK_ATTEMPT++)); do
    [[ -s "$FILMBOX_CHECK_TEMP/endpoint" ]] && break
    kill -0 "$FILMBOX_CHECK_SERVER_PID" 2>/dev/null || { echo "Mock WebDAV failed to start." >&2; exit 1; }
    sleep 0.05
done
[[ -s "$FILMBOX_CHECK_TEMP/endpoint" ]] || { echo "Mock WebDAV startup timed out." >&2; exit 1; }

.build/FilmboxCloudChecks/FilmboxCloudChecks "$(cat "$FILMBOX_CHECK_TEMP/endpoint")"
