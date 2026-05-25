---
name: run-pr-review
description: PR レビュー全体を 1 コマンドで実行する thin orchestrator。PR 情報取得 / `compose-review` (sub-agent) でのレビュー本文生成 / `post-pr-review` でのレビュー投稿 / `resolve-pr-threads` での過去スレッド整理を順に呼ぶ。レビュー方針 (`/pr-review-style-reference` 読み込み / プロジェクト指示ファイル / 本文生成) は `compose-review` に委ねる。
---

# run-pr-review skill

PR レビュー一式 (PR 情報取得 → compose-review でレビュー本文生成 → post-pr-review で投稿 → resolve-pr-threads で過去スレッド整理) を **1 つの skill 呼び出しで完結** させる thin orchestrator。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR の識別情報。省略時は後述の手順で自動取得する。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。`compose-review` にそのまま転送する。
- `THREAD_RESOLVE_SCOPE`: `resolve-pr-threads` に渡す resolve 範囲。`all` / `own` / `none`。省略時は `all`。
- `SELF_LOGIN` (任意, `THREAD_RESOLVE_SCOPE=own` 時): 自身を判定するための `author.login`。caller が判明していれば渡す。Step 5 で `resolve-pr-threads` に転送される。

caller プロジェクト固有の方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** に置く運用。読み込み手順は `compose-review` skill 側に集約しているため、本 skill では扱わない。

## 手順

### Step 1. PR 識別情報を確定する

caller から `OWNER` / `REPO` / `PR_NUMBER` が渡されていればそれを使う。揃っていない値だけ以下で補う:

- `OWNER` / `REPO`: `gh repo view --json nameWithOwner -q .nameWithOwner` で `OWNER/REPO` 形式を取得し分解する。
- `PR_NUMBER`: `gh pr view --json number -q .number` で現在のブランチに紐づく PR 番号を取得する。紐づく PR が無い場合はエラーとして停止し、caller に明示的に PR 番号を渡すよう促す。

3 つすべてが非空であることを確認してから次 step に進む。1 つでも空文字 / 未取得が混じると `compose-review` がローカルモードに falls through する可能性があるため、本 step で弾く責務は本 skill にある。

### Step 2. PR 状態と context を取得する

いずれの `gh` コマンドも、cwd の git remote と PR の所属リポジトリが異なる場合 (ドッグフーディングや別リポジトリ向け caller) に意図しない PR を参照しないよう、Step 1 で確定した `OWNER`/`REPO` を `--repo <OWNER>/<REPO>` で必ず明示する (`gh api graphql` は除く)。

- `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json title,body,headRefName,headRefOid,baseRefName,statusCheckRollup` で PR メタ情報と CI 状態を取得する。`headRefOid` を head SHA として控え、Step 4 で `post-pr-review` の `COMMIT_ID` 引数 (force-push / rebase での行ズレによる誤コメント防止) として常時転送する。
- 既存レビュー / コメント (compose-review に渡す重複指摘抑制用 context) は GraphQL で `reviewThreads` を取得する。GraphQL は `-F owner=<OWNER> -F name=<REPO> -F number=<PR_NUMBER>` で渡す。`reviewThreads(first: 100)` は API の 1 ページ上限なので、`pageInfo { hasNextPage endCursor }` を取得し `hasNextPage` が `true` の間 `-F after=<endCursor>` で全件取得する。各スレッドの `path` / `line` / `comments.nodes[].body` まで取り、各スレッドを `<path>:<line> - <主旨 1〜2 文要約>` の形式で 1 行ずつ整形し改行で連結したテキストを **`EXISTING_THREADS_CONTEXT`** として保持する (`path:line` を必ず併記。自由文の段落要約では位置が落ちて dedupe 精度が下がる)。
- `statusCheckRollup` に `FAILURE` のジョブがあれば run id を抽出して失敗ログ本体を読む: `statusCheckRollup.contexts[].detailsUrl` の末尾セグメント (`https://github.com/<O>/<R>/actions/runs/<RUN_ID>/...`) または `checkSuite.workflowRun.databaseId` から `RUN_ID` を取り、`gh run view <RUN_ID> --log --repo <OWNER>/<REPO>` で取得する。要点を **`CI_FAILURE_CONTEXT`** として整形する: 1 失敗ごとに `<ジョブ名>: <失敗箇所抜粋 1〜数行>` を 1 ブロックとし、空行で区切って連結する。ANSI escape は除去し、全体は 2000 文字以内に丸める (超過分は `(...truncated)` で打ち切る)。本値の中に `^[A-Z_]+=` 行頭パターン (例: `ENV=production`) があれば、compose-review 側の KEY=VALUE parser を破壊しないよう先頭にスペース 1 文字をインデントして escape する。失敗ジョブが無ければ本値は組み立てず、Step 3 で行ごと省略する。

### Step 3. `compose-review` (sub-agent) でレビュー本文を生成する

