---
name: run-pr-review
description: PR レビュー全体を1コマンドで実行する skill。スタイル参考ガイド (/pr-review-style-reference) の読み込み・PR 情報取得・レビュー文面作成・post-pr-review での投稿・resolve-pr-threads での過去スレッド整理までを通しで行う。caller (GitHub Actions など) からは本 skill を呼ぶだけで済むようにオーケストレーションを担う。
---

# run-pr-review skill

PR レビュー一式 (スタイル参考ガイド読み込み → PR 確認 → レビュー作成 → 投稿 → 過去スレッド resolve) を **1つの skill 呼び出しで完結** させるためのオーケストレーション skill。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR の識別情報。省略時は後述の手順で自動取得する。
- `PROJECT_GUIDELINES`: プロジェクトのレビュー指示ファイル (技術観点 / スタイル上書き / 全方針置換 のいずれを含めてもよい) のリポジトリ相対パス。複数指定する場合はカンマ区切り (例: `docs/ai_code_review/all.md, docs/ai_code_review/typescript.md`)。省略時は読み込まない。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited` 扱い (=`/pr-review-style-reference` 引数なしのデフォルト)。Step 2 で `/pr-review-style-reference max-inline-comments=<値>` として渡す。
- `THREAD_RESOLVE_SCOPE`: `resolve-pr-threads` skill に渡す resolve 範囲。`all` / `own` / `none` のいずれか。省略時は `all`。
- `SELF_LOGIN` (任意, `THREAD_RESOLVE_SCOPE=own` 時): 自身を判定するための `author.login`。caller が判明していれば渡す。Step 7 でそのまま `resolve-pr-threads` に転送される。

## 手順

### Step 1. PR 識別情報を確定する

caller から `OWNER` / `REPO` / `PR_NUMBER` が渡されていればそれを使う。揃っていない値だけ以下で補う:

- `OWNER` / `REPO`: `gh repo view --json nameWithOwner -q .nameWithOwner` で `OWNER/REPO` 形式を取得し分解する。
- `PR_NUMBER`: `gh pr view --json number -q .number` で現在のブランチに紐づく PR 番号を取得する。紐づく PR が無い場合はエラーとして停止し、caller に明示的に PR 番号を渡すよう促す。

### Step 2. スタイル参考ガイドを読み込む

`/pr-review-style-reference` slash command を実行し、スタイル参考ガイド (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い) を本セッションのレビュー方針の参考として読み込む。

レビュー方針は caller プロジェクトに委ねる前提。Step 3 で読み込む `PROJECT_GUIDELINES` が本スタイル参考ガイドに上乗せ・上書き・全置換のいずれを意図しているかは caller の指示に従う。caller 側に独自方針が無い場合は本スタイル参考ガイドをそのまま採用してよい。

`MAX_INLINE_COMMENTS` が指定されている場合は `/pr-review-style-reference max-inline-comments=<値>` として渡す。未指定なら引数なしで呼ぶ。

### Step 3. プロジェクト固有観点を読み込む (任意)

`PROJECT_GUIDELINES` が指定されている場合のみ、カンマで分割した各パスを `Read` ツールで読み (前後空白はトリム)、本セッションのレビュー方針として適用する。Step 2 のスタイル参考ガイドと矛盾する箇所はプロジェクト側を優先し、矛盾しない箇所は両者を併用する (プロジェクト側で「スタイル参考ガイドを使わない」旨が明示されている場合はそれに従う)。指定が無い場合はこのステップを skip する。

### Step 4. PR の状態を取得する

レビューに必要な情報を取得する。

いずれの `gh` コマンドも、cwd の git remote と PR の所属リポジトリが異なる場合 (ドッグフーディングや別リポジトリ向け caller) に意図しない PR を参照しないよう、Step 1 で確定した `OWNER`/`REPO` を `--repo <OWNER>/<REPO>` で必ず明示する。

- `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json title,body,headRefName,baseRefName,statusCheckRollup,commits` で PR メタ情報と CI 状態を取得する。
- `gh pr diff <PR_NUMBER> --repo <OWNER>/<REPO>` で差分を取得する。
- 既存レビュー / コメントは `resolve-pr-threads` 内でも取得するが、**重複指摘を避けるため** 本ステップでも GraphQL で `reviewThreads` を取得し、自分の過去コメント等を把握しておく (caller 側に方針が無い場合は `/pr-review-style-reference` の「既存レビュー/コメントとの重複回避」を参考にする)。GraphQL は `-F owner=<OWNER> -F name=<REPO>` で渡す。`reviewThreads(first: 100)` は GitHub GraphQL API の 1 ページあたりの上限値で、100 件を超える可能性がある PR では `pageInfo { hasNextPage endCursor }` を取得し、`hasNextPage` が `true` の間 `-F after=<endCursor>` を付けて再実行して全スレッドを取得しきること (取得漏れがあると重複指摘の検知が抜ける)。各スレッドの `comments.nodes[].body` まで取得し、Step 5 で本文の主旨重複判定に使う (`path`/`line` だけでは「位置は同じだが論点は別」のケースを取り違える)。
- `commits` の末尾要素 (`gh pr view ... --json commits` の最後の `oid`) を head SHA として控え、Step 6 で `post-pr-review` の引数に **常時** 転送する (受け側で必須でも任意でも害はなく、コミット移動による誤コメント防止に有効。「必要に応じて転送」のような条件分岐はしない)。
- caller の cwd と PR の所属リポジトリが異なるドッグフーディング系では、`PROJECT_GUIDELINES` のパスがローカルに存在しないことがある。その場合は `gh api repos/<OWNER>/<REPO>/contents/<path>` でリモートから取得して `Read` 相当に扱う (Step 3 の補足)。
- `statusCheckRollup` に `FAILURE` のジョブがあれば `gh run view --log --repo <OWNER>/<REPO>` 等で失敗ログ本体まで読み、`[must]` 指摘の根拠にする (詳細は `/pr-review-style-reference` の「CI の扱い」を参考)。

### Step 5. レビュー本文を作成する

Step 2〜4 で得た方針・観点・差分・CI 情報をもとに、総括 (`body`) とインライン指摘 (`comments[]`) を作成する。

- レビュー方針はプロジェクト (`PROJECT_GUIDELINES`) を最優先とし、プロジェクト側で明示的に上書きされていない論点については `/pr-review-style-reference` (スタイル参考ガイド) の重要度ラベル / ノイズ抑制 / 粒度ガイド等を参考にする。プロジェクト側でスタイル参考ガイドを使わない旨が明示されている場合はそれに従う。
- 既存スレッドと同主旨の指摘は再掲しない。判定は Step 4 で取得した `reviewThreads.nodes[].comments.nodes[].body` の主旨と現在の指摘の主旨を突き合わせて行う (位置 `path:line` だけが一致して論点が別のケースは「別件として新規指摘してよい」)。
- `event` (`post-pr-review` への引数) のデフォルト選定基準: `[must]` が 1 件以上含まれるなら `REQUEST_CHANGES`、`[must]` が 0 件で `[should]` 以下のみなら `COMMENT`、指摘ゼロなら `COMMENT` (空 Review として投稿)。`APPROVE` は caller / プロジェクト側で明示的に指定された場合のみ使う (誤承認のリスクを避けるため、自動 `APPROVE` はデフォルトでは選ばない)。
- 指摘が無い場合も Step 6 で「特に指摘なし」相当の Review を投稿する (skip しない)。

### Step 6. `post-pr-review` skill でレビューを投稿する

Step 1 で確定した `OWNER` / `REPO` / `PR_NUMBER` と Step 5 で作成した本文を `post-pr-review` skill に渡し、**1回の API コールで1つの Review として** 投稿する。`gh pr comment` や `gh pr review` での個別投稿はしない。

起動方法は **Skill ツールで `post-pr-review` を呼ぶ**。本文 (`body` / `event` / `comments[]`) は `post-pr-review/SKILL.md` のスキーマに従って組み立て、起動時の引数として渡す。`/tmp/review.json` の `Write` と `gh api .../reviews --input` の実行は呼び先の `post-pr-review` 側で行うため、本 skill 側で先回りして書かない。

### Step 7. `resolve-pr-threads` skill で過去スレッドを整理する

Step 1 の PR 識別情報と `THREAD_RESOLVE_SCOPE` (省略時 `all`) を `resolve-pr-threads` skill に渡して呼び出す。`THREAD_RESOLVE_SCOPE=none` の場合は呼び出すが skill 側で skip される。

`THREAD_RESOLVE_SCOPE=own` の場合、caller から `SELF_LOGIN` が渡されていれば一緒に渡す。

### Step 8. caller への報告

以下を簡潔に caller へ返す:

- 投稿した Review の URL (Step 6 のレスポンスから取れる場合)
- インライン指摘件数 / 総括の主要懸念件数
- resolve したスレッド件数 (Step 7 の戻り値)

## 守ること

- 各 step で使う既存資産 (`/pr-review-style-reference` / `post-pr-review` / `resolve-pr-threads`) は **必ずこの skill 経由で利用** する。本 skill 内で同等の処理を再実装してはならない (スタイル参考ガイド・投稿手順・resolve 判定の二重管理を防ぐため)。
- レビュー文面の規約 (重要度ラベル等) は `/pr-review-style-reference` (スタイル参考ガイド) に集約されているため、本 skill では再掲しない。caller 側に独自方針がある場合はそちらを優先する。
- 判定に迷ったら resolve しない / 投稿は1回だけ、という既存 skill の安全側ルールはそのまま守る。
