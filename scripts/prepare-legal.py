#!/usr/bin/env python3
"""Copy project notices and exact source correspondence into a candidate package."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--android', action='store_true')
    parser.add_argument('--public', action='store_true')
    args = parser.parse_args()
    if args.public and not (ROOT / 'LICENSE').is_file():
        parser.error('Owner-confirmed LICENSE is required for public distribution.')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (ROOT / 'LICENSE').is_file():
        shutil.copy2(ROOT / 'LICENSE', output / ('Filmbox-LICENSE' if args.android else 'LICENSE'))
    else:
        (output / ('Filmbox-LICENSE' if args.android else 'LICENSE')).write_text('主项目许可证待负责人确认。本候选包尚未完成公开发行许可确认。\n')
    for name in ['PRIVACY.md', 'THIRD_PARTY_NOTICES.md']:
        shutil.copy2(ROOT / name, output / name)
    command = [sys.executable, str(ROOT / 'scripts/source-release.py'), '--manifest', str(output / 'source-build.json')]
    archive_name = 'filmbox-source.tgz' if args.android else 'filmbox-source.tar.gz'
    if args.android:
        (output/'filmbox-source.tar.gz').unlink(missing_ok=True)
    command += ['--archive', str(output / archive_name)]
    if args.public:
        command.append('--public')
    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)

if __name__ == '__main__':
    main()