Task ツール (`subagent_type=general-purpose`、新 SDK 環境では `Agent` ツールに rename されているが両者は同義) を 1 回 dispatch する。`general-purpose` 以外 (`Plan` / `Explore` / `code-reviewer` 等の specialized subagent) は Skill ツールアクセスが制限される場合があるため使わない。subagent は parent の slash command を継承しないため、prompt 内で **Skill ツール経由で `compose-review` skill を呼ぶ** よう明示する。Prompt テンプレート (`<…>` プレースホルダは実値で埋める。値が未取得 / 空の引数行は行ごと省略する。空文字埋めはしない。**長文 value (`EXISTING_THREADS_CONTEXT` / `CI_FAILURE_CONTEXT`) は短い key より後ろに置く** — compose-review 側 KEY=VALUE parser は次の `^[A-Z_]+=` 行までを value とするため、長文中の偶発 `KEY=` 様行による早期切断を末尾配置で防ぐ):

```
pr-review プラグインの compose-review skill を呼び出すための subagent。
Skill ツール (`skill: "compose-review"`) で compose-review skill を起動し、
以下を引数として渡せ。skill の出力 (JSON) を最終メッセージとして verbatim に返せ。
最終メッセージは前置きも fenced ブロックもなしの生 JSON 1 つだけ。

MODE=pr
OWNER=<OWNER>
REPO=<REPO>
PR_NUMBER=<PR_NUMBER>
COMMIT_ID=<Step 2 で取得した headRefOid>
MAX_INLINE_COMMENTS=<値>
EXISTING_THREADS_CONTEXT=<Step 2 で組み立てたテキスト>
CI_FAILURE_CONTEXT=<Step 2 で組み立てたテキスト>
```

Task ツール result (sub-agent の最終メッセージ) を `json.loads()` 等で parse し、**以下の順序** で判定する (順序固定。error 検査を必ず最優先にする):

1. parse 失敗 (JSON として読めない / fenced ブロック付き / 複数 JSON / 想定外形式) なら整合性エラーとして停止し、Step 6 の caller 報告で「compose-review 戻り値が JSON として読めなかった」旨を転送する (Step 4/5 は skip)。
2. `error` フィールドがあれば Step 6 の caller 報告でそのメッセージを転送し停止する (Step 4/5 は skip)。**error 時の payload は `mode` を含まない仕様なので、必ず本 step を 3 より先に評価する**。
3. `mode` が `"pr"` でなければ整合性エラーとして停止する。
4. それ以外 (success 時) は `body` / `event` / `comments` / `commit_id` を Step 4 に渡し、**Step 4 → Step 5 → Step 6 を順に必ず実行する** (Task ツール result 受け取り時点では本 skill の処理は完了していない)。`commit_id` は差分なし時も含めて compose-review 側で **必須** (契約上)。万一欠落しているなら整合性違反としてログに 1 行記録した上で、Step 2 で取得済の `headRefOid` を defensive fallback として使う (Review 投稿自体は継続する)。

### Step 4. `post-pr-review` skill でレビューを投稿する

Step 1 の `OWNER` / `REPO` / `PR_NUMBER` と Step 3 で得たレビュー本文を `post-pr-review` skill に Skill ツール経由で渡し、**1 回の API コールで 1 つの Review として** 投稿する。`gh pr comment` や `gh pr review` での個別投稿はしない。

`compose-review` 出力 → `post-pr-review` 入力の対応:

| compose-review 出力 | post-pr-review 入力 |
|---|---|
| `body` | `body` |
| `event` | `event` |
| `comments` | `comments` |
| `commit_id` | `COMMIT_ID` |
| `mode` | (転送しない / 本 skill が `"pr"` 整合性チェック後に破棄。post-pr-review は `mode` を受け付けないため `--input` に含めると 422 になる) |

`/tmp/review.json` の `Write` と `gh api .../reviews --input` の実行は呼び先の `post-pr-review` 側で行うため、本 skill 側で先回りして書かない。

### Step 5. `resolve-pr-threads` skill で過去スレッドを整理する

Step 1 の PR 識別情報と `THREAD_RESOLVE_SCOPE` (省略時 `all`) を `resolve-pr-threads` skill に渡して呼び出す。`THREAD_RESOLVE_SCOPE=none` の場合は呼び出すが skill 側で skip される。

`THREAD_RESOLVE_SCOPE=own` の場合、caller から `SELF_LOGIN` が渡されていれば一緒に渡す。

### Step 6. caller への報告

以下を簡潔に caller へ返す:

- 投稿した Review の URL (Step 4 のレスポンスから取れる場合)
- インライン指摘件数 / 総括の主要懸念件数 / severity 内訳
- resolve したスレッド件数 (Step 5 の戻り値)

## 守ること

- 各 step で使う既存資産 (`compose-review` / `post-pr-review` / `resolve-pr-threads`) は **必ず本 skill 経由で利用** する。本 skill 内で同等の処理を再実装してはならない (スタイル参考ガイド・投稿手順・resolve 判定・本文生成の二重管理を防ぐため)。
- レビュー方針 (重要度ラベル等) / プロジェクト指示ファイル読み込み / `/pr-review-style-reference` の参照は `compose-review` の責務。本 skill では再実装しない。
- 判定に迷ったら resolve しない / 投稿は 1 回だけ、という既存 skill の安全側ルールはそのまま守る。
