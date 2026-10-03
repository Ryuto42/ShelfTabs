#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ShelfTabs"
VERSION="${1:-0.1.0}"
if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
APP_DIR="$ROOT/dist/${APP_NAME}.app"

cd "$ROOT"

echo "==> Building ${APP_NAME} ${VERSION}"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/${APP_NAME}"

echo "==> Creating app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
sed "s/VERSION_PLACEHOLDER/${VERSION}/g" "$ROOT/Resources/Info.plist" > "$APP_DIR/Contents/Info.plist"
cp "$BINARY" "$APP_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${APP_NAME}"

echo "==> Signing (${SIGN_IDENTITY})"
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "==> Done: $APP_DIR"
