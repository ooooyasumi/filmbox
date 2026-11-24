#!/bin/bash
set -euo pipefail
FILMBOX_PERF_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_PERF_ROOT"
if [[ -n "${FILMBOX_PERFORMANCE_BINARY_DIR:-}" ]]; then
    FILMBOX_PERF_BINARY_DIR="$FILMBOX_PERFORMANCE_BINARY_DIR"
else
    swift build -c debug
    FILMBOX_PERF_BINARY_DIR="$(swift build -c debug --show-bin-path)"
fi
# Bound compilation plus execution. The runner uses only synthetic records,
# temporary catalogues/caches and a temporary defaults suite; never app UI.
# --baseline links the archived 0.6.1 module without requiring newer delta APIs.
python3 - "$FILMBOX_PERF_BINARY_DIR" "$@" <<'PY'
from pathlib import Path
import subprocess, sys
root = Path.cwd()
binary = Path(sys.argv[1]).resolve()
arguments = sys.argv[2:]
checks = root / '.build/NativeAppChecks/FilmboxPerformanceChecks'
checks.mkdir(parents=True, exist_ok=True)
combined = checks / 'CheckRunner.swift'
combined.write_text('@testable import Filmbox\n' + (root / 'Tests/FilmboxPerformanceChecks/CheckRunner.swift').read_text())
objects = [path for path in sorted((binary / 'Filmbox.build').glob('*.o')) if path.name != 'FilmboxApp.swift.o']
objects += sorted((binary / 'FilmboxCore.build').glob('*.o'))
if not objects or not (binary / 'Modules/Filmbox.swiftmodule').exists():
    raise SystemExit('Missing complete Filmbox Debug objects; build first or select a baseline snapshot.')
output = checks / 'FilmboxPerformanceChecks'
command = ['swiftc', '-swift-version', '6', '-D', 'DEBUG', '-parse-as-library',
           '-module-name', 'FilmboxPerformanceChecks', '-I', str(binary / 'Modules')]
if '--baseline' in arguments: command += ['-D', 'PERFORMANCE_BASELINE_061']
subprocess.run([*command, str(combined), *map(str, objects), '-o', str(output)], check=True, timeout=45)
subprocess.run([str(output), *arguments], check=True, timeout=75)
PY
