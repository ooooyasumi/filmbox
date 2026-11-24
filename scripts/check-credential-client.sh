#!/bin/bash
set -euo pipefail
FILMBOX_CLIENT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$FILMBOX_CLIENT_ROOT"
FILMBOX_CLIENT_VARIANT="${1:-}"
if [[ "$FILMBOX_CLIENT_VARIANT" != "" && "$FILMBOX_CLIENT_VARIANT" != "--macos15" ]]; then
    printf '用法：%s [--macos15]\n' "$0" >&2
    exit 1
fi
if [[ "$FILMBOX_CLIENT_VARIANT" == "--macos15" ]]; then
    FILMBOX_CLIENT_HELPER="$(python3 scripts/build-credential-helper.py --macos15)"
else
    FILMBOX_CLIENT_HELPER="$(python3 scripts/build-credential-helper.py)"
fi
python3 - "$FILMBOX_CLIENT_HELPER" "$FILMBOX_CLIENT_VARIANT" <<'PY'
from pathlib import Path
import hashlib
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import uuid

root = Path.cwd()
work = Path(tempfile.mkdtemp(prefix="CredentialClientChecks.", dir=root / ".build"))
bundle = work / "Probe.app"
executable = bundle / "Contents/MacOS/Probe"
compatibility = sys.argv[2] == "--macos15"
helper_name = "filmbox-credential-helper-macos15-v1" if compatibility else "filmbox-credential-helper-v1"
helper = bundle / "Contents/Helpers" / helper_name
source_helper = Path(sys.argv[1])
source_digest = hashlib.sha256(source_helper.read_bytes()).digest()
account_id = str(uuid.uuid4()).upper()
started = False
completed = False
try:
    executable.parent.mkdir(parents=True)
    helper.parent.mkdir(parents=True)
    shutil.copy2(source_helper, helper)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.filmbox.app", "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL"}))
    source = work / "ClientChecks.swift"
    gateway = (root / "Sources/Filmbox/CloudGateway.swift").read_text()
    runner = (root / "Tests/FilmboxKeychainChecks/HelperClientRunner.swift").read_text()
    if compatibility:
        # Only the test copy uses a synthetic system version and a private
        # defaults domain. No production preference or credential is changed.
        gateway = gateway.replace("let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion", "let major = 15")
        gateway = gateway.replace("let defaults = UserDefaults.standard", 'let defaults = UserDefaults(suiteName: "filmbox.compatibility.check.' + account_id + '")!')
        runner = runner.replace("filmbox-credential-helper-v1", helper_name)
    source.write_text(gateway + "\n" + runner)
    binary = Path(os.environ.get("FILMBOX_CHECK_BINARY_DIR", str(root / ".build/arm64-apple-macosx/debug")))
    # Deliberately no DEBUG: this verifies Release never reads legacy items.
    subprocess.run(["swiftc", "-swift-version", "6", "-O", "-parse-as-library", "-I", str(binary / "Modules"),
                    str(source), *[str(p) for p in sorted((root / "Sources/Filmbox").glob("*.swift"))
                                  if p.name not in {"CloudGateway.swift", "FilmboxApp.swift"}],
                    *map(str, (binary / "FilmboxCore.build").glob("*.o")),
                    "-o", str(executable)], check=True, timeout=180)
    subprocess.run(["python3", "scripts/prepare-local-signing.py", "--sign", str(bundle),
                    "--identifier", "com.filmbox.app"], check=True, timeout=45, stdout=subprocess.DEVNULL)
    started = True
    subprocess.run([str(executable), account_id], check=True, timeout=45)
    completed = True
    if hashlib.sha256(helper.read_bytes()).digest() != source_digest:
        raise RuntimeError("Client validation changed its helper bytes")
    if hashlib.sha256(source_helper.read_bytes()).digest() != source_digest:
        raise RuntimeError("Client validation changed the frozen helper")
finally:
    if started and not completed:
        try:
            backup = helper.with_name(helper.name + ".fixture-backup")
            if backup.exists():
                backup.rename(helper)
            subprocess.run([str(executable), account_id, "cleanup"], check=True, timeout=15)
            completed = True
        except Exception:
            print(f"Random credential cleanup failed; retained cleanup probe: {work}, account: {account_id}", file=sys.stderr)
    if not started or completed:
        shutil.rmtree(work)
    if compatibility:
        subprocess.run(["/usr/bin/defaults", "delete", "filmbox.compatibility.check." + account_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
