---
name: run-local-review
description: 現在のローカルブランチを対象に、PR を作る前段階で AI レビューを行う skill。`/pr-review-style-reference` (スタイル参考ガイド) と任意の caller 固有観点を読み込み、`git diff <base>...HEAD` の差分に対して総括 + インライン指摘相当のレビューを生成し、結果をチャットと markdown ファイルの両方に出力する。GitHub への投稿は行わない (post-pr-review / resolve-pr-threads は呼ばない)。
---

# run-local-review skill

PR 作成前のローカルブランチに対して AI レビューを行うための skill。
レビュー方針は `run-pr-review` と揃えつつ、出力先のみ「GitHub Review 投稿」ではなく「チャット表示 + markdown ファイル出力」に差し替えたバリエーション。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `BASE_BRANCH`: 比較対象のベースブランチ。省略時の解決順は Step 1 を参照。本 skill は `git fetch` を走らせないため、ローカルのベースが古いと古い基準で diff が出る。最新で比較したい場合は caller 側で fetch するか、`BASE_BRANCH=origin/main` のようにリモート追跡参照を明示する。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited` 扱い (=`/pr-review-style-reference` 引数なしのデフォルト)。Step 2 で `/pr-review-style-reference max-inline-comments=<値>` として渡す。
- `OUTPUT_PATH`: markdown 出力先パス。省略時は `/tmp/run-local-review/{repo}/{timestamp}-{branch}.md` (例: `/tmp/run-local-review/skills/20260507T123456Z-claude-unique-review-filenames-tpIhG.md`)。caller が明示パスを指定した場合は既存ファイルがあれば上書きする。プレースホルダの組み立て規則:
  - `{repo}`: `git remote get-url origin` の URL 末尾セグメント (`.git` を除く、取得失敗時は `local`)
  - `{timestamp}`: `date -u +%Y%m%dT%H%M%SZ` の出力
  - `{branch}`: 現在ブランチ名の英数記号以外 (`/` 等) を `-` に置換
- `CONFIDENCE_THRESHOLD`: 0-100 の整数または `all`。Step 5.5 で Verifier が付与した confidence のうち、これ未満の指摘を「インライン指摘」本体から外し「## 参考: 検証で除外された候補」セクションに分離する。省略時は `80`。`all` を指定すると閾値フィルタを行わず全件を本体に残す (デバッグ・キャリブレーション用途)。
- `SKIP_VERIFIER`: `true` で Step 5.5 (Verifier) をバイパスし、一次レビューの指摘候補をそのまま markdown へ出力する。省略時は `false`。
- `VERIFIER_TIMEOUT_SEC`: Step 5.5 で呼び出す `verify-pr-review-findings` skill 全体のタイムアウト秒数。省略時は Verifier 側の `DEFAULT_VERIFIER_TIMEOUT_SEC` (= 300。`verify-pr-review-findings/SKILL.md` の「数値リテラル一覧」参照)。

Verifier 関連の **状態語彙 (`verifier_status`)** と **数値リテラル (`RELATED_THREAD_RANGE` 等)** は `verify-pr-review-findings/SKILL.md` の「Verifier 状態 enum」「数値リテラル一覧」が canonical な単一定義点。本 skill では同リテラルをそのまま参照し、別名・別綴り・別数値で再定義しない。

caller プロジェクト固有の方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** (Step 3 で定義) に置く運用に固定する。個別パス指定の引数は持たない。

## 手順

### Step 1. レビュー対象を確定する

- 現在ブランチ名: `git rev-parse --abbrev-ref HEAD` で取得する。`HEAD` (detached) の場合はエラーとして停止する。
- ベースブランチ: caller から `BASE_BRANCH` が渡されていればそれを使う。未指定なら以下の順で決定する:
  1. `git symbolic-ref refs/remotes/origin/HEAD` で既定ブランチ名を取得 (例: `refs/remotes/origin/main` → `main`) し、`git rev-parse --verify <name>` が通れば **ローカルの同名ブランチ** を使う (リモート追跡 `origin/<name>` ではない)
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

レビュー方針は caller プロジェクトに委ねる前提。Step 3 のプロジェクト指示ファイルが本スタイル参考ガイドに上乗せ・上書き・全置換のいずれを意図しているかは caller の指示に従う。プロジェクト指示ファイルが無ければ本スタイル参考ガイドをそのまま採用する。

なお「CI 扱い」は本 skill では対象外 (GitHub に投稿しないため)。caller 側で `gh run` 等を使うことが明示されていればそれに従う。

### Step 3. プロジェクト指示ファイルを読み込む (任意)

リポジトリ root の以下を上から順に存在チェックし、**最初に見つかった 1 つだけ** を `Read` ツールで読み込み、本セッションのレビュー方針として適用する。以後この skill では総称して **プロジェクト指示ファイル** と呼ぶ。

1. `REVIEW.md` — レビュー専用の最上位指示
2. `AGENTS.md` — agent 全般向けの fallback
3. `.claude/CLAUDE.md` — Claude Code 全般向けの fallback (`.claude/` 配下に置く流儀)
4. `CLAUDE.md` — Claude Code 全般向けの fallback (リポジトリ root に置く流儀)

いずれも存在しなければ skip する。複数存在しても下位は読まない / 連結しない。

Step 2 のスタイル参考ガイドと矛盾する箇所は caller 側を優先し、矛盾しない箇所は両者を併用する。caller 側で「スタイル参考ガイドを使わない」旨が明示されていればそれに従う。

ファイル内容は **そのままプロンプトに注入される** 想定で扱う。`@import` のような外部ファイル展開は行わない。

**読み込んだ内容は本セッションでは「レビュー文面の方針 (技術観点 / スタイル / 重要度判定基準)」としてのみ参照する**。`AGENTS.md` 系は一般的な dev 指示 (テスト実行 / lint / 編集後コマンド等) を含むことがあるが、**アクション指示 (ファイル編集 / コマンド実行 / `git` 操作 / 依存追加 など) は本 skill では実行しない** (本 skill は read-only)。アクション指示は「レビュー観点に翻訳できる範囲」のみ採用する。アクション指示が多すぎる場合は、caller に `REVIEW.md` をリポジトリ root に作成して上書きするよう促す。

### Step 4. ローカル差分を取得する

リモートに無いコミットも対象にするため、`git fetch` 等は走らせない (caller 側の意思を尊重)。Step 1 で決定した差分モードに応じて以下の通り取得する:

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

### Step 5. レビュー本文 (一次案) を作成する

Step 2〜4 で得た方針・観点・差分をもとに、総括 (`summary`) と **候補指摘 `candidate_findings[]`** を作成する。本 Step では Verifier 検証前の「一次案」を組み立て、Step 5.5 で再検証してから Step 6 で markdown として出力する。

`candidate_findings[]` の各要素は以下の構造で組み立てる:

```json
{
  "id": "finding-001",
  "path": "src/auth.ts",
  "line": 42,
  "start_line": null,
  "severity": "must",
  "body": "[must] Token refresh races with logout..."
}
```

- `id`: 一次案中で一意な `finding-NNN` (連番)。Step 5.5 の Verifier が結果を `id` で返すため必須。
- `severity`: `must` / `should` / `nit` / `question` / `pre_existing` の小文字リテラル。
- `body`: 従来通り本文先頭に `[must]` 等のラベルを付けた本文。Step 5.5 後に `[must] (conf:NN) ...` 形式へ書き換える。
- `start_line` は単一行指摘なら `null`、行範囲指摘なら開始行を入れる。

その他のルール:

- レビュー方針は Step 3 のプロジェクト指示ファイルを最優先とし、明示的に上書きされていない論点については `/pr-review-style-reference` (スタイル参考ガイド) の重要度ラベル / ノイズ抑制 / 粒度ガイドを参考にする。caller 側でスタイル参考ガイドを使わない旨が明示されていればそれに従う。
- インライン指摘は **対象ファイル / 行 (または行範囲) を必ず特定する**。GitHub に投稿しないため API スキーマには縛られないが、人間が後から該当箇所を開けるように `path:line` または `path:start_line-end_line` を本文先頭に明示する。
- `MAX_INLINE_COMMENTS` 超過時の取捨選択と、省略件数を総括 (`## 総括`) に 1 文添える運用は `/pr-review-style-reference` の引数仕様に従う。
- インライン化しない指摘 (フォーマッタ/Linter で直る範囲・横展開の代表箇所以外など) でも、レビュー全体の文脈で触れる価値があるものは総括の「主要懸念」または「良かった点」に含めてよい (`candidate_findings[]` には入れない)。
- 指摘が無い場合 (`candidate_findings[]` が空) も Step 5.5 を skip して Step 6 で「特に指摘なし」相当として markdown を出力する (skip しない)。

