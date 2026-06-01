---
name: compose-review
description: PR 差分 or ローカルブランチ差分に対してレビュー本文 (body / event / comments[]) を生成する skill。`/pr-review-style-reference` slash command とプロジェクト指示ファイル (REVIEW.md / AGENTS.md / .claude/CLAUDE.md / CLAUDE.md) を読み込んでレビュー方針を決め、差分を読んで `post-pr-review` のスキーマに揃った JSON を **`HANDOFF_PATH` (省略時は既定 temp パス) にファイル書き出しし、最終メッセージでは「そのファイルを Read して続行せよ」という継続指示を返す** (停止防止のため自己完結 JSON は最終メッセージに出さない)。レビュー指摘は自前レビューを必ず行い、加えてホストの外部レビュースキル (優先順: `code-review` (Claude Code 組み込み) → ホスト標準レビュースキル例 Codex `/review` → 無し) を 1 つ併用して指摘をマージする (通常は常に併用。外部スキルが 1 つも使えないときだけ自前単独)。`run-pr-review` / `run-local-review` orchestrator や Codex 等他 caller から現在コンテキストで直接 Skill ツール経由で呼ばれる。GitHub 投稿 / 過去スレッド resolve は行わない (read-only)。
---

# compose-review skill

差分 + 方針 → レビュー本文 (`body` / `event` / `comments[]`) を生成する skill。完成 JSON は **`HANDOFF_PATH` (省略時は既定 temp パス) にファイルとして書き出し**、最終メッセージでは **「そのファイルを `Read` して続行せよ」という継続指示を返す** (詳細は Step 6)。**最終メッセージに自己完結 JSON を出さない** — 自己完結 JSON は「タスク完了」シグナルに見え、caller (orchestrator) が投稿 step を実行する前にターンを終了してしまう停止バグを誘発するため、ファイル経由ハンドオフ + 継続指示に一本化している。

## 入力 (任意, caller から prompt 経由で渡される)

入力は `KEY=VALUE` 形式 1 行ずつで渡される想定。長文値 (`EXISTING_THREADS_CONTEXT` / `CI_FAILURE_CONTEXT` 等) は最初の `=` までを key、それ以降の改行も含めて次の `KEY=` (`^[A-Z_]+=`) または prompt 末尾までを value として扱う。**長文 value の中に `^[A-Z_]+=` 行頭パターンが混入すると誤切断するため、caller (orchestrator) は長文 value を prompt の末尾 (短い key より後) に配置すること**。未指定の key は呼び元で行ごと省略される。

### モード切替

- `MODE`: `pr` または `local`。caller (orchestrator) が必ず指定する想定。未指定の場合は `OWNER`/`REPO`/`PR_NUMBER` が 3 つとも非空なら `pr`、それ以外は `local` にフォールバック。
- `OWNER` / `REPO` / `PR_NUMBER`: PR モードの識別情報。
- `BASE_BRANCH`: ローカルモードの比較対象ベースブランチ。未指定なら Step 1 の解決順で決定。

### 共通

- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited`。詳細は `/pr-review-style-reference` の引数仕様。
- `HANDOFF_PATH`: 完成 JSON (または error JSON) の書き出し先**絶対パス**。caller (orchestrator) が生成して渡す想定 (**ファイルは作らずパス文字列のみ** — 空ファイルを先に作ると `Write` ツールが事前 `Read` を要求して書き出しに失敗するため)。**省略時は本 skill が `/tmp/compose-review-<UTCタイムスタンプ>-<ランダム英数字 4〜6 文字>.json` (例: `date -u +%Y%m%dT%H%M%SZ` + 一意サフィックスで `/tmp/compose-review-20260601T123456Z-a1b2c3.json`) を自動生成**し、最終メッセージの継続指示にそのパスを明記する。秒精度だけだと同一秒の再呼び出しで衝突し、2 回目の `Write` が既存ファイルへの上書きとなって事前 `Read` を要求されるため、ランダムサフィックスで一意化する。これにより `HANDOFF_PATH` を渡さない caller (手動 / Codex 等) でもファイル経由で結果を受け取れる。

### PR モードのみ (任意)

- `COMMIT_ID`: caller (orchestrator) が既に取得した head SHA。渡されればそのまま Step 6 の `commit_id` として使い、Step 1 の `gh pr view` 再取得を skip する (二重取得回避 + force-push race 防止)。
- `EXISTING_THREADS_CONTEXT`: caller が既に取得した既存 reviewThreads の主旨サマリ (各スレッドの `path:line` 併記 1〜2 文要約)。Step 5 の重複指摘抑制に使う。
- `CI_FAILURE_CONTEXT`: caller が既に収集した CI 失敗ログのサマリ。Step 5 で `[must]` 指摘の根拠として使う (失敗ジョブがあれば必ず `[must]` 扱いに昇格)。

caller プロジェクト固有の方針は **プロジェクト指示ファイル** (Step 3) に置く運用に固定。個別パス指定の引数は持たない。

## caller 向け呼び出し契約

本 skill は **現在コンテキストで直接 (Skill ツール経由で) 呼ばれる** 前提。本 skill は完成 JSON を **`HANDOFF_PATH` にファイル書き出し** し、最終メッセージでは継続指示文を返す。caller (`run-pr-review` / `run-local-review` / 他) は **`HANDOFF_PATH` を `Read` ツールで読み込み**、その JSON を parse して後続 step で使う (最終メッセージ自体は JSON ではないので parse 対象にしない)。

- 引数は `KEY=VALUE` 1 行ずつで渡す (詳細は「入力」節)。値が未取得 / 空の引数行は **行ごと省略** する (空文字埋めはしない)。長文 value の末尾配置ルールも同節を参照。
- `HANDOFF_PATH` は caller が生成して渡すのを推奨 (詳細は「入力」節)。caller が `HANDOFF_PATH` を渡せば、戻り後 `Read` すべきパスを caller 自身が既に把握している状態になる (最終メッセージの継続指示にも同じパスが明記される)。
- 本 skill は **致命エラー時に `{"error": "..."}` だけを `HANDOFF_PATH` に書き出す** (他フィールドを含めない)。caller は読み込んだ JSON を **`error` 判定 → `mode` 判定 → 正常** の順 (順序固定) で評価する: error payload は `mode` を含まない仕様なので必ず `error` を先に見る。`error` があれば停止して報告する。正常時は `mode` / `body` / `event` / `comments` 等を後続 step に渡す。各ケースで取るアクションは caller 固有 (停止して報告する / 擬似結果を組み立てて続行する 等)。

## 手順

### Step 1. モード判定と対象確定

#### PR モード

- `OWNER` / `REPO` / `PR_NUMBER` のいずれかが空ならエラーとし、`{"error":"PR モードで OWNER/REPO/PR_NUMBER が欠けています"}` を Step 6 の手順で `HANDOFF_PATH` に書き出し、継続指示を返して停止する (caller のガード漏れを本 skill 側でも弾く)。
- `COMMIT_ID` が caller から渡されていればそれを Step 6 出力 JSON の `commit_id` として控え、本 step での `gh pr view` 再取得は **skip する** (二重取得 / force-push race 回避)。
- `COMMIT_ID` 未指定なら `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json headRefOid -q .headRefOid` で head SHA を取得し `commit_id` として控える。失敗時は本 skill の「失敗時」節に従い `{"error":"..."}` を `HANDOFF_PATH` に書き出して停止する (transient/致命の自動判別はしない)。

#### ローカルモード

- 現在ブランチ名: `git rev-parse --abbrev-ref HEAD`。`HEAD` (detached) ならエラー停止。
- ベースブランチ: `BASE_BRANCH` が渡されていればそれを使う。未指定なら以下の順:
  1. `git symbolic-ref --short refs/remotes/origin/HEAD | sed 's@^origin/@@'` で純粋ブランチ名 (例: `main`) を取得 → `git rev-parse --verify <name>` が通れば採用 (リモート追跡 `origin/<name>` ではなくローカルの同名ブランチ)
  2. `git rev-parse --verify main`
  3. `git rev-parse --verify master`
  4. いずれも取れなければエラー停止し caller に `BASE_BRANCH` 明示を促す
- 差分モード判定 (本 step では空 / 非空のみ判定し `diff_mode` を確定。差分本体は Step 4 で取得):
  1. `git diff <base>...HEAD` が非空 → `diff_mode = "commit"`
  2. `commit` モード空 + `git diff --cached` が非空 → `diff_mode = "staged"`
  3. `staged` モード空 + `git diff` が非空 → `diff_mode = "worktree"`
  4. すべて空 → `diff_mode = "none"`。Step 2〜4 と Step 5 のレビュー生成 (5-1〜5-3) を skip し、Step 6 で `body` を「対象差分なし」、`comments` を `[]` にして返す。

### Step 2. スタイル参考ガイドを読み込む

**Skill ツール (`skill: "pr-review-style-reference"`)** で `pr-review-style-reference` を呼ぶ (`MAX_INLINE_COMMENTS` 指定があれば `max-inline-comments=<値>` を渡す)。`commands/` 配下のファイルも `skills/` と同じく Skill ツール名で解決される。重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱いを本セッションのレビュー方針として保持する。

### Step 3. プロジェクト指示ファイルを読み込む (任意)

リポジトリ root の以下を上から順に存在チェックし、**最初に見つかった 1 つだけ** を読み込む。複数あっても下位は読まない / 連結しない。

1. `REVIEW.md` — レビュー専用の最上位指示
2. `AGENTS.md` — agent 全般向けの fallback
3. `.claude/CLAUDE.md` — Claude Code 全般向けの fallback (`.claude/` 配下に置く流儀)
4. `CLAUDE.md` — Claude Code 全般向けの fallback (リポジトリ root に置く流儀)

#### 取得方法

- **ローカルモード**: `Read` ツールで cwd 直下を上記 4 候補の優先順で順に試す。
- **PR モード**: cwd の git remote URL から OWNER/REPO (大文字小文字無視) を頑健に抽出して入力 `OWNER`/`REPO` と比較。SSH 形式 (`git@github.com:owner/repo.git`) と HTTPS 形式 (`https://github.com/owner/repo.git`) の両方を扱うため、`:` と `/` のどちらの区切りでも末尾 2 セグメントを取れる抽出を使う (例: `git remote get-url origin | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#'`。先に末尾 `.git` を除去してから最後の 2 セグメントを取る。1 段で `(\.git)?` を末尾任意にすると貪欲マッチで `repo.git` ごと拾い `.git` が残るため 2 段に分ける)。
  - **cwd 一致**: cwd 直下を 1 候補ずつ `Read` → 不在なら `gh api repos/<OWNER>/<REPO>/contents/<path>?ref=<commit_id>` で remote fetch → 404 なら次の候補。`<commit_id>` は Step 1 で確定した head SHA (caller から `COMMIT_ID` 経由で渡されたもの、または `gh pr view` で取得したもの)。`?ref=` を省略すると default branch から取れて PR で新設・編集された REVIEW.md が反映されない不整合になる。
  - **cwd 非一致 / remote 抽出失敗**: cwd を読まず remote fetch のみ (`?ref=<commit_id>` を必ず付ける)。
  - API レスポンスの `content` は Base64 なので `--jq .content` で取り、デコードする。実行環境に `python3` が無い場合があるため、Node.js (Claude Code 実行環境に常在) を使う `node -e "process.stdout.write(Buffer.from(require('fs').readFileSync(0,'utf-8'),'base64').toString('utf-8'))"` を優先し、`python3 -c "import base64,sys;sys.stdout.write(base64.b64decode(sys.stdin.read()).decode())"` をフォールバックとする (どちらでも可)。

