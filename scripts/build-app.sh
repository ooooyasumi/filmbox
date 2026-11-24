#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${FILMBOX_BUILD_DIR:-$PROJECT_DIR/build}"
if [[ "$BUILD_DIR" != /* ]]; then
    printf 'FILMBOX_BUILD_DIR 必须是绝对路径。\n' >&2
    exit 1
fi
APP_DIR="$BUILD_DIR/Filmbox.app"
CODEC_INSTALL_DIR="$PROJECT_DIR/.build/CodecRuntime/install"
CLOUD_INSTALL_DIR="$PROJECT_DIR/.build/CloudEngine/install"
STAGING_DIR="$BUILD_DIR/.Filmbox.app.staging.$$"
PREVIOUS_DIR="$BUILD_DIR/.Filmbox.app.previous.$$"
ICON_DIR="$PROJECT_DIR/.build/AppIcon"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
    printf '用法：%s [release|debug]\n' "$0" >&2
    exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'Filmbox 需要在 macOS 上构建。\n' >&2
    exit 1
fi

SWIFT_BIN="$(xcrun --find swift)"
VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'VERSION 必须使用主版本.次版本.修订号格式。\n' >&2
    exit 1
fi

# The stable certificate authenticates the main app to the frozen credential
# helper. Its unchanged bytes preserve the Keychain cdhash partition; a local
# self-signed certificate alone does not preserve a changing app's partition.
SIGN_IDENTITY="${FILMBOX_SIGN_IDENTITY:-}"
DISTRIBUTION="${FILMBOX_DISTRIBUTION:-false}"
USE_LOCAL_SIGNING=false
if [[ "$DISTRIBUTION" == true && -z "$SIGN_IDENTITY" ]]; then
    printf '公开分发需要指定 Developer ID Application 签名身份。\n' >&2
    exit 1
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
    SIGN_IDENTITY="$(python3 "$SCRIPT_DIR/prepare-local-signing.py")"
    USE_LOCAL_SIGNING=true
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf '不使用临时签名构建正式应用：请配置稳定的 FILMBOX_SIGN_IDENTITY。\n' >&2
    exit 1
fi

cleanup() {
    if [[ ! -e "$APP_DIR" && -e "$PREVIOUS_DIR" ]]; then
        mv -- "$PREVIOUS_DIR" "$APP_DIR"
    fi
    if [[ -d "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd -- "$PROJECT_DIR"
"$SCRIPT_DIR/build-codec-runtime.sh"
"$SCRIPT_DIR/build-cloud-engine.sh"
if [[ "$DISTRIBUTION" == true ]]; then
    CREDENTIAL_HELPER="$(python3 "$SCRIPT_DIR/build-distribution-helper.py" --identity "$SIGN_IDENTITY")"
else
    CREDENTIAL_HELPER="$(python3 "$SCRIPT_DIR/build-credential-helper.py")"
    CREDENTIAL_HELPER_MACOS15="$(python3 "$SCRIPT_DIR/build-credential-helper.py" --macos15)"
fi
"$SWIFT_BIN" build -c "$CONFIGURATION" --product Filmbox
BINARY_DIR="$("$SWIFT_BIN" build -c "$CONFIGURATION" --show-bin-path)"
if [[ ! -x "$BINARY_DIR/Filmbox" ]]; then
    printf '没有找到可执行文件：%s\n' "$BINARY_DIR/Filmbox" >&2
    exit 1
fi

"$SWIFT_BIN" -swift-version 6 "$SCRIPT_DIR/generate-icon.swift" "$ICON_DIR"
mkdir -p -- "$STAGING_DIR/Contents/MacOS" "$STAGING_DIR/Contents/Helpers" "$STAGING_DIR/Contents/Resources/Licenses/Codecs"
mkdir -p -- "$STAGING_DIR/Contents/Resources/Licenses/CloudEngine"
cp -- "$CLOUD_INSTALL_DIR/filmbox-cloud-engine" "$STAGING_DIR/Contents/Helpers/filmbox-cloud-engine"
mkdir -p -- "$STAGING_DIR/Contents/Resources/CredentialHelper"
if [[ "$DISTRIBUTION" == true ]]; then
    cp -- "$CREDENTIAL_HELPER" "$STAGING_DIR/Contents/Helpers/filmbox-credential-helper-distribution-v1"
    cp -- "$PROJECT_DIR/Tools/FilmboxDistributionCredentialHelper/main.swift" "$STAGING_DIR/Contents/Resources/CredentialHelper/main.swift"
else
    cp -- "$CREDENTIAL_HELPER" "$STAGING_DIR/Contents/Helpers/filmbox-credential-helper-v1"
    cp -- "$CREDENTIAL_HELPER_MACOS15" "$STAGING_DIR/Contents/Helpers/filmbox-credential-helper-macos15-v1"
    cp -- "$PROJECT_DIR/Tools/FilmboxCredentialHelper/main.swift" "$STAGING_DIR/Contents/Resources/CredentialHelper/main.swift"
fi
for HELPER in "$STAGING_DIR/Contents/Helpers/filmbox-credential-helper-"*; do
    chmod 755 "$HELPER"
    codesign --verify --strict "$HELPER"
done
cp -- "$CLOUD_INSTALL_DIR/filmbox-cloud-engine-source.tar.gz" "$CLOUD_INSTALL_DIR/LICENSE" "$CLOUD_INSTALL_DIR/UPSTREAM.md" "$CLOUD_INSTALL_DIR/engine-build.json" "$STAGING_DIR/Contents/Resources/Licenses/CloudEngine/"
if [[ "$DISTRIBUTION" == true ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$STAGING_DIR/Contents/Helpers/filmbox-cloud-engine"
else
    codesign --force --sign - "$STAGING_DIR/Contents/Helpers/filmbox-cloud-engine"
fi
codesign --verify --strict "$STAGING_DIR/Contents/Helpers/filmbox-cloud-engine"
cp -- "$BINARY_DIR/Filmbox" "$STAGING_DIR/Contents/MacOS/Filmbox"
cp -- "$PROJECT_DIR/Resources/Info.plist" "$STAGING_DIR/Contents/Info.plist"
cp -- "$ICON_DIR/Filmbox.icns" "$STAGING_DIR/Contents/Resources/Filmbox.icns"
for CODEC_HELPER in ffmpeg ffprobe; do
    cp -- "$CODEC_INSTALL_DIR/bin/$CODEC_HELPER" "$STAGING_DIR/Contents/Helpers/$CODEC_HELPER"
    chmod 755 "$STAGING_DIR/Contents/Helpers/$CODEC_HELPER"
done
cp -R -- "$CODEC_INSTALL_DIR/share/filmbox-codecs/." "$STAGING_DIR/Contents/Resources/Licenses/Codecs/"
# Refresh prose notices even when unchanged codec binaries are reused.
cp -- "$PROJECT_DIR/Resources/Codecs/"* "$STAGING_DIR/Contents/Resources/Licenses/Codecs/"
cp -- "$PROJECT_DIR/docs/CODEC_RUNTIME.md" "$STAGING_DIR/Contents/Resources/Licenses/Codecs/CODEC_RUNTIME.md"
# Accompany the separately executed LGPL tools with their complete, exact
# unmodified source archive, as well as the recorded build script/configuration.
CODEC_VERSION="$(plutil -extract FFmpegVersion raw "$CODEC_INSTALL_DIR/share/filmbox-codecs/runtime-info.json")"
CODEC_SOURCE_ARCHIVE="$PROJECT_DIR/.build/CodecRuntime/downloads/ffmpeg-$CODEC_VERSION.tar.xz"
cp -- "$CODEC_SOURCE_ARCHIVE" "$STAGING_DIR/Contents/Resources/Licenses/Codecs/"

if [[ "$DISTRIBUTION" == true ]]; then
    python3 "$SCRIPT_DIR/prepare-legal.py" --output "$STAGING_DIR/Contents/Resources/Licenses/Filmbox" --public
else
    python3 "$SCRIPT_DIR/prepare-legal.py" --output "$STAGING_DIR/Contents/Resources/Licenses/Filmbox"
fi
cp -- "$PROJECT_DIR/Android/app/src/main/assets/Go-LICENSE" "$STAGING_DIR/Contents/Resources/Licenses/CloudEngine/Go-LICENSE"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGING_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$STAGING_DIR/Contents/Info.plist"
if [[ "$DISTRIBUTION" == true ]]; then
    /usr/libexec/PlistBuddy -c "Add :FilmboxCredentialProfile string developer-id-v1" "$STAGING_DIR/Contents/Info.plist"
fi
plutil -lint "$STAGING_DIR/Contents/Info.plist"
for CODEC_HELPER in ffmpeg ffprobe; do
    if [[ "$DISTRIBUTION" == true ]]; then
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$STAGING_DIR/Contents/Helpers/$CODEC_HELPER"
    else
        codesign --force --sign - "$STAGING_DIR/Contents/Helpers/$CODEC_HELPER"
    fi
    codesign --verify --strict "$STAGING_DIR/Contents/Helpers/$CODEC_HELPER"
    CODEC_HASH="$(shasum -a 256 "$STAGING_DIR/Contents/Helpers/$CODEC_HELPER" | awk '{print $1}')"
    plutil -insert "$CODEC_HELPER.PackagedSHA256" -string "$CODEC_HASH" "$STAGING_DIR/Contents/Resources/Licenses/Codecs/runtime-info.json"
done
if [[ "$USE_LOCAL_SIGNING" == true ]]; then
    python3 "$SCRIPT_DIR/prepare-local-signing.py" --sign "$STAGING_DIR"
else
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$STAGING_DIR"
fi
codesign --verify --deep --strict "$STAGING_DIR"
python3 - "$STAGING_DIR" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile
import re
app = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="filmbox-certificate-check-") as temporary:
    root = Path(temporary)
    certificates = []
    for index, path in enumerate([app] + sorted((app / "Contents/Helpers").glob("filmbox-credential-helper-*"))):
        details = subprocess.run(["codesign", "--display", "--verbose=4", str(path)],
                                 check=True, capture_output=True, text=True).stderr
        if not re.search(r"flags=0x[0-9a-f]+\([^\n)]*\bruntime\b", details):
            raise SystemExit("主程序与凭据组件必须启用运行时保护，未替换现有应用。")
        prefix = root / str(index)
        subprocess.run(["codesign", "--display", "--extract-certificates=" + str(prefix), str(path)],
                       check=True, capture_output=True)
        certificates.append(Path(str(prefix) + "0").read_bytes())
    if any(certificate != certificates[0] for certificate in certificates[1:]):
        raise SystemExit("主程序与固定凭据组件的签名身份不同，需要先做凭据迁移，未替换现有应用。")
PY
python3 "$SCRIPT_DIR/check-app-compatibility.py" "$STAGING_DIR"
python3 "$SCRIPT_DIR/check-macos-package.py" "$STAGING_DIR"

mkdir -p -- "$BUILD_DIR"
if [[ -e "$APP_DIR" ]]; then
    mv -- "$APP_DIR" "$PREVIOUS_DIR"
fi
if ! mv -- "$STAGING_DIR" "$APP_DIR"; then
    if [[ -e "$PREVIOUS_DIR" ]]; then
        mv -- "$PREVIOUS_DIR" "$APP_DIR"
    fi
    exit 1
fi
if [[ -e "$PREVIOUS_DIR" ]]; then
    rm -rf -- "$PREVIOUS_DIR"
fi

printf '\n已构建 Filmbox %s\n%s\n' "$VERSION" "$APP_DIR"
if [[ "$DISTRIBUTION" == true ]]; then
    printf 'Developer ID 候选包已签名，需继续公证与附加票据。\n'
else
    printf '此候选包使用本地签名，公开下载前需完成 Developer ID 分发流程。\n'
fi
