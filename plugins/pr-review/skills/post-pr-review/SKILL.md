---
name: post-pr-review
description: PR レビュー結果を1つの Review として GitHub に投稿する。複数のインライン指摘や総括コメントを含むレビューを投稿する場合は必ずこの skill を使うこと。`gh pr comment` / `gh pr review` / MCP の個別コメント投稿ツールを使った個別投稿は禁止。gh CLI / GitHub MCP ツールのどちらのチャネル (`CHANNEL=gh|mcp`) でも投稿できる。
---

# post-pr-review skill

PR レビュー結果を **「1つの Review」として投稿** する手順を提供する skill。
人間レビュアーの "Submit Review" と同じ構造で投稿する。

## 守ること

- レビュー結果は **必ず「1 つの Review」** として投稿する (`CHANNEL=gh` は 1 回の API コール、`CHANNEL=mcp` は pending review を組み立ててから 1 度に submit。いずれも GitHub 上では 1 つの Review オブジェクトになり、散らばった個別コメントにはならない)。
- 個別投稿系のツール (`mcp__github_inline_comment__create_inline_comment`、`mcp__github__add_issue_comment`、`gh pr comment` 等) は **使わない**。
- `event` は **常に `COMMENT`**。`APPROVE` / `REQUEST_CHANGES` は使わない (Bot がマージブロックや承認権を持つことを避けるため)。
- インラインコメントの本文フォーマット (重要度ラベル等) は **caller のレビュー方針に従う**。本 skill は手続きのみを担い、レビュー文面の規約は規定しない。
- 総括 `body` の先頭には **AI 自動投稿マーカーを必ず付与する** (詳細は「手順 1」参照)。認証主体が人間 PAT でも投稿内容は AI 生成であることを明示するため。caller 側で事前に付与する必要はなく、本 skill が一律に prepend する。エージェント名 (Claude Code / Codex / Cursor 等) はマーカーに含めない (本 skill は複数の AI エージェントから呼ばれうる前提)。

## Public Payload Interface

本 skill は「レビュー本文を受け取って GitHub Review として投稿するだけ」の純粋な投稿 skill。レビュー自体をどう生成するか (どの skill / どのエージェント / どんな観点で書くか) には関与しない。

下記の Payload スキーマと呼び出し経路は **本 skill の公開インターフェース** として扱う。`run-pr-review` 等の上流 skill 経由でも、人手 / 外部システムから直接呼ぶ場合でも、同一の Payload を受け付ける。後方互換性に注意して変更すること (キー追加は可、既存キーの削除 / 型変更 / 必須化はインターフェース変更扱い)。

### 識別情報 (必須)

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR を一意に決める 3 値。Skill 自身は PR を自動推定せず、caller が必ず渡す。

### GitHub アクセスチャネル (任意)

- `CHANNEL`: `gh` または `mcp`。投稿に使う経路。caller (`run-pr-review` Step 1) が解決済みならその値を渡す。**未指定なら本 skill が自分で解決する**: `gh api repos/<OWNER>/<REPO> --jq .full_name` が成功すれば `gh`、失敗して GitHub MCP ツール (`mcp__github__*`) がセッションで利用可能なら `mcp`、どちらも不可ならエラーとして caller に報告し停止する。gh と MCP は対等な正規チャネル (Claude Code の web/remote セッションでは gh が恒常 403 になるため MCP が唯一の経路、GitHub Actions では通常 gh のみが使える)。

### Payload スキーマ

caller が渡す Payload (TypeScript ライクに表記。マーカー prepend 前の生本文):