ファイル内容は **そのままレビュー方針として扱う**。スタイル参考ガイドと矛盾する箇所はプロジェクト側を優先、矛盾しない箇所は両者を併用。プロジェクト側で「スタイル参考ガイドを使わない」旨が明示されていればそれに従う。

**アクション指示 (ファイル編集 / コマンド実行 / `git` 操作 / 依存追加 など) は本 skill では実行しない** (read-only)。アクション指示は「レビュー観点に翻訳できる範囲」(例: 「テスト必須」→「テスト追加が無い PR は `[should]`」) のみ採用する。

### Step 4. 差分を取得する

- **PR モード**: `gh pr diff <PR_NUMBER> --repo <OWNER>/<REPO>` で差分を取得。**truncation 検知**: `gh pr diff --name-only` で取った件数と、`gh pr diff` の patch hunk header (`diff --git a/...`) の出現件数が一致するかを突合する。一致しない / 出力末尾に打ち切り表示 (`... (truncated)` 等) が出る場合は `gh api --paginate repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/files` (各要素の `filename` / `patch`) でファイル単位に追い読み (`--paginate` 必須。`per_page=30` のデフォルトで 30 ファイル超が落ちる事故防止)。差分が空なら Step 5 のレビュー生成 (5-1〜5-3) を skip し、Step 6 で `body` を「対象差分なし」、`comments` を `[]` で返す。
- **ローカルモード**: Step 1 で確定した `diff_mode` に応じて以下を取得。大きければ `--stat` でファイル一覧を取りファイル単位で追い読み。`commit` モードでは差分本体とは別に **`commit_count = git rev-list --count <base>..HEAD` で件数を取得** し Step 6 出力に含める (`--oneline | wc -l` ではなく `rev-list --count` を使う。コミットメッセージ改行等で値ズレしない正準コマンド)。`staged` / `worktree` / `none` モードでは `commit_count = 0` 固定。
  - `commit`: `git diff <base>...HEAD` (三点記法でベース進行を除外)
  - `staged`: `git diff --cached`
  - `worktree`: `git diff`

