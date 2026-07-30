---
name: run-local-review
description: 現在のローカルブランチを対象に、PR を作る前段階で AI レビューを行う thin orchestrator。`compose-review` skill を (sub-agent を立てず) 現在コンテキストで直接呼んでレビュー本文を生成し、結果をチャットと markdown ファイルの両方に出力する。GitHub への投稿は行わない (post-pr-review / resolve-pr-threads は呼ばない)。
---

# run-local-review skill

PR 作成前のローカルブランチに対して AI レビューを行うための thin orchestrator skill。レビュー方針は `run-pr-review` と揃え、出力先のみ「GitHub Review 投稿」ではなく「チャット表示 + markdown ファイル出力」に差し替えたバリエーション。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。

- `BASE_BRANCH`: 比較対象のベースブランチ。`compose-review` にそのまま転送する。本 skill / `compose-review` は `git fetch` を走らせないため、ローカルのベースが古いと古い基準で diff が出る。最新で比較したい場合は caller 側で fetch するか、`BASE_BRANCH=origin/main` のようにリモート追跡参照を明示する。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。`compose-review` にそのまま転送する。
- `OUTPUT_PATH`: markdown 出力先パス。省略時は `/tmp/run-local-review/{repo}/{timestamp}-{branch}.md` (例: `/tmp/run-local-review/skills/20260507T123456Z-claude-unique-review-filenames-tpIhG.md`)。caller が明示パスを指定した場合は既存ファイルがあれば上書きする。プレースホルダの組み立て規則:
  - `{repo}`: `git remote get-url origin` の URL 末尾セグメント (`.git` を除く、取得失敗時は `local`)
  - `{timestamp}`: `date -u +%Y%m%dT%H%M%SZ` の出力
  - `{branch}`: 現在ブランチ名の英数記号以外 (`/` 等) を `-` に置換

caller プロジェクト固有の方針は **プロジェクト指示ファイル** に置く運用。読み込み手順は `compose-review` skill 側に集約しているため、本 skill では扱わない。

## 手順

### Step 1. `compose-review` でレビュー本文を生成する (sub-agent を立てず現在コンテキストで直接呼ぶ)

Skill ツール (`skill: "compose-review"`) を **現在のコンテキストで直接** 呼び出す。**Task / Agent ツールで sub-agent を spawn しない** — sub-agent 起動のオーバーヘッドを避けサクッとレビューを回すため、かつ `compose-review` が Step 5-2 で `code-review` 等の外部レビュースキルを併用する際その fan-out (Agent ツール) が現在コンテキストでないと動かないため。レビュー方針の読み込み (`/pr-review-style-reference` / プロジェクト指示ファイル) ・差分取得・外部レビュースキル併用・本文生成は `compose-review` に委譲し、本 skill 側で再実装しない。

#### 外部レビューの手動併用 (任意, ユーザー向け運用)

`compose-review` Step 5-2 の外部レビュー併用は、Claude Code 組み込みの `code-review` が `disable-model-invocation` を持つため **モデルからは Skill ツール経由で呼べない**。自動経路では代わりに同梱の `scan-diff-findings` が使われる。`code-review` の findings を併用したい場合、ユーザーは **同一セッションで先に `/code-review` を手動実行** (`--fix` / `--comment` は付けない) してから本 skill を呼べばよい。1 回目の findings がコンテキストに残るため、`compose-review` はそれを外部レビュー結果として採用できる (詳細は plugin README「外部レビューの手動併用」)。本 skill 側で `code-review` を呼ぶ実装は持たない (Step 5-2 の責務)。

#### 渡す引数

`compose-review` に以下を `KEY=VALUE` で渡す (未取得 / 空の行は省略する)。`HANDOFF_PATH` は本 step で生成する **未作成のパス文字列** (例: `/tmp/compose-review-local-<branch>-<UTCタイムスタンプ>-<ランダム英数字 4〜6 文字>.json`、`UTCタイムスタンプ` は `date -u +%Y%m%dT%H%M%SZ`)。同一秒の再呼び出しでの衝突を避けるため `compose-review` の既定パスと同様にランダムサフィックスを付ける。`<branch>` は `OUTPUT_PATH` の `{branch}` 規則と同様に **現在ブランチ名の英数記号以外 (`/` 等) を `-` に置換** してから埋め込む (本リポジトリの `claude/...` のようなスラッシュ入りブランチで `/tmp/.../` のネストパスになり親ディレクトリ不在で `Write` 失敗するのを防ぐ)。これは markdown 出力先 `OUTPUT_PATH` とは **別物** (compose-review からの JSON 受け渡し用 temp ファイル) であり、**ファイルは作らずパス文字列を組み立てるだけ** にする (空ファイルを先に作ると `compose-review` の `Write` が事前 `Read` を要求して書き出しに失敗するため):

