#!/bin/bash
set -euo pipefail
FILMBOX_STREAM_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_STREAM_ROOT"
FILMBOX_STREAM_BIN="${1:-.build/arm64-apple-macosx/debug}"
FILMBOX_STREAM_TEMP="$(mktemp -d "${TMPDIR:-/tmp}/filmbox-streaming.XXXXXX")"
trap 'rm -rf -- "$FILMBOX_STREAM_TEMP"' EXIT
python3 - "$FILMBOX_STREAM_BIN" "$FILMBOX_STREAM_TEMP" <<'PY'
from pathlib import Path
import importlib.util,plistlib,subprocess,sys,threading,shutil
sys.dont_write_bytecode=True
binary=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve()
source=root/'sample.mp4'
ffmpeg=shutil.which('ffmpeg')
if not ffmpeg: raise SystemExit('流播回归需要开发机安装带 lavfi 的 FFmpeg；不影响应用播放。')
subprocess.run([ffmpeg,'-hide_banner','-loglevel','error','-f','lavfi','-i',
    'testsrc2=size=640x360:rate=30','-t','40','-c:v','h264_videotoolbox','-b:v','4M','-g','30','-an',
    '-movflags','+faststart',str(source)],check=True,timeout=45)
module_spec=importlib.util.spec_from_file_location('streaming_fixture','Tests/FilmboxStreamingChecks/server.py')
module=importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(module)
server=module.MediaServer(source);threading.Thread(target=server.serve_forever,daemon=True).start()
app=root/'StreamingChecks.app';macos=app/'Contents/MacOS';macos.mkdir(parents=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.filmbox.streaming-checks',
    'CFBundleExecutable':'StreamingChecks','CFBundlePackageType':'APPL','FilmboxDevelopmentCache':str(root/'isolated-cache'),
    'StreamCheckURL':f'http://127.0.0.1:{server.server_port}','StreamCheckSource':str(source)}))
runner=root/'Runner.swift';runner.write_text('@testable import Filmbox\n'+Path('Tests/FilmboxStreamingChecks/CheckRunner.swift').read_text())
objects=[p for p in sorted((binary/'Filmbox.build').glob('*.o')) if p.name!='FilmboxApp.swift.o']+sorted((binary/'FilmboxCore.build').glob('*.o'))
exe=macos/'StreamingChecks'
subprocess.run(['swiftc','-swift-version','6','-D','DEBUG','-parse-as-library','-module-name','StreamingChecks',
    '-I',str(binary/'Modules'),str(runner),*map(str,objects),'-o',str(exe)],check=True,timeout=45)
try:
    subprocess.run([str(exe)],check=True,timeout=100)
finally:
    with server.lock:
        server.gate=server.length;server.lock.notify_all()
    server.shutdown();server.server_close()
PY
