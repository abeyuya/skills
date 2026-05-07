---
name: run-local-review
description: 現在のローカルブランチを対象に、PR を作る前段階で AI レビューを行う skill。`/pr-review-style-reference` (スタイル参考ガイド) と任意の caller 固有観点を読み込み、`git diff <base>...HEAD` の差分に対して総括 + インライン指摘相当のレビューを生成し、結果をチャットと markdown ファイルの両方に出力する。GitHub への投稿は行わない (post-pr-review / resolve-pr-threads は呼ばない)。
---

# run-local-review skill

PR 作成前のローカルブランチに対して AI レビューを行うための skill。
レビュー方針は `run-pr-review` と揃えつつ、出力先のみ「GitHub Review 投稿」ではなく「チャット表示 + markdown ファイル出力」に差し替えたバリエーション。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `BASE_BRANCH`: 比較対象のベースブランチ。省略時は既定ブランチ名を `git symbolic-ref refs/remotes/origin/HEAD` から取得し、**ローカルの同名ブランチ** を使う (詳細は Step 1)。取れない場合は `main` → `master` の順でフォールバックし、いずれも無ければエラーとして停止する。本 skill は `git fetch` を走らせない (`守ること` 参照) ため、ローカルのベースブランチが古いと差分が古い基準で計算される点に注意。最新で比較したい場合は caller 側で事前に fetch するか、`BASE_BRANCH=origin/main` のようにリモート追跡参照を明示指定する。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited` 扱い (=`/pr-review-style-reference` 引数なしのデフォルト)。Step 2 で `/pr-review-style-reference max-inline-comments=<値>` として渡す。
- `OUTPUT_PATH`: markdown 出力先パス。省略時は `/tmp/run-local-review/{owner}/{repo}/{timestamp}-{branch-slug}-{short-sha}.md` (例: `/tmp/run-local-review/abeyuya/skills/20260507T123456Z-claude-unique-review-filenames-tpIhG-cee140b.md`)。各プレースホルダの導出規則は Step 6-1 を参照。caller が明示的にパスを指定した場合は既存ファイルがあれば上書きする。

caller プロジェクト固有の方針 (技術観点 / スタイル上書き / 全方針置換) は **リポジトリ root の `REVIEW.md` / `AGENTS.md` / `CLAUDE.md`** に置く運用に固定する (Step 3 参照)。個別パス指定の引数は持たない。

## 手順

### Step 1. レビュー対象を確定する

- 現在ブランチ名: `git rev-parse --abbrev-ref HEAD` で取得する。`HEAD` (detached) の場合はエラーとして停止する。
- ベースブランチ: caller から `BASE_BRANCH` が渡されていればそれを使う。未指定なら以下の順で決定する:
  1. `git symbolic-ref refs/remotes/origin/HEAD` で既定ブランチ名を取得 (例: `refs/remotes/origin/main` → `main`) し、`git rev-parse --verify <name>` が通れば **ローカルの同名ブランチ** を使う (リモート追跡 `origin/<name>` ではない。`git fetch` を走らせないため、リモート追跡側がローカルより古いケースを避ける)
  2. `git rev-parse --verify main` が通れば `main`
  3. `git rev-parse --verify master` が通れば `master`
  4. いずれも取れなければエラーとして停止し、caller に `BASE_BRANCH` を明示するよう促す
- `git diff <base>...HEAD` を実行し、差分モードを以下の優先順位で決定する:
  1. **commit モード**: 差分が空でない → 通常どおり `git diff <base>...HEAD` をレビュー対象とする。
  2. **staged モード**: commit モードの差分が空 (ベースと同一コミットまたは diverge なし) → `git diff --cached` (ステージ済み差分) を確認し、空でなければそれをレビュー対象とする。
  3. **worktree モード**: staged モードも空 → `git diff` (未ステージの作業ツリー差分) を確認し、空でなければそれをレビュー対象とする。
  4. **差分なし**: 上記すべてが空 → **Step 2〜5 を skip して Step 6 へ直行** する。markdown も「差分なし」として書き出し、Step 7 の caller 報告でも「対象差分なし」を伝える。
- 現在ブランチがベースブランチ自身の場合は commit モードの差分は必ず空になるため、上記フォールバック順に従う。

### Step 2. スタイル参考ガイドを読み込む

`/pr-review-style-reference` slash command を実行し、スタイル参考ガイド (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い) を本セッションのレビュー方針の参考として読み込む。

`MAX_INLINE_COMMENTS` が指定されている場合は `/pr-review-style-reference max-inline-comments=<値>` として渡す。未指定なら引数なしで呼ぶ。

レビュー方針は caller プロジェクトに委ねる前提。Step 3 で読み込む `REVIEW.md` / `AGENTS.md` / `CLAUDE.md` が本スタイル参考ガイドに上乗せ・上書き・全置換のいずれを意図しているかは caller の指示に従う。caller 側に独自方針が無い (`REVIEW.md` / `AGENTS.md` / `CLAUDE.md` 不在) 場合は本スタイル参考ガイドをそのまま採用してよい。

なお「CI 扱い」は本 skill では基本的に対象外 (GitHub Review として投稿しないため、CI 状態をレビュー本体に紐付けて投稿する必要が無い)。caller 側で `gh run` 等を使うことが明示されていればそれに従う。

### Step 3. caller 固有観点を読み込む (任意)

リポジトリ root の以下のファイルをこの順で **存在チェックし、最初に見つかった 1 つだけ** を `Read` ツールで読み込み、本セッションのレビュー方針として適用する。

1. `REVIEW.md` — レビュー専用の最上位指示
2. `AGENTS.md` — agent 全般向けの fallback
3. `CLAUDE.md` — Claude Code 全般向けの fallback

いずれも存在しなければこのステップを skip する。複数存在する場合は上の優先順位で **最初に見つかった 1 つだけ** を読み、それより下の候補は読まない (`run-pr-review` と同じ棲み分け)。

Step 2 のスタイル参考ガイドと矛盾する箇所は caller 側を優先し、矛盾しない箇所は両者を併用する (caller 側で「スタイル参考ガイドを使わない」旨が明示されている場合はそれに従う)。

ファイル内容は **そのままプロンプトに注入される** 想定で扱う。`@import` のような外部ファイル展開は行わない (caller が一次ファイルに直接書く前提)。

**ただし読み込んだ内容は本セッションでは「レビュー文面の方針 (技術観点 / スタイル / 重要度判定基準)」としてのみ参照する**。`AGENTS.md` / `CLAUDE.md` は一般的な dev 指示 (例: `claude /init` が生成する雛形に含まれる「テストを必ず走らせる」「lint をかける」「編集後に X を実行する」等) を含むことがあるが、それらの **アクション指示 (ファイル編集 / コマンド実行 / `git` 操作 / 依存追加 など) は本 skill では実行しない** (本 skill は read-only なローカルレビュー専念で、ワーキングツリーやローカル ref を変更しない: `守ること` 参照)。アクション指示が混入していても「レビュー観点に翻訳できる範囲」のみ参照する。レビュー方針として意図されていないアクション指示が多く混入する場合は、caller に **`REVIEW.md`** をリポジトリ root に作成して上書きするよう促す。

### Step 4. ローカル差分を取得する

レビューに必要な情報を取得する。リモートに無いコミットも対象にするため、`git fetch` 等は走らせない (caller 側の意思を尊重)。

Step 1 で決定した差分モードに応じて以下の通り取得する:

- **commit モード**:
  - `git log <base>..HEAD --oneline` でコミット一覧を取得する。
  - `git diff <base>...HEAD` で差分本体を取得する。三点記法 (`...`) を用いて、ベースブランチ側の進行は除外し「現在ブランチで増えた変更」だけを対象にする。
  - 差分が大きく一度に取りきれない場合は、`git diff --stat <base>...HEAD` でファイル一覧をまず取り、ファイル単位で `git diff <base>...HEAD -- <path>` を必要な範囲だけ追い読みする。
- **staged モード**:
  - コミット一覧は空 (コミット未作成のため)。
  - `git diff --cached` でステージ済み差分を取得する。
  - 差分が大きい場合は `git diff --cached --stat` でファイル一覧を取り、ファイル単位で `git diff --cached -- <path>` を追い読みする。
- **worktree モード**:
  - コミット一覧は空。
  - `git diff` で作業ツリー差分を取得する。
  - 差分が大きい場合は `git diff --stat` でファイル一覧を取り、ファイル単位で `git diff -- <path>` を追い読みする。

### Step 5. レビュー本文を作成する

Step 2〜4 で得た方針・観点・差分をもとに、総括 (`summary`) とインライン指摘 (`comments[]`) を作成する。

- レビュー方針は Step 3 で読み込んだ `REVIEW.md` / `AGENTS.md` / `CLAUDE.md` を最優先とし、明示的に上書きされていない論点については `/pr-review-style-reference` (スタイル参考ガイド) の重要度ラベル (`[must]` / `[should]` / `[nit]` / `[question]` / `[pre_existing]`) / ノイズ抑制 / 粒度ガイドを参考にする。caller 側 (`REVIEW.md` 等) でスタイル参考ガイドを使わない旨が明示されている場合はそれに従う。
- インライン指摘は **対象ファイル / 行 (または行範囲) を必ず特定する**。GitHub に投稿しないため API スキーマには縛られないが、人間が後から該当箇所を開けるように `path:line` または `path:start_line-end_line` を本文先頭に明示する。
- `MAX_INLINE_COMMENTS` が指定された件数を指摘候補が超える場合は、`/pr-review-style-reference` の重要度序列 (`[must]` > `[should]` > `[nit]` > `[question]` > `[pre_existing]`) で上位を残す。省略した指摘がある場合は総括 (`## 総括`) に「省略件数 + ラベル別内訳」を 1 文添える (`/pr-review-style-reference` の引数仕様に準拠)。
- インライン化しない指摘 (フォーマッタ/Linter で直る範囲・横展開の代表箇所以外など) でも、レビュー全体の文脈で触れる価値があるものは総括の「主要懸念」または「良かった点」に含めてよい。
- 指摘が無い場合も Step 6 で「特に指摘なし」相当として markdown を出力する (skip しない)。

