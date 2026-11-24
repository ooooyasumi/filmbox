#!/bin/sh
set -eu
FILMBOX_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -z "${JAVA_HOME:-}" ]; then
  if [ -d /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ]; then
    JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
    export JAVA_HOME
  fi
fi
FILMBOX_GO=${FILMBOX_GO:-/usr/local/go/bin/go}
if [ ! -x "$FILMBOX_GO" ]; then FILMBOX_GO=$(command -v go); fi
FILMBOX_ANDROID="$FILMBOX_ROOT/Android"
python3 "$FILMBOX_ROOT/scripts/generate-android-icon.py" --check
mkdir -p "$FILMBOX_ANDROID/app/src/main/jniLibs/arm64-v8a" "$FILMBOX_ANDROID/app/src/main/assets"
FILMBOX_ENGINE_OS=android "$FILMBOX_ROOT/scripts/build-cloud-engine.sh"
cp "$FILMBOX_ROOT/.build/CloudEngine/android-arm64/filmbox-cloud-engine" "$FILMBOX_ANDROID/app/src/main/jniLibs/arm64-v8a/libfilmbox_cloud.so"
cp "$FILMBOX_ROOT/.build/CloudEngine/android-arm64/filmbox-cloud-engine-source.tar.gz" "$FILMBOX_ANDROID/app/src/main/assets/cloud-source.tgz"
cp "$FILMBOX_ROOT/CloudEngine/LICENSE" "$FILMBOX_ANDROID/app/src/main/assets/CloudEngine-LICENSE"
FILMBOX_SIGNING=$(python3 "$FILMBOX_ROOT/scripts/android-signing.py")
if [ -n "${FILMBOX_GRADLE:-}" ]; then
  "$FILMBOX_GRADLE" -p "$FILMBOX_ANDROID" :app:testDebugUnitTest :app:lintRelease :app:assembleRelease "-PfilmboxSigningProperties=$FILMBOX_SIGNING"
else
  "$FILMBOX_ANDROID/gradlew" -p "$FILMBOX_ANDROID" :app:testDebugUnitTest :app:lintRelease :app:assembleRelease "-PfilmboxSigningProperties=$FILMBOX_SIGNING"
fi
FILMBOX_ANDROID_VERSION=$(cat "$FILMBOX_ANDROID/VERSION")
FILMBOX_DEST="$FILMBOX_ROOT/build/android/$FILMBOX_ANDROID_VERSION"
mkdir -p "$FILMBOX_DEST"
cp "$FILMBOX_ANDROID/app/build/outputs/apk/release/app-release.apk" "$FILMBOX_DEST/Filmbox-Android-$FILMBOX_ANDROID_VERSION-arm64.apk"
python3 "$FILMBOX_ROOT/scripts/check-android-package.py" "$FILMBOX_DEST/Filmbox-Android-$FILMBOX_ANDROID_VERSION-arm64.apk" > "$FILMBOX_DEST/verification.json"
printf 'Android APK: %s\n' "$FILMBOX_DEST/Filmbox-Android-$FILMBOX_ANDROID_VERSION-arm64.apk"
