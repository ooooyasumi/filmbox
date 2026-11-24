#!/bin/bash
set -euo pipefail
FILMBOX_KEYCHAIN_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_KEYCHAIN_ROOT"
FILMBOX_KEYCHAIN_WORK="$(mktemp -d "$FILMBOX_KEYCHAIN_ROOT/.build/KeychainChecks.XXXXXX")"
FILMBOX_KEYCHAIN_ID="$(uuidgen)"
FILMBOX_KEYCHAIN_DOMAIN="com.filmbox.keychain-checks.$(uuidgen | tr '[:upper:]' '[:lower:]')"
FILMBOX_KEYCHAIN_APP="$FILMBOX_KEYCHAIN_WORK/Probe.app"
FILMBOX_KEYCHAIN_EXECUTABLE="$FILMBOX_KEYCHAIN_APP/Contents/MacOS/Probe"
mkdir -p "$FILMBOX_KEYCHAIN_APP/Contents/MacOS"
cat > "$FILMBOX_KEYCHAIN_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$FILMBOX_KEYCHAIN_DOMAIN</string><key>CFBundleExecutable</key><string>Probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
cat Sources/Filmbox/CloudGateway.swift Tests/FilmboxKeychainChecks/CheckRunner.swift > "$FILMBOX_KEYCHAIN_WORK/GatewayChecks.swift"
compile_variant() {
    local variant="$1"
    shift
    swiftc -swift-version 6 -D DEBUG -parse-as-library "$@" \
        -I .build/arm64-apple-macosx/debug/Modules "$FILMBOX_KEYCHAIN_WORK/GatewayChecks.swift" \
        Sources/Filmbox/MediaLoadingText.swift Sources/Filmbox/CloudTransferCenter.swift Sources/Filmbox/MediaAssetResolver.swift Sources/Filmbox/CloudPreviewMetadata.swift \
        .build/arm64-apple-macosx/debug/FilmboxCore.build/*.o -o "$FILMBOX_KEYCHAIN_WORK/$variant"
}
compile_variant old
compile_variant new -D KEYCHAIN_NEW_SIGNATURE
install_variant() {
    cp "$FILMBOX_KEYCHAIN_WORK/$1" "$FILMBOX_KEYCHAIN_EXECUTABLE"
    codesign --force --sign - --identifier "$FILMBOX_KEYCHAIN_DOMAIN" "$FILMBOX_KEYCHAIN_APP" >/dev/null 2>&1
}
cleanup() {
    install_variant new
    "$FILMBOX_KEYCHAIN_EXECUTABLE" remove "$FILMBOX_KEYCHAIN_ID" >/dev/null 2>&1 || true
    install_variant old
    "$FILMBOX_KEYCHAIN_EXECUTABLE" cleanup "$FILMBOX_KEYCHAIN_ID" >/dev/null 2>&1 || true
    install_variant new
    "$FILMBOX_KEYCHAIN_EXECUTABLE" bound "$FILMBOX_KEYCHAIN_ID" >/dev/null 2>&1 || true
    rm -rf -- "$FILMBOX_KEYCHAIN_WORK"
}
trap cleanup EXIT
install_variant old
"$FILMBOX_KEYCHAIN_EXECUTABLE" write "$FILMBOX_KEYCHAIN_ID"
install_variant new
"$FILMBOX_KEYCHAIN_EXECUTABLE" denied "$FILMBOX_KEYCHAIN_ID"
"$FILMBOX_KEYCHAIN_EXECUTABLE" recover "$FILMBOX_KEYCHAIN_ID"
"$FILMBOX_KEYCHAIN_EXECUTABLE" remove "$FILMBOX_KEYCHAIN_ID"
install_variant old
"$FILMBOX_KEYCHAIN_EXECUTABLE" cleanup "$FILMBOX_KEYCHAIN_ID"
install_variant new
"$FILMBOX_KEYCHAIN_EXECUTABLE" bound "$FILMBOX_KEYCHAIN_ID"
"$FILMBOX_KEYCHAIN_EXECUTABLE" rotation "$FILMBOX_KEYCHAIN_ID"
cat > "$FILMBOX_KEYCHAIN_WORK/session-engine.py" <<'PY'
#!/usr/bin/env python3
import http.server
import json

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        status = 200
        if self.path == "/v1/accounts/connect":
            status = 503
            value = {"error": "synthetic-temporary", "code": "service_unavailable", "credential": "synthetic-error-rotation", "credential_revision": 3}
        elif self.path == "/v1/files/list":
            value = {"entries": [], "folder_id": "0", "path": "/", "credential": "synthetic-playback", "credential_revision": 20}
        elif self.path == "/v1/accounts/credential":
            value = {"credential": "synthetic-asset-refresh", "credential_revision": 30}
        else:
            value = {"session_id": "synthetic", "received_bytes": 0, "received_by_day": {}, "active_streams": 0}
        payload = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(json.dumps({"port": server.server_port}), flush=True)
server.serve_forever()
PY
chmod +x "$FILMBOX_KEYCHAIN_WORK/session-engine.py"
FILMBOX_CLOUD_ENGINE="$FILMBOX_KEYCHAIN_WORK/session-engine.py" "$FILMBOX_KEYCHAIN_EXECUTABLE" connect-failure "$FILMBOX_KEYCHAIN_ID"
printf 'Keychain signature/explicit-reconnect/blocked-worker/ordered-rotation checks passed; only random test items used.\n'
