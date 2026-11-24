#!/usr/bin/env python3
"""Create a stable, private Android signing identity. Never print secret values."""
import os
import pathlib
import secrets
import subprocess
import sys

base = pathlib.Path(os.environ.get("FILMBOX_ANDROID_SIGNING_DIR", str(pathlib.Path.home() / "Library/Application Support/Filmbox Development Signing/Android")))
base.mkdir(parents=True, exist_ok=True)
base.chmod(0o700)
config = base / "signing.properties"
if not config.exists():
    store = base / "filmbox-android.jks"
    if store.exists():
        sys.exit("Signing configuration is missing; preserve the existing keystore and restore its configuration.")
    password = secrets.token_urlsafe(36)
    env = os.environ.copy()
    env["FILMBOX_SIGN_PASS"] = password
    java = pathlib.Path(os.environ["JAVA_HOME"]) / "bin/keytool"
    subprocess.run([str(java), "-genkeypair", "-keystore", str(store), "-storetype", "JKS", "-alias", "filmbox", "-storepass:env", "FILMBOX_SIGN_PASS", "-keypass:env", "FILMBOX_SIGN_PASS", "-keyalg", "RSA", "-keysize", "3072", "-validity", "10950", "-dname", "CN=Filmbox Android, OU=Development, O=Filmbox"], env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    store.chmod(0o600)
    fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        output.write(f"storeFile={store}\nstorePassword={password}\nkeyAlias=filmbox\nkeyPassword={password}\n")
print(config)
