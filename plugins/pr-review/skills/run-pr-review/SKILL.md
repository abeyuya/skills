---
name: run-pr-review
description: PR レビュー全体を1コマンドで実行する skill。PR 状態取得 (CI / reviewThreads) → compose-review skill によるレビュー本文生成 → post-pr-review skill による投稿 → resolve-pr-threads skill による過去スレッド整理までを通しで行う。caller (GitHub Actions など) からは本 skill を呼ぶだけで済むようにオーケストレーションを担う。
---

# run-pr-review skill

PR レビュー一式 (PR 状態取得 → レビュー本文生成 → 投稿 → 過去スレッド resolve) を **1つの skill 呼び出しで完結** させるためのオーケストレーション skill。

レビュー方針の読み込み (スタイル参考ガイド / プロジェクト指示ファイル) と本文生成は `compose-review` skill に委譲する。本 skill はその前後 (PR 識別 / CI・既存スレッド context 収集 / 投稿 / resolve / 報告) のみを担う。

> **重要**: Step 3 で `compose-review` が返す fenced JSON は **中間成果物** で、Step 4 (`post-pr-review`) で初めて GitHub に投稿される。chat に成果物っぽい JSON が出力されても **ここで終わってはならない**。Step 6 (caller 報告) まで実行して初めて本 skill の主目的 (GitHub への 1 Review 投稿) が達成される。CI 内 (人間不在) で実行された場合、Step 4 が抜けると無音で終わるため再発防止対策を Step 3 と Step 4 の両方に置いている。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。各項目に「省略時の挙動」と「Step N への forward 仕様」を併記する。

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR の識別情報。**省略時**は Step 1 の手順で自動取得 (空文字も未指定扱い)。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。**省略時** は Step 3 で `compose-review` に渡さない (`compose-review` 側のデフォルト `unlimited` が適用される)。
- `THREAD_RESOLVE_SCOPE`: `resolve-pr-threads` skill に渡す resolve 範囲。`all` / `own` / `none` のいずれか。**省略時** は `all` を明示的に Step 5 へ渡す。
- `SELF_LOGIN` (`THREAD_RESOLVE_SCOPE=own` 時のみ意味を持つ): 自身を判定するための `author.login`。**省略時** は Step 5 で `resolve-pr-threads` に渡さない。
- `RECHECK_HEAD_SHA`: 真偽値 (`true` / `false`)。**省略時** は Step 3 で `compose-review` に渡さない (`compose-review` 側のデフォルト `false` が適用される)。`true` を指定すると force-push 検知時に `compose-review` が停止し本 skill も Step 4 以降を実行せずに caller へ異常終了を報告する (詳細仕様は `compose-review/SKILL.md` の Step 1 PR モード TOCTOU 注意を参照)。force-push が頻繁な PR をドッグフーディング系 caller から扱う場合のみ使う。

caller プロジェクト固有のレビュー方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** (`REVIEW.md` / `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` の優先順で最初の 1 つだけ) に置く運用に固定する。読み込み自体は `compose-review` 側で行うため本 skill では扱わない。

## 手順

### Step 1. PR 識別情報を確定する

caller から `OWNER` / `REPO` / `PR_NUMBER` が **非空の値で** 渡されていればそれを使う。空文字 (`""`) は GitHub Actions 等で env 変数が未設定だと展開されうるので **未指定と同等に扱い、補完対象とする**。揃っていない値だけ以下で補う:

- `OWNER` / `REPO`: `gh repo view --json nameWithOwner -q .nameWithOwner` で `OWNER/REPO` 形式を取得し分解する。**戻り値が `OWNER/REPO` 形式 (スラッシュを 1 つ含む 2 トークン) を満たさない場合** (空文字 / 単一トークン / 複数スラッシュ等) は補完失敗として扱う。
- `PR_NUMBER`: `gh pr view --json number -q .number` で現在のブランチに紐づく PR 番号を取得する。**戻り値が非空の正の整数** でなければ補完失敗。紐づく PR が無い場合も同様にエラーとして停止し、caller に明示的に PR 番号を渡すよう促す。

補完後も 3 つのいずれかが確定できなかった場合 (`gh` コマンドの非ゼロ exit / 戻り値の形式不正 / 空文字を含む) は **エラーとして停止する** (`compose-review` を呼ばない)。`compose-review` 側のモード判定 (3 つ揃わなければ局所 diff モードへ退化) は本 skill の用途と意図が合わないため、本 skill では混在 / 部分欠落 / 形式不正を弾く責務を持つ。

### Step 2. CI / 既存スレッドの context を収集する

