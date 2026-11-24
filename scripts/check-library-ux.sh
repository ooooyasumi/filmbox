#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ -z "${FILMBOX_CHECK_BINARY_DIR:-}" ]]; then
    swift build -c debug
    FILMBOX_CHECK_BINARY_DIR="$(swift build -c debug --show-bin-path)"
fi
python3 scripts/run-app-check.py "$FILMBOX_CHECK_BINARY_DIR" Tests/FilmboxLibraryUXChecks/CheckRunner.swift FilmboxLibraryUXChecks
python3 - "$FILMBOX_CHECK_BINARY_DIR" <<'PY'
from pathlib import Path
import subprocess
import sys
root=Path.cwd();binary=Path(sys.argv[1]).resolve();work=root/'.build/LibraryDragChecks';work.mkdir(parents=True,exist_ok=True)
source=work/'Runner.swift'
source.write_text((root/'Sources/Filmbox/MainView.swift').read_text()+'\n'+(root/'Tests/FilmboxLibraryUXChecks/DragRunner.swift').read_text())
objects=[str(p) for p in (binary/'Filmbox.build').glob('*.o') if p.name!='FilmboxApp.swift.o']+[str(p) for p in (binary/'FilmboxCore.build').glob('*.o')]
subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-I',str(binary/'Modules'),str(source),*objects,'-o',str(work/'Checks')],check=True)
subprocess.run([str(work/'Checks')],check=True)
PY
