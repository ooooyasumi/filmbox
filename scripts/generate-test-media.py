#!/usr/bin/env python3
"""Generate disposable regression media from test patterns and synthesized audio."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ffmpeg', default=shutil.which('ffmpeg'))
    args = parser.parse_args()
    mp4 = ROOT / 'Tests/Fixtures/h264-aac.mp4'
    webm = ROOT / 'Tests/Fixtures/vp9-opus.webm'
    android = ROOT / 'Android/app/src/androidTest/assets/qa-video.mp4'
    if not (mp4.exists() and webm.exists()):
        if not args.ffmpeg:
            parser.error('Install FFmpeg with H.264, VP9 and Opus encoders to generate test fixtures.')
        mp4.parent.mkdir(parents=True, exist_ok=True)
        def generate(destination, size, seconds, video, audio):
            if destination.exists():
                return
            temporary = destination.with_name(destination.stem + '.building' + destination.suffix)
            command = [args.ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                       'testsrc2=size=' + size + ':rate=12', '-f', 'lavfi', '-i',
                       'sine=frequency=880:sample_rate=48000', '-t', str(seconds),
                       '-c:v', video, '-pix_fmt', 'yuv420p', '-c:a', audio, '-y', str(temporary)]
            try:
                subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
                temporary.replace(destination)
            finally:
                temporary.unlink(missing_ok=True)
        generate(mp4, '128x86', 2, 'h264_videotoolbox' if sys.platform == 'darwin' else 'libx264', 'aac')
        generate(webm, '320x180', 1.2, 'libvpx-vp9', 'libopus')
    android.parent.mkdir(parents=True, exist_ok=True)
    if not android.exists():
        shutil.copyfile(mp4, android)
    print('Synthetic media ready for macOS and Android tests.')

if __name__ == '__main__':
    main()
