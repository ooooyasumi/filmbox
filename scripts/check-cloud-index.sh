#!/bin/bash
set -euo pipefail
FILMBOX_INDEX_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_INDEX_ROOT"
swift build --target FilmboxCore
FILMBOX_INDEX_BINARY_DIR="$(swift build --show-bin-path)"
mkdir -p .build/FilmboxCloudIndexChecks
swiftc -swift-version 6 -parse-as-library \
    -I "$FILMBOX_INDEX_BINARY_DIR/Modules" \
    Sources/Filmbox/AppStore.swift \
    Sources/Filmbox/LocalPhotoRotation.swift \
    Sources/Filmbox/CloudLibraryScanner.swift \
    Sources/Filmbox/CloudIndexStore.swift \
    Tests/FilmboxCloudIndexChecks/CheckRunner.swift \
    "$FILMBOX_INDEX_BINARY_DIR/FilmboxCore.build/"*.o \
    -o .build/FilmboxCloudIndexChecks/FilmboxCloudIndexChecks
.build/FilmboxCloudIndexChecks/FilmboxCloudIndexChecks
