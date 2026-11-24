#!/bin/bash
set -euo pipefail
FILMBOX_RECOVERY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_RECOVERY_ROOT"
swift build -c debug
FILMBOX_RECOVERY_BIN="$(swift build -c debug --show-bin-path)"
python3 scripts/run-app-check.py "$FILMBOX_RECOVERY_BIN" Tests/FilmboxRecoveryChecks/CheckRunner.swift FilmboxRecoveryChecks
