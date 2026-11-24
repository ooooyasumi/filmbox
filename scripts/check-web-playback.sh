#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd -- "$PROJECT_DIR"

# Reuse an existing complete app build to avoid competing SwiftPM processes.
# --reuse-core remains a compatibility alias, but now also needs app objects.
if [[ "${1:-}" == "--reuse-app" || "${1:-}" == "--reuse-core" ]]; then
    BINARY_DIR="${2:-$PROJECT_DIR/.build/debug}"
else
    swift build -c debug
    BINARY_DIR="$(swift build -c debug --show-bin-path)"
fi
python3 "$SCRIPT_DIR/run-app-check.py" "$BINARY_DIR" \
    Tests/FilmboxWebPlaybackChecks/CheckRunner.swift FilmboxWebPlaybackChecks "$PROJECT_DIR/Tests/Fixtures"
