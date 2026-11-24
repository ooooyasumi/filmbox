#!/bin/bash
set -euo pipefail
FILMBOX_STRIP_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_STRIP_ROOT"
FILMBOX_STRIP_BIN="${1:-.build/arm64-apple-macosx/debug}"
FILMBOX_STRIP_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filmbox-filmstrip.XXXXXX")"
trap 'rm -rf -- "$FILMBOX_STRIP_TEMP"' EXIT
python3 - "$FILMBOX_STRIP_BIN" "$FILMBOX_STRIP_TEMP" <<'PY'
from pathlib import Path
import plistlib,subprocess,sys
binary=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve()
app=root/'ViewerFilmstripChecks.app';macos=app/'Contents/MacOS';macos.mkdir(parents=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.filmbox.viewer-filmstrip-checks',
    'CFBundleExecutable':'ViewerFilmstripChecks','CFBundlePackageType':'APPL','FilmboxDevelopmentCache':str(root/'isolated-cache')}))
runner=root/'Runner.swift';runner.write_text('@testable import Filmbox\n'+Path('Tests/FilmboxViewerFilmstripChecks/CheckRunner.swift').read_text())
objects=[p for p in sorted((binary/'Filmbox.build').glob('*.o')) if p.name!='FilmboxApp.swift.o']+sorted((binary/'FilmboxCore.build').glob('*.o'))
executable=macos/'ViewerFilmstripChecks'
subprocess.run(['swiftc','-swift-version','6','-D','DEBUG','-parse-as-library','-module-name','ViewerFilmstripChecks',
    '-I',str(binary/'Modules'),str(runner),*map(str,objects),'-o',str(executable)],check=True,timeout=45)
subprocess.run([str(executable)],check=True,timeout=30)
PY
