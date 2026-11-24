#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Build the application once before running this check. Reusing its module and
# objects lets several native regression runners run without competing for the
# SwiftPM build database.
BINARY_DIR="${FILMBOX_CHECK_BINARY_DIR:-$PROJECT_DIR/.build/debug}"
python3 - "$PROJECT_DIR" "$BINARY_DIR" <<'PY'
from pathlib import Path
import subprocess
import sys

project = Path(sys.argv[1])
binary_dir = Path(sys.argv[2]).resolve()
module = binary_dir / "Modules" / "Filmbox.swiftmodule"
objects = [p for p in sorted((binary_dir / "Filmbox.build").glob("*.o"))
           if p.name != "FilmboxApp.swift.o"]
objects += sorted((binary_dir / "FilmboxCore.build").glob("*.o"))
if not module.exists() or not objects:
    raise SystemExit("先完成 Filmbox 的 Debug 构建，再运行双击交互检查")
checks_dir = project / ".build" / "FilmboxDoubleClickChecks"
checks_dir.mkdir(parents=True, exist_ok=True)
executable = checks_dir / "FilmboxDoubleClickChecks"
subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library",
                "-module-name", "FilmboxDoubleClickChecks", "-I", str(binary_dir / "Modules"),
                str(project / "Tests" / "FilmboxDoubleClickChecks" / "CheckRunner.swift"),
                *map(str, objects), "-o", str(executable)], check=True)
subprocess.run([str(executable)], check=True)
PY
