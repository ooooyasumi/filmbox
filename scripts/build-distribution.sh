#!/bin/bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${FILMBOX_SIGN_IDENTITY:?请配置有效的 Developer ID Application 身份名称或 SHA-1。}"
: "${FILMBOX_NOTARY_PROFILE:?请配置已保存到钥匙串的 notarytool 配置名称。}"
python3 "$ROOT/scripts/check-release.py"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
export FILMBOX_DISTRIBUTION=true
export FILMBOX_BUILD_DIR="$ROOT/build/distribution/$VERSION"
"$ROOT/scripts/build-app.sh" release
python3 "$ROOT/scripts/notarize-app.py" "$FILMBOX_BUILD_DIR/Filmbox.app" \
  --keychain-profile "$FILMBOX_NOTARY_PROFILE" --output "$FILMBOX_BUILD_DIR/Filmbox-$VERSION.zip"
