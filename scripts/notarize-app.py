#!/usr/bin/env python3
"""Submit a Developer ID app, staple its ticket, and verify Gatekeeper assessment."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def run(command):
    return subprocess.run(list(map(str, command)), check=True, capture_output=True, text=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--keychain-profile', required=True, help='Existing notarytool keychain profile name')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    app = args.app.resolve()
    if app.name != 'Filmbox.app':
        parser.error('Expected a built Filmbox.app')
    requirement = 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
    executables = [app, *sorted((app/'Contents/Helpers').iterdir())]
    for binary in executables:
        run(['codesign', '--verify', '--strict', '-R', requirement, binary])
    run(['codesign', '--verify', '--deep', '--strict', app])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='filmbox-notarize-') as temporary:
        submission = Path(temporary)/'Filmbox-submit.zip'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, submission])
        result = json.loads(run(['xcrun', 'notarytool', 'submit', submission, '--keychain-profile', args.keychain_profile, '--wait', '--output-format', 'json']).stdout)
        receipt = args.output.with_suffix('.notary.json')
        receipt.write_text(json.dumps(result, indent=2)+'\n')
        if result.get('status') != 'Accepted':
            raise SystemExit('Apple did not accept this submission. See '+str(receipt))
        run(['xcrun', 'stapler', 'staple', app])
        run(['xcrun', 'stapler', 'validate', app])
        run(['spctl', '--assess', '--type', 'execute', '--verbose=4', app])
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', app, args.output])
    print(json.dumps({'asset': args.output.name, 'sha256': hashlib.file_digest(args.output.open('rb'),'sha256').hexdigest(),
                      'notarized': True, 'stapled': True, 'notarySubmissionId': result['id']}, indent=2))

if __name__ == '__main__':
    main()