### Step 5.5. Verifier サブエージェントで各指摘を再検証する

Step 5 で生成した `candidate_findings[]` を `verify-pr-review-findings` skill に渡し、独立コンテキストのサブエージェントで再検証する。返却された `verdicts[]` をもとにフィルタ・ソート・本文書き換えを行ってから Step 6 へ進む。

`SKIP_VERIFIER=true` または `candidate_findings[]` が空のときは本 Step を skip する (skip ステータスは Step 6-1 の markdown ヘッダに残す)。

#### 5.5-1. skip 条件のチェック

- `SKIP_VERIFIER=true`: `verifier_status="skipped:user_flag"` を控えて 5.5 全体を skip。「インライン指摘」は `candidate_findings[]` の各要素を本文書き換えなしでそのまま使う。
- `candidate_findings[]` が空: `verifier_status="skipped:zero_candidates"` を控えて 5.5 全体を skip。

両方とも 5.5-2 以降は実行せず Step 6 へ進む。

#### 5.5-2. Verifier への入力を組み立てる

`candidate_findings[]` の各 candidate について、以下を Verifier に渡せる形に整形する。範囲の数値は `verify-pr-review-findings/SKILL.md` の「数値リテラル一覧」を参照し、本 skill 側では再定義しない。

- **DIFF**: Step 4 で取得した差分 (commit / staged / worktree モードに応じた `git diff` 出力) をそのまま使う。
- **FILE_EXCERPTS**: 各 candidate の周辺 `FILE_EXCERPT_RANGE` (= ±50 行) を以下の通り差分モード別に取得し、必要範囲のみ抜粋。同 path で重複する範囲はマージして 1 件にまとめる。
  - **commit モード**: `git show HEAD:<path>` で HEAD コミットの内容を取得 (read-only)。
  - **staged モード**: `git show :<path>` (= `:0:<path>`、index のステージ 0) で staged 内容を取得。
  - **worktree モード**: `Read` ツールで作業ツリーから直接読み取る (未ステージ差分なので index には載っていない)。
  - いずれも取得失敗した candidate はその entry を `FILE_EXCERPTS` に含めないだけで Verifier 呼び出しは続行する (Verifier 側 Step 0 で欠損許容)。
