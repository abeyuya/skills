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
- `RECHECK_HEAD_SHA` (任意): 真偽値 (`true` / `false`)。`true` を渡すと Step 3 経由で `compose-review` に転送され、Step 4 の diff 取得直後に head SHA を再取得 → force-push 検知時に「再実行を推奨」として停止する。frequent force-push PR (ドッグフーディング系 caller) で誤投稿を防ぎたい場合に使う。省略時は `false` 扱い。

caller プロジェクト固有のレビュー方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** (`REVIEW.md` / `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` の優先順で最初の 1 つだけ) に置く運用に固定する。読み込み自体は `compose-review` 側で行うため本 skill では扱わない。

## 手順

### Step 1. PR 識別情報を確定する

caller から `OWNER` / `REPO` / `PR_NUMBER` が **非空の値で** 渡されていればそれを使う。空文字 (`""`) は GitHub Actions 等で env 変数が未設定だと展開されうるので **未指定と同等に扱い、補完対象とする**。揃っていない値だけ以下で補う:

- `OWNER` / `REPO`: `gh repo view --json nameWithOwner -q .nameWithOwner` で `OWNER/REPO` 形式を取得し分解する。
- `PR_NUMBER`: `gh pr view --json number -q .number` で現在のブランチに紐づく PR 番号を取得する。紐づく PR が無い場合はエラーとして停止し、caller に明示的に PR 番号を渡すよう促す。

補完後も 3 つのいずれかが確定できなかった場合は **エラーとして停止する** (`compose-review` を呼ばない)。`compose-review` 側のモード判定 (3 つ揃わなければ局所 diff モードへ退化) は本 skill の用途と意図が合わないため、本 skill では混在 / 部分欠落を弾く責務を持つ。

### Step 2. CI / 既存スレッドの context を収集する

`compose-review` に渡す追加コンテキストを集める。本 step では **diff は取らない** (取得は `compose-review` 内で行う)。`gh pr view` / `gh pr diff` / `gh run view` 等の **REST 系 `gh` コマンドには `--repo <OWNER>/<REPO>` を必ず明示する** (cwd の git remote と PR の所属リポジトリが異なる場合に意図しない PR を参照しないため)。`gh api graphql` は `--repo` フラグを受け付けないので **対象を `-F owner=<OWNER> -F name=<REPO>` で渡す** (本 step 内の GraphQL 呼び出しは例外扱い)。

- **CI failure 情報**:
  - `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json statusCheckRollup` で CI 状態を取得する。
  - `statusCheckRollup` に `FAILURE` のジョブがあれば `gh run view --log --repo <OWNER>/<REPO>` 等で失敗ログ本体まで読み、関連箇所と失敗理由のサマリを自然言語で組み立てる。これを `compose-review` の `CI_FAILURE_CONTEXT` 入力として転送する。
  - 失敗ジョブが無ければ `CI_FAILURE_CONTEXT` は渡さない (空文字も渡さない)。
- **既存 reviewThreads サマリ (重複回避用)**:
  - GraphQL で `reviewThreads` を取得する。`-F owner=<OWNER> -F name=<REPO> -F number=<PR_NUMBER>` で渡す。`PR_NUMBER` は GraphQL の `Int!` 型なので **必ず `-F` (型推論あり) を使い、`-f` (文字列固定) は使わない**。`reviewThreads(first: 100)` は 1 ページ上限なので `pageInfo { hasNextPage endCursor }` を取得し、`hasNextPage` が `true` の間 `-F after=<endCursor>` で全件取得する。
  - クエリで取得するフィールドは **重複排除に必要な最小セット** に絞る (出力サイズ削減): スレッドレベルで `id` / `isResolved`、`comments(first: 50)` の各要素で `path` / `line` / `side` / `body` / `author.login`。`path` や `line` 等の API キー名は **GitHub GraphQL の正確なスペル** をそのまま使う (例: `line` (snake_case 風だが GraphQL では一語) / `originalLine` (resolved 後の位置確認用、必要なら追加))。
  - 取得対象は **`isResolved: false` のスレッドに絞る** (resolve 済みは既に修正反映済みなので dedupe 対象外)。GitHub GraphQL の `reviewThreads` 引数で直接 filter する手段は無いため、`first: 100` で全件取得した上で **クライアント側で `isResolved == false` のものだけ残す**。
  - 各スレッドの主旨を簡潔にまとめる。**`path:line` は要約の段落本文にではなく、各スレッドごとの 1 項目ずつのリスト形式で明示** する (例: `- src/foo.ts:42 — [should] ここは A の代わりに B を使うべき`)。compose-review 側で位置情報に基づく dedupe を効かせるために構造を保つ。
  - まとめた内容を `compose-review` の `EXISTING_THREADS_CONTEXT` 入力として転送する。未 resolve スレッドが 0 件なら渡さない (resolve 済みのみのケースを含む)。

