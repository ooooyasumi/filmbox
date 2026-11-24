#!/bin/bash
set -euo pipefail
FILMBOX_FILTER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_FILTER_ROOT"
if [[ -n "${FILMBOX_FILTER_BINARY_DIR:-}" ]]; then
    FILMBOX_FILTER_BINARY_PATH="$FILMBOX_FILTER_BINARY_DIR"
else
    swift build -c debug
    FILMBOX_FILTER_BINARY_PATH="$(swift build -c debug --show-bin-path)"
fi
python3 scripts/run-app-check.py "$FILMBOX_FILTER_BINARY_PATH" Tests/FilmboxFilterChecks/CheckRunner.swift FilmboxFilterChecks
