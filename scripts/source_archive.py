"""Verify a complete Filmbox source archive against its recorded file tree."""
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile


def verify_source_archive(value):
    stream = io.BytesIO(value) if isinstance(value, bytes) else Path(value).open('rb')
    with stream, tarfile.open(fileobj=stream, mode='r:gz') as archive:
        contents = {}
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if not member.isfile() or path.parts[0] != 'filmbox' or '..' in path.parts:
                raise ValueError('Unexpected source archive entry')
            relative = '/'.join(path.parts[1:])
            if relative in contents:
                raise ValueError('Duplicate source archive entry')
            contents[relative] = archive.extractfile(member).read()
    record = json.loads(contents.pop('source-build.json'))
    digest = hashlib.sha256()
    for name in sorted(contents):
        digest.update(name.encode() + b'\0')
        digest.update(hashlib.sha256(contents[name]).digest())
    if digest.hexdigest() != record['sourceTreeSHA256'] or len(contents) != record['sourceFileCount']:
        raise ValueError('Source archive differs from its recorded file tree')
    return record
