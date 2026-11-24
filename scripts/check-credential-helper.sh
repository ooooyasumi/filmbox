#!/bin/bash
set -euo pipefail
FILMBOX_HELPER_CHECK_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_HELPER_CHECK_ROOT"
FILMBOX_HELPER_CHECK_EXECUTABLE="${1:-${FILMBOX_CREDENTIAL_HELPER:-}}"
if [[ -z "$FILMBOX_HELPER_CHECK_EXECUTABLE" ]]; then
    FILMBOX_HELPER_CHECK_EXECUTABLE="$(python3 scripts/build-credential-helper.py)"
fi
FILMBOX_HELPER_CHECK_IDENTITY="$(python3 scripts/prepare-local-signing.py)"
python3 - "$FILMBOX_HELPER_CHECK_EXECUTABLE" "$FILMBOX_HELPER_CHECK_IDENTITY" <<'PY'
from pathlib import Path
import hashlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

root = Path.cwd()
source_helper = Path(sys.argv[1]).resolve()
identity = sys.argv[2].strip()
if not source_helper.is_file() or source_helper.name != "filmbox-credential-helper-v1":
    raise SystemExit("Expected the fixed filmbox-credential-helper-v1 executable.")
work = Path(tempfile.mkdtemp(prefix="CredentialHelperChecks.", dir=root / ".build"))
account_id = str(uuid.uuid4()).upper()
bundle = work / "Probe.app"
macos = bundle / "Contents/MacOS"
macos.mkdir(parents=True)
executable = macos / "Probe"
helper = bundle / "Contents/Helpers/filmbox-credential-helper-v1"
helper.parent.mkdir(parents=True)
shutil.copy2(source_helper, helper)
helper_digest = hashlib.sha256(helper.read_bytes()).digest()


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


def install(variant, *, trusted=True, correct_id=True, runtime=True):
    shutil.copy2(work / variant, executable)
    bundle_id = "com.filmbox.app" if correct_id else "com.filmbox.helper-test." + str(uuid.uuid4())
    with (bundle / "Contents/Info.plist").open("wb") as out:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL"}, out)
    requirement = f'designated => identifier "{bundle_id}" and certificate leaf = H"{identity}"'
    if trusted:
        arguments = ["python3", "scripts/prepare-local-signing.py", "--sign", bundle,
                     "--identifier", bundle_id, "--requirements", "=" + requirement,
                     "--options", "runtime" if runtime else ""]
    else:
        arguments = ["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", bundle_id, "--options", "runtime", bundle]
    run(arguments, capture=True, timeout=45)
    run(["/usr/bin/codesign", "--verify", "--strict", bundle], capture=True)
    if hashlib.sha256(helper.read_bytes()).digest() != helper_digest:
        raise RuntimeError("Signing the parent unexpectedly changed the fixed helper bytes.")


def probe(mode):
    run([executable, mode, helper, account_id], timeout=12)


attempted_write = False
cleaned = False
try:
    source = root / "Tests/FilmboxSigningChecks/CredentialHelperRunner.swift"
    run(["swiftc", "-swift-version", "6", "-parse-as-library", source, "-o", work / "old"], timeout=45)
    run(["swiftc", "-swift-version", "6", "-D", "HELPER_NEW_PARENT", "-parse-as-library", source, "-o", work / "new"], timeout=45)
    if hashlib.sha256((work / "old").read_bytes()).digest() == hashlib.sha256((work / "new").read_bytes()).digest():
        raise RuntimeError("The upgrade test requires different parent binaries.")
    install("old")
    attempted_write = True
    probe("write")
    install("new")
    probe("read-initial")
    probe("refresh")
    install("old")
    probe("read-refreshed")
    install("new", trusted=False)
    probe("denied-adhoc")
    install("new", correct_id=False)
    probe("denied-identifier")
    install("new", runtime=False)
    probe("denied-runtime")
    install("new")
    probe("read-refreshed")
    probe("cleanup")
    cleaned = True
    if hashlib.sha256(source_helper.read_bytes()).digest() != helper_digest:
        raise RuntimeError("The source helper changed during the upgrade check.")
    print("稳定凭据组件 9 阶段通过：主程序跨升级连续读写；非信任/异标识/无运行时保护父进程拒绝；随机账户已清理。")
finally:
    if attempted_write and not cleaned and (work / "old").exists():
        try:
            install("old")
            probe("cleanup")
            cleaned = True
        except Exception as error:
            print(f"随机测试账户清理失败：account={account_id}；{error}", file=sys.stderr)
    if attempted_write and not cleaned:
        print(f"保留随机测试清理工具：{work}", file=sys.stderr)
    else:
        shutil.rmtree(work)
PY
