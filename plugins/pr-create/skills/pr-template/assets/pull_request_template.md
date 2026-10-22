# このPRで実現したいこと

<!--
「どんな課題があり、それをどう解決するのか」や「実現したい新規機能の概要」などをここに記述
処理やデータの流れ、コンポーネント・テーブルの関係、状態遷移など、文章より図のほうが伝わる内容は mermaid 図や画像も載せる (1〜2 行の文章で伝わるものは図にしない)
-->

## 関連リンク

<!--
このPRの関連issue, 関連webページ, slackなどへのリンク。 例: - #135
リポジトリ内のファイルを記述する場合はgithub上の該当ファイルへのリンクにする 例: [src/main.ts](https://github.com/<owner>/<repo>/blob/main/src/main.ts)
-->

## 変更内容

<!--
主な変更点を簡潔に箇条書き
構成や処理の流れが変わる場合は、before / after の図も載せる
-->

## 動作確認スクリーンショット

<!--
- VRT が無い画面、VRT で確認できない画面・状態や動きは、動作確認時のスクリーンショットや動画を添付
- 新しい画面・機能 (画面を伴うもの。既存画面への機能追加を含む) は、VRTの有無にかかわらず、その機能を一通り操作するウォークスルーの動画を添付
- VRT (リポジトリに commit された baseline 画像との比較) で差分を確認できる画面は、撮影の代わりに VRT の画像を以下のような形式で記載する
  - 画像URLは上限149文字なので、必ず短縮SHAを指定したURLにする
  - before は分岐元 (ベースブランチとの merge-base)、after は PR の head の短縮SHAにする (merge-base は `git rev-parse --short "$(git merge-base HEAD origin/<ベースブランチ>)"` で取れる)
  - 新しい画面で before の画像が無ければ、before は「なし (新規画面)」と書く
```
### <画面名>

| before | after |
| --- | --- |
| <img width="400" alt="before" src="https://github.com/<owner>/<repo>/blob/<before の短縮SHA>/<baseline 画像のパス>?raw=true"> | <img width="400" alt="after" src="https://github.com/<owner>/<repo>/blob/<after の短縮SHA>/<baseline 画像のパス>?raw=true"> |

### <画面名> (<状態>)

| before | after |
| --- | --- |
| <img width="400" alt="before" src="https://github.com/<owner>/<repo>/blob/<before の短縮SHA>/<baseline 画像のパス>?raw=true"> | <img width="400" alt="after" src="https://github.com/<owner>/<repo>/blob/<after の短縮SHA>/<baseline 画像のパス>?raw=true"> |
```
- UIの変更がない場合は実行ログなどを添付
- 動作確認がない場合は"なし"
-->

## 特に人間にレビューしてほしい箇所

<!-- 人間に重点的に見てほしい箇所(実装時に悩んだ箇所、設計判断、未対応の残課題など)があれば。ない場合は"なし" -->
