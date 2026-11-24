#!/usr/bin/env python3
"""Record source and binary identity for the independently built cloud engine."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--platform', required=True)
    args = parser.parse_args()
    files = sorted(p for p in (ROOT/'CloudEngine').rglob('*') if p.is_file() and p.name != '.DS_Store')
    digest = hashlib.sha256()
    for path in files:
        digest.update(str(path.relative_to(ROOT)).encode()+b'\0')
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    commit = subprocess.run(['git','-C',str(ROOT),'rev-parse','HEAD'],capture_output=True,text=True) if (ROOT/'.git').exists() else None
    saved = json.loads((ROOT/'source-build.json').read_text()) if (ROOT/'source-build.json').is_file() else {}
    go = os.environ.get('FILMBOX_GO') or shutil.which('go') or '/usr/local/go/bin/go'
    record = {'sourceCommit':commit.stdout.strip() if commit is not None and commit.returncode==0 else saved.get('sourceCommit','unversioned'),
              'sourceTreeSHA256':digest.hexdigest(), 'sourceFileCount':len(files),
              'binarySHA256':hashlib.file_digest(args.binary.open('rb'),'sha256').hexdigest(),
              'platform':args.platform, 'goVersion':subprocess.check_output([go,'version'],text=True).strip(),
              'upstreamRevision':'e72822f5390f4272c9fe9da8cabba3c1a270182f',
              'buildFlags':['CGO_ENABLED=0','-trimpath',"-ldflags=-s -w -buildid="]}
    args.output.write_text(json.dumps(record,indent=2)+'\n')

if __name__ == '__main__':
    main()