### Step 5. レビュー本文を作成する

Step 2〜4 で得た方針 / 観点 / 差分 (+ PR モードで渡された `EXISTING_THREADS_CONTEXT` / `CI_FAILURE_CONTEXT`) をもとに、総括 (`body`) とインライン指摘 (`comments[]`) を作成する。本 step は **5-1 自前レビュー (常時)** → **5-2 外部レビュースキル併用 (通常は常に実施)** → **5-3 マージと後処理** → **5-4 body 構成** の順で進める。

#### 5-1. 自前レビュー (常時実施)

差分を自分で読み、インライン指摘の候補リストを作る。これが基盤であり、外部レビュースキルが使えない環境でも本 step 単独でレビュー品質を担保する。

- レビュー方針は Step 3 のプロジェクト指示ファイルを最優先、未上書きの論点は Step 2 のスタイル参考ガイドを参考にする。

#### 5-2. 外部レビュースキルの併用 (通常は常に実施)

ホストの外部レビュースキルを **優先順で 1 つだけ** 解決し、使えるなら 5-1 に加えてもう 1 系統の指摘を得る (5-1 → 外部スキル呼び出し → 5-3 マージの逐次実行。本 skill 自身は sub-agent を spawn しない)。利用可否は実行中の model が available-skills / コマンド一覧から判断する (本 skill はホスト非依存に書く)。

本 skill は `run-pr-review` / `run-local-review` から **現在コンテキストで直接呼ばれる前提** に統一されているため、5-2 は **通常は常に実施する** (見出しの条件は「現在コンテキスト = Agent ツールが使える」異常時ガードであり、dead condition ではない)。自身の実行コンテキストを判断しかねた場合に 5-2 全体を勝手にスキップして 5-1 単独へ退化しない (それは本 skill の主目的=外部レビュー併用を黙って無効化する)。外部レビューを省くのは、下の解決順で **外部スキルが 1 つも利用できない / Agent ツールが使えない** と確認できたときだけ。

- **解決順**:
  1. `code-review` (Claude Code 組み込み) が当セッションで利用可能、**かつ** Agent/Task ツールが当コンテキストで利用可能なら → これを使う。`code-review` は内部で Agent ツールによる finder/verifier の fan-out を行うため、Agent ツールが利用できない環境では使えない。
  2. ↑が無い/不可なら、ホスト coding agent の標準レビュースキル (例: **Codex の `/review`**) が当セッションで利用可能ならそれを使う。
  3. いずれも無ければ外部レビューは行わず、5-1 の自前レビュー単独で 5-3 へ進む。
