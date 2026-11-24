#!/usr/bin/env python3
"""Check source versions and optional release artifacts against release.json."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
from urllib.parse import urlparse
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifacts', type=Path)
    parser.add_argument('--site', type=Path)
    parser.add_argument('--public', action='store_true')
    args = parser.parse_args()
    config = json.loads((ROOT / 'release.json').read_text())
    errors = []
    def require(condition, message):
        if not condition:
            errors.append(message)
    mac = config['macos']; android = config['android']
    require((ROOT / 'VERSION').read_text().strip() == mac['version'], 'macOS VERSION differs from release.json')
    require((ROOT / 'Android/VERSION').read_text().strip() == android['version'], 'Android VERSION differs from release.json')
    gradle = (ROOT / 'Android/app/build.gradle.kts').read_text()
    require('versionName = "' + android['version'] + '"' in gradle, 'Android versionName differs')
    require('versionCode = ' + str(android['versionCode']) in gradle, 'Android versionCode differs')
    for version, file in [(mac['version'], 'README.md'), (android['version'], 'README.md'), (android['version'], 'Android/README.md')]:
        require(version in (ROOT / file).read_text(), file + ' does not show ' + version)
    plist = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    require(plist['CFBundleShortVersionString'] == mac['version'], 'Info.plist version differs')
    require(plist['LSMinimumSystemVersion'] == mac['minimumSystem'], 'Info.plist minimum system differs')
    for item, file in [(mac, 'CHANGELOG.md'), (android, 'Android/CHANGELOG.md')]:
        require('## ' + item['version'] in (ROOT / file).read_text(), file + ' lacks current release notes')
    wrapper = ROOT / 'Android/gradle/wrapper/gradle-wrapper.jar'
    require(wrapper.is_file(), 'Gradle wrapper JAR missing')
    tool = config['buildTools']['gradle']
    if wrapper.is_file():
        require(hashlib.sha256(wrapper.read_bytes()).hexdigest() == tool['wrapperJarSHA256'], 'Gradle wrapper JAR differs from the pinned official checksum')
    properties = (ROOT/'Android/gradle/wrapper/gradle-wrapper.properties').read_text()
    require('distributionSha256Sum='+tool['distributionSHA256'] in properties, 'Gradle distribution checksum differs')
    require('gradle-'+tool['version']+'-bin.zip' in properties, 'Gradle distribution version differs')
    if args.public:
        require((ROOT / 'LICENSE').is_file(), 'Owner-confirmed main LICENSE missing')
        require(config['license']['application'] != 'pending-owner-confirmation', 'Main license approval is still pending')
        url = urlparse(config['repositoryUrl'])
        require(url.scheme == 'https' and url.hostname == 'github.com' and len(url.path.strip('/').split('/')) == 2, 'Formal GitHub URL missing or invalid')
        require(bool(config['feedbackUrl']), 'Feedback URL missing')
    if args.site:
        site = args.site.resolve()
        data = json.loads((site / 'release.json').read_text())
        for platform in ['macos', 'android']:
            require(data[platform]['version'] == config[platform]['version'], 'Website ' + platform + ' version differs')
            require(data[platform]['asset'] == config[platform]['asset'], 'Website ' + platform + ' filename differs')
        require(data['repositoryUrl'] == config['repositoryUrl'], 'Website source URL differs')
    if args.artifacts:
        folder = args.artifacts.resolve()
        for platform in ['macos', 'android']:
            entry = config[platform]
            path = folder / entry['asset']
            metadata = folder / (platform + '-release.json')
            require(path.is_file() and metadata.is_file(), platform + ' artifact or receipt missing')
            if not (path.is_file() and metadata.is_file()):
                continue
            receipt = json.loads(metadata.read_text())
            require(receipt['version'] == entry['version'], platform + ' receipt version differs')
            checksum_matches = receipt['sha256'] == hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
            require(checksum_matches, platform + ' checksum differs; the download may be incomplete or corrupt')
            if not checksum_matches:
                continue
            require(bool(receipt.get('sourceCommit')) and bool(receipt.get('sourceTreeSHA256')), platform + ' source correspondence missing')
            if platform == 'macos':
                try:
                    with zipfile.ZipFile(path) as archive:
                        info = plistlib.loads(archive.read('Filmbox.app/Contents/Info.plist'))
                        require(info['CFBundleShortVersionString'] == entry['version'], 'Packaged macOS version differs')
                except (zipfile.BadZipFile, KeyError, plistlib.InvalidFileException):
                    require(False, 'macOS archive is incomplete, corrupt or missing its application version')
            if args.public and platform == 'macos':
                require(receipt.get('notarized') is True and receipt.get('stapled') is True, 'Public macOS artifact requires notarization and stapling')
    if errors:
        raise SystemExit('\n'.join(errors))
    print('Release source versions and requested artifacts are consistent.')

if __name__ == '__main__':
    main()