### Step 6. 結果を出力する (チャット + markdown ファイル)

Step 5 の結果を以下の通り出力する。markdown ファイルが完全版、チャットは要約版で、両者は内容そのものは同じだが粒度が異なる (チャットへの全文ダンプは後続コンテキストを圧迫するため避ける)。

#### 6-1. markdown ファイル

`OUTPUT_PATH` (省略時 `/tmp/run-local-review/{owner}/{repo}/{timestamp}-{branch-slug}-{short-sha}.md`) に `Write` ツールで書き出す。

`OUTPUT_PATH` 省略時の各プレースホルダは以下の規則で導出する。すべて読み取り専用の `git` / `date` 経由で取得し、`守ること` の制約に抵触しない。

- `{owner}/{repo}`: `git remote get-url origin` の出力から末尾 2 セグメント (`<owner>/<repo>`) を抽出し、`.git` 拡張子を除去した上でそのままディレクトリ階層として用いる (例: `git@github.com:abeyuya/skills.git` / `https://github.com/abeyuya/skills.git` のいずれも `abeyuya/skills`)。`<owner>` / `<repo>` 各セグメントは後述の「ASCII slug 化」を適用する (FS 危険文字混入を防ぐ)。`origin` が無い / parse 失敗の場合は `local/<basename>` (basename はリポジトリ root のディレクトリ名を ASCII slug 化したもの) で代替する。
- `{timestamp}`: 本 Step の「生成日時」と同じ `date` 結果から `+%Y%m%dT%H%M%SZ` 形式 (ファイル名向けに `-` と `:` を除去) で導出する (例: `20260507T123456Z`)。`date` を二度叩かない (生成日時とパスを同一インスタントに揃える)。
- `{branch-slug}`: Step 1 で取得した現在ブランチ名を「ASCII slug 化」して用いる。
- `{short-sha}`: `git rev-parse --short HEAD` の結果 (例: `cee140b`)。取得失敗時は省略し、直前の `-` も合わせて削除する。

