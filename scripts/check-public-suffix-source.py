#!/usr/bin/env python3
"""Verify that the MPL rule source reproduces OkHttp's packaged data payload."""
import hashlib
import json
from pathlib import Path
import struct

ROOT=Path(__file__).resolve().parents[1]
folder=ROOT/'Android/third-party/publicsuffix'
source=[line for line in (folder/'rules.txt').read_text().splitlines() if line and not line.startswith('//')]
regular=sorted((line.encode() for line in source if not line.startswith('!')))
exceptions=sorted((line[1:].encode() for line in source if line.startswith('!')))
first=b'\n'.join(regular)+b'\n'
second=b'\n'.join(exceptions)+b'\n'
payload=struct.pack('>I',len(first))+first+struct.pack('>I',len(second))+second
metadata=json.loads((folder/'source.json').read_text())
assert hashlib.sha256(payload).hexdigest()==metadata['decodedSHA256'], 'Public Suffix source differs from packaged rule data'
print('Public Suffix preferred rule source matches the packaged payload.')