- **実行 (read-only)**: 解決したスキルを **read-only モードで** 呼ぶ。**投稿 / 自動修正フラグは付けない** (`code-review` なら `--comment` / `--fix` を付けない。他ホストでも投稿・working tree 改変モードは使わない。投稿は `post-pr-review` の責務、working tree 改変は本 skill の禁止事項)。特に PR モードで `--comment` を付けると、`code-review` 由来の生 inline コメント (AI 自動投稿マーカーなし) が `post-pr-review` の 1 Review と **二重投稿** されるため厳禁。
- **scope 引数** (レビュー対象の diff 範囲を伝える): 外部レビュースキルの scope 引数は **単一値 (PR番号 / branch名 / file path) を取る前提で、`<base>...HEAD` のような範囲そのものは渡せないことが多い**。`code-review` の branch/range scope の正確な解釈は **未検証** (環境依存)。以下を目安にしつつ、**自前レビュー (5-1) が見ている diff 範囲と外部スキルが見る範囲が一致しているか実行時に確認する** (一致しないなら不一致を前提に扱い、取りこぼしは 5-1 の自前レビューが拾う):
  - PR モード: PR 番号を scope として渡す。
  - ローカル `commit` モード: branch 名を渡して `<base>...HEAD` 相当を見させる。ただし `BASE_BRANCH` が default branch 以外に上書きされている場合、外部スキルが別の merge-base 基準で diff を取り 5-1 と範囲がズレうる点に注意。範囲を正しく表現できなければ、自前レビュー (5-1) を主、外部スキルを補助として扱う。
  - ローカル `staged` / `worktree` モード: 外部スキルの既定 scope (uncommitted 差分) に委ねる。`code-review` は既定で `git diff HEAD` 相当も見るため staged 差分も拾えるが、**staged のみ (worktree クリーン) のケースで外部スキルが空 diff を返したら、その回は外部レビューを「指摘なし」として扱い 5-1 のみで続行する** (silent skip ではなく自前レビューで担保)。
- **正規化** (外部スキルの findings → 本 skill の指摘形式):
  - 各 finding の対象ファイル / 行を `path` / `line`、`side="RIGHT"` (単一行) に正規化する。`path` は **リポジトリルートからの相対パスに揃える** (外部スキルが絶対パスや `./` 始まりで返す場合があり、`post-pr-review` の投稿や 5-3 の重複排除が `path` の表記一貫性に依存するため)。
  - 外部スキルの出力に本 skill 互換の重要度ラベルが無い場合 (例: `code-review` の出力は `[{file,line,summary,failure_scenario}]` の配列で、配列順=重大度のみでラベル無し) は、Step 2 のスタイル参考ガイド + Step 3 の `REVIEW.md` 方針で `[must]` / `[should]` / `[nit]` / `[question]` を付与する (correctness 上位は `[must]` / `[should]`、cleanup / altitude 下位は `[nit]` を基準にし、`REVIEW.md` が必須化する観点は昇格)。
  - 指摘本文は `[label] <要約>。<根拠 / 再現>` をスタイル参考ガイドの日本語トーンで整形する。
  - `code-review` 以外 (Codex `/review` 等) の出力形式は環境依存で未確定なため、得られた構造から `path` / `line` / 要約 / 重大度を抽出して同様に正規化する。形式が読み取れない部分は安全側 (取りこぼし回避) で残す。

#### 5-3. マージと後処理

5-1 と 5-2 の指摘を統合し、最終 `comments[]` を確定する。

