#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"
if [[ -z "${FILMBOX_CHECK_BINARY_DIR:-}" ]]; then
    swift build -c debug
    FILMBOX_CHECK_BINARY_DIR="$(swift build -c debug --show-bin-path)"
fi
python3 scripts/run-app-check.py "$FILMBOX_CHECK_BINARY_DIR" Tests/FilmboxRefreshChecks/CheckRunner.swift FilmboxRefreshChecks
