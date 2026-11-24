#!/usr/bin/env python3
"""Record the exact source tree and export source without local build products."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRS = {'Sources', 'CloudEngine', 'Android', 'Tools', 'scripts', 'Tests', 'Resources', 'design', 'docs', '.github'}
SOURCE_FILES = {'Package.swift', 'README.md', 'LICENSE', 'PRIVACY.md', 'THIRD_PARTY_NOTICES.md',
                'CHANGELOG.md', 'CONTRIBUTING.md', 'SECURITY.md', 'VERSION', 'release.json', '.gitignore', '.gitattributes'}
GENERATED_SUFFIXES = {'.mp4', '.webm', '.apk', '.zip', '.tgz', '.so', '.dylib', '.p12', '.jks', '.keystore', '.pyc'}

def source_files():
    if (ROOT / '.git').exists():
        names = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-c', '-o', '--exclude-standard', '-z']).decode().split('\0')
    else:
        names = [str(p.relative_to(ROOT)) for name in SOURCE_DIRS for p in (ROOT / name).rglob('*') if p.is_file()]
        names += [name for name in SOURCE_FILES if (ROOT / name).is_file()]
    result = []
    for name in sorted(set(names)):
        if not name:
            continue
        relative = Path(name)
        path = ROOT / relative
        if relative.parts[0] not in SOURCE_DIRS and name not in SOURCE_FILES:
            continue
        if any(p in {'.build', 'build', '.gradle', '.kotlin', '__pycache__', 'jniLibs'} for p in relative.parts):
            continue
        if path.name.endswith(('.tar.gz', '.tar.xz')):
            continue
        if relative.as_posix().startswith('Android/app/src/main/assets/') and path.name in {'Filmbox-LICENSE', 'THIRD_PARTY_NOTICES.md', 'PRIVACY.md'}:
            continue
        if path.suffix in GENERATED_SUFFIXES or path.name in {'local.properties', 'signing.properties', 'cloud-source.tgz', 'source-build.json'}:
            continue
        if not path.is_file():
            continue
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT):
            raise ValueError('Source symlink requires explicit review: ' + name)
        result.append(relative)
    return result

def manifest(files):
    digest = hashlib.sha256()
    for relative in files:
        digest.update(str(relative).encode() + b'\0')
        digest.update(hashlib.sha256((ROOT / relative).read_bytes()).digest())
    saved = json.loads((ROOT / 'source-build.json').read_text()) if (ROOT / 'source-build.json').is_file() else {}
    commit = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip() if (ROOT / '.git').exists() else saved.get('sourceCommit', 'unversioned')
    dirty = bool(subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain'], text=True).strip()) if (ROOT / '.git').exists() else saved.get('sourceTreeSHA256') != digest.hexdigest()
    return {'schemaVersion': 1, 'sourceCommit': commit, 'workingTreeDirty': dirty,
            'sourceTreeSHA256': digest.hexdigest(), 'sourceFileCount': len(files),
            'macOSVersion': (ROOT / 'VERSION').read_text().strip(),
            'androidVersion': (ROOT / 'Android/VERSION').read_text().strip()}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--public', action='store_true')
    args = parser.parse_args()
    files = source_files()
    record = manifest(files)
    if args.public:
        if not (ROOT / 'LICENSE').is_file():
            parser.error('The project owner must confirm the main license before a public source export.')
        if record['workingTreeDirty']:
            parser.error('Commit source changes before creating a public release export.')
    encoded = (json.dumps(record, ensure_ascii=False, indent=2) + '\n').encode()
    if args.manifest:
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_bytes(encoded)
    if args.archive:
        args.archive.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.archive.with_suffix(args.archive.suffix + '.partial')
        try:
            with temporary.open('wb') as stream, gzip.GzipFile(filename='', fileobj=stream, mode='wb', mtime=0) as compressed, tarfile.open(fileobj=compressed, mode='w') as archive:
                for relative in files:
                    content = (ROOT / relative).read_bytes()
                    info = tarfile.TarInfo('filmbox/' + relative.as_posix())
                    info.size = len(content)
                    info.mode = 0o755 if (ROOT / relative).stat().st_mode & 0o111 else 0o644
                    archive.addfile(info, io.BytesIO(content))
                info = tarfile.TarInfo('filmbox/source-build.json')
                info.size = len(encoded)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(encoded))
            temporary.replace(args.archive)
        finally:
            temporary.unlink(missing_ok=True)
    print(encoded.decode(), end='')

if __name__ == '__main__':
    main()
