---
name: post-pr-review
description: PR レビュー結果を1回の API コールで1つの Review として GitHub に投稿する。複数のインライン指摘や総括コメントを含むレビューを投稿する場合は必ずこの skill を使うこと。`gh pr comment` や `gh pr review` を使った個別投稿は禁止。
---

# post-pr-review skill

PR レビュー結果を **1回の API コールで「1つの Review」として投稿** する手順を提供する skill。
人間レビュアーの "Submit Review" と同じ構造で投稿する。

## 守ること

- レビュー結果は **必ず1回の API コール** で投稿する。
- 個別投稿系のツール (`mcp__github_inline_comment__create_inline_comment`、`gh pr comment` 等) は **使わない**。
- `event` は **常に `COMMENT`**。`APPROVE` / `REQUEST_CHANGES` は使わない (Bot がマージブロックや承認権を持つことを避けるため)。
- インラインコメントの本文フォーマット (重要度ラベル等) は **caller のレビュー方針に従う**。本 skill は手続きのみを担い、レビュー文面の規約は規定しない。

## 入力 (caller から prompt 経由で渡される想定)

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR の識別情報
- レビュー本文 (総括 + インラインコメント配列)

## 手順

### 1. `/tmp/review.json` を `Write` ツールで書き出す

`heredoc` や `cat` リダイレクトは使わず、必ず `Write` ツールで書く。スキーマは以下のとおり。

```json
{
  "body": "総括コメント本文 (Markdown可)",
  "event": "COMMENT",
  "comments": [
    {
      "path": "src/example.ts",
      "line": 42,
      "side": "RIGHT",
      "body": "[should] ここの処理は..."
    },
    {
      "path": "src/example.ts",
      "start_line": 50,
      "start_side": "RIGHT",
      "line": 55,
      "side": "RIGHT",
      "body": "[must] この複数行ブロックは..."
    }
  ]
}
```

- 単一行コメントは `path` / `line` / `side` を指定する。
- 複数行範囲のコメントは上記に加えて `start_line` / `start_side` を併用する (`start_line` は `line` より前の行)。
- 指摘がない場合: `body` を「特に指摘なし」相当の文言とし、`comments` は `[]`、`event` は `COMMENT` で投稿する。

### 2. `gh api` を1回だけ実行して投稿する

```bash
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  /repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/reviews \
  --input /tmp/review.json
```

`<OWNER>/<REPO>` と `<PR_NUMBER>` は caller から渡された値で置き換える。
