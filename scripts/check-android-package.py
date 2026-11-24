#!/usr/bin/env python3
"""Validate an Android deliverable without installing it or touching any media."""
import hashlib
import gzip
import json
import os
import pathlib
import struct
import subprocess
import sys
import zipfile
from source_archive import verify_source_archive

root = pathlib.Path(__file__).resolve().parent.parent
version = (root / "Android/VERSION").read_text().strip()
apk = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / f"build/android/{version}/Filmbox-Android-{version}-arm64.apk"
sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
if not sdk:
    local = root / "Android/local.properties"
    sdk = next((line.split("=", 1)[1] for line in local.read_text().splitlines() if line.startswith("sdk.dir=")), None)
if not sdk:
    sys.exit("Android SDK location is required to verify the APK.")
tools = pathlib.Path(sdk) / "build-tools/35.0.0"
manifest = subprocess.check_output([str(tools / "aapt"), "dump", "badging", str(apk)], text=True)
assert "package: name='com.filmbox.app'" in manifest
assert f"versionName='{version}'" in manifest
assert "sdkVersion:'30'" in manifest and "targetSdkVersion:'35'" in manifest
assert "native-code: 'arm64-v8a'" in manifest
assert "application-debuggable" not in manifest
signature = subprocess.run([str(tools / "apksigner"), "verify", "--verbose", str(apk)], check=True, capture_output=True, text=True).stdout
assert "Verified using v2 scheme (APK Signature Scheme v2): true" in signature
with zipfile.ZipFile(apk) as archive:
    names = archive.namelist()
    assert "assets/cloud-source.tgz" in names and "assets/CloudEngine-LICENSE" in names
    assert "assets/Apache-LICENSE" in names and "assets/Go-LICENSE" in names
    assert not any(name.endswith((".jks", ".keystore", ".db")) or "signing.properties" in name or "qa-video" in name or "FILMBOX_QA" in name for name in names)
    for required in ["assets/Filmbox-LICENSE", "assets/PRIVACY.md", "assets/THIRD_PARTY_NOTICES.md", "assets/source-build.json", "assets/filmbox-source.tgz"]:
        assert required in names, required
    source_record = verify_source_archive(archive.read("assets/filmbox-source.tgz"))
    assert source_record == json.loads(archive.read("assets/source-build.json"))
    assert source_record["androidVersion"] == version
    for required in ["assets/Mozilla-MPL-2.0.txt", "assets/PublicSuffix-NOTICE.txt"]:
        assert required in names, required
    psl = json.loads((root / "Android/third-party/publicsuffix/source.json").read_text())
    assert psl['resource'] in names
    assert hashlib.sha256(archive.read(psl['resource'])).hexdigest() == psl['compressedSHA256']
    native = {}
    for name in names:
        if not name.endswith(".so"):
            continue
        blob = archive.read(name)
        header = struct.unpack_from("<16sHHIQQQIHHHHHH", blob)
        assert blob[:4] == b"\x7fELF" and header[2] == 183
        align = []
        for index in range(header[10]):
            segment = struct.unpack_from("<IIQQQQQQ", blob, header[5] + index * header[9])
            if segment[0] == 1:
                align.append(segment[7])
        assert align and min(align) >= 16384, (name, align)
        native[name] = min(align)
result = {"sourceCommit": source_record["sourceCommit"], "sourceTreeSHA256": source_record["sourceTreeSHA256"], "version": version, "apk": str(apk), "bytes": apk.stat().st_size, "sha256": hashlib.file_digest(apk.open("rb"), "sha256").hexdigest(), "minAndroid": "11 (API 30)", "targetApi": 35, "abi": "arm64-v8a", "releaseSigned": True, "nativeLoadAlignment": native, "privateFilesAbsent": True}
print(json.dumps(result, ensure_ascii=False, indent=2))
