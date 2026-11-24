#!/bin/bash
set -euo pipefail
FILMBOX_SIGNING_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_SIGNING_ROOT"
FILMBOX_SIGNING_CHECK_IDENTITY="${1:-${FILMBOX_SIGN_IDENTITY:-${FILMBOX_SIGNING_IDENTITY:-}}}"
if [[ -z "$FILMBOX_SIGNING_CHECK_IDENTITY" ]]; then
    FILMBOX_SIGNING_CHECK_IDENTITY="$(python3 scripts/prepare-local-signing.py)"
fi
python3 - "$FILMBOX_SIGNING_CHECK_IDENTITY" <<'PY'
from pathlib import Path
import hashlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

root = Path.cwd()
identity = sys.argv[1].strip()
if not re.fullmatch(r"[0-9a-fA-F]{40}", identity):
    raise SystemExit("Expected the public certificate SHA-1 from prepare-local-signing.py.")
work = Path(tempfile.mkdtemp(prefix="StableSigningChecks.", dir=root / ".build"))
random_id = str(uuid.uuid4()).upper()
bundle_id = "com.filmbox.signing-checks." + str(uuid.uuid4())
service = "com.filmbox.signing-checks." + random_id
bundle = work / "Probe.app"
macos = bundle / "Contents/MacOS"
macos.mkdir(parents=True)
executable = macos / "Probe"
with (bundle / "Contents/Info.plist").open("wb") as out:
    plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL"}, out)
requirement = f'designated => identifier "{bundle_id}" and certificate leaf = H"{identity}"'


def run(args, *, timeout=15, capture=False):
    try:
        return subprocess.run(list(map(str, args)), check=True, timeout=timeout,
                              stdout=subprocess.PIPE if capture else None,
                              stderr=subprocess.PIPE if capture else None,
                              text=True)
    except subprocess.CalledProcessError as error:
        if capture and error.stderr:
            print(error.stderr.strip(), file=sys.stderr)
        raise


def install(variant, *, trusted=True):
    shutil.copy2(work / variant, executable)
    if trusted:
        # The helper serializes signing and manages only its own keychain's
        # temporary search-list entry. The check never changes that list.
        arguments = ["python3", "scripts/prepare-local-signing.py", "--sign", bundle,
                     "--identifier", bundle_id, "--requirements", "=" + requirement]
    else:
        arguments = ["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", bundle_id, bundle]
    run(arguments, capture=True, timeout=45)
    run(["/usr/bin/codesign", "--verify", "--strict", bundle], capture=True)
    result = run(["/usr/bin/codesign", "--display", "-r-", bundle], capture=True)
    if trusted and (identity.lower() not in result.stdout.lower() or "certificate leaf" not in result.stdout):
        raise RuntimeError("Signed test app has an unexpected designated requirement.")


def probe(mode):
    run([executable, mode, service, random_id], timeout=12)


cleaned = False
attempted_write = False
try:
    source = root / "Tests/FilmboxSigningChecks/CheckRunner.swift"
    run(["swiftc", "-swift-version", "6", "-parse-as-library", source, "-o", work / "old"], timeout=45)
    run(["swiftc", "-swift-version", "6", "-D", "SIGNING_NEW_VARIANT", "-parse-as-library", source, "-o", work / "new"], timeout=45)
    if hashlib.sha256((work / "old").read_bytes()).digest() == hashlib.sha256((work / "new").read_bytes()).digest():
        raise RuntimeError("The upgrade test requires two different binaries.")
    install("old")
    attempted_write = True
    probe("write")
    # A self-signed certificate has no Apple developer team partition. A new
    # binary is therefore denied even with the same leaf pin and bundle ID.
    install("new")
    probe("denied")
    install("old")
    probe("refresh")
    install("new")
    probe("denied")
    install("new", trusted=False)
    probe("denied")
    install("old")
    probe("read-refreshed")
    probe("cleanup")
    cleaned = True
    print("本地自签分区边界 7 阶段通过：相同证书的新二进制仍被拒绝；未放宽 ACL；随机账户已清理。")
finally:
    if attempted_write and not cleaned and (work / "new").exists():
        try:
            install("new")
            probe("cleanup")
            cleaned = True
        except Exception as error:
            print(f"随机测试账户清理失败：service={service} account={random_id}；{error}", file=sys.stderr)
    if attempted_write and not cleaned:
        print(f"保留随机测试清理工具：{work}", file=sys.stderr)
    else:
        shutil.rmtree(work)
PY