```
MODE=local
BASE_BRANCH=<値>
MAX_INLINE_COMMENTS=<値>
HANDOFF_PATH=<本 step で生成した /tmp/compose-review-local-<branch (/ 等を - に置換)>-<UTCタイムスタンプ>-<ランダム英数字>.json のパス文字列>
```

#### 戻り値の扱い

> ⚠️ **ターンを終了しない (最頻の停止バグ)**: `compose-review` は完成 JSON を **`HANDOFF_PATH` にファイル書き出し**し、最終メッセージでは「`HANDOFF_PATH` を `Read` して続行せよ」という **継続指示文** を返す (自己完結 JSON は最終メッセージに出さない設計)。現在コンテキスト直接呼びでは Task ツールのような明示的な制御戻り境界が無いため、ここで応答を打ち切ると、レビュー本文を生成しただけで **Step 2 (markdown 出力) 以降が実行されず、何も出力されないまま停止する** (この設計で最も起こりやすい失敗)。**`compose-review` から戻ったら、まず `Read` ツールで `HANDOFF_PATH` (本 skill が Step 1 で渡したパス) を読み込む**こと。読み込んだ JSON は **中間成果物** として保持し、**同一応答内で間を置かず Step 2 → Step 3 まで連続実行する**。markdown 出力・報告 (Step 3) を終えるまで応答を終了してはならない。

> ⚠️ **外部レビュー fan-out の待ちでターンを yield しない (上記停止バグの変種)**: `compose-review` の Step 5-2 は `code-review` 等の外部レビュースキルを現在コンテキストで呼び、その内部で **Agent ツールによる finder/verifier の fan-out** が走る。リモート実行環境では並列起動した Agent の一部が **harness によって自動で background 実行に回される** ことがあるが、その完了を **`Monitor` / `run_in_background` の完了通知 / sleep ループ等で待って応答 (ターン) を終了してはならない**。background agent の完了を待つために応答を打ち切った時点で「何も出力しないまま停止」に見え、上の停止バグと同じ結末になる。**同期的に得られた finder 結果だけで先へ進む** — recall は `compose-review` の 5-1 自前レビューが必ず担保しており、background 化した一部 finder を取りこぼしても致命ではない。Step 2 (markdown 出力) → Step 3 (報告) を **同一応答内で完了させることを最優先** する。background agent の結果がどうしても要るなら、ターンを yield せず現在の応答内で待ち合わせる手段だけを使う (`compose-review` 側も sub-agent を直接 spawn せず外部スキルに委ねる契約のため、本 skill が背後の Agent を background 化して待つ必要は本来無い)。

`Read` で取得した `HANDOFF_PATH` の中身はローカルモードの JSON (`mode` / `base_branch` / `diff_mode` / `commit_count` / `body` / `event` / `comments[]` / `label_counts`) または error JSON。これを parse して各フィールドを読み取り、得られた `base_branch` / `diff_mode` / `commit_count` / `body` / `comments` をそのまま Step 2 に渡し、**Step 2 → Step 3 を順に必ず実行する**。

`label_counts` は `post-pr-review` が Review body の機械可読サマリ行 (`AI-REVIEW-RESULT`) を組み立てるための値で、GitHub 投稿を行わない本 skill では **使わない** (markdown 出力の「インライン指摘」件数は従来どおり `comments[]` から数える)。欠落していてもエラー扱いにしない (必須フィールド判定の対象外)。

