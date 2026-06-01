---
name: run-pr-review
description: PR レビュー全体を 1 コマンドで実行する thin orchestrator。PR 情報取得 / `compose-review` (現在コンテキストで直接呼ぶ) でのレビュー本文生成 / `post-pr-review` でのレビュー投稿 / `resolve-pr-threads` での過去スレッド整理を順に呼ぶ。レビュー方針 (`/pr-review-style-reference` 読み込み / プロジェクト指示ファイル / 本文生成 / `code-review` 等外部レビュースキルの併用) は `compose-review` に委ねる。
---

# run-pr-review skill

PR レビュー一式 (PR 情報取得 → compose-review でレビュー本文生成 → post-pr-review で投稿 → resolve-pr-threads で過去スレッド整理) を **1 つの skill 呼び出しで完結** させる thin orchestrator。

`compose-review` は **sub-agent を立てず現在コンテキストで直接呼ぶ** (Step 3 参照)。これは `compose-review` の Step 5-2 で `code-review` 等の外部レビュースキルを併用する際、その fan-out (Agent ツール) が現在コンテキストでないと動かないため。トレードオフとして、大きい PR 差分 + 外部レビューの実行が orchestrator のコンテキストを膨らませる点は許容する。

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
- 既存レビュー / コメント (compose-review に渡す重複指摘抑制用 context) は GraphQL で `reviewThreads` を取得する。GraphQL は `-F owner=<OWNER> -F name=<REPO> -F number=<PR_NUMBER>` で渡す。`reviewThreads(first: 100)` は API の 1 ページ上限なので、`pageInfo { hasNextPage endCursor }` を取得し `hasNextPage` が `true` の間 `-F after=<endCursor>` で全件取得する。各スレッドの `path` / `line` / `comments.nodes[].body` まで取り、各スレッドを `<path>:<line> - <主旨 1〜2 文要約>` の形式で 1 行ずつ整形し改行で連結したテキストを **`EXISTING_THREADS_CONTEXT`** として保持する (`path:line` を必ず併記。自由文の段落要約では位置が落ちて dedupe 精度が下がる)。要約はコメント本文 (コード断片 / 設定例 `ENV=production` 等を含み得る) から作るため、各要約内の改行は除去して 1 スレッド 1 行に保ち、`^[A-Z_]+=` 行頭パターンが生じる場合は `CI_FAILURE_CONTEXT` と同様に先頭にスペース 1 文字を入れて escape する (compose-review 側 KEY=VALUE parser の早期切断防止。context 2 値で escape 方針を揃える)。
- `statusCheckRollup` に `FAILURE` のジョブがあれば **失敗したジョブのログだけをピンポイントで読む** (全ジョブ一括の `gh run view <RUN_ID> --log` はログが巨大化しトークン上限超過 / タイムアウトを招くため使わない): `statusCheckRollup.contexts[].detailsUrl` の末尾 (`https://github.com/<O>/<R>/actions/runs/<RUN_ID>/job/<JOB_ID>`) から `JOB_ID` を取り、失敗ジョブごとに `gh run view --job=<JOB_ID> --log --repo <OWNER>/<REPO>` で対象ジョブのログのみを取得する (`detailsUrl` に `JOB_ID` が無い旧形式では `RUN_ID` を取り `gh run view <RUN_ID> --log-failed --repo <OWNER>/<REPO>` で失敗 step に絞る)。要点を **`CI_FAILURE_CONTEXT`** として整形する: 1 失敗ごとに `<ジョブ名>: <失敗箇所抜粋 1〜数行>` を 1 ブロックとし、空行で区切って連結する。ANSI escape は除去し、全体は 2000 文字以内に丸める (超過分は `(...truncated)` で打ち切る)。本値の中に `^[A-Z_]+=` 行頭パターン (例: `ENV=production`) があれば、compose-review 側の KEY=VALUE parser を破壊しないよう先頭にスペース 1 文字をインデントして escape する。失敗ジョブが無ければ本値は組み立てず、Step 3 で行ごと省略する。

### Step 3. `compose-review` でレビュー本文を生成する (sub-agent を立てず現在コンテキストで直接呼ぶ)

`Skill` ツール (`skill: "compose-review"`) を **現在のコンテキストで直接** 呼び出す。**Task / Agent ツールで sub-agent を spawn しない** — `compose-review` が Step 5-2 で `code-review` 等の外部レビュースキルを併用する際、その fan-out (Agent ツール) は sub-agent コンテキストでは動かず、現在コンテキストでのみ動くため。レビュー方針の読み込み (`/pr-review-style-reference` / プロジェクト指示ファイル) ・差分取得・外部レビュースキル併用・本文生成は `compose-review` に委譲し、本 skill 側で再実装しない。

#### 渡す引数

