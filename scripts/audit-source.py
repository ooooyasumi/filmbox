#!/usr/bin/env python3
"""Audit public source candidates without printing possible secret values."""
from pathlib import Path
import importlib.util
import re

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('source_release', ROOT / 'scripts/source-release.py')
source = importlib.util.module_from_spec(spec); spec.loader.exec_module(source)
files = source.source_files()
problems = []
secret_assignment = re.compile(r'''(?i)(?:refresh_token|access_token|client_secret|password|cookie)\s*[=:]\s*["']([A-Za-z0-9_+/=.%~-]{40,})["']''')
for relative in files:
    path = ROOT / relative
    if path.stat().st_size > 2 * 1024 * 1024:
        problems.append(str(relative) + ' exceeds source asset budget')
    if path.suffix in {'.pem', '.p12', '.jks', '.keystore', '.db'} or path.name in {'.env', 'local.properties', 'signing.properties'}:
        problems.append(str(relative) + ' is a local credential or data file')
    if path.suffix == '.jar':
        if relative.as_posix() != 'Android/gradle/wrapper/gradle-wrapper.jar':
            problems.append(str(relative) + ' is an unreviewed binary dependency')
        continue
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        if path.suffix not in {'.png', '.webp'} or not str(relative).startswith('docs/screenshots/'):
            problems.append(str(relative) + ' is an unexpected binary')
        continue
    for line, content in enumerate(text.splitlines(), 1):
        if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', content):
            problems.append(f'{relative}:{line} contains a private-key marker')
        if secret_assignment.search(content) and 'test' not in str(relative).lower():
            problems.append(f'{relative}:{line} requires secret review (value omitted)')
if problems:
    raise SystemExit('\n'.join(problems))
print(f'Public source audit passed for {len(files)} files. No possible secret values were printed.')
