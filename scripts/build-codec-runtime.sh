#!/bin/bash
set -euo pipefail

# Build only the separately executed codec tools. No SwiftPM or system package
# manager is involved, and no installed Homebrew libraries enter this build.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RUNTIME_ROOT="$PROJECT_DIR/.build/CodecRuntime"
INSTALL_DIR="$RUNTIME_ROOT/install"
FFMPEG_VERSION="9.0.2"
FFMPEG_SHA256="8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
SOURCE_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
ARCHIVE="$RUNTIME_ROOT/downloads/ffmpeg-$FFMPEG_VERSION.tar.xz"
SOURCE_DIR="$RUNTIME_ROOT/src/ffmpeg-$FFMPEG_VERSION"
BUILD_DIR="$RUNTIME_ROOT/build-arm64"
STAGING_DIR="$RUNTIME_ROOT/.install.$$"
LOCK_DIR="$RUNTIME_ROOT/.build-lock"
LOCK_OWNED=false
VERIFY_ONLY=false
if [[ "${1:-}" == "--verify-only" && $# == 1 ]]; then
    VERIFY_ONLY=true
elif [[ $# != 0 ]]; then
    printf '用法：%s [--verify-only]\n' "$0" >&2
    exit 1
fi

fail() { printf 'Codec runtime: %s\n' "$*" >&2; exit 1; }
[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || fail "当前构建目标为 Apple Silicon macOS。"
for tool in /usr/bin/xcrun /usr/bin/make /usr/bin/curl /usr/bin/shasum /usr/bin/tar /usr/bin/otool /usr/bin/lipo /usr/bin/plutil; do
    [[ -x "$tool" ]] || fail "缺少 macOS 构建工具：$tool；请安装 Apple Command Line Tools。"
done
CLANG="$(/usr/bin/xcrun --sdk macosx --find clang)"
CLANGXX="$(/usr/bin/xcrun --sdk macosx --find clang++)"
AR="$(/usr/bin/xcrun --find ar)"
RANLIB="$(/usr/bin/xcrun --find ranlib)"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
JOBS="${CODEC_JOBS:-$(/usr/sbin/sysctl -n hw.logicalcpu)}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || fail "CODEC_JOBS 必须为正整数。"
if (( JOBS > 10 )); then JOBS=10; fi

sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
SCRIPT_SHA256="$(sha256 "$SCRIPT_DIR/build-codec-runtime.sh")"
FINGERPRINT="$(printf '%s\n' "$FFMPEG_SHA256" "$SCRIPT_SHA256" "$SDK_VERSION" "$("$CLANG" --version)" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"

verify_binary() {
    local binary="$1" dependency
    [[ -x "$binary" && -f "$binary" && ! -L "$binary" ]] || return 1
    [[ "$(/usr/bin/lipo -archs "$binary")" == "arm64" ]] || return 1
    while IFS= read -r dependency; do
        case "$dependency" in
            /usr/lib/*|/System/Library/*) ;;
            *) printf '拒绝非系统动态依赖：%s (%s)\n' "$dependency" "$binary" >&2; return 1 ;;
        esac
    done < <(/usr/bin/otool -L "$binary" | /usr/bin/awk 'NR > 1 {print $1}')
}

verify_install() {
    [[ -f "$INSTALL_DIR/.build-fingerprint" && "$(cat "$INSTALL_DIR/.build-fingerprint")" == "$FINGERPRINT" ]] || return 1
    [[ -f "$INSTALL_DIR/share/filmbox-codecs/runtime-info.json" ]] || return 1
    local name expected
    for name in ffmpeg ffprobe; do
        verify_binary "$INSTALL_DIR/bin/$name" || return 1
        expected="$(/usr/bin/plutil -extract "$name.SHA256" raw "$INSTALL_DIR/share/filmbox-codecs/runtime-info.json")" || return 1
        [[ "$(sha256 "$INSTALL_DIR/bin/$name")" == "$expected" ]] || return 1
    done
    [[ -f "$ARCHIVE" && "$(sha256 "$ARCHIVE")" == "$FFMPEG_SHA256" ]] || return 1
}

if verify_install; then
    printf 'Codec runtime 已验证：FFmpeg %s (arm64)\n%s\n' "$FFMPEG_VERSION" "$INSTALL_DIR"
    exit 0
fi
$VERIFY_ONLY && fail "runtime 缺失、版本已过期或完整性检查失败；运行 scripts/build-codec-runtime.sh 重新构建。"

mkdir -p -- "$RUNTIME_ROOT/downloads" "$RUNTIME_ROOT/src"
cleanup() {
    [[ ! -d "$STAGING_DIR" ]] || rm -rf -- "$STAGING_DIR"
    if $LOCK_OWNED; then rm -rf -- "$LOCK_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
waited=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if [[ -f "$LOCK_DIR/pid" ]]; then
        owner="$(cat "$LOCK_DIR/pid")"
        if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
            rm -rf -- "$LOCK_DIR"
            continue
        fi
    fi
    (( waited < 1800 )) || fail "等待其它 runtime 构建超时。"
    /bin/sleep 2
    waited=$((waited + 2))
done
LOCK_OWNED=true
printf '%s\n' "$$" > "$LOCK_DIR/pid"
# Another app build may have completed while we waited for its lock.
if verify_install; then
    printf 'Codec runtime 已由另一构建完成并验证。\n'
    exit 0
fi

if [[ ! -f "$ARCHIVE" ]]; then
    printf '下载官方 FFmpeg %s 源码（仅开发构建需要联网）…\n' "$FFMPEG_VERSION"
    /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 \
        --connect-timeout 20 --max-time 240 --retry 2 --output "$ARCHIVE.part" "$SOURCE_URL"
    [[ "$(sha256 "$ARCHIVE.part")" == "$FFMPEG_SHA256" ]] || fail "官方源码 SHA256 不匹配，未执行下载内容。"
    mv -- "$ARCHIVE.part" "$ARCHIVE"
fi
[[ "$(sha256 "$ARCHIVE")" == "$FFMPEG_SHA256" ]] || fail "源码归档 SHA256 不匹配；请检查 $ARCHIVE。"

# Always unpack the pinned archive when rebuilding; do not silently reuse an
# edited source tree. The archive and complete source remain available locally.
rm -rf -- "$SOURCE_DIR" "$BUILD_DIR"
/usr/bin/tar -xf "$ARCHIVE" -C "$RUNTIME_ROOT/src"
[[ "$(cat "$SOURCE_DIR/RELEASE")" == "$FFMPEG_VERSION" ]] || fail "源码版本标记不符。"
mkdir -p -- "$BUILD_DIR" "$STAGING_DIR/bin" "$STAGING_DIR/share/filmbox-codecs"

# Keep broad native decoding, but only the encoders, muxers, protocols and
# filters required for posters and an AVFoundation-compatible MP4 proxy.
CONFIGURE_ARGS=(
    --prefix="$STAGING_DIR"
    --arch=arm64 --target-os=darwin
    --cc="$CLANG" --cxx="$CLANGXX" --host-cc="$CLANG" --ar="$AR" --ranlib="$RANLIB"
    --sysroot="$SDK"
    --host-cflags="-isysroot $SDK -mmacosx-version-min=15.0"
    --host-ldflags="-isysroot $SDK -mmacosx-version-min=15.0"
    --extra-cflags=-mmacosx-version-min=15.0
    --extra-ldflags=-mmacosx-version-min=15.0
    --disable-autodetect --disable-gpl --disable-version3 --disable-nonfree
    --disable-shared --enable-static --enable-small
    --disable-debug --disable-doc --disable-ffplay --disable-avdevice
    --disable-network --disable-protocols --enable-protocol=file,pipe
    --disable-encoders --enable-encoder=h264_videotoolbox,aac,png,mjpeg
    --disable-muxers --enable-muxer=mp4,mov,image2,image2pipe
    --disable-filters --enable-filter=scale,format,null,aformat,aresample,anull,transpose,hflip,vflip,rotate,setsar
    --enable-videotoolbox --enable-audiotoolbox --enable-zlib
)
cd -- "$BUILD_DIR"
printf '配置并编译 FFmpeg %s（%s 个并行任务）…\n' "$FFMPEG_VERSION" "$JOBS"
# A clean PATH and disabled autodetection prevent accidental Homebrew linkage.
/usr/bin/env -u CFLAGS -u CPPFLAGS -u CXXFLAGS -u LDFLAGS -u LIBRARY_PATH \
    -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin PKG_CONFIG=/usr/bin/false \
    LC_ALL=C SDKROOT="$SDK" MACOSX_DEPLOYMENT_TARGET=15.0 \
    "$SOURCE_DIR/configure" "${CONFIGURE_ARGS[@]}" > configure-output.log 2>&1 || {
        tail -80 configure-output.log >&2
        fail "配置失败，详见 $BUILD_DIR/ffbuild/config.log。"
    }
/usr/bin/env -u CFLAGS -u CPPFLAGS -u CXXFLAGS -u LDFLAGS -u LIBRARY_PATH \
    -u CPATH -u C_INCLUDE_PATH -u CPLUS_INCLUDE_PATH \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C SDKROOT="$SDK" MACOSX_DEPLOYMENT_TARGET=15.0 \
    /usr/bin/make -j "$JOBS" ffmpeg ffprobe > build-output.log 2>&1 || {
        tail -100 build-output.log >&2
        fail "编译失败，详见 $BUILD_DIR/build-output.log。"
    }
for name in ffmpeg ffprobe; do
    cp -- "$BUILD_DIR/$name" "$STAGING_DIR/bin/$name"
    chmod 755 "$STAGING_DIR/bin/$name"
    verify_binary "$STAGING_DIR/bin/$name" || fail "$name 的架构或动态依赖不合格。"
done

NOTICE_DIR="$STAGING_DIR/share/filmbox-codecs"
cp -- "$SOURCE_DIR/COPYING.LGPLv2.1" "$NOTICE_DIR/COPYING.LGPLv2.1.txt"
cp -- "$SOURCE_DIR/LICENSE.md" "$NOTICE_DIR/FFmpeg-LICENSE.md"
cp -- "$PROJECT_DIR/Resources/Codecs/SOURCE_INFO.txt" "$NOTICE_DIR/SOURCE_INFO.txt"
cp -- "$SCRIPT_DIR/build-codec-runtime.sh" "$NOTICE_DIR/build-codec-runtime.sh"
cp -- "$PROJECT_DIR/docs/CODEC_RUNTIME.md" "$NOTICE_DIR/CODEC_RUNTIME.md"
"$STAGING_DIR/bin/ffmpeg" -hide_banner -buildconf > "$NOTICE_DIR/build-configuration.txt" 2>&1
"$STAGING_DIR/bin/ffmpeg" -hide_banner -L > "$NOTICE_DIR/runtime-license.txt" 2>&1
/usr/bin/grep -q '^License: LGPL version 2.1 or later$' "$BUILD_DIR/configure-output.log" || fail "配置后的 FFmpeg 许可不是 LGPL 2.1+。"
/usr/bin/grep -q 'version 2.1 of the License' "$NOTICE_DIR/runtime-license.txt" || fail "构建后的 FFmpeg 未报告 LGPL 2.1+。"
INFO="$NOTICE_DIR/runtime-info.json"
/usr/bin/plutil -create xml1 "$INFO"
/usr/bin/plutil -insert FFmpegVersion -string "$FFMPEG_VERSION" "$INFO"
/usr/bin/plutil -insert SourceURL -string "$SOURCE_URL" "$INFO"
/usr/bin/plutil -insert SourceSHA256 -string "$FFMPEG_SHA256" "$INFO"
/usr/bin/plutil -insert Architecture -string arm64 "$INFO"
/usr/bin/plutil -insert MinimumMacOSVersion -string 15.0 "$INFO"
/usr/bin/plutil -insert BuildScriptSHA256 -string "$SCRIPT_SHA256" "$INFO"
for name in ffmpeg ffprobe; do
    /usr/bin/plutil -insert "$name" -dictionary "$INFO"
    /usr/bin/plutil -insert "$name.SHA256" -string "$(sha256 "$STAGING_DIR/bin/$name")" "$INFO"
    /usr/bin/plutil -insert "$name.Bytes" -integer "$(/usr/bin/stat -f %z "$STAGING_DIR/bin/$name")" "$INFO"
done
/usr/bin/plutil -convert json "$INFO"
printf '%s\n' "$FINGERPRINT" > "$STAGING_DIR/.build-fingerprint"

# Preserve a previous successful runtime until a replacement is complete.
PREVIOUS_DIR="$RUNTIME_ROOT/.install.previous.$$"
if [[ -e "$INSTALL_DIR" ]]; then mv -- "$INSTALL_DIR" "$PREVIOUS_DIR"; fi
if ! mv -- "$STAGING_DIR" "$INSTALL_DIR"; then
    [[ ! -e "$PREVIOUS_DIR" ]] || mv -- "$PREVIOUS_DIR" "$INSTALL_DIR"
    fail "无法安装新的 runtime。"
fi
[[ ! -e "$PREVIOUS_DIR" ]] || rm -rf -- "$PREVIOUS_DIR"
verify_install || fail "最终 runtime 校验失败。"
printf 'Codec runtime 构建并验证完成：FFmpeg %s (arm64)\n%s\n' "$FFMPEG_VERSION" "$INSTALL_DIR"
/usr/bin/du -h "$INSTALL_DIR/bin/ffmpeg" "$INSTALL_DIR/bin/ffprobe"