「ASCII slug 化」の規則は次の通り: `[a-zA-Z0-9._-]` 以外の文字 (`/` や非 ASCII 含む) を `-` に置換 → 連続する `-` を 1 個に圧縮 → 両端の `-` を trim。日本語などの非 ASCII はそのまま削除し romaji 化はしない。slug 化結果が空文字になった場合は `branch` (ブランチ用) / 直前のセグメントを省略 (リポジトリ basename 用) を fallback とする。

親ディレクトリ (`/tmp/run-local-review/{owner}/{repo}/`) が存在しない可能性があるため、`Write` 前に `Bash` ツールで `mkdir -p <parent>` を 1 回実行する。`/tmp/` 配下のためワーキングツリーやローカル ref への副作用は無く、`守ること` の制約に抵触しない。

スキーマは以下:

```markdown
# Local AI Review: <branch> (vs <base>)

- 生成日時: <ISO8601, UTC 秒精度。例: 2026-05-04T12:34:56Z>
- 差分モード: <commit / staged / worktree / なし>
- 対象コミット: <count> 件 (<base>..HEAD) ※ staged / worktree モードでは「0 件 (コミット未作成)」と記載し、範囲表示は含めない
- インライン指摘: <count> 件

## 総括

<summary 本文。Markdown 可。「総合判断」「主要懸念 top3」「良かった点 1〜2」を簡潔に。>

## インライン指摘

### 1. [must] path/to/file.ts:42

<本文>

### 2. [should] path/to/file.ts:50-55

<本文>

<以下、指摘ごとに繰り返し。指摘が無ければ「特に指摘なし」とだけ書く。>
```