`compose-review` に以下を `KEY=VALUE` で渡す (未取得 / 空の行は省略する)。`HANDOFF_PATH` は本 step で生成する **未作成のパス文字列** (例: `/tmp/compose-review-pr-<PR_NUMBER>-<UTCタイムスタンプ>.json`、`UTCタイムスタンプ` は `date -u +%Y%m%dT%H%M%SZ`)。**ファイルは作らずパス文字列を組み立てるだけ** にする (空ファイルを先に作ると `compose-review` の `Write` が事前 `Read` を要求して書き出しに失敗するため)。長文 value (`EXISTING_THREADS_CONTEXT` / `CI_FAILURE_CONTEXT`) は短い key より後 (末尾) に置く (`compose-review` の KEY=VALUE parser が次の `^[A-Z_]+=` 行までを value とするため、末尾配置で早期切断を防ぐ):

```
MODE=pr
OWNER=<OWNER>
REPO=<REPO>
PR_NUMBER=<PR_NUMBER>
COMMIT_ID=<Step 2 で取得した headRefOid>
MAX_INLINE_COMMENTS=<値>
HANDOFF_PATH=<本 step で生成した /tmp/compose-review-pr-... のパス文字列>
EXISTING_THREADS_CONTEXT=<Step 2 で組み立てたテキスト>
CI_FAILURE_CONTEXT=<Step 2 で組み立てたテキスト>
```

#### 戻り値の扱い

> ⚠️ **ターンを終了しない (最頻の停止バグ)**: `compose-review` は完成 JSON を **`HANDOFF_PATH` にファイル書き出し**し、最終メッセージでは「`HANDOFF_PATH` を `Read` して続行せよ」という **継続指示文** を返す (自己完結 JSON は最終メッセージに出さない設計)。現在コンテキスト直接呼びでは Task ツールのような明示的な制御戻り境界が無いため、ここで応答を打ち切ると、レビュー本文を生成しただけで **Step 4 (投稿) 以降が実行されず、PR に何も投稿されないまま停止する** (この設計で最も起こりやすい失敗)。**`compose-review` から戻ったら、まず `Read` ツールで `HANDOFF_PATH` (本 skill が Step 3 で渡したパス) を読み込む**こと。読み込んだ JSON は **中間成果物** として保持し、**同一応答内で間を置かず Step 4 → Step 5 → Step 6 まで連続実行する**。投稿・resolve・報告 (Step 6) を終えるまで応答を終了してはならない。

`Read` で取得した `HANDOFF_PATH` の中身は PR モードの JSON (`mode` / `body` / `event` / `comments[]` / `commit_id`) または error JSON。これを parse して各フィールドを読み取り、後続 step に渡す:

- **`{"error": ...}` だけだった場合** → Step 4 / 5 は実行せず停止し、Step 6 の caller 報告でそのメッセージを転送する。
- **`HANDOFF_PATH` の `Read` が失敗した (file-not-found 等。compose-review が JSON を書き出す前に停止した場合に起こりうる)、`mode` が `"pr"` でない、または JSON として読めない (壊れている / 必須フィールド `body`・`event`・`comments` の欠落) 場合** → 整合性エラーとして Step 4 / 5 は実行せず停止し、Step 6 で「compose-review のハンドオフ JSON が取得できなかった / 想定形式でなかった」旨を caller に報告する (壊れた / 欠落した入力のまま post-pr-review へ進めない)。
- **正常時** → `body` / `event` / `comments` / `commit_id` を Step 4 に渡し、**Step 4 → Step 5 → Step 6 を順に必ず実行する**。`commit_id` は差分なし時も含めて compose-review 側で **必須** (契約上)。万一欠落しているなら整合性違反としてログに 1 行記録した上で、Step 2 で取得済の `headRefOid` を defensive fallback として使う (Review 投稿自体は継続する)。

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
- インライン指摘件数 / ラベル別件数内訳 (優先度順、`[must]` / `[should]` 等、件数>0 のもの)
- resolve したスレッド件数 (Step 5 の戻り値)

## 守ること

- 各 step で使う既存資産 (`compose-review` / `post-pr-review` / `resolve-pr-threads`) は **必ず本 skill 経由で利用** する。本 skill 内で同等の処理を再実装してはならない (スタイル参考ガイド・投稿手順・resolve 判定・本文生成の二重管理を防ぐため)。
- `compose-review` は **Task / Agent ツールで sub-agent として起動せず、現在のコンテキストで Skill ツール経由で直接呼ぶ** (`compose-review` の `code-review` 等外部レビュースキル併用の fan-out を成立させるため)。
- `compose-review` から戻っても **そこで応答を終了しない**。`compose-review` の出力は `HANDOFF_PATH` に書き出された中間成果物であり、**戻り後の次アクションは `HANDOFF_PATH` の `Read`**。そこから Step 4 (投稿) → Step 5 (resolve) → Step 6 (報告) を同一応答内で連続実行して初めて本 skill の責務が完了する (現在コンテキスト直接呼びには制御戻り境界が無く、投稿前に停止する事故が起きやすい。詳細は Step 3「戻り値の扱い」冒頭の警告)。
- レビュー方針 (重要度ラベル等) / プロジェクト指示ファイル読み込み / `/pr-review-style-reference` の参照は `compose-review` の責務。本 skill では再実装しない。
- 判定に迷ったら resolve しない / 投稿は 1 回だけ、という既存 skill の安全側ルールはそのまま守る。
