#!/bin/bash
set -euo pipefail
FILMBOX_ORIGINAL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_ORIGINAL_ROOT"
# Reuse a completed Debug build; no concurrent SwiftPM or cloud helper needed.
FILMBOX_ORIGINAL_BINARY_DIR="${1:-.build/arm64-apple-macosx/debug}"
python3 scripts/run-app-check.py "$FILMBOX_ORIGINAL_BINARY_DIR" \
    Tests/FilmboxOriginalCacheChecks/CheckRunner.swift FilmboxOriginalCacheChecks
