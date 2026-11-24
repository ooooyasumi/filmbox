#!/bin/bash
set -euo pipefail
FILMBOX_PREVIEW_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_PREVIEW_ROOT"
# Reuse the root agent's completed Debug build; do not launch another SwiftPM.
FILMBOX_PREVIEW_BINARY_DIR="${1:-.build/arm64-apple-macosx/debug}"
FILMBOX_PREVIEW_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filmbox-cloud-preview.XXXXXX")"
trap 'rm -rf -- "$FILMBOX_PREVIEW_TEMP"' EXIT
python3 - "$FILMBOX_PREVIEW_BINARY_DIR" "$FILMBOX_PREVIEW_TEMP" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys

binary_dir = Path(sys.argv[1]).resolve()
temporary = Path(sys.argv[2]).resolve()
bundle = temporary / "CloudPreviewChecks.app"
macos = bundle / "Contents" / "MacOS"
macos.mkdir(parents=True)
with (bundle / "Contents" / "Info.plist").open("wb") as out:
    plistlib.dump({
        "CFBundleIdentifier": "com.filmbox.cloud-preview-checks",
        "CFBundleExecutable": "CloudPreviewChecks",
        "CFBundlePackageType": "APPL",
        "FilmboxDevelopmentCache": str(temporary / "isolated-cache"),
    }, out)
runner = temporary / "CheckRunner.swift"
runner.write_text("@testable import Filmbox\n" + Path("Tests/FilmboxOriginalCacheChecks/CloudPreviewRunner.swift").read_text())
objects = [p for p in sorted((binary_dir / "Filmbox.build").glob("*.o")) if p.name != "FilmboxApp.swift.o"]
objects += sorted((binary_dir / "FilmboxCore.build").glob("*.o"))
if not objects or not (binary_dir / "Modules" / "Filmbox.swiftmodule").exists():
    raise SystemExit("Missing complete Debug app objects; run swift build first.")
executable = macos / "CloudPreviewChecks"
subprocess.run(["swiftc", "-swift-version", "6", "-D", "DEBUG", "-parse-as-library", "-module-name", "CloudPreviewChecks",
    "-I", str(binary_dir / "Modules"), str(runner), *map(str, objects), "-o", str(executable)], check=True, timeout=45)
subprocess.run([str(executable)], check=True, timeout=30)
PY
