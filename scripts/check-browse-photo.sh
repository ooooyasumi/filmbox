#!/bin/bash
set -euo pipefail
FILMBOX_BROWSE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_BROWSE_ROOT"
# Reuse a completed Debug build; this check never runs a competing SwiftPM.
FILMBOX_BROWSE_BIN="${1:-.build/arm64-apple-macosx/debug}"
FILMBOX_BROWSE_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filmbox-browse-photo.XXXXXX")"
trap 'rm -rf -- "$FILMBOX_BROWSE_TEMP"' EXIT
python3 - "$FILMBOX_BROWSE_BIN" "$FILMBOX_BROWSE_TEMP" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys

binary_dir = Path(sys.argv[1]).resolve()
temporary = Path(sys.argv[2]).resolve()
bundle = temporary / "BrowsePhotoChecks.app"
macos = bundle / "Contents" / "MacOS"
macos.mkdir(parents=True)
with (bundle / "Contents" / "Info.plist").open("wb") as out:
    plistlib.dump({
        "CFBundleIdentifier": "com.filmbox.browse-photo-checks",
        "CFBundleExecutable": "BrowsePhotoChecks",
        "CFBundlePackageType": "APPL",
        "FilmboxDevelopmentCache": str(temporary / "isolated-cache"),
    }, out)
runner = temporary / "CheckRunner.swift"
runner.write_text("@testable import Filmbox\n" + Path("Tests/FilmboxBrowsePhotoChecks/CheckRunner.swift").read_text())
objects = [p for p in sorted((binary_dir / "Filmbox.build").glob("*.o")) if p.name != "FilmboxApp.swift.o"]
objects += sorted((binary_dir / "FilmboxCore.build").glob("*.o"))
if not objects or not (binary_dir / "Modules" / "Filmbox.swiftmodule").exists():
    raise SystemExit("Missing Debug app objects; run swift build first.")
executable = macos / "BrowsePhotoChecks"
subprocess.run(["swiftc", "-swift-version", "6", "-D", "DEBUG", "-parse-as-library", "-module-name", "BrowsePhotoChecks",
    "-I", str(binary_dir / "Modules"), str(runner), *map(str, objects), "-o", str(executable)], check=True, timeout=45)
subprocess.run([str(executable)], check=True, timeout=30)
PY