`compose-review` に渡す追加コンテキストを集める。本 step では **diff は取らない** (取得は `compose-review` 内で行う)。`gh pr view` / `gh pr diff` / `gh run view` 等の **REST 系 `gh` コマンドには `--repo <OWNER>/<REPO>` を必ず明示する** (cwd の git remote と PR の所属リポジトリが異なる場合に意図しない PR を参照しないため)。`gh api graphql` は `--repo` フラグを受け付けないので **対象を `-F owner=<OWNER> -F name=<REPO>` で渡す** (本 step 内の GraphQL 呼び出しは例外扱い)。

- **CI failure 情報**:
  - `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json statusCheckRollup` で CI 状態を取得する。
  - `statusCheckRollup` に `FAILURE` のジョブがあれば `gh run view --log --repo <OWNER>/<REPO>` 等で失敗ログ本体まで読み、関連箇所と失敗理由のサマリを自然言語で組み立てる。これを `compose-review` の `CI_FAILURE_CONTEXT` 入力として転送する。
  - 失敗ジョブが無ければ `CI_FAILURE_CONTEXT` は渡さない (空文字も渡さない)。
- **既存 reviewThreads サマリ (重複回避用)**:
  - GraphQL で `reviewThreads` を取得する。`-F owner=<OWNER> -F name=<REPO> -F number=<PR_NUMBER>` で渡す。`PR_NUMBER` は GraphQL の `Int!` 型なので **必ず `-F` (型推論あり) を使い、`-f` (文字列固定) は使わない**。`reviewThreads(first: 100)` は 1 ページ上限なので `pageInfo { hasNextPage endCursor }` を取得し、`hasNextPage` が `true` の間 `-F after=<endCursor>` で全件取得する。クエリ雛形は次の通り (初回は `$after` を `null` として呼び、以降 `-F after=<endCursor>` を追加する):

    ```graphql
    query($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              comments(first: 50) {
                nodes {
                  path
                  line
                  originalLine
                  body
                  author { login }
                }
              }
            }
          }
        }
      }
    }
    ```

  - クエリで取得するフィールドは **必要最小限のセット** に絞る (出力サイズ削減):
    - dedupe 本体用 (path:line + body 突合): `comments(first: 50)` 要素の `path` / `line` / `originalLine` / `body`。`originalLine` はコメント先のコミットが進んで `line` が `null` になっているスレッドで位置情報を保つために併記。
    - filter / 拡張用: スレッドレベルの `id` (将来 `resolve-pr-threads` 側と参照を揃える用途) / `isResolved` (本 step でクライアント側 filter する) / `comments.nodes[].author.login` (将来 `THREAD_RESOLVE_SCOPE=own` 時の自己判定で再利用する想定)。
    - **`side` は `PullRequestReviewComment` 型に存在しないため絶対にクエリに含めない** (`undefinedField` で 422 になる; dedupe は `path` / `line` / `body` の組み合わせで充分)。
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
- `OUTPUT_DESTINATION=file` (**必ず `file` を明示指定する**)

