<p align="center"><img src="Sources/Resources/Twinfold-1024.png" width="160" alt="Twinfold のアイコン"></p>

# Twinfold

Finder にデュアル表示・クイックウインドウ・切り取りと移動を足す、macOS 用の小さな拡張です。
Finder の中に小さな dylib を読み込ませて動きます。Finder を置き換える別のファイラーではありません。

> **English summary** — Twinfold adds a dual-pane view (⌘U), a drop-down "quick window" (control+option+F) and real cut & paste (⌘X → ⌘V) to the macOS Finder by injecting a small dylib.
> It **requires System Integrity Protection to be disabled** and is meant for people who understand what that means. The UI is Japanese only for now. MIT License.

## ⚠️ 入れる前に

Twinfold は macOS の保護を外さないと動きません。

- **SIP（システム整合性保護）を無効にする必要があります。** Mac 全体の安全性が下がります。意味が分からない場合は入れないでください。
- Apple silicon では、起動設定（boot-args）とライブラリ検証の変更も必要です（下の「必要な設定」）。
- Apple の公証を受けていないアプリです（アドホック署名）。ソースを読んで自分でビルドすることもできます。
- 無保証です（MIT ライセンス）。Finder がおかしくなったときのために、すぐ外す方法を用意しています（「すぐ外す・アンインストール」）。

## できること

| 機能 | 操作 |
|---|---|
| デュアル表示 | `⌘U` で左右2画面と1画面を切り替え。右は同じフォルダで開く。左右それぞれでタブを使える。片方を動かすともう片方も付いてくる |
| クイックウインドウ | **control＋option＋F**（キーボード左下の control と option を押したまま F）で、どのアプリからでも画面下に Finder を出し入れ。編集アプリやメールへファイルをドラッグするときに使う。マウスのある画面の下に横いっぱいで出て、全デスクトップで使える。ほかのアプリに切り替えると隠れる（固定もできる）。上端をドラッグした高さは次回も使う |
| 切り取りと移動 | ファイルを `⌘X` → 移動先で `⌘V`。途中で別の物をコピーするか `esc` を押すと普通のペーストになる。名前の変更中など文字入力中は普通のカット＆ペースト |
| 隠しファイル・フォルダを常に上に | メニューバーから切り替え（隠しファイルは Finder 標準の `⌘⇧.` でも可） |
| タブ | Finder 標準のタブ（`⌘T`、`⌘W`、`⌃⇥`）をそのまま使う |

Finder の「ウインドウ」メニューにも「デュアル表示」「クイックウインドウを表示／隠す」「クイックウインドウを固定」が入ります。

### 設定（Finder 設定 → Twinfold）

Finder 設定（`⌘,`）のツールバーで「詳細」の右に「Twinfold」タブが出ます。メニューバーの「そのほかの設定…」からも開けます。

- クイックウインドウのオン・オフ
- ホットキー：ボタンを押してから新しいキーを押す。修飾キーが必要で、`esc` で取り消す
- 高さと、隠す条件
- デュアル表示と、切り取りのオン・オフ
- 「一時的にオフにする」と「アンインストール…」のボタン

## マニュアル

使い方は [docs/manual/Twinfold-Manual-JA.pdf](docs/manual/Twinfold-Manual-JA.pdf)（14ページ、キーの場所の図つき）にまとめています。
アプリのメニューバーの「マニュアルを開く」と、Finder 設定の Twinfold タブの「マニュアル」からも開けます。
元の文章は [docs/manual/MANUAL_JA.md](docs/manual/MANUAL_JA.md) です（`./build.sh manual` で PDF にする）。

## 対応環境

| 項目 | 内容 |
|---|---|
| macOS | 14 以降。macOS 27.2 と 26.6.2（Apple silicon）で確認済み |
| CPU | Apple silicon。Intel 用も入れてビルドしていますが、Intel Mac では試していません |
| ビルド | Command Line Tools の clang（Xcode は不要） |

## 必要な設定

3つとも、一度設定すれば macOS のアップデート後も残ります（27.2 で確認）。