ただし `HANDOFF_PATH` の中身が致命エラーの `{"error": ...}` だけだった場合 (例: `HEAD` detached、ベースブランチ解決失敗)、**`HANDOFF_PATH` の `Read` が file-not-found 等で失敗した場合** (compose-review が JSON を書き出す前に停止した可能性)、**または読み込んだ内容が JSON として parse できない / `mode` が `"local"` でない / 必須フィールド (`base_branch` / `diff_mode` / `body` / `comments`) を欠く場合** は、擬似結果 (`comments=[]` / `base_branch="<unknown>"` / `diff_mode="none"` / `commit_count=0` / `body="compose-review エラー: <error message / ハンドオフ JSON 取得・parse 失敗>"`) を組み立てて Step 2 (markdown 出力) を **必ず実行** し、Step 3 で同旨を報告する (markdown ファイルは差分が空でも必ず生成する、という本 skill「守ること」の不変条件と整合させる)。なお正常時も、同一コンテキスト実行だからと parse を省かず、必ず読み込んだ JSON を parse して各フィールドを抽出する (前段落参照)。

### Step 2. 結果を出力する (チャット + markdown ファイル)

markdown ファイルが完全版、チャットは要約版で、両者は内容そのものは同じだが粒度が異なる (チャットへの全文ダンプは後続コンテキストを圧迫するため避ける)。

#### 2-1. markdown ファイル

`OUTPUT_PATH` (省略時の組み立て規則は「入力」セクションの `OUTPUT_PATH` 説明を参照) に `Write` ツールで書き出す。

`Write` ツールは中間ディレクトリの自動作成を保証していないため、書き出し前に `Bash` ツールで `mkdir -p "$(dirname "<OUTPUT_PATH>")"` を実行して親ディレクトリを作成する (`<OUTPUT_PATH>` をダブルクォートで囲むことでスペース入りパスも安全に動く)。caller が明示パスを指定したケースも同様。

現在ブランチ名は `git rev-parse --abbrev-ref HEAD` で取得する (markdown 見出し用)。

スキーマ:

```markdown
# Local AI Review: <branch> (vs <base_branch>)

- 生成日時: <ISO8601, UTC 秒精度。例: 2026-05-04T12:34:56Z>
- 差分モード: <commit / staged / worktree / none>
- 対象コミット: <ここは `diff_mode="commit"` のとき `<commit_count> 件 (<base_branch>..HEAD)` (例: `3 件 (main..HEAD)`)、それ以外 (`staged` / `worktree` / `none`) のとき `0 件 (コミット未作成)` と固定文字列で書き込む。機械的な置換ではなく `diff_mode` で分岐する>
- インライン指摘: <count> 件

## 総括

<compose-review の `body` を埋め込む。埋め込み時、`body` 内の **行頭 `^## ` を一律 `### ` に機械置換** して h2 を h3 に 1 段下げる (特定見出し名 `## 総合判断` / `## 指摘内訳` / `## 良かった点` への依存を避け、compose-review が将来見出し文言を変えても取りこぼさないため)。h3 以降 (`### ` 等) はそのまま。markdown 親見出し `## 総括` の下に同レベルの h2 が並んで階層が崩れるのを防ぐ変換であり、post-pr-review 投稿時は h2 のままが自然なので本変換は run-local-review でのみ行い、compose-review 自体は h2 を出力する契約のままにする。>

## インライン指摘

### 1. [must] path/to/file.ts:42

<comments[0].body>

### 2. [should] path/to/file.ts:50-55

<comments[1].body>

<以下、指摘ごとに繰り返し。指摘が無ければ「特に指摘なし」とだけ書く。>
```

各インライン指摘の見出しは `### <番号>. <body 先頭の重要度ラベル> <path>:<line>` の形式で揃える。重要度ラベルは `comments[i].body` の先頭にある `[must]` / `[should]` / `[nit]` / `[question]` / `[pre_existing]` のいずれか (正規表現 `^\[[a-z_]+\]` を `body` 冒頭にマッチさせて取り出す)。見出しに使ったラベル文字列は本文側からは削除せず `body` をそのまま掲載する (本文先頭でも重複表示で問題ない)。マッチしない場合は見出しからラベルを省く (`### <番号>. <path>:<line>`)。複数行範囲 (`start_line` / `line` 併用) のコメントは `<path>:<start_line>-<line>` で表記する。

