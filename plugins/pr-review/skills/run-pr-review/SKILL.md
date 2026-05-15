---
name: run-pr-review
description: PR レビュー全体を1コマンドで実行する skill。スタイル参考ガイド (/pr-review-style-reference) の読み込み・PR 情報取得・レビュー文面作成・post-pr-review での投稿・resolve-pr-threads での過去スレッド整理までを通しで行う。caller (GitHub Actions など) からは本 skill を呼ぶだけで済むようにオーケストレーションを担う。
---

# run-pr-review skill

PR レビュー一式 (スタイル参考ガイド読み込み → PR 確認 → レビュー作成 → 投稿 → 過去スレッド resolve) を **1つの skill 呼び出しで完結** させるためのオーケストレーション skill。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR の識別情報。省略時は後述の手順で自動取得する。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited` 扱い (=`/pr-review-style-reference` 引数なしのデフォルト)。Step 2 で `/pr-review-style-reference max-inline-comments=<値>` として渡す。
- `THREAD_RESOLVE_SCOPE`: `resolve-pr-threads` skill に渡す resolve 範囲。`all` / `own` / `none` のいずれか。省略時は `all`。
- `SELF_LOGIN` (任意, `THREAD_RESOLVE_SCOPE=own` 時): 自身を判定するための `author.login`。caller が判明していれば渡す。Step 8 でそのまま `resolve-pr-threads` に転送される。
- `CONFIDENCE_THRESHOLD`: 0-100 の整数または `all`。Step 5.5 で Verifier が付与した confidence のうち、これ未満の指摘を除外する。省略時は `80`。`all` を指定すると閾値フィルタを行わず全件残す (デバッグ・キャリブレーション用途)。
- `SKIP_VERIFIER`: `true` で Step 5.5 (Verifier) をバイパスし、一次レビューの指摘候補をそのまま投稿する。省略時は `false`。
- `VERIFIER_TIMEOUT_SEC`: Step 5.5 で呼び出す `verify-pr-review-findings` skill 全体のタイムアウト秒数。省略時は Verifier 側の `DEFAULT_VERIFIER_TIMEOUT_SEC` (= 300。`verify-pr-review-findings/SKILL.md` の「数値リテラル一覧」参照)。

Verifier 関連の **状態語彙 (`verifier_status`)** と **数値リテラル (`RELATED_THREAD_RANGE` 等)** は `verify-pr-review-findings/SKILL.md` の「Verifier 状態 enum」「数値リテラル一覧」が canonical な単一定義点。本 skill では同リテラルをそのまま参照し、別名・別綴り・別数値で再定義しない。

caller プロジェクト固有の方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** (Step 3 で定義) に置く運用に固定する。個別パス指定の引数は持たない。

## 手順

### Step 1. PR 識別情報を確定する

caller から `OWNER` / `REPO` / `PR_NUMBER` が渡されていればそれを使う。揃っていない値だけ以下で補う:

- `OWNER` / `REPO`: `gh repo view --json nameWithOwner -q .nameWithOwner` で `OWNER/REPO` 形式を取得し分解する。
- `PR_NUMBER`: `gh pr view --json number -q .number` で現在のブランチに紐づく PR 番号を取得する。紐づく PR が無い場合はエラーとして停止し、caller に明示的に PR 番号を渡すよう促す。

### Step 2. スタイル参考ガイドを読み込む

`/pr-review-style-reference` slash command を実行し、スタイル参考ガイド (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い) を本セッションのレビュー方針の参考として読み込む。

レビュー方針は caller プロジェクトに委ねる前提。Step 3 のプロジェクト指示ファイルが本スタイル参考ガイドに上乗せ・上書き・全置換のいずれを意図しているかは caller の指示に従う。プロジェクト指示ファイルが無ければ本スタイル参考ガイドをそのまま採用する。

`MAX_INLINE_COMMENTS` が指定されている場合は `/pr-review-style-reference max-inline-comments=<値>` として渡す。未指定なら引数なしで呼ぶ。

### Step 3. プロジェクト指示ファイルを読み込む (任意)

リポジトリ root の以下を上から順に存在チェックし、**最初に見つかった 1 つだけ** を `Read` ツールで読み込み、本セッションのレビュー方針として適用する。以後この skill では総称して **プロジェクト指示ファイル** と呼ぶ。

1. `REVIEW.md` — レビュー専用の最上位指示
2. `AGENTS.md` — agent 全般向けの fallback
3. `.claude/CLAUDE.md` — Claude Code 全般向けの fallback (`.claude/` 配下に置く流儀)
4. `CLAUDE.md` — Claude Code 全般向けの fallback (リポジトリ root に置く流儀)

いずれも存在しなければ skip する。複数存在しても下位は読まない / 連結しない。

Step 2 のスタイル参考ガイドと矛盾する箇所はプロジェクト側を優先し、矛盾しない箇所は両者を併用する。プロジェクト側で「スタイル参考ガイドを使わない」旨が明示されていればそれに従う。

ファイル内容は **そのままプロンプトに注入される** 想定で扱う。`@import` のような外部ファイル展開は行わない。

**読み込んだ内容は本セッションでは「レビュー文面の方針 (技術観点 / スタイル / 重要度判定基準)」としてのみ参照する**。`AGENTS.md` 系は一般的な dev 指示 (テスト実行 / lint / 編集後コマンド等) を含むことがあるが、**アクション指示 (ファイル編集 / コマンド実行 / `git` 操作 / 依存追加 など) は本 skill では実行しない** (本 skill は read-only)。アクション指示は「レビュー観点に翻訳できる範囲」(例: 「テスト必須」→「テスト追加が無い PR は `[should]` で指摘」) のみ採用する。アクション指示が多すぎる場合は、caller に `REVIEW.md` をリポジトリ root に作成して上書きするよう促す。

### Step 4. PR の状態を取得する

いずれの `gh` コマンドも、cwd の git remote と PR の所属リポジトリが異なる場合 (ドッグフーディングや別リポジトリ向け caller) に意図しない PR を参照しないよう、Step 1 で確定した `OWNER`/`REPO` を `--repo <OWNER>/<REPO>` で必ず明示する。

- `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json title,body,headRefName,headRefOid,baseRefName,statusCheckRollup,commits` で PR メタ情報と CI 状態を取得する。`headRefOid` を head SHA として控え、Step 6 で `post-pr-review` の `COMMIT_ID` 引数 (force-push / rebase での行ズレによる誤コメント防止) と Step 7 の check run 投稿の `head_sha` の双方で常時転送する。
- `gh pr diff <PR_NUMBER> --repo <OWNER>/<REPO>` で差分を取得する。
- 既存レビュー / コメント (重複指摘の検知用) は GraphQL で `reviewThreads` を取得する。GraphQL は `-F owner=<OWNER> -F name=<REPO> -F number=<PR_NUMBER>` で渡す。`reviewThreads(first: 100)` は API の 1 ページ上限なので、`pageInfo { hasNextPage endCursor }` を取得し `hasNextPage` が `true` の間 `-F after=<endCursor>` で全件取得する。各スレッドの `comments.nodes[].body` まで取得し、Step 5 で本文主旨の重複判定に使う (位置 `path:line` だけでは論点違いのケースを取り違えるため)。
- caller の cwd と PR の所属リポジトリが異なるドッグフーディング系では、Step 3 のプロジェクト指示ファイルがローカルに存在しないことがある。その場合は `gh api repos/<OWNER>/<REPO>/contents/<path>` でリモートから取得して `Read` 相当に扱う (`<path>` は Step 3 の優先順で最初に見つかった 1 つ)。API レスポンスの `content` フィールドは Base64 なので、`--jq .content` で抽出して `python3 -c "import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode())"` 等でデコードしてから利用する。
- `statusCheckRollup` に `FAILURE` のジョブがあれば `gh run view --log --repo <OWNER>/<REPO>` 等で失敗ログ本体まで読み、`[must]` 指摘の根拠にする (詳細は `/pr-review-style-reference` の「CI の扱い」を参考)。

### Step 5. レビュー本文 (一次案) を作成する

Step 2〜4 で得た方針・観点・差分・CI 情報をもとに、総括 (`body`) と **候補指摘 `candidate_findings[]`** を作成する。本 Step では Verifier 検証前の「一次案」を組み立て、Step 5.5 で再検証してから Step 6 で `comments[]` として投稿する。

`candidate_findings[]` の各要素は以下の構造で組み立てる:

```json
{
  "id": "finding-001",
  "path": "src/auth.ts",
  "line": 42,
  "start_line": null,
  "side": "RIGHT",
  "severity": "must",
  "body": "[must] Token refresh races with logout..."
}
```

- `id`: 一次案中で一意な `finding-NNN` (連番)。Step 5.5 の Verifier が結果を `id` で返すため必須。
- `severity`: `must` / `should` / `nit` / `question` / `pre_existing` の小文字リテラル (本文先頭の `[must]` 等とは別に独立フィールドとして持つ)。
- `body`: 従来通り本文先頭に `[must]` 等のラベルを付けた本文。Step 5.5 後に `[must] (conf:NN) ...` 形式へ書き換える。
- `start_line` / `side` / `start_side` は単一行のみなら `null` で良い (`post-pr-review` のスキーマと整合する形で残す)。

その他のルール:

- レビュー方針は Step 3 のプロジェクト指示ファイルを最優先とし、明示的に上書きされていない論点については `/pr-review-style-reference` (スタイル参考ガイド) の重要度ラベル / ノイズ抑制 / 粒度ガイド等を参考にする。プロジェクト指示ファイル側でスタイル参考ガイドを使わない旨が明示されていればそれに従う。
- 既存スレッドと同主旨の指摘は再掲しない。判定は Step 4 で取得した `reviewThreads.nodes[].comments.nodes[].body` の主旨と現在の指摘の主旨を突き合わせて行う (位置 `path:line` が一致しても論点が別なら新規指摘してよい)。
- `event` は **常に `COMMENT`** とする (`post-pr-review` の規約)。`[must]` の有無にかかわらず `COMMENT` で投稿し、修正の要否は本文 (`body`) と各インライン (`comments[]`) の `[must]` ラベルで伝える。
- 指摘が無い場合 (`candidate_findings[]` が空) も Step 5.5 を skip して Step 6 で「特に指摘なし」相当の Review を投稿する (skip しない)。
- CI failure 起因の指摘で anchor が特定できず総括 (`body`) にしか書けないものは `candidate_findings[]` に入れず、総括内のテキストとしてのみ扱う (Verifier は `comments[]` 相当のインライン指摘候補のみを対象とする)。

### Step 5.5. Verifier サブエージェントで各指摘を再検証する

Step 5 で生成した `candidate_findings[]` を `verify-pr-review-findings` skill に渡し、独立コンテキストのサブエージェントで再検証する。返却された `verdicts[]` をもとにフィルタ・ソート・本文書き換えを行ってから Step 6 へ進む。

`SKIP_VERIFIER=true` または `candidate_findings[]` が空のときは本 Step を skip する (skip ステータスは Step 7-2 で Check Run に残す)。

#### 5.5-1. skip 条件のチェック

- `SKIP_VERIFIER=true`: `verifier_status="skipped:user_flag"` を控えて 5.5 全体を skip。`comments[]` は `candidate_findings[]` の各要素を `path` / `line` / `side` / `body` だけ拾って組み立て (本文書き換えなし)。
- `candidate_findings[]` が空: `verifier_status="skipped:zero_candidates"` を控えて 5.5 全体を skip。`comments[]` は空配列。

両方とも 5.5-2 以降は実行せず Step 6 へ進む。

#### 5.5-2. Verifier への入力を組み立てる

`candidate_findings[]` の各 candidate について、以下を Verifier に渡せる形に整形する。範囲の数値は `verify-pr-review-findings/SKILL.md` の「数値リテラル一覧」を参照し、本 skill 側では再定義しない。

- **DIFF**: Step 4 で取得済みの `gh pr diff` の出力をそのまま使う。
- **FILE_EXCERPTS**: 各 candidate の周辺 `FILE_EXCERPT_RANGE` (= ±50 行) を、PR の head SHA から `gh api repos/<OWNER>/<REPO>/contents/<path>?ref=<HEAD_SHA>` で取得し、レスポンス JSON の `.content` フィールドを抽出して Base64 デコード、必要範囲のみ抜粋。同 path で重複する範囲はマージして 1 件にまとめる。`gh api` が 404 (新規追加で base 側に存在しない場合を含む) / サイズ超過などで取得失敗した candidate は、その entry を `FILE_EXCERPTS` に含めないだけで Verifier 呼び出しは続行する (Verifier 側 Step 0 で欠損許容)。
- **RELATED_THREADS**: Step 4 で取得済みの `reviewThreads` から、各 candidate と同 `path` かつ `RELATED_THREAD_RANGE` (= ±10 行) に該当するスレッド本文を抜粋。なければ空配列。
- **CANDIDATES**: `candidate_findings[]` の `id` / `path` / `line` / `severity` / `body` をそのまま渡す。

#### 5.5-3. `verify-pr-review-findings` skill を呼ぶ

Skill ツールで `verify-pr-review-findings` を呼び出し、上記入力に加えて `MODE="pr"` / `REPO_CONTEXT={OWNER, REPO, PR_NUMBER}` / `VERIFIER_TIMEOUT_SEC` (本 skill の入力値、省略時は Verifier 側の `DEFAULT_VERIFIER_TIMEOUT_SEC`) を渡す。

返却値 (`{"verdicts":[...], "stats":{...}}`) を受け取る。`verifier_status` は **Verifier 側返却の `stats.status` をそのまま採用** する (`ok` / `skipped:zero_candidates` / `skipped:timeout` のいずれか)。完了分の `verdicts[]` は `stats.timeout=true` でも通常通り採用する (未完了分は skill 側で `verdict=uncertain` / `confidence=0` で埋められている)。

skill 呼び出し自体が例外 / 応答なしで失敗した場合は、`verifier_status="skipped:error"` を控え、`verdicts[]` を空とみなして 5.5-4 以降は **一次レビューをそのまま採用** する (`comments[]` は `candidate_findings[]` の `path` / `line` / `side` / `body` のみ拾って組み立て、本文書き換えなし)。`skipped:timeout` と `skipped:error` の区別 (タイムアウトと skill 呼び出し失敗) は Step 9 のデバッグ報告で観察可能になるよう保持する。

#### 5.5-4. フィルタ・ソート・本文書き換え

`verifier_status` が `ok` または `skipped:timeout` (完了分のみ採用) の場合、`candidate_findings[]` と `verdicts[]` を `id` で突き合わせて以下を実施する。`skipped:user_flag` / `skipped:zero_candidates` / `skipped:error` のときは本サブステップを実行しない (5.5-1 / 5.5-3 の skip パスで `comments[]` を組み立て済み)。

1. **フィルタ**:
   - `verdict == "likely_false_positive"` かつ `confidence >= 80` → 除外 (FP として確信のあるもの)
   - `confidence < CONFIDENCE_THRESHOLD` (デフォルト 80) → 除外
   - `CONFIDENCE_THRESHOLD=all` のときは閾値フィルタを skip し、すべて本体に残す
   - その他は採用

2. **本文書き換え**: 採用した各指摘の `body` 先頭を `[<severity>] (conf:<NN>) <元本文の severity ラベル除去後>` に書き換える (例: `[must] Token refresh...` → `[must] (conf:87) Token refresh...`)。`severity` は元の `candidate.severity` を使う (Verifier の `severity_suggestion` は本リポジトリ運用では破棄: `verify-pr-review-findings/SKILL.md` の出力スキーマ注記参照)。

3. **ソート**: 採用した指摘を severity 順 (must → should → nit → question → pre_existing) 一次キー、同 severity 内は confidence 降順二次キーで並べる。

4. **集計**: 除外された指摘の件数と内訳を控える (FP 除外 / 閾値未満、severity 別件数、平均 conf、最低 conf)。

#### 5.5-5. 総括 (`body`) への 1 文添付

除外件数が 1 件以上なら、Step 5 で作った総括 (`body`) の末尾に以下の形式で 1 文添える:

```
Verifier で N 件除外 (FP: A, 閾値未満: B — 平均 conf XX, [should] X / [nit] Y)
```

除外 0 件のときは何も添えない。`verifier_status` が `ok` 以外 (`skipped:*` のいずれか) のときも添えない。

### Step 6. `post-pr-review` skill でレビューを投稿する

Step 1 で確定した `OWNER` / `REPO` / `PR_NUMBER` と Step 5/5.5 で作成した本文 (`body` + Step 5.5-4 で組み立てた `comments[]`) を `post-pr-review` skill に渡し、**1回の API コールで1つの Review として** 投稿する。`gh pr comment` や `gh pr review` での個別投稿はしない。

起動方法は **Skill ツールで `post-pr-review` を呼ぶ**。本文 (`body` / `event` / `comments[]`) と `COMMIT_ID` (Step 4 で控えた head SHA) は `post-pr-review/SKILL.md` のスキーマに従って組み立て、起動時の引数として渡す。`/tmp/review.json` の `Write` と `gh api .../reviews --input` の実行は呼び先の `post-pr-review` 側で行うため、本 skill 側で先回りして書かない。

### Step 7. Check Run でサマリと機械可読 severity を出力する

Step 6 で投稿した Review の内容を **Checks タブの Details ページから一覧で参照できる索引** として check run に書き出す。inline review comment の本文は再掲しない (重複させない)。merge gate を組みたい caller のため、`output.text` 末尾に severity 件数の JSON を HTML コメントとして埋める。

本ステップは **best-effort**。失敗 (403 等) しても Step 6 / Step 8 の成否には影響させず、Step 9 で警告として報告するだけに留める。

#### 7-1. severity 件数と confidence 統計を集計する

Step 5.5-4 後の `comments[]` の本文先頭からラベルと confidence を抽出して集計する。指摘 0 件のときも全ラベル `0` で埋めた JSON を作る (caller が常に同じスキーマで読めるように)。

ラベル + confidence の抽出パターン (前方一致):

```
^\[(must|should|nit|question|pre_existing)\](?: \(conf:(\d+)\))?
```

- `(conf:NN)` あり (通常ケース = `verifier_status == "ok"`): ラベルと confidence の両方を取る。
- `(conf:NN)` なし (`verifier_status != "ok"` のすべて): ラベルのみ取り、confidence は集計から除外する。

confidence 統計 (`verifier_status == "ok"` のときのみ計算):
- `mean`: 採用された指摘の confidence 平均 (整数に丸める)
- `min`: 採用された指摘の confidence 最低値
- `threshold`: 本 skill の入力 `CONFIDENCE_THRESHOLD` (省略時 80、`all` のときは文字列 `"all"`)
- `filtered_out`: Step 5.5-4 でフィルタ (FP 除外 + 閾値未満) して落とした件数
- `verifier`: `verify-pr-review-findings/SKILL.md` の「Verifier 状態 enum」の 5 値 (`ok` / `skipped:zero_candidates` / `skipped:timeout` / `skipped:error` / `skipped:user_flag`) のいずれか。Step 5.5-1 / 5.5-3 で控えた `verifier_status` をそのまま入れる。

`verifier` が `ok` 以外のときは `mean` / `min` / `filtered_out` を `null` にする。

#### 7-2. `/tmp/check-run.json` を `Write` ツールで書き出す

`heredoc` や `cat` リダイレクトは使わず、必ず `Write` ツールで書く。スキーマは以下:

```json
{
  "name": "pr-review (abeyuya/skills)",
  "head_sha": "<HEAD_SHA>",
  "status": "completed",
  "conclusion": "neutral",
  "output": {
    "title": "Code Review Summary",
    "summary": "5 件の指摘 (must: 2, should: 1, nit: 2, question: 0, pre_existing: 0, 平均 conf: 86)",
    "text": "| Severity | Conf | File:Line | Issue |\n| --- | --- | --- | --- |\n| [must] | 92 | src/auth.ts:42 | Token refresh races with logout |\n| [must] | 87 | src/db.ts:88 | Tenant scoping missing |\n| [should] | 84 | src/api.ts:14 | Error message contains raw \\| separator (must be escaped) |\n| [nit] | 81 | src/util.ts:7 | Inconsistent naming |\n| [nit] | 80 | README.md:3 | Typo |\n\n<!-- pr-review-severity: {\"must\":2,\"should\":1,\"nit\":2,\"question\":0,\"pre_existing\":0} -->\n<!-- pr-review-confidence: {\"mean\":86,\"min\":80,\"threshold\":80,\"filtered_out\":3,\"verifier\":\"ok\"} -->"
  }
}
```

- `name`: `pr-review (abeyuya/skills)` 固定。docs の managed Code Review (`Claude Code Review`) と衝突しないように本リポジトリ由来であることを明示する。
- `head_sha`: Step 4 の `headRefOid` をそのまま使う。
- `conclusion`: 必ず `neutral`。merge を block する権限を持たないため。
- `output.title`: 固定文言 `Code Review Summary`。
- `output.summary`: 1 行サマリ。件数の総数 + severity 内訳 + 平均 conf (`verifier:ok` のみ表示)。
- `output.text`: severity 順 (must → should → nit → question → pre_existing) 一次キー、同 severity 内は confidence 降順二次キーで並べた表。
  - 表ヘッダは `| Severity | Conf | File:Line | Issue |`。
  - データ行は `| [label] | <NN> | <path>:<line> | <summary> |` の形 (`[label]` は `[must]` / `[should]` / `[nit]` / `[question]` / `[pre_existing]` のいずれかリテラル、`<NN>` は 0-100 の整数、`<path>` / `<line>` / `<summary>` は placeholder)。
  - `Conf` 列は `verifier:ok` 以外 (skip / timeout) のときは `-` を入れる。
  - `<summary>` は Step 5.5-4 後の本文先頭 1 行を要約したもの (ラベルと `(conf:NN)` プレフィックスを除いた要旨)。テーブルレイアウト崩れを防ぐため、次のサニタイズを **必須** とする:
    - Issue カラム内のパイプ `|` は `\|` にエスケープする。`output.text` は JSON 文字列リテラルに入るため、JSON 値としては `\\|` (バックスラッシュ 2 つ + パイプ) と書く (上記スキーマ例の `[should]` 行参照)。
    - 改行は半角スペースに置換して 1 行に畳む。
  - 表のあとに **空行 1 行を空けて** HTML コメント形式で 2 行 (`pr-review-severity:` と `pr-review-confidence:`) を書く。順序は severity → confidence の固定。
  - 指摘 0 件の場合は表の代わりに `特に指摘なし` の 1 行 + 2 行の HTML コメント。`pr-review-confidence` の `verifier` は `skipped:zero_candidates`。

#### 7-3. `gh api` で投稿する

```bash
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  /repos/<OWNER>/<REPO>/check-runs \
  --input /tmp/check-run.json