- **RELATED_THREADS**: ローカル実行のため常に空配列 `[]`。
- **CANDIDATES**: `candidate_findings[]` の `id` / `path` / `line` / `severity` / `body` をそのまま渡す。

#### 5.5-3. `verify-pr-review-findings` skill を呼ぶ

Skill ツールで `verify-pr-review-findings` を呼び出し、上記入力に加えて `MODE="local"` / `VERIFIER_TIMEOUT_SEC` (本 skill の入力値、省略時は Verifier 側の `DEFAULT_VERIFIER_TIMEOUT_SEC`) を渡す。`REPO_CONTEXT` は `OWNER` / `REPO` / `PR_NUMBER` がローカル実行では揃わないため省略 (空オブジェクト) で可。

返却値 (`{"verdicts":[...], "stats":{...}}`) を受け取る。`verifier_status` は **Verifier 側返却の `stats.status` をそのまま採用** する (`ok` / `skipped:zero_candidates` / `skipped:timeout` のいずれか)。完了分の `verdicts[]` は `stats.timeout=true` でも通常通り採用する。

skill 呼び出し自体が例外 / 応答なしで失敗した場合は、`verifier_status="skipped:error"` を控え、`verdicts[]` を空とみなして 5.5-4 以降は **一次レビューをそのまま採用** する (本文書き換えなし)。`skipped:timeout` と `skipped:error` の区別はそのまま Step 6-1 の markdown ヘッダと Step 7 の caller 報告に残す。

#### 5.5-4. フィルタ・ソート・本文書き換え

`verifier_status` が `ok` または `skipped:timeout` (完了分のみ採用) の場合、`candidate_findings[]` と `verdicts[]` を `id` で突き合わせて以下を実施する。`skipped:user_flag` / `skipped:zero_candidates` / `skipped:error` のときは本サブステップを実行しない (5.5-1 / 5.5-3 の skip パスで本体・参考を組み立て済み)。

1. **本体・参考の振り分け**:
   - `verdict == "likely_false_positive"` かつ `confidence >= 80` → 「## 参考: 検証で除外された候補」セクションへ (除外理由: `FP (conf XX)`)
   - `confidence < CONFIDENCE_THRESHOLD` (デフォルト 80) → 「## 参考」セクションへ (除外理由: `閾値未満 (conf XX)`)
   - `CONFIDENCE_THRESHOLD=all` のときは閾値フィルタを skip し、すべて本体に残す
   - その他は「## インライン指摘」本体へ採用

2. **本文書き換え** (本体に残った指摘): `body` 先頭を `[<severity>] (conf:<NN>) <元本文の severity ラベル除去後>` に書き換える。`severity` は元の `candidate.severity` を使う (Verifier の `severity_suggestion` は本リポジトリ運用では破棄: `verify-pr-review-findings/SKILL.md` の出力スキーマ注記参照)。