1. **SIP を無効にする**：復旧モードで起動します（Apple silicon は電源ボタンを長押し →「オプション」）。ターミナルで次を実行して、再起動します。
   ```bash
   csrutil disable
   ```
2. **boot-args を追加する**（Apple silicon のみ）。設定したら再起動します。既にほかの boot-args を使っている場合は、それも並べて書いてください。
   ```bash
   sudo nvram boot-args=-arm64e_preview_abi
   ```
3. **ライブラリ検証を無効にする**：
   ```bash
   sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
   ```

確認するときは `csrutil status`、`nvram boot-args`、`defaults read /Library/Preferences/com.apple.security.libraryvalidation.plist` を使います。
足りない設定があると、Twinfold は Finder に触らずに、足りない項目をダイアログで知らせます。

元に戻すには、Twinfold をアンインストールしてから、次の3つを行います。
- 復旧モードで `csrutil enable` を実行する
- `sudo nvram -d boot-args` を実行する
- `sudo defaults delete /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation` を実行する

## インストール

### 配布版（ZIP）

1. Releases から `Twinfold-<版>.zip` をダウンロードして展開し、`Twinfold.app` を `/Applications`（または `~/Applications`）に入れます。
2. 公証していないので、初回は macOS に止められます。次のコマンドでダウンロードの印を外してから開きます。
   ```bash
   xattr -dr com.apple.quarantine /Applications/Twinfold.app
   ```
3. 開くと Finder が一度再起動し、メニューバーに Twinfold のアイコンが出ます。ログイン時に自動で起動するには、メニューの「ログイン時に起動」を選びます。

### ソースからビルド

```bash
./build.sh            # 単体試験 → ビルド（警告はエラー扱い）
./build.sh test       # 単体試験だけ
./build.sh install    # ビルドして ~/Applications/Twinfold.app に入れて起動
./build.sh dist       # ビルドして dist/Twinfold-<版>.zip を作る
```

新しい版を入れると、Finder の中にある古い版に気づいて、自動で組み込み直します（Finder が一度再起動します）。
アイコンを作り直すときは `tools/make_icon.sh` を実行します（`Sources/Resources/Twinfold.icns` を書き出します）。

## すぐ外す・アンインストール

| したいこと | 方法 |
|---|---|
| 一時的に外す | メニューバーの「Twinfold をオフにする」、または設定の「一時的にオフにする」。Finder が通常の Finder で再起動します。オフの状態は次のログイン後も続きます。戻すときは「Twinfold をオンにする」 |
| Finder がおかしいときに、組み込まずに起動する | `Shift` を押しながら Twinfold.app を起動します（その起動の間だけ止まります） |
| アンインストール | メニューバーか設定の「アンインストール…」。下の4つを行います |

アンインストールで行うこと：
- 通常の Finder に戻す
- ログイン項目を外す
- 設定ファイル（`~/Library/Preferences/com.lulu.twinfold.plist`）を消す
- `Twinfold.app` をゴミ箱に入れる

Finder 自体の設定（隠しファイル、フォルダを常に上に）は変えません。

Finder がコピー中などで終了しなかった場合は、アンインストールした後も、今の Finder には読み込まれたままです。
作業が終わってから Finder を再起動すると、完全に外れます（`⌥` を押しながら Dock の Finder を右クリック →「再度開く」）。

## 仕組み

```
Twinfold.app（メニューバー常駐、arm64 / x86_64）
  └─ Finder を終了させ、DYLD_INSERT_LIBRARIES=TwinfoldCore.dylib 付きで起動し直す
       └─ TwinfoldCore.dylib（arm64e / x86_64、Finder の中で動く）
            ├─ TWFQuickWindow … Carbon のホットキーと、NSWindow の位置・透明度のアニメーション
            ├─ TWFDual        … 2枚の Finder ウインドウを親子ウインドウにして左右に並べる
            ├─ TWFSettings    … Finder 設定のツールバーに「Twinfold」タブを足す
            └─ TWFCore        … ⌘X/⌘V を、メニュー項目「コピー」「ここに項目を移動」に置き換える
```