```

失敗時は **再試行せず** Step 9 で警告として報告する (403 / 404 はそれぞれ権限不足 / 該当 SHA が無い、ネットワーク系もすべて同様に 1 回だけ試して終わる)。

### Step 8. `resolve-pr-threads` skill で過去スレッドを整理する

Step 1 の PR 識別情報と `THREAD_RESOLVE_SCOPE` (省略時 `all`) を `resolve-pr-threads` skill に渡して呼び出す。`THREAD_RESOLVE_SCOPE=none` の場合は呼び出すが skill 側で skip される。

`THREAD_RESOLVE_SCOPE=own` の場合、caller から `SELF_LOGIN` が渡されていれば一緒に渡す。

### Step 9. caller への報告

以下を簡潔に caller へ返す:

- 投稿した Review の URL (Step 6 のレスポンスから取れる場合)
- インライン指摘件数 / 総括の主要懸念件数 / severity 内訳
- Verifier ステータス (`verify-pr-review-findings/SKILL.md` の「Verifier 状態 enum」5 値: `ok` / `skipped:zero_candidates` / `skipped:timeout` / `skipped:error` / `skipped:user_flag`) と、`ok` の場合は除外件数 (FP 除外 / 閾値未満) と平均 conf
- 作成した check run の URL または ID (Step 7 が成功した場合) / 失敗した場合はその旨を 1 行 (例: `check run skipped: 403 Forbidden`)
- resolve したスレッド件数 (Step 8 の戻り値)

## 守ること

- 各 step で使う既存資産 (`/pr-review-style-reference` / `verify-pr-review-findings` / `post-pr-review` / `resolve-pr-threads`) は **必ずこの skill 経由で利用** する。本 skill 内で同等の処理を再実装してはならない (スタイル参考ガイド・Verifier 検証・投稿手順・resolve 判定の二重管理を防ぐため)。
- レビュー文面の規約 (重要度ラベル等) は `/pr-review-style-reference` (スタイル参考ガイド) に集約されているため、本 skill では再掲しない。caller 側に独自方針がある場合はそちらを優先する。
- 判定に迷ったら resolve しない / 投稿は1回だけ、という既存 skill の安全側ルールはそのまま守る。
- Step 5.5 で Verifier が失敗 / タイムアウトした場合は一次レビューをそのまま採用する (best-effort)。Verifier の存在を前提に投稿を skip してはならない。
- Step 7 の check run `name` (`pr-review (abeyuya/skills)`) は本リポジトリ由来であることを示す固定文言。**fork / 別 org で再配信する場合は**、本 SKILL.md (Step 7-2 の JSON スキーマ例) と README の「Check Run 出力」セクションを新しい owner/repo に書き換える。動的解決はしない。
