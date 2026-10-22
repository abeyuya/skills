# このPRで実現したいこと

<!--
「どんな課題があり、それをどう解決するのか」や「実現したい新規機能の概要」などをここに記述
処理やデータの流れ、コンポーネント・テーブルの関係、状態遷移など、文章より図のほうが伝わる内容は mermaid 図や画像も載せる (1〜2 行の文章で伝わるものは図にしない)
-->

## 関連リンク

<!--
このPRの関連issue, 関連webページ, slackなどへのリンク。 例: - #135
リポジトリ内のファイルを記述する場合はgithub上の該当ファイルへのリンクにする 例: [src/main.ts](https://github.com/<owner>/<repo>/blob/<ブランチ or コミットSHA>/src/main.ts)
-->

## 変更内容

<!--
主な変更点を簡潔に箇条書き
構成や処理の流れが変わる場合は、before / after の図も載せる
-->

## 動作確認スクリーンショット

<!--
- UIの変更がある場合は、影響を受ける画面の before / after のスクリーンショットを以下のような形式で添付
  - 画像はアップロードしたものを載せる。gh の `--attach` で添付するときは、URL の代わりにローカルのパスを書いておくと、アップロードした画像の URL に置き換わる
  - 新しい画面で before が無ければ、before は「なし (新規画面)」と書く
- 動き・アニメーション・画面遷移など、スクリーンショットで確認しにくい変化は before / after の動画を添付
  - 動画は表に入れず、参照だけを 1 つの段落に単独で書く (同じ段落や表のセルに入れると、プレーヤーではなくリンクとして表示される)。何の動画かは直前の段落に書く
- 新しい画面・機能 (画面を伴うもの。既存画面への機能追加を含む) は、その機能を一通り操作するウォークスルーの動画を添付
```
### <画面名>

| before | after |
| --- | --- |
| ![before: <画面名>](https://github.com/user-attachments/assets/<before の画像の ID>) | ![after: <画面名>](https://github.com/user-attachments/assets/<after の画像の ID>) |

### <画面名> (<状態>)

| before | after |
| --- | --- |
| ![before: <画面名> (<状態>)](https://github.com/user-attachments/assets/<before の画像の ID>) | ![after: <画面名> (<状態>)](https://github.com/user-attachments/assets/<after の画像の ID>) |

### <画面名> (<操作>の動画)

before: <何を操作した動画か>

![](https://github.com/user-attachments/assets/<before の動画の ID>)

after: <何を操作した動画か>

![](https://github.com/user-attachments/assets/<after の動画の ID>)
```
- UIの変更がない場合は実行ログなどを添付
- 動作確認がない場合は"なし"
-->

## 特に人間にレビューしてほしい箇所

<!-- 人間に重点的に見てほしい箇所(実装時に悩んだ箇所、設計判断、未対応の残課題など)があれば。ない場合は"なし" -->
