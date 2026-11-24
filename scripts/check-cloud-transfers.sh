#!/bin/bash
set -euo pipefail
FILMBOX_TRANSFER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_TRANSFER_ROOT"
sh scripts/build-cloud-engine.sh
swift build -c debug
python3 - <<'PY'
import subprocess,sys
binary_dir=subprocess.check_output(['swift','build','-c','debug','--show-bin-path'],text=True).strip()
fixture=subprocess.Popen([sys.executable,'Tests/FilmboxTransferChecks/fixture.py'],stdout=subprocess.PIPE,text=True)
try:
 endpoint=fixture.stdout.readline().strip()
 subprocess.run([sys.executable,'scripts/run-app-check.py',binary_dir,'Tests/FilmboxTransferChecks/CheckRunner.swift','FilmboxTransferChecks',endpoint],check=True,timeout=90)
finally:
 fixture.terminate();fixture.wait(timeout=5)
PY
