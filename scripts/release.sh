#!/bin/zsh
# リリース用の zip とアップデート情報（appcast.xml）を dist/ に作る
#   SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=... scripts/release.sh 0.1.0
# 作ったファイルを GitHub のリリースに添付すると、既存ユーザーに Sparkle 経由で配信される。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?使い方: scripts/release.sh <バージョン>  例: 0.1.0}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "バージョンは 0.1.0 のような X.Y.Z 形式で指定してください: $VERSION" >&2; exit 1; }
REPO="Ryuto42/ShelfTabs"
TOOLS=".build/artifacts/sparkle/Sparkle/bin"
BUILD_DIR="build"

[[ -s Resources/sparkle-public-key.txt ]] || { echo "先に scripts/setup-sparkle-keys.sh を実行してください" >&2; exit 1; }
# ad-hoc 署名だと更新のたびに利用者のアクセシビリティ許可が外れるため、リリースでは証明書を必須にする
[[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]] || { echo "SIGN_IDENTITY に証明書を指定してください（毎回同じ証明書を使うこと）" >&2; exit 1; }
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || echo "warning: コミットされていない変更があります" >&2

rm -rf dist "$BUILD_DIR" && mkdir -p dist

# CFBundleVersion は Sparkle が新旧の比較に使うため、必ず増える値にする（package.sh が日時を使う）
NO_INSTALL=1 OUT_DIR="$BUILD_DIR" ARCHS="arm64 x86_64" ./scripts/package.sh "$VERSION"
APP="$BUILD_DIR/ShelfTabs.app"
ZIP="dist/ShelfTabs-$VERSION.zip"

# Developer ID で署名し、NOTARY_PROFILE（xcrun notarytool store-credentials で作る）があれば公証する
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" dist/notarize.zip
  xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm dist/notarize.zip
else
  echo "warning: 公証していないビルドです。初回起動時に「右クリック → 開く」が必要になります" >&2
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 秘密鍵（キーチェーン）で zip に署名し、appcast.xml を作る
"$TOOLS/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  dist

# アプリは署名のない appcast.xml を受け付けない（SURequireSignedFeed）ため、署名されているか確かめる
grep -q "sparkle-signatures:" dist/appcast.xml || { echo "appcast.xml に署名がありません。generate_appcast の出力を確認してください" >&2; exit 1; }

shasum -a 256 "$ZIP"
cat <<MSG

できました:
  $ZIP
  dist/appcast.xml

公開するには（内容を確認してから実行してください）:
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION $ZIP dist/appcast.xml --title "ShelfTabs $VERSION" --generate-notes
MSG
