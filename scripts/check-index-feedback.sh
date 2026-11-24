#!/bin/bash
set -euo pipefail
FILMBOX_FEEDBACK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_FEEDBACK_ROOT"
if [[ -n "${FILMBOX_CHECK_BINARY_DIR:-}" ]]; then
    FILMBOX_FEEDBACK_BINARY_DIR="$FILMBOX_CHECK_BINARY_DIR"
else
    swift build -c debug
    FILMBOX_FEEDBACK_BINARY_DIR="$(swift build -c debug --show-bin-path)"
fi
python3 scripts/run-app-check.py "$FILMBOX_FEEDBACK_BINARY_DIR" Tests/FilmboxIndexFeedbackChecks/CheckRunner.swift FilmboxIndexFeedbackChecks
