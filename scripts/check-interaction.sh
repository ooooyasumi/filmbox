#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

swift build -c debug
BINARY_DIR="$(swift build -c debug --show-bin-path)"

python3 - "$PROJECT_DIR" "$BINARY_DIR" <<'PY'
from pathlib import Path
import subprocess
import sys

project = Path(sys.argv[1])
binary_dir = Path(sys.argv[2])
checks_dir = project / ".build" / "FilmboxInteractionChecks"
checks_dir.mkdir(parents=True, exist_ok=True)
sources = [project / "Sources" / "Filmbox" / name
           for name in ["BrowseView.swift", "BrowseTimeRuler.swift"]]
checks = project / "Tests" / "FilmboxInteractionChecks" / "BrowseChecks.swift"
combined = checks_dir / "BrowseChecks.swift"
# Compile the production component itself. Sharing a file lets the checks use
# its private native layout without widening the application's public surface.
combined.write_text("\n".join(source.read_text() for source in sources) + "\n" + checks.read_text())
objects = [p for p in sorted((binary_dir / "Filmbox.build").glob("*.o"))
           if p.name != "FilmboxApp.swift.o"]
objects += sorted((binary_dir / "FilmboxCore.build").glob("*.o"))
if not objects:
    raise SystemExit("No debug build objects found in the resolved SwiftPM binary directory")
executable = checks_dir / "FilmboxInteractionChecks"
subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
                "-module-name", "FilmboxInteractionChecks", "-I", str(binary_dir / "Modules"),
                str(combined), *map(str, objects), "-o", str(executable)], check=True)
subprocess.run([str(executable)], check=True)
PY
