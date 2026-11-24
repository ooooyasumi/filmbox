#!/usr/bin/env python3
"""Verify macOS package licensing, source correspondence and signing profile."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
from source_archive import verify_source_archive

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--public', action='store_true')
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    legal = app/'Contents/Resources/Licenses/Filmbox'
    for name in ['LICENSE', 'PRIVACY.md', 'THIRD_PARTY_NOTICES.md', 'filmbox-source.tar.gz', 'source-build.json']:
        if not (legal/name).is_file():
            parser.error('Missing package legal/source resource: '+name)
    record = verify_source_archive(legal/'filmbox-source.tar.gz')
    if record != json.loads((legal/'source-build.json').read_text()):
        parser.error('Package source receipt differs from its source archive')
    if record['macOSVersion'] != info['CFBundleShortVersionString']:
        parser.error('Package version differs from corresponding source')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    subprocess.run(['python3', str(ROOT/'scripts/check-app-compatibility.py'), str(app)], check=True)
    if args.public:
        if info.get('FilmboxCredentialProfile') != 'developer-id-v1':
            parser.error('Developer ID credential profile missing')
        if record['workingTreeDirty']:
            parser.error('Public binary was built from an uncommitted source tree')
        subprocess.run(['codesign', '--verify', '--strict', '-R', 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists', str(app)],check=True)
        subprocess.run(['xcrun','stapler','validate',str(app)],check=True)
        subprocess.run(['spctl','--assess','--type','execute',str(app)],check=True)
    print(json.dumps({'version':info['CFBundleShortVersionString'], **record,
                      'credentialProfile':info.get('FilmboxCredentialProfile','local-v1'),
                      'publicDistributionVerified':args.public}, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
