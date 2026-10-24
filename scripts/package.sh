#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ShelfTabs"
VERSION="${1:-0.1.0}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: バージョンは X.Y.Z 形式で指定してください: ${VERSION}" >&2
  exit 1
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
  echo "ERROR: SIGN_IDENTITY を指定してください（例: SIGN_IDENTITY=\"Apple Development: Your Name (XXXXXXXXXX)\"、ad-hoc 署名は SIGN_IDENTITY=-）" >&2
  exit 1
fi
# Sparkle は CFBundleVersion の大小で新旧を判定するため、必ず増える値にする
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  echo "ERROR: BUILD は数字のみで指定してください: ${BUILD}" >&2
  exit 1
fi
if [ "${NO_INSTALL:-0}" = "1" ]; then
  APP_DIR="${OUT_DIR:-$ROOT/dist}/${APP_NAME}.app"
else
  STAGING="$(mktemp -d)"
  trap 'rm -rf "$STAGING"' EXIT
  APP_DIR="$STAGING/${APP_NAME}.app"
fi

cd "$ROOT"

arch_flags=()
for arch in ${ARCHS:-}; do arch_flags+=(--arch "$arch"); done

echo "==> Building ${APP_NAME} ${VERSION} (${BUILD})"
swift build -c release ${arch_flags[@]+"${arch_flags[@]}"}
BIN_DIR="$(swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"

echo "==> Creating app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
PLIST="$APP_DIR/Contents/Info.plist"
sed -e "s/VERSION_PLACEHOLDER/${VERSION}/g" -e "s/BUILD_PLACEHOLDER/${BUILD}/g" "$ROOT/Resources/Info.plist" > "$PLIST"
if [ -s "$ROOT/Resources/sparkle-public-key.txt" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $(tr -d '[:space:]' < "$ROOT/Resources/sparkle-public-key.txt")" "$PLIST"
else
  echo "warning: Resources/sparkle-public-key.txt がないため、このビルドでは自動アップデートが無効です（scripts/setup-sparkle-keys.sh で作成）" >&2
fi
plutil -lint "$PLIST" >/dev/null
cp "$BIN_DIR/${APP_NAME}" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
for lproj in "$ROOT"/Resources/*.lproj; do ditto "$lproj" "$APP_DIR/Contents/Resources/$(basename "$lproj")"; done
FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$FRAMEWORK"
# サンドボックスを使わないため XPC サービスは不要
rm -rf "$FRAMEWORK/Versions/B/XPCServices" "$FRAMEWORK/XPCServices"

echo "==> Signing (${SIGN_IDENTITY})"
sign_args=(--force --options runtime --sign "$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" != "-" ]; then
  sign_args+=(--timestamp)
fi
# --deep は使わず、内側から順に署名する
codesign "${sign_args[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${sign_args[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${sign_args[@]}" "$FRAMEWORK"
codesign "${sign_args[@]}" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> Built"

if [ "${NO_INSTALL:-0}" = "1" ]; then
  exit 0
fi

INSTALL_DIR="/Applications/${APP_NAME}.app"
echo "==> Installing to ${INSTALL_DIR}"
if pgrep -x "$APP_NAME" >/dev/null; then
  pkill -x "$APP_NAME" || true
  for _ in $(seq 1 50); do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.1
  done
fi
rm -rf "$INSTALL_DIR"
ditto "$APP_DIR" "$INSTALL_DIR"
open "$INSTALL_DIR"
echo "==> Done: ${INSTALL_DIR}"
