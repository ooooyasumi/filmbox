#!/usr/bin/env python3
"""Stable local code signing, without changing certificate trust or app ACLs.

The private signing identity lives in its own encrypted keychain. Its random
password lives in the login keychain, accessible to Apple's security tool for
local builds. No cloud credentials are read here. Temporary key material is
owner-only and removed. Only public identity metadata is printed.
"""
from pathlib import Path
import argparse
import fcntl
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
import unicodedata

LABEL = "Filmbox Local Development"
SECURITY = "/usr/bin/security"
OPENSSL = "/usr/bin/openssl"
SERVICE = "com.filmbox.build.signing"
ACCOUNT = "local-code-signing-v1"
FOLDER = Path.home() / "Library/Application Support/Filmbox Development Signing"
KEYCHAIN = FOLDER / "signing.keychain-db"
METADATA = FOLDER / "identity.json"


def security_argument(value):
    value = str(value)
    if any(unicodedata.category(character) in ("Cc", "Zl", "Zp") for character in value):
        raise RuntimeError("签名参数含控制字符，未执行钥匙串操作。")
    # security's interactive parser supports double quotes and backslash
    # escapes; shell quoting is not its grammar. One private stdin command is
    # followed immediately by EOF, and its real failure exit code is retained.
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def run(args, *, check=True, timeout=30):
    command = list(map(str, args))
    private_input = None
    if command[0] == SECURITY:
        # Passwords never enter argv, environment variables, or diagnostics.
        # The noninteractive pipe is not echoed and is closed after one command.
        private_input = " ".join(map(security_argument, command[1:])) + "\n"
        command = [SECURITY, "-q", "-i", "-p", ""]
    try:
        result = subprocess.run(command, input=private_input, text=True, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        # Captured output and subprocess exceptions can contain sensitive data.
        raise RuntimeError("本地签名操作超时，请检查登录钥匙串是否已解锁。") from None
    if check and result.returncode:
        raise RuntimeError("本地签名操作失败，请检查登录钥匙串是否已解锁。")
    return result


def password():
    return run([SECURITY, "find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"]).stdout.rstrip("\n")


def fingerprint():
    metadata = json.loads(METADATA.read_text())
    value = metadata.get("fingerprint", "")
    if not re.fullmatch(r"[0-9A-F]{40}", value):
        raise RuntimeError("本地签名身份记录损坏，请恢复原身份，未自动更换证书。")
    output = run([SECURITY, "find-identity", "-p", "codesigning", str(KEYCHAIN)]).stdout
    matches = []
    for line in output.splitlines():
        match = re.match(r'\s*\d+\) ([0-9A-Fa-f]{40}) "' + re.escape(LABEL) + r'"(.*)$', line)
        if match and match[1].upper() == value:
            matches.append(match[2].strip())
    if not matches or any(note and note != "(CSSMERR_TP_NOT_TRUSTED)" for note in matches):
        raise RuntimeError("原有本地签名身份不可用，请恢复原身份，未自动更换证书。")
    return value


def ensure_identity():
    if KEYCHAIN.exists() or METADATA.exists():
        if not KEYCHAIN.exists() or not METADATA.exists():
            raise RuntimeError("本地签名身份不完整，请恢复原身份，未自动创建替代证书。")
        run([SECURITY, "unlock-keychain", "-p", password(), str(KEYCHAIN)])
        return fingerprint()
    previous_password = run([SECURITY, "find-generic-password", "-s", SERVICE, "-a", ACCOUNT], check=False)
    if previous_password.returncode == 0:
        raise RuntimeError("已存在本地签名记录但身份文件缺失，请恢复原身份。")
    old_mask = os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix="filmbox-local-signing-") as temporary:
            folder = Path(temporary)
            config, key, cert, password_file, archive = [folder / name for name in
                ("certificate.cnf", "private.pem", "certificate.pem", "password", "identity.p12")]
            config.write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
                              f"[dn]\nCN={LABEL}\n[ext]\nbasicConstraints=critical,CA:FALSE\n"
                              "keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n")
            secret = secrets.token_urlsafe(40)
            password_file.write_text(secret)
            run([OPENSSL, "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256",
                 "-days", "3650", "-set_serial", str(secrets.randbits(127) + 1), "-config", str(config),
                 "-keyout", str(key), "-out", str(cert)])
            run([OPENSSL, "pkcs12", "-export", "-inkey", str(key), "-in", str(cert),
                 "-name", LABEL, "-out", str(archive), "-passout", "file:" + str(password_file)])
            run([SECURITY, "create-keychain", "-p", secret, str(KEYCHAIN)])
            os.chmod(KEYCHAIN, 0o600)
            run([SECURITY, "unlock-keychain", "-p", secret, str(KEYCHAIN)])
            run([SECURITY, "set-keychain-settings", "-l", "-u", "-t", "1800", str(KEYCHAIN)])
            run([SECURITY, "import", str(archive), "-k", str(KEYCHAIN), "-P", secret, "-T", "/usr/bin/codesign"])
            # This keychain contains only our new signing key. No existing user
            # key or cloud-credential ACL is changed by this tool partition.
            run([SECURITY, "set-key-partition-list", "-S", "apple-tool:", "-s", "-t", "private",
                 "-k", secret, str(KEYCHAIN)])
            run([SECURITY, "add-generic-password", "-s", SERVICE, "-a", ACCOUNT,
                 "-w", secret, "-T", SECURITY])
            value = run([OPENSSL, "x509", "-in", str(cert), "-noout", "-fingerprint", "-sha1"]).stdout
            value = value.strip().split("=", 1)[1].replace(":", "").upper()
            METADATA.write_text(json.dumps({"version": 1, "fingerprint": value}, indent=2) + "\n")
            return fingerprint()
    finally:
        os.umask(old_mask)


def sign(bundle, identity, identifier=None, requirements=None, options="runtime"):
    old_paths = shlex.split(run([SECURITY, "list-keychains", "-d", "user"]).stdout)
    added = str(KEYCHAIN) not in old_paths
    try:
        # codesign requires a searchable certificate chain even with --keychain.
        # Add only during signing, then remove only our entry; preserve others.
        if added:
            run([SECURITY, "list-keychains", "-d", "user", "-s", *old_paths, str(KEYCHAIN)])
        args = ["/usr/bin/codesign", "--force", "--sign", identity, "--keychain", str(KEYCHAIN), "--timestamp=none"]
        if options:
            args += ["--options", options]
        if identifier:
            args += ["--identifier", identifier]
        if requirements:
            args += ["--requirements", requirements]
        run([*args, bundle])
        run(["/usr/bin/codesign", "--verify", "--strict", bundle])
    finally:
        if added:
            current = shlex.split(run([SECURITY, "list-keychains", "-d", "user"]).stdout)
            run([SECURITY, "list-keychains", "-d", "user", "-s", *[p for p in current if p != str(KEYCHAIN)]])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sign")
    parser.add_argument("--identifier")
    parser.add_argument("--requirements")
    parser.add_argument("--keychain", action="store_true")
    parser.add_argument("--options", default="runtime")
    args = parser.parse_args()
    FOLDER.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(FOLDER, 0o700)
    lock_path = FOLDER / "signing.lock"
    lock_fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(lock_fd, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        identity = ensure_identity()
        if args.sign:
            sign(args.sign, identity, args.identifier, args.requirements, args.options)
        else:
            print(KEYCHAIN if args.keychain else identity)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
