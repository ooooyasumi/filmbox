#!/bin/bash
set -euo pipefail
FILMBOX_LOGIN_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_LOGIN_ROOT"
FILMBOX_LOGIN_CHECKS=".build/FilmboxLoginChecks"
mkdir -p "$FILMBOX_LOGIN_CHECKS"
swiftc -swift-version 6 -parse-as-library \
    Sources/Filmbox/QuarkLoginCredential.swift \
    Tests/FilmboxLoginChecks/CheckRunner.swift \
    -o "$FILMBOX_LOGIN_CHECKS/FilmboxLoginChecks"
"$FILMBOX_LOGIN_CHECKS/FilmboxLoginChecks"
