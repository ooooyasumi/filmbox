#!/bin/bash
set -euo pipefail
FILMBOX_GRID_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_GRID_ROOT"
FILMBOX_GRID_BIN="${1:-.build/arm64-apple-macosx/debug}"
FILMBOX_GRID_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filmbox-grid-transition.XXXXXX")"
trap 'rm -rf -- "$FILMBOX_GRID_TEMP"' EXIT
python3 - "$FILMBOX_GRID_BIN" "$FILMBOX_GRID_TEMP" <<'PY'
from pathlib import Path
import plistlib,subprocess,sys
binary=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve()
app=root/'GridTransitionChecks.app';macos=app/'Contents/MacOS';macos.mkdir(parents=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.filmbox.grid-transition-checks',
    'CFBundleExecutable':'GridTransitionChecks','CFBundlePackageType':'APPL','FilmboxDevelopmentCache':str(root/'isolated-cache')}))
runner=root/'Runner.swift';runner.write_text('@testable import Filmbox\n'+Path('Tests/FilmboxGridTransitionChecks/CheckRunner.swift').read_text())
objects=[p for p in sorted((binary/'Filmbox.build').glob('*.o')) if p.name!='FilmboxApp.swift.o']+sorted((binary/'FilmboxCore.build').glob('*.o'))
executable=macos/'GridTransitionChecks'
subprocess.run(['swiftc','-swift-version','6','-D','DEBUG','-parse-as-library','-module-name','GridTransitionChecks',
    '-I',str(binary/'Modules'),str(runner),*map(str,objects),'-o',str(executable)],check=True,timeout=45)
subprocess.run([str(executable)],check=True,timeout=30)
PY