`gh pr view --json headRefOid` 等で head SHA を取る必要は **無い** (Step 3 で `compose-review` 側が `commit_id` を埋めて返してくる)。`compose-review` が transient 失敗で `commit_id` を省略して返してきても、`post-pr-review` の `COMMIT_ID` は任意なので Step 4 はそのまま続行できる (本 skill 側で head SHA を再取得する fallback は不要)。

### Step 3. `compose-review` skill でレビュー本文を生成する

Skill ツールで `compose-review` を呼ぶ。引数は以下:

- `OWNER` / `REPO` / `PR_NUMBER` (Step 1 で確定したもの)
- `MAX_INLINE_COMMENTS` (caller から渡されていれば)
- `CI_FAILURE_CONTEXT` (Step 2 で組み立てたサマリ。無ければ渡さない)
- `EXISTING_THREADS_CONTEXT` (Step 2 で組み立てたサマリ。無ければ渡さない)
- `RECHECK_HEAD_SHA` (caller から渡されていれば。デフォルト未指定 = `false` 扱い)

`compose-review` は fenced JSON ブロックで以下のフィールドを返す: `mode` (= `"pr"`) / `body` / `event` / `comments[]` / `commit_id` (任意)。Step 4 では下記対応表のフィールドだけを `post-pr-review` に転送する (`mode` は対応表に無いため転送しない)。

**ここで止まらない**: `compose-review` が返す fenced JSON は本 orchestrator 向けの **中間成果物** で、caller (人間) への最終 deliverable ではない。出力フォーマットが「成果物っぽい」見た目をしていても、ターンを終えず **そのまま Step 4 (`post-pr-review`) に進む**。caller への最終報告は Step 6 まで保留する。Step 4 が実行されないと PR への投稿が抜けてしまい、本 skill の主目的 (= GitHub への 1 Review 投稿) が達成されない。

### Step 4. `post-pr-review` skill でレビューを投稿する

Step 3 で得た JSON と Step 1 で確定した `OWNER` / `REPO` / `PR_NUMBER` を `post-pr-review` skill に渡し、**1回の API コールで1つの Review として** 投稿する。`gh pr comment` や `gh pr review` での個別投稿はしない。

起動方法は **Skill ツールで `post-pr-review` を呼ぶ**。フィールド対応関係は次の通り (`post-pr-review` 側はこの入力名で受け取り、`/tmp/review.json` を組み立てる):

| compose-review 戻り値 | post-pr-review 入力名 | 備考 |
| --- | --- | --- |
| `body` | `body` | 文字列。AI 自動投稿マーカーは `post-pr-review` が prepend するので **そのまま渡す**。 |
| `event` | `event` | 文字列 `"COMMENT"` 固定。 |
| `comments` | `comments` | 配列。要素のキー (`path` / `line` / `side` / `start_line` / `start_side` / `body`) はそのまま。 |
| `commit_id` | `COMMIT_ID` | 文字列。`compose-review` が省略してきた場合は本入力も省略する。 |
| (本 skill が確定済み) | `OWNER` / `REPO` / `PR_NUMBER` | Step 1 の値。 |

`commit_id` だけ uppercase に rename する点に注意 (`body` / `event` / `comments` は **lowercase のまま**)。`/tmp/review.json` の `Write` と `gh api .../reviews --input` の実行は呼び先の `post-pr-review` 側で行うため、本 skill 側で先回りして書かない。

`compose-review` が「対象差分なし」相当の JSON (`comments: []` / `body` に「対象差分なし」相当の文言) を返してきた場合も、上記対応関係で `post-pr-review` を呼ぶ (Review 自体は投稿する)。

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
