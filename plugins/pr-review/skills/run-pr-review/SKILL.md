---
name: run-pr-review
description: PR レビュー全体を1コマンドで実行する skill。共通レビュー方針 (/pr-review-guidelines) の読み込み・PR 情報取得・レビュー文面作成・post-pr-review での投稿・resolve-pr-threads での過去スレッド整理までを通しで行う。caller (GitHub Actions など) からは本 skill を呼ぶだけで済むようにオーケストレーションを担う。
---

# run-pr-review skill

PR レビュー一式 (方針読み込み → PR 確認 → レビュー作成 → 投稿 → 過去スレッド resolve) を **1つの skill 呼び出しで完結** させるためのオーケストレーション skill。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR の識別情報。省略時は後述の手順で自動取得する。
- `CALLER_GUIDELINES`: caller プロジェクト固有のレビュー観点ファイルのリポジトリ相対パス (例: `docs/ai_code_review/all.md`)。省略時は読み込まない。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は AI 判断 (=`/pr-review-guidelines` 引数なし相当)。Step 2 で `/pr-review-guidelines max-inline-comments=<値>` として渡す。
- `MODE`: `resolve-pr-threads` skill に渡す resolve 範囲。`all` / `own` / `none` のいずれか。省略時は `all`。

## 手順

### Step 1. PR 識別情報を確定する

caller から `OWNER` / `REPO` / `PR_NUMBER` が渡されていればそれを使う。揃っていない値だけ以下で補う:

- `OWNER` / `REPO`: `gh repo view --json nameWithOwner -q .nameWithOwner` で `OWNER/REPO` 形式を取得し分解する。
- `PR_NUMBER`: `gh pr view --json number -q .number` で現在のブランチに紐づく PR 番号を取得する。紐づく PR が無い場合はエラーとして停止し、caller に明示的に PR 番号を渡すよう促す。

### Step 2. 共通レビュー方針を読み込む

`/pr-review-guidelines` slash command を実行し、共通レビュー方針 (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い) を本セッションの方針として適用する。

`MAX_INLINE_COMMENTS` が指定されている場合は `/pr-review-guidelines max-inline-comments=<値>` として渡す。未指定なら引数なしで呼ぶ。

### Step 3. caller 固有観点を読み込む (任意)

`CALLER_GUIDELINES` が指定されている場合のみ、そのパスのファイルを `Read` ツールで読み、共通方針と併用するレビュー観点として適用する。指定が無い場合はこのステップを skip する。

### Step 4. PR の状態を取得する

レビューに必要な情報を取得する。

- `gh pr view <PR_NUMBER> --json title,body,headRefName,baseRefName,statusCheckRollup,commits` で PR メタ情報と CI 状態を取得する。
- `gh pr diff <PR_NUMBER>` で差分を取得する。
- 既存レビュー / コメントは `resolve-pr-threads` 内でも取得するが、**重複指摘を避けるため** 本ステップでも GraphQL で `reviewThreads` を取得し、自分の過去コメント等を把握しておく (`/pr-review-guidelines` の「既存レビュー/コメントとの重複回避」に従う)。
- `statusCheckRollup` に `FAILURE` のジョブがあれば `gh run view --log` 等で失敗ログ本体まで読み、`[must]` 指摘の根拠にする (詳細は `/pr-review-guidelines` の「CI の扱い」)。

### Step 5. レビュー本文を作成する

Step 2〜4 で得た方針・観点・差分・CI 情報をもとに、総括 (`body`) とインライン指摘 (`comments[]`) を作成する。

- 重要度ラベル / ノイズ抑制 / 粒度ガイドはすべて `/pr-review-guidelines` の規定に従う。
- 既存スレッドと同主旨の指摘は再掲しない。
- 指摘が無い場合も Step 6 で「特に指摘なし」相当の Review を投稿する (skip しない)。

### Step 6. `post-pr-review` skill でレビューを投稿する

Step 1 で確定した `OWNER` / `REPO` / `PR_NUMBER` と Step 5 で作成した本文を `post-pr-review` skill に渡し、**1回の API コールで1つの Review として** 投稿する。`gh pr comment` や `gh pr review` での個別投稿はしない。

### Step 7. `resolve-pr-threads` skill で過去スレッドを整理する

Step 1 の PR 識別情報と `MODE` (省略時 `all`) を `resolve-pr-threads` skill に渡して呼び出す。`MODE=none` の場合は呼び出すが skill 側で skip される。

`MODE=own` の場合、caller から `SELF_LOGIN` が渡されていれば一緒に渡す。

### Step 8. caller への報告

以下を簡潔に caller へ返す:

- 投稿した Review の URL (Step 6 のレスポンスから取れる場合)
- インライン指摘件数 / 総括の主要懸念件数
- resolve したスレッド件数 (Step 7 の戻り値)

## 守ること

- 各 step で使う既存資産 (`/pr-review-guidelines` / `post-pr-review` / `resolve-pr-threads`) は **必ずこの skill 経由で利用** する。本 skill 内で同等の処理を再実装してはならない (方針・投稿手順・resolve 判定の二重管理を防ぐため)。
- レビュー文面の規約 (重要度ラベル等) は `/pr-review-guidelines` に集約されているため、本 skill では再掲しない。
- 判定に迷ったら resolve しない / 投稿は1回だけ、という既存 skill の安全側ルールはそのまま守る。
