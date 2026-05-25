---
name: run-local-review
description: 現在のローカルブランチを対象に、PR を作る前段階で AI レビューを行う thin orchestrator。`compose-review` (sub-agent) でレビュー本文を生成し、結果をチャットと markdown ファイルの両方に出力する。GitHub への投稿は行わない (post-pr-review / resolve-pr-threads は呼ばない)。
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

### Step 1. `compose-review` (sub-agent) でレビュー本文を生成する

Task ツール (`subagent_type=general-purpose`) を 1 回 dispatch する。Prompt テンプレート (`<…>` プレースホルダは実値で埋める。値が未取得 / 空の引数行は行ごと省略する。空文字埋めはしない):

```
pr-review プラグインの compose-review skill を呼び出すための subagent。
以下の引数で /compose-review を呼び、その出力 (JSON) を最終メッセージとして
verbatim に返せ。最終メッセージは前置きも fenced ブロックもなしの生 JSON 1 つだけ。

MODE=local
BASE_BRANCH=<値>
MAX_INLINE_COMMENTS=<値>
```

Task ツール result (sub-agent の最終メッセージ) を `json.loads()` 等で parse する:

- parse 失敗 (JSON として読めない / fenced ブロック付き / 複数 JSON / 想定外形式) は整合性エラーとして停止し、Step 3 の caller 報告で「compose-review 戻り値が JSON として読めなかった」旨を転送する (Step 2 は skip)。
- `error` フィールドがあれば Step 3 の caller 報告でそのメッセージを転送し停止する (Step 2 は skip)。
- `mode` が `"local"` でなければ整合性エラーとして停止する。
- それ以外 (success 時) は `base_branch` / `diff_mode` / `body` / `comments` を Step 2 に渡し、**Step 2 → Step 3 を順に必ず実行する** (Task ツール result 受け取り時点では本 skill の処理は完了していない)。

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
- インライン指摘: <count> 件

## 総括

<compose-review の body 全文。Markdown 可。>

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

- 既存資産 (`compose-review`) は **必ず Task ツール (sub-agent) 経由で利用** する。本 skill 内でレビュー本文 (`/pr-review-style-reference` 読み込み / プロジェクト指示ファイル / 差分取得 / 本文生成) を再実装しない。
- GitHub への投稿は行わない。`post-pr-review` / `resolve-pr-threads` skill は呼ばない。`gh pr comment` / `gh pr review` / `gh api .../reviews` も使わない。
- `git fetch` / `git pull` / `git checkout` / `git reset` 等、ワーキングツリーやローカル ref を書き換える操作はしない。読み取り専用 (`git rev-parse` / `git remote get-url`) のみ。
- 差分が空の場合も markdown 出力 + 報告は行う (skip しない)。判定は `compose-review` 側の `diff_mode` に従う。
