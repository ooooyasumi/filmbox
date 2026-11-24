#!/usr/bin/env python3
"""Freeze the Developer ID credential helper in its own credential namespace."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Tools/FilmboxDistributionCredentialHelper/main.swift'
IDENTIFIER = 'com.filmbox.app.credential-helper.distribution.v1'
STORE = Path.home() / 'Library/Application Support/Filmbox Distribution Signing/credential-helper-developer-id-v1'

def run(command):
    return subprocess.run(list(map(str, command)), check=True, capture_output=True, text=True, timeout=120)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', required=True, help='Developer ID Application name or certificate SHA-1')
    args = parser.parse_args()
    identities = run(['security', 'find-identity', '-v', '-p', 'codesigning']).stdout
    matches = re.findall(r'([0-9A-F]{40}) "(Developer ID Application:[^"\n]+)"', identities)
    matches = [(fingerprint, name) for fingerprint, name in matches if args.identity.upper() == fingerprint or args.identity == name]
    if len(matches) != 1:
        parser.error('One valid Developer ID Application certificate with its private key is required in the keychain.')
    identity = matches[0][0]
    expected = {'profile': 'developer-id-v1', 'identifier': IDENTIFIER, 'minimumMacOS': '15.0',
                'sourceSHA256': sha(SOURCE), 'certificateSHA1': identity, 'architecture': 'arm64'}
    STORE.mkdir(parents=True, exist_ok=True, mode=0o700)
    binary = STORE / 'filmbox-credential-helper-distribution-v1'
    manifest = STORE / 'manifest.json'
    with (STORE / 'build.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if binary.exists() or manifest.exists():
            if not (binary.is_file() and manifest.is_file()):
                parser.error('Distribution helper state is incomplete. Restore its recorded identity before building.')
            saved = json.loads(manifest.read_text())
            if any(saved.get(k) != v for k, v in expected.items()) or saved.get('binarySHA256') != sha(binary):
                parser.error('Distribution helper identity changed. An explicit new credential profile and migration are required.')
        else:
            with tempfile.TemporaryDirectory(dir=STORE) as work:
                candidate = Path(work) / binary.name
                run(['xcrun', 'swiftc', '-swift-version', '6', '-O', '-parse-as-library', '-target', 'arm64-apple-macosx15.0', SOURCE, '-o', candidate])
                run(['codesign', '--force', '--sign', identity, '--identifier', IDENTIFIER, '--options', 'runtime', '--timestamp', candidate])
                run(['codesign', '--verify', '--strict', '-R', 'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists', candidate])
                expected['binarySHA256'] = sha(candidate)
                candidate.chmod(0o700)
                candidate.replace(binary)
                manifest.write_text(json.dumps(expected, indent=2)+'\n')
        run(['codesign', '--verify', '--strict', '-R', f'identifier "{IDENTIFIER}" and certificate leaf = H"{identity}"', binary])
        print(binary)

if __name__ == '__main__':
    try:
        main()
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        raise SystemExit('Distribution helper build failed. Check the Developer ID identity and frozen helper manifest.') from None
