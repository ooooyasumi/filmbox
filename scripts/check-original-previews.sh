#!/bin/bash
set -euo pipefail
FILMBOX_HD_PREVIEW_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_HD_PREVIEW_ROOT"
# Reuse the root agent's completed Debug build; do not launch another SwiftPM.
FILMBOX_HD_PREVIEW_BINARY_DIR="${1:-.build/arm64-apple-macosx/debug}"
FILMBOX_HD_PREVIEW_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filmbox-original-preview.XXXXXX")"
trap 'rm -rf -- "$FILMBOX_HD_PREVIEW_TEMP"' EXIT
python3 - "$FILMBOX_HD_PREVIEW_BINARY_DIR" "$FILMBOX_HD_PREVIEW_TEMP" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys
import shutil

binary_dir = Path(sys.argv[1]).resolve()
temporary = Path(sys.argv[2]).resolve()
bundle = temporary / "OriginalPreviewChecks.app"
macos = bundle / "Contents" / "MacOS"
macos.mkdir(parents=True)
with (bundle / "Contents" / "Info.plist").open("wb") as out:
    plistlib.dump({
        "CFBundleIdentifier": "com.filmbox.original-preview-checks",
        "CFBundleExecutable": "OriginalPreviewChecks",
        "CFBundlePackageType": "APPL",
        "FilmboxDevelopmentCache": str(temporary / "isolated-cache"),
    }, out)
ffmpeg = shutil.which("ffmpeg")
if not ffmpeg: raise SystemExit("高清预览回归需要开发机 FFmpeg 生成本机测试视频。")
subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=10",
                "-t", "1", "-c:v", "h264_videotoolbox", "-b:v", "3M", "-g", "10", "-an", "-movflags", "+faststart",
                str(temporary / "sample.mp4")], check=True, timeout=30)
runner = temporary / "CheckRunner.swift"
runner.write_text("@testable import Filmbox\n" + Path("Tests/FilmboxOriginalPreviewChecks/CheckRunner.swift").read_text())
objects = [p for p in sorted((binary_dir / "Filmbox.build").glob("*.o")) if p.name != "FilmboxApp.swift.o"]
objects += sorted((binary_dir / "FilmboxCore.build").glob("*.o"))
if not objects or not (binary_dir / "Modules" / "Filmbox.swiftmodule").exists():
    raise SystemExit("Missing complete Debug app objects; run swift build first.")
executable = macos / "OriginalPreviewChecks"
subprocess.run(["swiftc", "-swift-version", "6", "-D", "DEBUG", "-parse-as-library", "-module-name", "OriginalPreviewChecks",
    "-I", str(binary_dir / "Modules"), str(runner), *map(str, objects), "-o", str(executable)], check=True, timeout=45)
subprocess.run([str(executable)], check=True, timeout=60)
PY
