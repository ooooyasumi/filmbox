#!/usr/bin/env python3
"""Compile a native check against the real Debug app, without its @main entry."""
from pathlib import Path
import subprocess
import sys

project = Path(__file__).resolve().parent.parent
if len(sys.argv) < 4:
    raise SystemExit("Usage: run-app-check.py BINARY_DIR RUNNER CHECK_NAME [ARG ...]")
binary_dir = Path(sys.argv[1]).resolve()
runner = project / sys.argv[2]
name = sys.argv[3]
if not (binary_dir / "Modules" / "Filmbox.swiftmodule").exists():
    raise SystemExit("缺少完整 Filmbox Debug 构建，请先运行 swift build。")
objects = [p for p in sorted((binary_dir / "Filmbox.build").glob("*.o"))
           if p.name != "FilmboxApp.swift.o"]
objects += sorted((binary_dir / "FilmboxCore.build").glob("*.o"))
if not objects:
    raise SystemExit("未找到 Filmbox 构建对象。")
checks_dir = project / ".build" / "NativeAppChecks" / name
checks_dir.mkdir(parents=True, exist_ok=True)
combined = checks_dir / "CheckRunner.swift"
combined.write_text("@testable import Filmbox\n" + runner.read_text())
executable = checks_dir / name
subprocess.run(["swiftc", "-swift-version", "6", "-D", "DEBUG", "-parse-as-library",
                "-module-name", name, "-I", str(binary_dir / "Modules"),
                str(combined), *map(str, objects), "-o", str(executable)], check=True)
subprocess.run([str(executable), *sys.argv[4:]], check=True)