- **範囲外の指摘の除外**: 外部スキル (5-2) から得られた指摘のうち、Step 4 で取得した実際の差分に含まれないファイル / 行への指摘は、マージ時に除外する (scope 解釈の差で未変更行や対象外ファイルへの指摘が返りうるため。無関係な箇所への誤投稿を防ぐ)。
- **重複排除**: 同一 `path:line` かつ同主旨の指摘は 1 件に集約する (自前と外部スキルが同じ問題を指したケース)。位置が同じでも論点が別なら両方残す。
- **重要度競合**: 同主旨で重要度が割れた場合は高い方を採用する (`[must]` > `[should]` > `[nit]` > `[question]` > `[pre_existing]`)。判定に迷えば残す方向 (取りこぼし回避優先)。
- `EXISTING_THREADS_CONTEXT` が渡されている場合、同主旨の指摘は再掲しない (位置が同じでも論点が別なら新規指摘してよい)。重要度が既存より高い場合は別主旨として残す ([must]/[should] を dedupe で抑制すると実害大のため判定に迷えば残す方向)。
- `CI_FAILURE_CONTEXT` が渡されている場合は **`[must]` 指摘の根拠として扱う**: 失敗ジョブが存在する以上「修正必須」であり `[nit]` や `[question]` で扱わない (詳細はスタイル参考ガイドの「CI の扱い」を参考)。
- `MAX_INLINE_COMMENTS` が正の整数なら `comments[]` を N 件以下に絞る (優先度: `[must]` > `[should]` > `[nit]` > `[question]` > `[pre_existing]`)。N 超過で省略があれば `body` 末尾に「省略件数 + ラベル別内訳」を 1 文添える。

#### 5-4. body 構成

- `event` は **常に `"COMMENT"`** (`post-pr-review` の規約)。
- 指摘が無くても Step 6 で「特に指摘なし」相当の JSON を返す (skip しない)。
- `body` は最低限 `## 総合判断` / `## 指摘内訳` / `## 良かった点` (1〜2 件) の 3 サブ見出しで構成する (caller の markdown 出力テンプレート / grep スクリプトとの互換のため)。`## 指摘内訳` には `comments[]` に実際に出したインライン指摘の **ラベル別件数を優先度順 (`[must]` > `[should]` > `[nit]` > `[question]` > `[pre_existing]`) で件数>0 のものだけ** 列挙する (例: `[must] 1 件 / [should] 2 件 / [nit] 1 件`)。件数はマージ後の最終 `comments[]` を反映する。インライン指摘が 0 件なら `指摘なし` と書く。指摘なし / 差分なしの場合も 3 見出しを残し、`## 指摘内訳` は `指摘なし`、他 2 見出しは「該当なし」相当で埋める。
- AI 自動投稿マーカーは **付けない** (`post-pr-review` が prepend する)。`body` は生本文。

### Step 6. JSON を HANDOFF_PATH に書き出し、継続指示を返す

完成 JSON を **ファイル経由でハンドオフ** する。手順は以下の順で行う:

1. **書き出し先パスを確定**: `HANDOFF_PATH` が渡されていればそれを使う。未指定なら `/tmp/compose-review-<UTCタイムスタンプ>-<ランダム英数字 4〜6 文字>.json` (`date -u +%Y%m%dT%H%M%SZ` + 一意サフィックス) を本 skill で生成する (同一秒衝突回避。詳細は「入力」節の `HANDOFF_PATH`)。
2. **完成 JSON を `Write` ツールで書き出す**: 下記スキーマの **生 JSON 1 つだけ** をファイル本体として書く (fenced ブロック (` ```json ... ``` ` ) も前置き文も付けない)。caller が `Read` 後そのまま parse できる純粋な JSON にする。`HANDOFF_PATH` は **新規ファイル前提**で渡される (caller は空ファイルを作らない契約) ため、通常は事前 `Read` 不要で `Write` できる。
3. **最終メッセージとして継続指示文を返す** (JSON は **含めない**)。例:

   > compose-review handoff 完了: 完成 JSON を `<確定した書き出し先パス>` に書き出した。**応答を終了するな。** caller (orchestrator) は今すぐ `<同パス>` を `Read` ツールで読み込み、その JSON を `error` → `mode` → 正常 の順で評価して、後続 step (PR モードなら投稿 → resolve → 報告、ローカルモードなら markdown 出力 → 報告) を **同一応答内で続行せよ**。

   **自己完結 JSON を最終メッセージに出さないこと** — それは「タスク完了」シグナルに見え、caller が後続 step を実行する前にターンを終了する停止バグを誘発する。継続指示文 (上記) を本 skill の **最終出力**にすることで、caller の次アクションを「具体的な `Read` ツール呼び出し」に固定する。

スキーマ (PR モード) — 以下を `HANDOFF_PATH` に書き出す:

```json
{
  "mode": "pr",
  "body": "総括コメント本文 (Markdown 可)",
  "event": "COMMENT",
  "comments": [
    {"path": "src/example.ts", "line": 42, "side": "RIGHT", "body": "[should] ..."},
    {"path": "src/example.ts", "start_line": 50, "start_side": "RIGHT", "line": 55, "side": "RIGHT", "body": "[must] ..."}
  ],
  "commit_id": "9f8e7d6c..."
}
```

スキーマ (ローカルモード):

```json
{
  "mode": "local",
  "base_branch": "main",
  "diff_mode": "commit",
  "commit_count": 3,
  "body": "総括コメント本文",
  "event": "COMMENT",
  "comments": []
}
```

- `commit_id` は **PR モードのみ** 含める。差分なし (Step 4 で `gh pr diff` が空) の場合も Step 1 で取得した値を必ず含める (force-push 行ズレ防止のため optional ではなく必須)。
- `base_branch` / `diff_mode` / `commit_count` は **ローカルモードのみ** 含める。`diff_mode` は `"commit"` / `"staged"` / `"worktree"` / `"none"` のいずれか。`commit_count` の取得手順は Step 4 ローカルモードに集約 (`git rev-list --count <base>..HEAD`、`staged` / `worktree` / `none` 時は `0` 固定)。
- 単一行コメントは `path` / `line` / `side` を指定。複数行は加えて `start_line` / `start_side` を併用 (`start_line` は `line` より前)。
- 指摘なしまたは差分なしの場合: `body` は最低 1 文 (例: `"特に指摘なし。"` / `"対象差分なし (評価対象なし)。"`)、`comments` は `[]`。空文字列は不可。

### 失敗時

致命エラー (Step 1 で head SHA 取得失敗、`HEAD` detached、ベースブランチ解決失敗、PR モードで `OWNER` / `REPO` / `PR_NUMBER` が空など) は `{"error":"<人間向けメッセージ>"}` を Step 6 と同じ手順で `HANDOFF_PATH` に書き出し、最終メッセージでは「`<書き出し先パス>` を `Read` して error 分岐に従え」という継続指示を返す。**error 時は他フィールド (`mode` / `body` / `event` / `comments` / `commit_id` / `base_branch` / `diff_mode` / `commit_count`) を含めない** (orchestrator が `error` 判定を `mode` 判定より先に評価する前提と整合させる)。orchestrator は読み込んだ JSON に `error` フィールドがあれば caller に転送して停止する。

## 守ること

- Task ツール / Agent ツールで **本 skill 自身が直接 sub-agent を spawn しない**。ただし Step 5-2 の外部レビュースキル併用 (`code-review` / Codex `/review` 等) を許容し、**その外部スキルが内部で Agent ツール等を使うことは妨げない** (本 skill が直接 spawn するのではなく、Skill 経由で呼んだ外部スキルが行う)。`/run-pr-review` / `/run-local-review` を再帰的に呼ぶこともしない (orchestrator が parent 側の責務)。
- `post-pr-review` / `resolve-pr-threads` は呼ばない (orchestrator の責務)。
- `gh pr review` / `gh pr comment` / `gh api .../reviews` を直接叩かない。レビュー投稿は本 skill の責務外。
- `git fetch` / `git pull` / `git checkout` / `git reset` / `git commit` / `git push` 等の書き換え操作は使わない。read-only の git コマンド (`git rev-parse` / `git log` / `git diff` / `git symbolic-ref` / `git remote get-url`) のみ。
- CI failure log の **収集** や reviewThreads の **取得** は本 skill では行わない (caller が `CI_FAILURE_CONTEXT` / `EXISTING_THREADS_CONTEXT` 経由で渡す前提)。
- AI 自動投稿マーカーは付けない (`post-pr-review` が prepend する)。
- `Write` ツールでのファイル出力は **`HANDOFF_PATH` への完成 JSON / error JSON 書き出しのみ許可** (Step 6 / 失敗時)。markdown 等それ以外の Write は行わない。
- **最終メッセージに自己完結 JSON を出さない**。最終メッセージは常に「`HANDOFF_PATH` を `Read` して続行せよ」という継続指示文にする (停止バグ防止。詳細は Step 6 / 冒頭概要)。