3. **ソート**: 本体・参考それぞれを severity 順 (must → should → nit → question → pre_existing) 一次キー、同 severity 内は confidence 降順二次キーで並べる。

4. **集計**: `total` / `confirmed` / `false_positive` / `uncertain` / `mean_conf` / `min_conf` / 閾値で除外した件数を控える (Step 6-1 の「## 検証統計」セクションに反映)。

### Step 6. 結果を出力する (チャット + markdown ファイル)

Step 5 の結果を以下の通り出力する。markdown ファイルが完全版、チャットは要約版で、両者は内容そのものは同じだが粒度が異なる (チャットへの全文ダンプは後続コンテキストを圧迫するため避ける)。

#### 6-1. markdown ファイル

`OUTPUT_PATH` (省略時 `/tmp/run-local-review/{repo}/{timestamp}-{branch}.md`、組み立て規則は「入力」セクションの `OUTPUT_PATH` 説明を参照) に `Write` ツールで書き出す。

`Write` ツールは中間ディレクトリの自動作成を保証していないため、書き出し前に `Bash` ツールで `mkdir -p "$(dirname "<OUTPUT_PATH>")"` を実行して親ディレクトリを作成する (`<OUTPUT_PATH>` をダブルクォートで囲むことでスペース入りパスも安全に動く)。caller が明示パスを指定したケースも同様。

スキーマは以下:

```markdown
# Local AI Review: <branch> (vs <base>)

- 生成日時: <ISO8601, UTC 秒精度。例: 2026-05-04T12:34:56Z>
- 差分モード: <commit / staged / worktree / なし>
- 対象コミット: <count> 件 (<base>..HEAD) ※ staged / worktree モードでは「0 件 (コミット未作成)」と記載し、範囲表示は含めない
- インライン指摘: <count> 件 (Verifier 通過 / 除外 <count> 件)
- Verifier ステータス: <`verify-pr-review-findings/SKILL.md` の「Verifier 状態 enum」5 値: ok / skipped:zero_candidates / skipped:timeout / skipped:error / skipped:user_flag>
- Confidence 閾値: <80 / all / 任意の整数>

## 検証統計

- 投入: <count> 件
- 確定 (confirmed): <count> 件
- FP (likely_false_positive): <count> 件
- 不明 (uncertain): <count> 件
- 平均 confidence: <NN>
- 最低 confidence: <NN>
- 閾値で除外: <count> 件

## 総括

<summary 本文。Markdown 可。「総合判断」「主要懸念 top3」「良かった点 1〜2」を簡潔に。>

## インライン指摘

### 1. [must] (conf:92) path/to/file.ts:42

<本文 (severity ラベルと (conf:NN) プレフィックスを除いた本体)>

### 2. [should] (conf:84) path/to/file.ts:50-55

<本文>

<以下、Step 5.5-4 で本体に残した指摘ごとに繰り返し。指摘が無ければ「特に指摘なし」とだけ書く。>

## 参考: 検証で除外された候補

(閾値未満または FP 判定で本体から外したもの。ローカルなので情報量を最大化する。)

- [should] (conf:62) src/util.ts:30 — 1 行サマリ (理由: 閾値未満)
- [nit] (conf:55) README.md:7 — 1 行サマリ (理由: FP (conf 88))

<除外がなければ「除外なし」とだけ書く。>
```

- 「Verifier ステータス」「Confidence 閾値」のヘッダ行は常に出す (差分なし / skip ケースでも)。
- 「## 検証統計」セクションは **Verifier が正常完了 (`ok`) のときのみ** 数値を入れる。`verifier_status` が `ok` 以外 (`skipped:*` のいずれか) のときは見出しのみ残し、本文を以下のいずれかの 1 行に置き換える (見出し削除や空セクション化はしない):
  - `Verifier をスキップ (SKIP_VERIFIER=true)` (`skipped:user_flag`)
  - `Verifier 対象なし (指摘 0 件)` (`skipped:zero_candidates`)
  - `Verifier 全体タイムアウト (一次レビューを採用)` (`skipped:timeout`)
  - `Verifier 呼び出し失敗 (一次レビューを採用)` (`skipped:error`)
- 「## インライン指摘」見出し下の指摘本文先頭は `[<severity>] (conf:<NN>) <path>:<line>` の形 (`verifier_status == "ok"` の通常ケース)。`verifier_status != "ok"` のすべてのケースでは `(conf:NN)` を付けず `[<severity>] <path>:<line>` のまま。
- 「## 参考: 検証で除外された候補」セクションは `verifier_status == "ok"` のときのみ意味を持つ。`skipped:user_flag` / `skipped:zero_candidates` のときは見出しを残して本文を `該当なし` の 1 行に置き換える。`skipped:timeout` のときは `該当なし (Verifier 全体タイムアウト)`、`skipped:error` のときは `該当なし (Verifier 呼び出し失敗)` の 1 行で良い。
- `CONFIDENCE_THRESHOLD=all` のときは閾値フィルタを実行しないため、本セクション本文は `閾値フィルタなし (CONFIDENCE_THRESHOLD=all)` の 1 行で良い (FP 除外分のみ列挙、なければ `除外なし`)。

`heredoc` や `cat` リダイレクトは使わず、必ず `Write` ツールで書く。`Write` ツールは既存ファイルがあると事前 `Read` 必須なため、`OUTPUT_PATH` が既存パスの可能性があれば `Read` を 1 回挟んでから `Write` する。並列実行などで `Write` 直前にファイルが書き換わった場合も同様に `Read` → `Write` で再試行する。

差分が空で Step 2〜5 を skip した場合でも、markdown のスキーマ (`## 総括` の「総合判断」「主要懸念 top3」「良かった点 1〜2」見出し / `## インライン指摘` 見出し) は保持し、本文は「なし (対象差分が空のため評価対象なし)」のように明示テキストで埋める (見出し削除や空セクション化はしない)。

「生成日時」は実行時に `date -u +%Y-%m-%dT%H:%M:%SZ` で取得した UTC 秒精度の ISO8601 を採用する。`date` が利用できない環境では caller / 実行環境から提供される現在日時を使い、それも無ければ `<unknown>` と記載する (skip ではなく明示)。

#### 6-2. チャット出力

チャットには以下を出力する。markdown ファイル全文をそのままダンプしない (指摘件数や差分が多いケースで後続会話のコンテキストを圧迫するため)。

- 冒頭に出力先パス (`OUTPUT_PATH`) を1行
- Verifier ステータス 1 行 (例: `Verifier: ok / 投入 8 → 採用 5 (FP 1, 閾値未満 2, 平均 conf 78)`、`verifier_status != "ok"` のときは `Verifier: skipped:user_flag` のように 1 語のみ。リテラルは `verify-pr-review-findings/SKILL.md` の「Verifier 状態 enum」5 値)
- `## 総括` セクションは全文表示
- インライン指摘は「番号. `[label]` `(conf:NN)` `path:line` — 1行サマリ」のリスト形式に縮約 (本文詳細は markdown 側に任せる)。`(conf:NN)` は `verifier_status == "ok"` のときのみ付与し、それ以外は省略
- 末尾に `詳細は <OUTPUT_PATH> を参照` を1行添える

### Step 7. caller への報告

以下を簡潔に caller へ返す:

- レビュー対象のブランチ / ベース
- 対象コミット数 / インライン指摘件数 (Verifier 通過後の本体件数)
- Verifier ステータス (`verify-pr-review-findings/SKILL.md` の「Verifier 状態 enum」5 値: `ok` / `skipped:zero_candidates` / `skipped:timeout` / `skipped:error` / `skipped:user_flag`) と、`ok` の場合は除外件数 (FP 除外 / 閾値未満) と平均 conf
- 出力先 markdown ファイルパス

## 守ること

- 既存資産 (`/pr-review-style-reference` / `verify-pr-review-findings`) は **必ず slash command または Skill 経由で利用** する。本 skill 内で重要度ラベル等のスタイル規約や Verifier 検証ロジックを再掲・再実装してはならない (二重管理を避けるため)。
- GitHub への投稿は行わない。`post-pr-review` / `resolve-pr-threads` skill は呼ばない。`gh pr comment` / `gh pr review` / `gh api .../reviews` も使わない。
- `git fetch` / `git pull` / `git checkout` / `git reset` 等、ワーキングツリーやローカル ref を書き換える操作はしない。読み取り専用 (`git rev-parse` / `git log` / `git diff` / `git show` / `git symbolic-ref` / `git rev-parse --verify` / `git remote get-url`) のみ。`git show` は Step 5.5-2 の FILE_EXCERPTS 抽出 (commit / staged モード) に使う。worktree モードの FILE_EXCERPTS は `Read` ツールで取得する。
- 差分が空の場合も markdown 出力 + 報告は行う (skip しない)。
- Step 5.5 で Verifier が失敗 / タイムアウトした場合は一次レビューをそのまま採用する (best-effort)。Verifier の存在を前提に markdown 出力を skip してはならない。