- **Finder の内部クラスには依存していません。** 使うのはキーイベント、メニュー項目（アクション名で探す）、NSWindow の公開 API だけです。
  Finder の中身に深く手を入れる拡張は macOS の更新で壊れやすいため、この方針にしています。
- 常駐アプリは Finder の起動と終了を見張り、通常の Finder が起動したら組み込み直します。
  ただし2分間に3回を超えたら、組み込みを止めて通常の Finder に戻します（Finder が落ち続けるのを防ぐため）。
- Finder がコピー中などで終了しないときは、強制終了しません（作業が壊れるため）。
- Finder は `responsibility_spawnattrs_setdisclaim` を使って起動し、フォルダへのアクセス許可を Finder 自身の名義にしています。
- 設定タブは、ツールバーの delegate を中継役で包み、Twinfold の項目だけを自分で返します。ほかの問い合わせは Finder にそのまま渡します。
  ツールバーの構成は保存させないので、アンインストールした後に Finder 設定へ項目が残りません。

### macOS 27.2 で分かったこと

- Finder の実行ファイルは `arm64e` と `arm64e.x1` の2つになり、x86_64 は無くなりました。arm64e の dylib はそのまま読み込めました。
- SIP の無効と `-arm64e_preview_abi` は、アップデート後も残っていました。
- 常駐アプリで、自分のバンドル ID と同じ名前を `NSUserDefaults initWithSuiteName:` に使うと、設定を読めなくなりました（26 では警告だけでした）。
- Finder 設定ウインドウの中身を差し替えたり、ウインドウの大きさを変えたりすると、Finder が大きさを合わせ続けて落ちました（`_enumeratingSubviewsCount` のアサーション）。そのため、上に重ねて表示しています。

### 記録を見る

```bash
/usr/bin/log stream --predicate 'subsystem == "com.lulu.twinfold"'
```

## 実機で確認したこと

macOS 27.2（Apple silicon、2026-11）：
- 組み込み：常駐アプリの起動、`killall Finder` 後の組み込み直し、版が変わったときの組み込み直し
- 設定タブ：「詳細」の右に出る。一般・詳細・サイドバーと繰り返し切り替えても落ちない
- 一時的にオフ：通常の Finder に戻り、オンに戻すと再び組み込まれる
- アンインストール：通常の Finder に戻り、アプリがゴミ箱に入り、設定が消える
- クイックウインドウの出し入れ、デュアル表示の分割
- クイックウインドウを隠しているときも、Dock の Finder を押すと新しいウインドウが開く（0.3.1 で修正。それまでは何も開かなかった）
- control＋option＋F（0.4.0 からの標準）を実際に押して、クイックウインドウが出る（日本語配列のキーボード）
- 設定タブの「マニュアル」ボタンで PDF が開く。一般・詳細・サイドバーと8回切り替えても落ちない

macOS 26.6.2：
- 単体試験（`tests/test_logic.c`）
- 組み込み直し、クイックウインドウ、デュアル表示
- 切り取りと移動：`⌘X` → 別のフォルダで `⌘V` でファイルが移動する

## 未確認・既知の制限

- 今後の macOS で、`DYLD_INSERT_LIBRARIES` や `-arm64e_preview_abi` の条件が変わると、読み込めなくなります。
- まだ実機で試していないもの：
  - Intel Mac での動作
  - クイックウインドウの中でのデュアル表示とタブ
  - 「フォルダを常に上に」「隠しファイル」のメニュー切り替え
  - ログイン時に起動
  - 設定タブでのホットキー変更
  - メニューバーからのオン・オフ（設定のボタンと同じ処理です）
- 設定タブは、直前に開いていた Finder のタブが小さいと、下がスクロールになります。
- 安全モードで起動して通常の Finder に戻したとき、一度だけ、Finder が起動しきらずに応答しなくなりました（ウインドウが開かず、終了もできない）。原因はまだ分かっていません。起きたときは、アクティビティモニタで Finder を終了すると、macOS が起動し直します。
- 切り取り中の項目を薄く表示する機能はありません。
- 画面の文字は日本語だけです。

## ライセンス

MIT License（[LICENSE](LICENSE)）。
