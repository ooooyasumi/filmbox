#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd -- "$PROJECT_DIR"

# Build/reuse only our pinned runtime and Core; no app or user-installed codec
# executable is used. The small checked-in media fixtures are wholly synthetic.
"$SCRIPT_DIR/build-codec-runtime.sh"
swift build -c debug
BINARY_DIR="$(swift build -c debug --show-bin-path)"
python3 "$SCRIPT_DIR/run-app-check.py" "$BINARY_DIR" Tests/FilmboxCompatibilityChecks/CheckRunner.swift FilmboxCompatibilityChecks "$PROJECT_DIR/Tests/Fixtures"
