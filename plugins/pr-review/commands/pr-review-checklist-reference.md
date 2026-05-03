---
description: PR レビュー時に anthropics/claude-code の pr-review-toolkit エージェント群を呼び出して技術観点レビューを行うよう指示する。
argument-hint: '[focus=all|tests|errors|comments|types|quality|simplify]'
---

# PR レビュー時の技術観点ガイド (pr-review-toolkit 呼び出し)

レビューで **何を見るか (技術観点)** は、anthropics/claude-code リポジトリの [`pr-review-toolkit`](https://github.com/anthropics/claude-code/blob/5bf19945e4e9e38d298ddc2befd5c30a7d504fb8/plugins/pr-review-toolkit/README.md) が提供する各エージェントに委譲してください。本ファイルでは観点の中身は転記しません。最新の定義は上記 README を参照してください。

レビューコメントの **書き方・体裁** (重要度ラベル / ノイズ抑制 / 粒度 など) は本ファイルの対象外で、`/pr-review-style-reference` 側で別途指定する想定です。

レビュー方針は caller プロジェクト (ユーザー) に委ねる前提で、以下のいずれの使い方でも構いません。

- そのまま採用する
- 採用した上で caller 側のカスタム指示を上に重ねる
- 採用せず無視する

caller 側のカスタム指示と本ガイドラインの内容が矛盾する場合は caller 側を優先してください。

## 引数 (`$ARGUMENTS`)

呼び出すエージェントを切り替える。

- 引数なし (デフォルト): `focus=all` と同じ扱い。下記すべてのエージェントを使う。
- `focus=all`: 下記すべてのエージェントを使う (明示指定用)。
- `focus=tests`: `pr-test-analyzer` のみ。
- `focus=errors`: `silent-failure-hunter` のみ。
- `focus=comments`: `comment-analyzer` のみ。
- `focus=types`: `type-design-analyzer` のみ。
- `focus=quality`: `code-reviewer` のみ。
- `focus=simplify`: `code-simplifier` のみ。

複数指定したい場合はカンマ区切り (例: `focus=tests,errors`) を許容する。指定されたエージェント以外は本レビューでは呼び出さない。

## 呼び出すエージェント

`pr-review-toolkit` の以下のエージェントを、変更された差分に対して呼び出してください。各エージェントの観点・トリガー・推奨タイミングは README 側の記述に従います。

- `pr-test-analyzer` — テスト網羅性
- `silent-failure-hunter` — エラーハンドリング / silent failure
- `comment-analyzer` — コメント / ドキュメント
- `type-design-analyzer` — 型設計
- `code-reviewer` — 一般的なコード品質 (CLAUDE.md 準拠等)
- `code-simplifier` — コード簡潔性 / 可読性

## 出力時の注意

- 各エージェントが返した指摘は、`/pr-review-style-reference` の重要度ラベル・粒度ガイド・件数制御に従って整形する。
- 同一の根本原因が複数エージェントに跨がる場合は、最も妥当な 1 観点に寄せて 1 箇所だけ指摘する (重複再掲はしない)。
- 観点ごとに必ず指摘を出すノルマではない。「該当なし」も明示してよい。
