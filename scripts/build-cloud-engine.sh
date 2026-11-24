#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
set -eu

FILMBOX_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FILMBOX_GO=${FILMBOX_GO:-/usr/local/go/bin/go}
if [ ! -x "$FILMBOX_GO" ]; then
  FILMBOX_GO=$(command -v go || true)
fi
if [ -z "$FILMBOX_GO" ]; then
  echo "Go 1.23 or newer is required to build the bundled cloud engine." >&2
  exit 1
fi

FILMBOX_ENGINE_OS=${FILMBOX_ENGINE_OS:-darwin}
case "$FILMBOX_ENGINE_OS" in darwin|android) ;; *) echo "Supported cloud engine targets: darwin, android" >&2; exit 1 ;; esac
FILMBOX_INSTALL="$FILMBOX_ROOT/.build/CloudEngine/install"
if [ "$FILMBOX_ENGINE_OS" = android ]; then FILMBOX_INSTALL="$FILMBOX_ROOT/.build/CloudEngine/android-arm64"; fi
FILMBOX_ENGINE_ARCH=${FILMBOX_ENGINE_ARCH:-arm64}
mkdir -p "$FILMBOX_INSTALL"
cd "$FILMBOX_ROOT/CloudEngine"
GOTOOLCHAIN=local "$FILMBOX_GO" test ./...
CGO_ENABLED=0 GOOS="$FILMBOX_ENGINE_OS" GOARCH="$FILMBOX_ENGINE_ARCH" GOTOOLCHAIN=local \
  "$FILMBOX_GO" build -trimpath -ldflags='-s -w -buildid=' -o "$FILMBOX_INSTALL/filmbox-cloud-engine" .

# Complete corresponding source: this module has no third-party module
# dependencies. Included originals, license, build script and tests reproduce it.
cd "$FILMBOX_ROOT"
python3 "$FILMBOX_ROOT/scripts/record-cloud-build.py" "$FILMBOX_INSTALL/filmbox-cloud-engine" --platform "$FILMBOX_ENGINE_OS/$FILMBOX_ENGINE_ARCH" --output "$FILMBOX_INSTALL/engine-build.json"
COPYFILE_DISABLE=1 tar --exclude='.DS_Store'  -czf "$FILMBOX_INSTALL/filmbox-cloud-engine-source.tar.gz" \
  CloudEngine scripts/build-cloud-engine.sh scripts/record-cloud-build.py -C "$FILMBOX_INSTALL" engine-build.json
cp "$FILMBOX_ROOT/CloudEngine/LICENSE" "$FILMBOX_INSTALL/LICENSE"
cp "$FILMBOX_ROOT/CloudEngine/UPSTREAM.md" "$FILMBOX_INSTALL/UPSTREAM.md"
echo "Cloud Engine built: $FILMBOX_INSTALL/filmbox-cloud-engine"
