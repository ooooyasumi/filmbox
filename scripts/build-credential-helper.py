#!/usr/bin/env python3
"""Freeze a narrowly scoped credential process across local app updates.

Self-signed macOS processes receive a cdhash Keychain partition. Preserve this
small, reviewed helper byte-for-byte so changing the main app never changes its
credential identity. Source/identity changes fail closed and require migration.
"""
from pathlib import Path
import fcntl
import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
import argparse

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Tools/FilmboxCredentialHelper/main.swift"
parser = argparse.ArgumentParser()
parser.add_argument("--macos15", action="store_true", help="构建独立冻结的 macOS 15 凭据组件，保留旧版组件")
OPTIONS = parser.parse_args()
MINIMUM_MACOS = "15.0" if OPTIONS.macos15 else "26.0"
STORE = Path.home() / "Library/Application Support/Filmbox Development Signing" / ("credential-helper-macos15-v1" if OPTIONS.macos15 else "credential-helper-v1")
BINARY = STORE / "filmbox-credential-helper-v1"
MANIFEST = STORE / "manifest.json"
SIGNER = ROOT / "scripts/prepare-local-signing.py"


def run(args):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(result.stderr[-2000:] or "凭据组件构建失败。")
    return result.stdout.strip()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    identity = run([sys.executable, SIGNER])
    expected = {"version": 1, "sourceSHA256": sha(SOURCE), "certificateSHA1": identity, "architecture": platform.machine()}
    if OPTIONS.macos15:
        expected["minimumMacOS"] = MINIMUM_MACOS
    STORE.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(STORE, 0o700)
    fd = os.open(STORE / "build.lock", os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if MANIFEST.exists() or BINARY.exists():
            if not MANIFEST.exists() or not BINARY.exists():
                raise RuntimeError("凭据组件记录不完整，请恢复现有组件；未自动替换。")
            saved = json.loads(MANIFEST.read_text())
            if any(saved.get(k) != v for k, v in expected.items()) or saved.get("binarySHA256") != sha(BINARY):
                raise RuntimeError("凭据组件源代码、签名或文件发生变化，需要显式迁移，未自动替换现有组件。")
            run(["codesign", "--verify", "--strict", BINARY])
            run(["codesign", "--verify", "-R", '=identifier "com.filmbox.app.credential-helper.v1" and certificate leaf = H"' + identity + '"', BINARY])
        else:
            with tempfile.TemporaryDirectory(prefix="helper-build-", dir=STORE) as temporary:
                output = Path(temporary) / "filmbox-credential-helper-v1"
                run(["xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library", "-target",
                     platform.machine() + "-apple-macosx" + MINIMUM_MACOS, SOURCE, "-o", output])
                run([sys.executable, SIGNER, "--sign", output, "--identifier", "com.filmbox.app.credential-helper.v1"])
                expected["binarySHA256"] = sha(output)
                output.chmod(0o700)
                os.replace(output, BINARY)
                MANIFEST.write_text(json.dumps(expected, indent=2) + "\n")
        print(BINARY)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
