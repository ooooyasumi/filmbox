#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Reuse a completed app build. These checks create no windows and contact no
# account; they verify that browsing an uncached cloud WebM remains passive.
BINARY_DIR="${FILMBOX_CHECK_BINARY_DIR:-$PROJECT_DIR/.build/debug}"
python3 "$SCRIPT_DIR/run-app-check.py" "$BINARY_DIR" \
    Tests/FilmboxCloudWebMIntentChecks/CheckRunner.swift FilmboxCloudWebMIntentChecks