`OUTPUT_DESTINATION=file` を指定することで、`compose-review` は JSON 本体を `/tmp/compose-review-output.json` に書き出し、chat には 1 行サマリのみを返す。**chat に fenced JSON が出ない** ことで、orchestrator (実装エージェント) が「JSON が出たからタスク完了」と誤認するリスクを構造的に取り除く (PR #34 で実害が発生した既知の踏み外しパターン)。

**🛑 ここでターンを終えてはいけない**: `compose-review` の Skill ツール呼び出しが完了し chat に 1 行サマリ (中間成果物完了の知らせ) が返ったら、それは **「次に進め」のシグナル**。完了報告の見た目に騙されず、SKILL.md の次行 (Step 3.5) に進む。これは PR #34 で 3 回踏み抜かれた既知パターンへの再掲警告。

### Step 3.5. `_intermediate` を確認し Step 4 に進む準備をする

**🛑 本 step は Step 3 終了直後に必ず実行する** (意図的に独立 step として番号を振っている)。Step 3 の `compose-review` 呼び出しが完了したら、chat 出力の見た目に関わらずここで「タスク完了」と判定してはならない。本 PR で 3 回踏み抜かれた既知パターンの一次防止線。

1. `Read` ツールで `/tmp/compose-review-output.json` を読み込む。
2. パースして `_intermediate` フィールドを確認する。
   - `_intermediate: true` であることを確認する (PR モードでは必ずこの値)。
   - `next_step: "post-pr-review"` であることを確認する (次に呼ぶべき skill 名)。
3. 後続で `post-pr-review` に転送する各フィールド (`body` / `event` / `comments` / `commit_id`) を JSON から取り出す。`_intermediate` / `next_step` / `mode` は orchestrator 内部用の meta フィールドのため転送しない。
4. ここで **絶対にターンを終えない**。本 step を読了したらそのまま Step 4 に続けて進む。本 step を独立 step として置いている目的は「Step 3 で JSON を受け取った直後の "区切り感" よりも強い継続フック」を作ること。`_intermediate: true` を確認したまま終わったら本 skill の主目的 (= GitHub への 1 Review 投稿) は達成されない。CI 内で人間不在のまま走る運用 (claude-code-action 等) では Step 4 抜けは無音の事故になるため、本 step を読了 → Step 4 へ進む、を機械的に守ること。

### Step 4. `post-pr-review` skill でレビューを投稿する

Step 3.5 で `/tmp/compose-review-output.json` から取り出したフィールドと Step 1 で確定した `OWNER` / `REPO` / `PR_NUMBER` を `post-pr-review` skill に渡し、**1回の API コールで1つの Review として** 投稿する。`gh pr comment` や `gh pr review` での個別投稿はしない。

起動方法は **Skill ツールで `post-pr-review` を呼ぶ**。フィールド対応関係は次の通り (`post-pr-review` 側はこの入力名で受け取り、`/tmp/review.json` を組み立てる):

| compose-review 戻り値 | post-pr-review 入力名 | 備考 |
| --- | --- | --- |
| `body` | `body` | 文字列。AI 自動投稿マーカーは `post-pr-review` が prepend するので **そのまま渡す**。 |
| `event` | `event` | 文字列 `"COMMENT"` 固定。 |
| `comments` | `comments` | 配列。要素のキー (`path` / `line` / `side` / `start_line` / `start_side` / `body`) はそのまま。**ここでの `side` は GitHub Review REST API (`POST /repos/.../reviews`) の `comments[]` 入力スキーマで `"RIGHT"` / `"LEFT"` を取る正規フィールドであり、Step 2 で「クエリに含めるな」とした GraphQL の `PullRequestReviewComment` 型の `side` (存在しない) とは別物。文脈 (REST POST vs GraphQL Read) で扱いが反転する点に注意。** |
| `commit_id` | `COMMIT_ID` | 文字列。`compose-review` が省略してきた場合 (transient 失敗による省略 / 「対象差分なし」分岐で commit_id が含まれていなかった場合等、理由を問わず) は本入力も省略する。空文字を渡さない (`gh api .../reviews` が 422 で失敗するため)。 |
| `_intermediate` / `next_step` / `mode` | (転送しない) | orchestrator 内部用の meta フィールド。`post-pr-review` には渡さない。 |
| (本 skill が確定済み) | `OWNER` / `REPO` / `PR_NUMBER` | Step 1 の値。`post-pr-review` の入力名 (`post-pr-review/SKILL.md` の入力セクション参照) もこの **大文字スネークケースそのまま**。改名 / 小文字化はしない。 |

`commit_id` だけ uppercase に rename する点に注意 (`body` / `event` / `comments` は **lowercase のまま**)。`/tmp/review.json` の `Write` と `gh api .../reviews --input` の実行は呼び先の `post-pr-review` 側で行うため、本 skill 側で先回りして書かない。

`compose-review` が「対象差分なし」相当の JSON (`comments: []` / `body` に「対象差分なし」相当の文言) を返してきた場合も、上記対応関係で `post-pr-review` を呼ぶ (Review 自体は投稿する)。

### Step 5. `resolve-pr-threads` skill で過去スレッドを整理する

Step 1 の PR 識別情報と `THREAD_RESOLVE_SCOPE` (省略時 `all`) を `resolve-pr-threads` skill に渡して呼び出す。`THREAD_RESOLVE_SCOPE=none` の場合は呼び出すが skill 側で skip される。

`THREAD_RESOLVE_SCOPE=own` の場合、caller から `SELF_LOGIN` が渡されていれば一緒に渡す。

### Step 6. caller への報告

以下を簡潔に caller へ返す:

- 投稿した Review の URL (Step 4 のレスポンスから取れる場合)
- インライン指摘件数 / 総括の主要懸念件数 / severity 内訳 (Step 3.5 で `/tmp/compose-review-output.json` から取り出した `comments[]` の長さと `body` 内訳から算出)
- resolve したスレッド件数 (Step 5 の戻り値)

## 守ること

- 各 step で使う既存資産 (`compose-review` / `post-pr-review` / `resolve-pr-threads`) は **必ずこの skill 経由で利用** する。本 skill 内で同等の処理 (スタイル参考ガイド読み込み / レビュー本文生成 / 投稿 / resolve 判定) を再実装してはならない (二重管理を防ぐため)。
- レビュー文面の規約 (重要度ラベル等) は `compose-review` 配下の `style-reference.md` に集約されているため、本 skill では再掲しない。caller 側に独自方針がある場合はプロジェクト指示ファイルで上書きする。
- 判定に迷ったら resolve しない / 投稿は1回だけ、という既存 skill の安全側ルールはそのまま守る。
