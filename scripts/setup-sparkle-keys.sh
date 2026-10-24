#!/bin/zsh
# アップデート署名用の鍵を作る（最初の1回だけ）
# 秘密鍵はログインキーチェーンに保存され、公開鍵だけを Resources/sparkle-public-key.txt に書き出す。
# 秘密鍵をなくすと既存ユーザーへアップデートを配れなくなるため、`generate_keys -x <file>` でバックアップしておくこと。
set -euo pipefail
cd "$(dirname "$0")/.."

swift package resolve >/dev/null
TOOLS=".build/artifacts/sparkle/Sparkle/bin"

"$TOOLS/generate_keys"
"$TOOLS/generate_keys" -p > Resources/sparkle-public-key.txt
echo "公開鍵を Resources/sparkle-public-key.txt に保存しました（コミットして構いません）"
