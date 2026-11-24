#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
cd "$PROJECT_DIR"
swift build -c debug
BINARY_DIR="$(swift build -c debug --show-bin-path)"
python3 "$SCRIPT_DIR/run-app-check.py" "$BINARY_DIR" Tests/FilmboxViewerLoadingChecks/CheckRunner.swift FilmboxViewerLoadingChecks
