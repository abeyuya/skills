---
name: run-pr-review
description: PR レビュー全体を1コマンドで実行する skill。PR 状態取得 (CI / reviewThreads) → compose-review skill によるレビュー本文生成 → post-pr-review skill による投稿 → resolve-pr-threads skill による過去スレッド整理までを通しで行う。caller (GitHub Actions など) からは本 skill を呼ぶだけで済むようにオーケストレーションを担う。
---

# run-pr-review skill

PR レビュー一式 (PR 状態取得 → レビュー本文生成 → 投稿 → 過去スレッド resolve) を **1つの skill 呼び出しで完結** させるためのオーケストレーション skill。

レビュー方針の読み込み (スタイル参考ガイド / プロジェクト指示ファイル) と本文生成は `compose-review` skill に委譲する。本 skill はその前後 (PR 識別 / CI・既存スレッド context 収集 / 投稿 / resolve / 報告) のみを担う。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR の識別情報。省略時は後述の手順で自動取得する。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited` 扱い。Step 3 で `compose-review` にそのまま転送する。
- `THREAD_RESOLVE_SCOPE`: `resolve-pr-threads` skill に渡す resolve 範囲。`all` / `own` / `none` のいずれか。省略時は `all`。
- `SELF_LOGIN` (任意, `THREAD_RESOLVE_SCOPE=own` 時): 自身を判定するための `author.login`。caller が判明していれば渡す。Step 5 でそのまま `resolve-pr-threads` に転送される。

caller プロジェクト固有のレビュー方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** (`REVIEW.md` / `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` の優先順で最初の 1 つだけ) に置く運用に固定する。読み込み自体は `compose-review` 側で行うため本 skill では扱わない。

## 手順

### Step 1. PR 識別情報を確定する

caller から `OWNER` / `REPO` / `PR_NUMBER` が渡されていればそれを使う。揃っていない値だけ以下で補う:

- `OWNER` / `REPO`: `gh repo view --json nameWithOwner -q .nameWithOwner` で `OWNER/REPO` 形式を取得し分解する。
- `PR_NUMBER`: `gh pr view --json number -q .number` で現在のブランチに紐づく PR 番号を取得する。紐づく PR が無い場合はエラーとして停止し、caller に明示的に PR 番号を渡すよう促す。

### Step 2. CI / 既存スレッドの context を収集する

`compose-review` に渡す追加コンテキストを集める。本 step では **diff は取らない** (取得は `compose-review` 内で行う)。`gh` コマンドはいずれも `--repo <OWNER>/<REPO>` を必ず明示する (cwd の git remote と PR の所属リポジトリが異なる場合に意図しない PR を参照しないため)。

- **CI failure 情報**:
  - `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json statusCheckRollup` で CI 状態を取得する。
  - `statusCheckRollup` に `FAILURE` のジョブがあれば `gh run view --log --repo <OWNER>/<REPO>` 等で失敗ログ本体まで読み、関連箇所と失敗理由のサマリを自然言語で組み立てる。これを `compose-review` の `CI_FAILURE_CONTEXT` 入力として転送する。
  - 失敗ジョブが無ければ `CI_FAILURE_CONTEXT` は渡さない (空文字も渡さない)。
- **既存 reviewThreads サマリ (重複回避用)**:
  - GraphQL で `reviewThreads` を取得する。`-F owner=<OWNER> -F name=<REPO> -F number=<PR_NUMBER>` で渡す。`reviewThreads(first: 100)` は 1 ページ上限なので `pageInfo { hasNextPage endCursor }` を取得し、`hasNextPage` が `true` の間 `-F after=<endCursor>` で全件取得する。
  - 各スレッドの `comments.nodes[].body` まで取得し、未 resolve のものを中心に主旨を簡潔にまとめる。位置 `path:line` も併記する。
  - まとめた内容を `compose-review` の `EXISTING_THREADS_CONTEXT` 入力として転送する。既存スレッドが無ければ渡さない。

`gh pr view --json headRefOid` 等で head SHA を取る必要は **無い** (Step 3 で `compose-review` 側が `commit_id` を埋めて返してくる)。

### Step 3. `compose-review` skill でレビュー本文を生成する

Skill ツールで `compose-review` を呼ぶ。引数は以下:

- `OWNER` / `REPO` / `PR_NUMBER` (Step 1 で確定したもの)
- `MAX_INLINE_COMMENTS` (caller から渡されていれば)
- `CI_FAILURE_CONTEXT` (Step 2 で組み立てたサマリ。無ければ渡さない)
- `EXISTING_THREADS_CONTEXT` (Step 2 で組み立てたサマリ。無ければ渡さない)

`compose-review` は fenced JSON ブロックで `body` / `event` / `comments[]` / `commit_id` を返す。これを Step 4 でそのまま `post-pr-review` に転送する。

### Step 4. `post-pr-review` skill でレビューを投稿する

Step 3 で得た JSON (`body` / `event` / `comments[]` / `commit_id`) と Step 1 で確定した `OWNER` / `REPO` / `PR_NUMBER` を `post-pr-review` skill に渡し、**1回の API コールで1つの Review として** 投稿する。`gh pr comment` や `gh pr review` での個別投稿はしない。

起動方法は **Skill ツールで `post-pr-review` を呼ぶ**。`compose-review` が返した JSON の各フィールドを `post-pr-review/SKILL.md` のスキーマに従って起動時の引数として渡す (`commit_id` は `COMMIT_ID` として転送)。`/tmp/review.json` の `Write` と `gh api .../reviews --input` の実行は呼び先の `post-pr-review` 側で行うため、本 skill 側で先回りして書かない。

### Step 5. `resolve-pr-threads` skill で過去スレッドを整理する

Step 1 の PR 識別情報と `THREAD_RESOLVE_SCOPE` (省略時 `all`) を `resolve-pr-threads` skill に渡して呼び出す。`THREAD_RESOLVE_SCOPE=none` の場合は呼び出すが skill 側で skip される。

`THREAD_RESOLVE_SCOPE=own` の場合、caller から `SELF_LOGIN` が渡されていれば一緒に渡す。

### Step 6. caller への報告

以下を簡潔に caller へ返す:

- 投稿した Review の URL (Step 4 のレスポンスから取れる場合)
- インライン指摘件数 / 総括の主要懸念件数 / severity 内訳 (Step 3 の `compose-review` 戻り値から抽出)
- resolve したスレッド件数 (Step 5 の戻り値)

## 守ること

- 各 step で使う既存資産 (`compose-review` / `post-pr-review` / `resolve-pr-threads`) は **必ずこの skill 経由で利用** する。本 skill 内で同等の処理 (スタイル参考ガイド読み込み / レビュー本文生成 / 投稿 / resolve 判定) を再実装してはならない (二重管理を防ぐため)。
- レビュー文面の規約 (重要度ラベル等) は `compose-review` 配下の `style-reference.md` に集約されているため、本 skill では再掲しない。caller 側に独自方針がある場合はプロジェクト指示ファイルで上書きする。
- 判定に迷ったら resolve しない / 投稿は1回だけ、という既存 skill の安全側ルールはそのまま守る。