`heredoc` や `cat` リダイレクトは使わず、必ず `Write` ツールで書く。`Write` ツールは既存ファイルがあると事前 `Read` 必須なため、`OUTPUT_PATH` が既存パスの可能性があれば `Read` を 1 回挟んでから `Write` する。

差分なし (`diff_mode: "none"`) で `compose-review` から空 `comments[]` + 「対象差分なし」相当の `body` が返った場合でも、markdown のスキーマ (`## 総括` / `## インライン指摘` 見出し) は保持し、本文は compose-review が返した文言と「特に指摘なし」で埋める (見出し削除や空セクション化はしない)。

「生成日時」は実行時に `date -u +%Y-%m-%dT%H:%M:%SZ` で取得した UTC 秒精度の ISO8601 を採用する。`date` が利用できない環境では caller / 実行環境から提供される現在日時を使い、それも無ければ `<unknown>` と記載する。

#### 2-2. チャット出力

チャットには以下を出力する。markdown ファイル全文をそのままダンプしない (指摘件数や差分が多いケースで後続会話のコンテキストを圧迫するため):

- 冒頭に出力先パス (`OUTPUT_PATH`) を 1 行
- `## 総括` セクションは全文表示
- インライン指摘は「番号. `[label]` `path:line` — 1 行サマリ」のリスト形式に縮約 (本文詳細は markdown 側に任せる)
- 末尾に `詳細は <OUTPUT_PATH> を参照` を 1 行添える

### Step 3. caller への報告

以下を簡潔に caller へ返す:

- レビュー対象のブランチ / `base_branch` / `diff_mode`
- インライン指摘件数
- 出力先 markdown ファイルパス

## 守ること

- レビュー本文生成は **`compose-review` skill に委譲** する (本 skill 内で `/pr-review-style-reference` 読み込み / プロジェクト指示ファイル / 差分取得 / 本文生成を再実装しない)。`compose-review` は **Task / Agent ツールで sub-agent として起動せず、現在のコンテキストで Skill ツール経由で直接呼ぶ** (sub-agent 起動のオーバーヘッドを避けるため、かつ `compose-review` の Step 5-2 で `code-review` 等の外部レビュースキルを併用する際その fan-out (Agent ツール) が現在コンテキストでないと動かないため。後者の制約上、直接呼びは任意の最適化ではなく**必須**)。
- `compose-review` から戻っても **そこで応答を終了しない**。`compose-review` の出力は `HANDOFF_PATH` に書き出された中間成果物であり、**戻り後の次アクションは `HANDOFF_PATH` の `Read`**。そこから Step 2 (markdown 出力) → Step 3 (報告) を同一応答内で連続実行して初めて本 skill の責務が完了する (現在コンテキスト直接呼びには制御戻り境界が無く、出力前に停止する事故が起きやすい。詳細は Step 1「戻り値の扱い」冒頭の警告)。
- 外部レビュー (`compose-review` Step 5-2 / `code-review`) の内部 fan-out で起きた **sub-agent が harness により background 化しても、その完了を待って応答を終了しない**。`Monitor` / background 完了通知待ち / sleep ループでターンを yield せず、**同期的に得られた結果だけで Step 2 → Step 3 を完了する** (recall は `compose-review` の 5-1 自前レビューが担保する。詳細は Step 1「戻り値の扱い」2 つ目の警告)。
- GitHub への投稿は行わない。`post-pr-review` / `resolve-pr-threads` skill は呼ばない。**経路を問わず** GitHub 投稿系ツールを使わない (`gh pr comment` / `gh pr review` / `gh api .../reviews` も、`mcp__github__pull_request_review_write` / `add_comment_to_pending_review` / `add_reply_to_pull_request_comment` / `add_issue_comment` 等の MCP 投稿ツールも使わない。web/remote では MCP が唯一の GitHub 経路になるため、gh のみを禁じても read-only 保証が漏れる)。
- `git fetch` / `git pull` / `git checkout` / `git reset` 等、ワーキングツリーやローカル ref を書き換える操作はしない。読み取り専用 (`git rev-parse` / `git remote get-url`) のみ。
- 差分が空の場合も markdown 出力 + 報告は行う (skip しない)。判定は `compose-review` 側の `diff_mode` に従う。