```ts
type ReviewPayload = {
  body: string;                // 必須。総括コメント本文 (Markdown 可)。AI 自動投稿マーカーは skill 側で自動 prepend するため caller は付けない。指摘なし時も「特に指摘なし」相当の本文を入れる。
  event: "COMMENT";            // 必須。リテラル固定。"APPROVE" / "REQUEST_CHANGES" は禁止。
  comments: ReviewComment[];   // 必須。空配列 ([]) 可。
  commit_id?: string;          // 任意。head commit の SHA。force-push / rebase での行ズレ防止に推奨。省略時は GitHub 側で最新 commit を採用。
};

type ReviewComment =
  | {                          // 単一行コメント
      path: string;            // 必須。リポジトリ root からの相対パス。
      line: number;            // 必須。1-based。
      side: "RIGHT" | "LEFT";  // 必須。新ファイル側 (RIGHT) / 旧ファイル側 (LEFT)。通常 "RIGHT"。
      body: string;            // 必須。本文 (重要度ラベル等は caller の方針に従う)。
    }
  | {                          // 複数行範囲コメント
      path: string;
      start_line: number;      // 必須。範囲開始行。`line` より前の行であること。
      start_side: "RIGHT" | "LEFT"; // 必須。
      line: number;            // 必須。範囲終了行。
      side: "RIGHT" | "LEFT";  // 必須。
      body: string;            // 必須。
    };
```

`commit_id` は caller 側で PR の head SHA (`headRefOid`) を取得して渡すと、force-push / rebase で行ズレが起きた際の誤コメントを防げる (`run-pr-review` Step 2 が CHANNEL に応じて `gh pr view --json headRefOid` または `mcp__github__pull_request_read` method=`get` で取得済みの値を流用する想定)。

### 契約の前提 (Payload 設計上の制約)

- `body` 先頭の **AI 自動投稿マーカー** は本 skill が自動 prepend する。caller は付けない (詳細は「手順 1」のマーカー文言を参照)。
- `event` は **常に `COMMENT`** (Bot がマージブロック / 承認権を持つことを避けるため、`APPROVE` / `REQUEST_CHANGES` は禁止)。
- `comments[].body` の本文フォーマット (`[must]` / `[should]` 等の重要度ラベル等) は **caller のレビュー方針** に従う。本 skill は手続きのみを担う。
- `comments[].body` には Review 本体側のマーカーで帰属が示されるため **個別マーカーを付けない**。

### 呼び出し経路

#### (a) 上流 skill から Skill ツール経由で呼ぶ場合

`run-pr-review` Step 4 のように、上流 skill が `OWNER` / `REPO` / `PR_NUMBER` (+ 解決済みなら `CHANNEL`) と Payload (`body` / `event` / `comments[]` / 任意で `commit_id`) を組み立てて Skill ツールの引数として渡す。投稿の実行 (CHANNEL に応じた `gh api` または MCP ツール呼び出し。詳細は「手順」) は本 skill 側で行う。caller 側で先回りして JSON を書き出したり API を叩いたりする必要はない。

#### (b) 人手 / 外部システムから prompt 経由で呼ぶ場合

prompt の中に上記スキーマに沿った Payload を埋め込んで本 skill を起動する。最小例:

```
post-pr-review skill を呼んでください。

OWNER: octocat
REPO: hello-world
PR_NUMBER: 42
COMMIT_ID: 9f8e7d6c1a2b3c4d5e6f7890abcdef1234567890

body: |
  ## 総合判断
  概ね問題なし。下記 1 点のみ確認お願いします。

event: COMMENT
comments:
  - path: src/example.ts
    line: 42
    side: RIGHT
    body: "[should] ここの処理は null チェックが抜けています。"
```

caller (人 / 外部システム) は Payload を渡すだけで、投稿の実行 (CHANNEL の解決・`gh api` / MCP ツール呼び出し) は本 skill が行う。

## 手順

### 0. CHANNEL を確定する

caller から `CHANNEL` が渡されていればそれを使う。未指定なら「GitHub アクセスチャネル (任意)」の解決手順で `gh` / `mcp` を確定する。どちらも使えなければ投稿せずエラーを caller に報告して停止する。

### 1. `body` 先頭に AI 自動投稿マーカーを付与し、最終 Payload を確定する

caller から渡された総括本文 (Markdown 可) はマーカーと区切り線 (`---`) の後ろに連結する。指摘なしの場合 (`comments` が `[]`) も同じマーカーを付ける。

マーカー文言 (エージェント非依存・固定):

