# ShelfTabs

[English](README.md)

任意のアプリのウィンドウを「棚」にまとめ、タブで切り替える macOS 26 以降向けのメニューバーアプリです。

## 主な機能

- **どのアプリでもタブに**：ウィンドウを別のウィンドウの左上へドラッグし、青い枠が出たところで離すと合体します。修飾キー（初期値は Shift）を押しながらなら、ウィンドウのどこに離しても合体します
- **タブの切り替え**：合体したウィンドウの信号機の上に、小さなグラスのボタンが出ます。ボタンにポインタを合わせるとタブの一覧が開き、行にポインタを置くとそのタブに切り替わります
- **タブの操作**：一覧の行を外へドラッグすると分離、別の棚のボタンへドロップすると移動、≡ で並べ替えができます。「ウィンドウを追加」で開いているウィンドウを加えられます。ボタンの右クリックで、棚の名前変更・アクセントカラー・解散ができます。1 つを最小化すると棚ごと最小化します
- **キーボード**：Ctrl+Opt+[ / ] でフォーカス中の棚のタブを順送りします（設定で変更可）
- **Finder・プレビュー**：同じアプリのウィンドウはネイティブタブにまとめます。新しいウィンドウを既存のウィンドウのタブで開けるほか、タブにポインタを置くだけで切り替えられます
- **ウィンドウのスナップ**：画面の端や角へドラッグ、またはショートカットでウィンドウを配置します。領域とショートカットは設定で変更できます
- **外部 Dock 対応**：サードパーティ製 Dock アプリの分だけ画面の余白を空けます
- **外観の自動切り替え**：「透明度を下げる」「コントラストを上げる」とライト/ダークに追従し、リキッドグラスと単色を切り替えます
- **自動アップデート**：[Sparkle](https://sparkle-project.org) を使い、EdDSA 署名を検証してから更新を適用します

## スクリーンショット

_準備中です。_

## インストール

macOS 26 Tahoe 以降（Apple シリコン / Intel）が必要です。

1. [Releases](https://github.com/Ryuto42/ShelfTabs/releases) から `ShelfTabs-x.y.z.zip` をダウンロードして展開し、`ShelfTabs.app` を「アプリケーション」フォルダへ移します
2. 公証されていないリリースは、初回の起動が止められます。一度 `ShelfTabs.app` を開いてから、システム設定 > プライバシーとセキュリティ で「このまま開く」を押してください。ターミナルで次を実行しても開けるようになります

   ```sh
   xattr -dr com.apple.quarantine /Applications/ShelfTabs.app
   ```

3. 求められた権限を許可します

Homebrew には未対応です。

## 必要な権限

- **アクセシビリティ**（必須）：ウィンドウの取得と移動、キー・マウス操作の受け取りに使います。システム設定 > プライバシーとセキュリティ > アクセシビリティで許可してください
- **入力監視**：ショートカットとドラッグの検出のために求められることがあります

署名の異なるビルドは別のアプリとして扱われるため、署名が変わる更新のあとはアクセシビリティの許可をやり直す必要がある場合があります。

## プライバシー

ShelfTabs は分析も利用状況の送信も行いません。通信するのは Sparkle のアップデート確認（GitHub から `appcast.xml` と更新ファイルを取得）だけです。Mac 上で読み取るものは次のとおりです。

- **ウィンドウ**：タブバーの表示と移動のため、ほかのアプリのウィンドウのタイトル・位置・大きさ・ウィンドウ ID をアクセシビリティ API で読み取ります。下記の退避記録以外は保存しません
- **キーとマウス**：キーコードは設定したショートカットと照合するだけで、保存も送信もしません。それ以外の入力はそのままアプリに渡します
- **Finder・プレビュー**：ネイティブタブの合体・分離のため、この 2 つのアプリのメニュー項目を操作します
- **外部 Dock アプリ**（任意）：選んだアプリの設定 `reservedAreas` を読み、必要な余白を調べます
- **壁紙**：スナップ設定のプレビュー表示にだけデスクトップ画像を読み込みます
- **設定**：ショートカット・外観・記憶した外部 Dock の位置などを UserDefaults（`com.ryuto.shelftabs`）に保存します
- **非公開 API**：SkyLight（`SLSSetWindowAlpha` など）と `_AXUIElementGetWindow` を使います。macOS のアップデートで動かなくなる可能性があり、Mac App Store では配布できません

## クラッシュしたときの復元

タブの裏に隠したウィンドウは `~/Library/Application Support/ShelfTabs/parked.json` に記録します。強制終了やクラッシュで画面外に残ったウィンドウは、次回起動時（アクセシビリティ権限がある場合）に自動で画面内へ戻ります。メニューバーのアイコンから「すべてのウィンドウを復元」を選んでも戻せます。棚そのものは再起動後には復元されません。

## ソースからビルド

Xcode 26 以降が必要です。

```sh
git clone https://github.com/Ryuto42/ShelfTabs.git
cd ShelfTabs
swift build
```

アプリを作って署名し、`/Applications` にインストールして起動するには次を実行します。

```sh
security find-identity -v -p codesigning
SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" scripts/package.sh
```

`NO_INSTALL=1` を付けるとインストールせず `dist/ShelfTabs.app` に出力します。`SIGN_IDENTITY=-` は ad-hoc 署名で、ビルドのたびにアクセシビリティの許可がリセットされます。`Resources/sparkle-public-key.txt` がないビルドでは自動アップデートが無効です。

### リリースの作り方（メンテナー向け）

```sh
scripts/setup-sparkle-keys.sh   # 最初の1回だけ。署名鍵を作り、公開鍵を保存
SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=... scripts/release.sh 0.1.0
```

`dist/` にユニバーサルの zip と署名付き `appcast.xml` を作り、`gh release create` のコマンドを表示します。Developer ID がない場合は Apple Development 証明書でも作れます（`NOTARY_PROFILE` は省き、公証なしになります）。更新後もアクセシビリティの許可が残るよう、リリースは毎回同じ証明書で署名してください。秘密鍵は `generate_keys -x` で必ずバックアップしてください。

## アンインストール

ShelfTabs を終了し、`/Applications/ShelfTabs.app` を削除します。ログイン時に起動を有効にしていた場合は、先に設定でオフにしてください。不要なら `~/Library/Application Support/ShelfTabs` を削除し、`defaults delete com.ryuto.shelftabs` で設定も消せます。

## ライセンス

[MIT](LICENSE)

## クレジット

実装の一部は Origami（MIT、XiaoXianThis）を参考に改変しています。アップデートには [Sparkle](https://sparkle-project.org)（MIT）を使っています。詳細は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) を参照してください。
