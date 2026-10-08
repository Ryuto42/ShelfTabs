# ShelfTabs

任意のアプリのウィンドウを「棚」にまとめ、タブで切り替える macOS 26 専用のメニューバーアプリ。

## 使い方

- 修飾キー（初期値 Shift）を押しながらウィンドウを別のウィンドウへドラッグして離すと合体し、ウィンドウ上端にタブバーが出る。
- タブをクリックで切替。ホバーで出る × でタブを分離。タブをバーの外へドラッグしても分離、別の棚のバーへドロップで移動。
- 末尾の「+」で、開いているウィンドウを追加。
- バーを右クリックで、棚の名前変更・アクセントカラー・棚の解散。
- Ctrl+Opt+←/→ でフォーカス中の棚のタブを順送り（設定で変更可）。
- メニューバーのアイコンから設定と「すべてのウィンドウを復元」を開ける。

## 外観

「透明度を下げる」「コントラストを上げる」とライト/ダークに追従し、リキッドグラスと単色を自動で切り替える。設定でスタイル・グラスの種類・テーマを固定できる。

## ビルドと実行

```sh
swift build
SIGN_IDENTITY="..." scripts/package.sh                # ビルドして /Applications/ShelfTabs.app にインストールし起動
SIGN_IDENTITY="..." NO_INSTALL=1 scripts/package.sh   # インストールせず dist/ShelfTabs.app に出力
swift scripts/generate-icon.swift /tmp/icon && iconutil -c icns /tmp/icon/AppIcon.iconset -o Resources/AppIcon.icns   # アイコン再生成
```

初回起動時にアクセシビリティ権限を求められる。システム設定 > プライバシーとセキュリティ > アクセシビリティで許可する。キー入力の監視用に「入力監視」も求められることがある。

署名 ID は環境変数 `SIGN_IDENTITY` で必ず指定する（未指定ならエラー）。Apple Development 証明書で署名すると、ビルドしてもアクセシビリティ権限が保持される。`SIGN_IDENTITY=-` で ad-hoc 署名にした場合は、ビルドごとに権限がリセットされる。バージョンは第1引数に `X.Y.Z` 形式で渡す（省略時は 0.1.0）。

```sh
security find-identity -v -p codesigning
SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" scripts/package.sh
```

## 仕組みと注意

- 非アクティブなタブのウィンドウは、SkyLight の `SLSSetWindowAlpha`（非公開 API）で透明にして同じ位置に重ねる。透明化できない場合は画面外へ移動する。
- 棚の状態はメモリ上のみ。再起動後には復元されない。
- 終了時と SIGTERM/SIGINT 受信時は、全ウィンドウを元の位置と不透明度に戻す。強制終了後に透明なウィンドウが残ったら、再起動して「すべてのウィンドウを復元」を実行する。

## ライセンス

MIT。Origami（MIT）の実装を参考にしている。詳細は THIRD_PARTY_NOTICES.md。
