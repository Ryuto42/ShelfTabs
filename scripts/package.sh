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
if [ "${NO_INSTALL:-0}" = "1" ]; then
  APP_DIR="$ROOT/dist/${APP_NAME}.app"
else
  STAGING="$(mktemp -d)"
  trap 'rm -rf "$STAGING"' EXIT
  APP_DIR="$STAGING/${APP_NAME}.app"
fi

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
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Signing (${SIGN_IDENTITY})"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"

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
