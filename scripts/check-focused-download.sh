#!/bin/bash
set -euo pipefail
FILMBOX_FOCUS_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_FOCUS_ROOT"
# Reuse a completed Debug build; never run a second SwiftPM alongside the app.
FILMBOX_FOCUS_BINARY_DIR="${1:-.build/arm64-apple-macosx/debug}"
FILMBOX_FOCUS_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filmbox-focused-download.XXXXXX")"
trap 'rm -rf -- "$FILMBOX_FOCUS_TEMP"' EXIT
python3 - "$FILMBOX_FOCUS_BINARY_DIR" "$FILMBOX_FOCUS_TEMP" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys

binary_dir = Path(sys.argv[1]).resolve()
temporary = Path(sys.argv[2]).resolve()
bundle = temporary / "FocusedDownloadChecks.app"
macos = bundle / "Contents" / "MacOS"
macos.mkdir(parents=True)
with (bundle / "Contents" / "Info.plist").open("wb") as output:
    plistlib.dump({
        "CFBundleIdentifier": "com.filmbox.focused-download-checks",
        "CFBundleExecutable": "FocusedDownloadChecks",
        "CFBundlePackageType": "APPL",
        "FilmboxDevelopmentCache": str(temporary / "isolated-cache"),
    }, output)
runner = temporary / "CheckRunner.swift"
runner.write_text("@testable import Filmbox\n" + Path("Tests/FilmboxFocusedDownloadChecks/CheckRunner.swift").read_text())
objects = [p for p in sorted((binary_dir / "Filmbox.build").glob("*.o")) if p.name != "FilmboxApp.swift.o"]
objects += sorted((binary_dir / "FilmboxCore.build").glob("*.o"))
if not objects or not (binary_dir / "Modules" / "Filmbox.swiftmodule").exists():
    raise SystemExit("Missing complete Debug app objects; run swift build first.")
executable = macos / "FocusedDownloadChecks"
subprocess.run(["swiftc", "-swift-version", "6", "-D", "DEBUG", "-parse-as-library", "-module-name", "FocusedDownloadChecks",
    "-I", str(binary_dir / "Modules"), str(runner), *map(str, objects), "-o", str(executable)], check=True, timeout=45)
fixture = subprocess.Popen([sys.executable, "Tests/FilmboxFocusedDownloadChecks/fixture.py"], stdout=subprocess.PIPE, text=True)
try:
    endpoint = fixture.stdout.readline().strip()
    subprocess.run([str(executable), endpoint], check=True, timeout=50)
finally:
    fixture.terminate()
    fixture.wait(timeout=5)
PY
