#!/usr/bin/env python3
"""Reject packages whose required executables cannot launch on Apple Silicon Sequoia."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def output(*args):
    return subprocess.check_output(list(map(str, args)), text=True, stderr=subprocess.STDOUT)


def verify(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("LSMinimumSystemVersion") != "15.0":
        raise RuntimeError("Info.plist 的最低版本必须是 macOS 15.0")
    primary = app / "Contents/MacOS/Filmbox"
    helpers = app / "Contents/Helpers"
    distribution = info.get("FilmboxCredentialProfile") == "developer-id-v1"
    legacy = helpers / "filmbox-credential-helper-v1"
    names = ["ffmpeg", "ffprobe", "filmbox-cloud-engine"]
    names += ["filmbox-credential-helper-distribution-v1"] if distribution else ["filmbox-credential-helper-macos15-v1", "filmbox-credential-helper-v1"]
    required = [primary, *(helpers / name for name in names)]
    for binary in required:
        if not binary.is_file() or binary.is_symlink():
            raise RuntimeError(f"缺少独立可执行组件：{binary.name}")
        if output("/usr/bin/lipo", "-archs", binary).strip() != "arm64":
            raise RuntimeError(f"组件架构不符：{binary.name}")
        match = re.search(r"\bminos\s+(\d+)\.(\d+)", output("/usr/bin/vtool", "-show-build", binary))
        if not match:
            raise RuntimeError(f"无法读取组件的最低系统要求：{binary.name}")
        minimum = tuple(map(int, match.groups()))
        # The byte-frozen legacy helper is used exclusively by existing Tahoe
        # installations. Sequoia must use the separate compatible helper.
        if binary == legacy:
            if minimum != (26, 0):
                raise RuntimeError("旧凭据组件必须保留原有构建身份")
        elif minimum > (15, 0):
            raise RuntimeError(f"{binary.name} 仍要求 macOS {minimum[0]}.{minimum[1]}")
        for line in output("/usr/bin/otool", "-L", binary).splitlines()[1:]:
            dependency = line.strip().split(" ", 1)[0]
            if not dependency.startswith(("/usr/lib/", "/System/Library/")):
                raise RuntimeError(f"组件依赖未随包提供的动态库：{binary.name}: {dependency}")
    newer_symbols = [line for line in output("/usr/bin/nm", "-m", primary).splitlines()
                     if "(undefined)" in line and ("glassEffect" in line or "7SwiftUI5GlassV" in line)]
    if any("weak external" not in line for line in newer_symbols):
        raise RuntimeError("macOS 26 玻璃效果被强链接，旧系统可能无法启动")
    print("macOS 15 / arm64 包检查通过：主程序、视频工具、云盘与兼容登录组件；新版玻璃接口仅弱链接")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: check-app-compatibility.py Filmbox.app")
    try:
        verify(Path(sys.argv[1]).resolve())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
