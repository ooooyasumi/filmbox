#!/bin/bash
set -euo pipefail
FILMBOX_BACKEND_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_BACKEND_ROOT"
FILMBOX_BACKEND_BIN="$FILMBOX_BACKEND_ROOT/.build/$(uname -m)-apple-macosx/debug"
FILMBOX_BACKEND_WORK="$(mktemp -d "$FILMBOX_BACKEND_ROOT/.build/BackendChecks.XXXXXX")"
trap 'python3 -c '\''import pathlib,shutil,sys;p=pathlib.Path(sys.argv[1]);shutil.rmtree(p) if p.is_dir() and not p.is_symlink() else None'\'' "$FILMBOX_BACKEND_WORK"' EXIT
cat Sources/Filmbox/CloudGateway.swift Sources/Filmbox/MediaLoadingText.swift Sources/Filmbox/CloudTransferCenter.swift \
    Sources/Filmbox/MediaAssetResolver.swift Tests/FilmboxBackendChecks/CheckRunner.swift \
    > "$FILMBOX_BACKEND_WORK/BackendChecks.swift"
swiftc -swift-version 6 -O -D DEBUG -parse-as-library -I "$FILMBOX_BACKEND_BIN/Modules" \
    "$FILMBOX_BACKEND_WORK/BackendChecks.swift" Sources/Filmbox/CloudPreviewMetadata.swift \
    "$FILMBOX_BACKEND_BIN/FilmboxCore.build/"*.o -o "$FILMBOX_BACKEND_WORK/BackendChecks"
"$FILMBOX_BACKEND_WORK/BackendChecks"
