#!/usr/bin/env python3
"""Read-only loopback fixture for native Filmbox cloud integration QA.

Usage: python3 mock_webdav.py --directory /absolute/fixture/media
Prints one JSON connection object. Credentials are fixed test-only values.
Never point this at a user's cloud cache or private production media.
"""
import argparse
import base64
import email.utils
import http.server
import json
import mimetypes
import pathlib
import re
import urllib.parse
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True, type=pathlib.Path)
    parser.add_argument("--port", type=int, default=0)
    args = parser.parse_args()
    root = args.directory.resolve(strict=True)
    if not root.is_dir():
        parser.error("directory must be an existing fixture directory")
    username, password = "filmbox", "fixture-only"
    authorization = "Basic " + base64.b64encode(f"{username}:{password}".encode()).decode()
    ET.register_namespace("d", "DAV:")

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def target(self):
            if self.headers.get("Authorization") != authorization:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="Filmbox fixture"')
                self.end_headers()
                return None
            path = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path)
            if not path.startswith("/dav/"):
                self.send_error(404)
                return None
            target = (root / path.removeprefix("/dav/")).resolve()
            if target != root and root not in target.parents:
                self.send_error(403)
                return None
            if not target.exists():
                self.send_error(404)
                return None
            return target

        def do_PROPFIND(self):
            target = self.target()
            if target is None:
                return
            # Consume request body so keep-alive implementations remain valid.
            self.rfile.read(min(int(self.headers.get("Content-Length", 0)), 1048576))
            multistatus = ET.Element("{DAV:}multistatus")
            children = [target] + (sorted(target.iterdir()) if target.is_dir() else [])
            for child in children:
                if child.name.startswith("."):
                    continue
                response = ET.SubElement(multistatus, "{DAV:}response")
                relative = str(child.relative_to(root))
                if relative == ".":
                    relative = ""
                href = "/dav/" + urllib.parse.quote(relative)
                if child.is_dir() and not href.endswith("/"):
                    href += "/"
                ET.SubElement(response, "{DAV:}href").text = href
                propstat = ET.SubElement(response, "{DAV:}propstat")
                prop = ET.SubElement(propstat, "{DAV:}prop")
                ET.SubElement(prop, "{DAV:}displayname").text = child.name
                resource = ET.SubElement(prop, "{DAV:}resourcetype")
                if child.is_dir():
                    ET.SubElement(resource, "{DAV:}collection")
                stat = child.stat()
                ET.SubElement(prop, "{DAV:}getcontentlength").text = str(stat.st_size)
                ET.SubElement(prop, "{DAV:}getlastmodified").text = email.utils.formatdate(stat.st_mtime, usegmt=True)
                ET.SubElement(propstat, "{DAV:}status").text = "HTTP/1.1 200 OK"
            body = ET.tostring(multistatus, encoding="utf-8", xml_declaration=True)
            self.send_response(207)
            self.send_header("Content-Type", "application/xml")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def media(self):
            target = self.target()
            if target is None:
                return
            if not target.is_file():
                self.send_error(404)
                return
            length = target.stat().st_size
            first, last = 0, length - 1
            partial = False
            if value := self.headers.get("Range"):
                match = re.fullmatch(r"bytes=(\d*)-(\d*)", value)
                if not match:
                    self.send_error(416)
                    return
                a, b = match.groups()
                if a:
                    first = int(a)
                    last = min(int(b), last) if b else last
                elif b:
                    first = max(0, length - int(b))
                if first > last or first >= length:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{length}")
                    self.end_headers()
                    return
                partial = True
            self.send_response(206 if partial else 200)
            self.send_header("Content-Type", mimetypes.guess_type(str(target))[0] or "application/octet-stream")
            self.send_header("Content-Length", str(last - first + 1))
            self.send_header("Accept-Ranges", "bytes")
            if partial:
                self.send_header("Content-Range", f"bytes {first}-{last}/{length}")
            self.end_headers()
            if self.command == "HEAD":
                return
            with target.open("rb") as stream:
                stream.seek(first)
                remaining = last - first + 1
                try:
                    while remaining:
                        data = stream.read(min(65536, remaining))
                        if not data:
                            break
                        self.wfile.write(data)
                        remaining -= len(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        do_GET = media
        do_HEAD = media

    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(json.dumps({"endpoint": f"http://127.0.0.1:{server.server_port}/dav/", "username": username, "password": password}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