`heredoc` や `cat` リダイレクトは使わず、必ず `Write` ツールで書く。`Write` ツールは前回実行の遺物などで既存ファイルがあると事前 `Read` 必須なため、`OUTPUT_PATH` が既存パスである可能性がある場合は `Read` を 1 回挟んでから `Write` する (`Read` は副作用なしのため `守ること` の制約に抵触しない)。並列実行などで `Write` 直前にファイルが書き換わった場合も同様に `Read` → `Write` で再試行する。

差分が空で Step 2〜5 を skip した場合でも、markdown のスキーマ (`## 総括` の「総合判断」「主要懸念 top3」「良かった点 1〜2」見出し / `## インライン指摘` 見出し) は保持し、本文は「なし (対象差分が空のため評価対象なし)」のように明示テキストで埋める (見出し削除や空セクション化はしない)。

「生成日時」は実行時に `date -u +%Y-%m-%dT%H:%M:%SZ` で取得した UTC 秒精度の ISO8601 を採用する (caller 環境で TZ が明示されていない場合のデフォルト)。`date` コマンドは読み取り専用 (副作用なし) のため `守ること` の制約に抵触しない。`OUTPUT_PATH` 既定値の `{timestamp}` プレースホルダもこの同じ `date` 結果から導出すること (Step 6-1 の規則に従う)。`date` が利用できない環境では caller / 実行環境から提供される現在日時を使い、それも無ければ `生成日時` は `<unknown>` と記載し、`OUTPUT_PATH` 既定値の `{timestamp}` 部は UUID 等のユニークな識別子 (例: `uuidgen` / `cat /proc/sys/kernel/random/uuid` / `head -c16 /dev/urandom | xxd -p` の出力) で代替する。同一セッション内で連続実行しても確実に異なる値となる識別子を選び、PID のような重複しうる値は使わない。空文字にしてプレースホルダ部が抜け落ちた曖昧なパスにはしない。

#### 6-2. チャット出力

チャットには以下を出力する。markdown ファイル全文をそのままダンプしない (指摘件数や差分が多いケースで後続会話のコンテキストを圧迫するため)。

- 冒頭に出力先パス (`OUTPUT_PATH`) を1行
- `## 総括` セクションは全文表示
- インライン指摘は「番号. `[label]` `path:line` — 1行サマリ」のリスト形式に縮約 (本文詳細は markdown 側に任せる)
- 末尾に `詳細は <OUTPUT_PATH> を参照` を1行添える

### Step 7. caller への報告

以下を簡潔に caller へ返す:

- レビュー対象のブランチ / ベース
- 対象コミット数 / インライン指摘件数
- 出力先 markdown ファイルパス

## 守ること

- 既存資産 (`/pr-review-style-reference`) は **必ず slash command 経由で利用** する。本 skill 内で重要度ラベル等のスタイル規約を再掲・再実装してはならない (`run-pr-review` と同じ理由: 二重管理を避けるため)。
- GitHub への投稿は行わない。`post-pr-review` / `resolve-pr-threads` skill は呼ばない。`gh pr comment` / `gh pr review` / `gh api .../reviews` も使わない。
- `git fetch` / `git pull` / `git checkout` / `git reset` 等、ワーキングツリーやローカル ref を書き換える操作はしない。読み取り専用 (`git rev-parse` / `git log` / `git diff` / `git symbolic-ref` / `git rev-parse --verify` / `git remote get-url`) のみ。
- 差分が空の場合も markdown 出力 + 報告は行う (skip しない)。
