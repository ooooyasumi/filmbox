#!/bin/bash
set -euo pipefail
FILMBOX_SEARCH_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_SEARCH_ROOT"
python3 - <<'PY'
from pathlib import Path
import subprocess

root = Path.cwd()
source = (root / 'Sources/Filmbox/MainView.swift').read_text()
start = source.index('@MainActor @Observable final class SearchInputCoordinator {')
end = source.index('\nstruct SidebarView:', start)
checks = root / '.build/FilmboxSearchInputChecks'
checks.mkdir(parents=True, exist_ok=True)
coordinator = checks / 'SearchInputCoordinator.swift'
# Compile the production coordinator itself; the runner supplies no second
# implementation and needs neither SwiftPM nor any app/window lifecycle.
coordinator.write_text('import Foundation\nimport Observation\n' + source[start:end])
executable = checks / 'FilmboxSearchInputChecks'
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                str(coordinator), str(root / 'Tests/FilmboxSearchInputChecks/CheckRunner.swift'),
                '-o', str(executable)], check=True, timeout=30)
subprocess.run([str(executable)], check=True, timeout=10)
PY