```markdown
> **[AI 自動投稿]** このレビューは AI エージェントによって自動生成されました。レビュー内容の判断は AI が行っています。

---

<caller から渡された総括本文 (指摘なし時は「特に指摘なし」相当)>
```

確定した最終 Payload のスキーマは以下のとおり (`body` は上記マーカー込みの文字列)。`CHANNEL=gh` ではこれを `/tmp/review.json` に **`Write` ツールで** 書き出す (`heredoc` や `cat` リダイレクトは使わない)。`CHANNEL=mcp` ではファイルには書き出さず、手順 2 の各ツール引数として直接渡す:

```json
{
  "commit_id": "9f8e7d6c1a2b3c4d5e6f7890abcdef1234567890",
  "body": "> **[AI 自動投稿]** このレビューは AI エージェントによって自動生成されました。レビュー内容の判断は AI が行っています。\n\n---\n\n総括コメント本文 (Markdown可)",
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
- `commit_id` は caller から `COMMIT_ID` が渡された場合のみ含める (詳細は「Public Payload Interface」セクションの「Payload スキーマ」参照)。
- 指摘がない場合: `body` はマーカー + 区切り線 + 「特に指摘なし」相当の文言、`comments` は `[]`、`event` は `COMMENT` で投稿する。
- インラインコメント (`comments[].body`) には個別マーカーを付けない (Review 本文側のマーカーで帰属は十分であり、`[must]` 等の重要度ラベルとの衝突や冗長さも避けるため)。

### 2. CHANNEL に応じて「1 つの Review」として投稿する

`<OWNER>` / `<REPO>` / `<PR_NUMBER>` は caller から渡された値で置き換える。

#### 2-a. `CHANNEL=gh` — `gh api` を 1 回だけ実行する

手順 1 で書き出した `/tmp/review.json` を使い、1 回の API コールで投稿する:

```bash
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  /repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/reviews \
  --input /tmp/review.json
```

#### 2-b. `CHANNEL=mcp` — pending review を組み立てて submit する

MCP には Payload 全体を 1 コールで受けるツールが無いため、pending review を組み立ててから 1 度に submit する (GitHub 上では 2-a と同じ 1 つの Review オブジェクトになる)。`comments` の有無で分岐する:

- **`comments` が空配列 (`[]`) の場合 — 1 呼び出しで submit**: `mcp__github__pull_request_review_write` を method=`create` で呼ぶ。`owner` / `repo` / `pullNumber` に加え、`body` = 手順 1 のマーカー込み総括本文、`event` = `"COMMENT"`、`commitID` = `commit_id` (Payload に含まれる場合のみ) を渡す (`event` を付けると作成と同時に submit される)。
- **`comments` が非空の場合 — pending review 組み立て**:
  1. **pending review 作成**: `mcp__github__pull_request_review_write` を method=`create` で、**`event` を省略して** 呼ぶ (event 省略で pending review になる)。`owner` / `repo` / `pullNumber` と、`commitID` = `commit_id` (Payload に含まれる場合のみ) をここで渡す。`body` はここでは渡さず submit 時に渡す。
  2. **各インラインコメントを追加**: `comments[]` の各要素について `mcp__github__add_comment_to_pending_review` を呼ぶ: `owner` / `repo` / `pullNumber`、`path` / `body` / `subjectType`=`"LINE"`、`line` / `side`。複数行範囲コメントは加えて `startLine` = `start_line` / `startSide` = `start_side` を渡す。
  3. **submit**: `mcp__github__pull_request_review_write` を method=`submit_pending` で呼ぶ: `owner` / `repo` / `pullNumber`、`body` = 手順 1 のマーカー込み総括本文、`event` = `"COMMENT"`。

**失敗時のクリーンアップ**: 2-b の組み立ては複数呼び出しに分かれるため、2-a の単一 atomic コールと違い途中失敗で pending review が宙に浮きうる。コメント追加または submit が失敗したら、`mcp__github__pull_request_review_write` を method=`delete_pending` (`owner` / `repo` / `pullNumber`) で pending review を破棄してから caller にエラーを報告する (submit されないまま残った pending review は他の投稿の妨げになるため残さない)。
