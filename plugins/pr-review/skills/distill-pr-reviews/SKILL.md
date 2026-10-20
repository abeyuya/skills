---
name: distill-pr-reviews
description: 期間内 merged PR のレビューコメント (AI 自動投稿 + 人間レビュー両方) を集約し、REVIEW.md に追記する価値のある指摘候補を proposals.md として出力する skill。一般的なレビュー観点 (レビュアーが REVIEW.md なしでも指摘するもの) は採用候補にせず保留 / 棄却に降格し、プロジェクト固有の観点を重点的に抽出する。各候補には配置先 REVIEW.md (root / apps/web/REVIEW.md 等のディレクトリ別) を付けて振り分け、配置先ごとにそのまま追記できる断片ファイル (review-md/) も出力する。バグ修正PR (fix型title / bugラベル / revert 等で検知) の修正diffも抽出源にし、コメントの付かない hotfix からも再発防止のレビュー観点を抽出する。取り込み判定の信号収集はスクリプト、最終的な採否分類とクラスタリングと配置先決定は AI が行う。本 skill は read-only で、REVIEW.md の編集や PR 作成は行わない。収集スクリプトが gh CLI に依存するため gh チャネル専用 (gh の GraphQL が使えない web/remote セッション等では動かない)。
---

# distill-pr-reviews skill

過去 merged PR のレビューコメントから「REVIEW.md に蓄積する価値のある指摘」を抽出する skill。
出力 (`proposals.md` + 配置先ごとの `review-md/` 断片) を後工程 (人間 or 別 skill) が読んで REVIEW.md 編集 PR を作る、という運用を想定している。

REVIEW.md を読むのは `compose-review` のレビュアー (LLM) で、null チェック・エラーハンドリング・分かりやすい命名・セキュリティ一般のような **一般的なレビュー観点は REVIEW.md が無くても指摘する**。REVIEW.md の価値は **差分だけからは分からない、このリポジトリ固有の知識** (ドメインの不変条件 / アーキテクチャ・モジュール境界の約束事 / 社内 API や共通モジュールの落とし穴 / 命名・用語の規約 / 運用上の制約 等) にある。そこで本 skill は一般的な観点の重要度を下げ (出典から固有の文脈を読み取れなければ採用しない)、プロジェクト固有の観点を重点的に抽出する (Step 2 判断軸 1)。

`compose-review` は **変更ファイルの祖先ディレクトリにある `REVIEW.md`** を root → 親 → 子の順に読み、それぞれの配下にだけ適用する (monorepo 向けのディレクトリ別方針)。本 skill もこれに追従し、各候補を **可能な限りディレクトリ別の REVIEW.md に振り分ける** (root は「リポジトリ横断で成立するルール」だけに絞る)。

**本 skill のスコープは proposals.md + `review-md/` 断片の出力で停止する。** REVIEW.md の編集 / commit / push / PR 作成は一切行わない。断片は `OUTPUT_DIR` 配下に書き出すだけで、リポジトリ内の REVIEW.md は作成も編集もしない。
状態管理ファイルは持たず、毎回期間引数を渡す方式 (運用がシンプルで監査性が高い)。

**本 skill は gh チャネル専用**: 収集ロジックが bash スクリプト (`scripts/collect-signals.sh`) にあり bash からは GitHub MCP ツールを呼べないため、`gh` CLI が使えない環境では実行できない。PR 一覧 (`gh pr list`) と PR 詳細の取得が GraphQL なので、gh の REST は通るが GraphQL が 403 になる Claude Code のクラウドセッション (web / remote) でも実行できない。その場合はエラーとして caller に報告して停止する。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `OWNER` / `REPO`: 対象リポジトリ。省略時は `gh repo view --json nameWithOwner -q .nameWithOwner` で cwd の git リポジトリから自動推定する。ドッグフーディング時の取り違え防止のため明示推奨。
- `SINCE` / `UNTIL`: merged at で絞る期間 (`YYYY-MM-DD` 形式、UTC)。`SINCE` 省略時は `UNTIL - DAYS`、`UNTIL` 省略時は今日 (UTC) を使う。両方省略時は「過去 `DAYS` 日」になる。
- `DAYS`: `SINCE` 未指定時のフォールバック期間 (日数)。省略時 `7`。`SINCE` が指定されていれば無視される。
- `MAX_PRS`: 期間内 PR 数の上限警告閾値。省略時 `100`。超過しても処理は継続し、proposals.md 冒頭に「対象 PR が多いため信号品質が低下している可能性あり」を明記する。
- `MAX_BUGFIX_DIFFS`: バグ修正PR (`pr_kind=bugfix`) の diff を取得する上限件数。省略時 `30`。バグ修正PRはレビューをすり抜けたバグの証拠であり、その修正 diff から再発防止のレビュー観点を抽出する。コスト抑制のため subset 限定 + 件数上限で取得し、超過分は新しい順に打ち切って `meta.bugfix_diffs_truncated` に記録する。
- `FILTER_AUTHOR`: PR 作成者で絞り込む (例: `dependabot[bot]` を除外したい場合は `-author:dependabot[bot]` 形式で渡す)。省略時はフィルタなし。`gh pr list --search` の検索式にそのまま連結する。
- `FILTER_LABEL`: PR ラベルで絞り込む (例: `label:bug`)。省略時はフィルタなし。同上、`--search` に連結する。
- `INCLUDE_AI_AUTHORED`: `> **[AI 自動投稿]**` プレフィックス付きのコメントを採否候補に含めるか。省略時 `true`。`false` の場合でも信号 (`is_ai_authored`) は付与するが、Phase C で AI が一律 reject に倒す。値は `true` / `false` を推奨するが、scripts/collect-signals.sh では大文字小文字 / 周辺空白を正規化し `1` / `yes` / `y` / `0` / `no` / `n` も受け入れる (それ以外は `exit 2`)。
- `OUTPUT_DIR`: 出力先ディレクトリ。省略時は `/tmp/distill-pr-reviews/{repo}/{timestamp}` (例: `/tmp/distill-pr-reviews/skills/20260524T120000Z`)。caller が明示パスを指定した場合は既存ファイルがあれば上書きする。**リポジトリの作業ツリー外を指定すること** — Step 3.5 が `review-md/**/REVIEW.md` という実ファイル名の断片を書くため、リポジトリ配下に出すと `compose-review` の祖先 `REVIEW.md` 探索や次回蒸留の既存パス一覧に混入する。**リポジトリ配下のパスが渡された場合は `scripts/collect-signals.sh` が既定の `/tmp` 配下へ機械的に差し替える** (入力仕様に書くだけでは誰も実行しないため、`OUTPUT_DIR` を確定するスクリプト側で弾く)。差し替えた回は stderr WARNING に加え `meta.output_dir_relocated=true` が立つので、Step 4 の caller 報告に 1 行添える。
  - `{repo}`: `OWNER/REPO` の `REPO` 部分 (取得失敗時は `local`)
  - `{timestamp}`: `date -u +%Y%m%dT%H%M%SZ` の出力

明示的に持たない引数:

- DRY-RUN フラグ: 本 skill はそもそも GitHub 投稿 / PR 作成を一切行わないため不要 (常に dry-run 相当)。
- 状態ファイルパス: 状態管理しない方針なので持たない。
- 出力 PR ブランチ名 / commit message: 本 skill は PR を作らないため不要。

## 既存スキルとの違い / 棲み分け

- `run-pr-review` / `post-pr-review` / `resolve-pr-threads` / `run-local-review` はいずれも **単一の進行中 PR ライフサイクル** が対象。本 skill は **過去 merged PR 群** からの横断的な学習材料抽出が対象。
- 依存関係なし: 本 skill から他 skill は呼ばない。他 skill も本 skill に依存しない。
- `/pr-review-style-reference` の severity ラベル定義 (`[must]` / `[should]` / `[nit]` / `[question]` / `[pre_existing]`) は Phase B / C で参照する。本 skill では再掲しない (二重管理を避けるため)。
- 既存 `REVIEW.md` の **中身は読まない** (それは `compose-review` Step 3 の役割)。本 skill は「REVIEW.md を育てるための候補ファイル」を出すだけで、既存内容との重複判定は AI が proposals.md 内に「重複可能性あり」フラグとして残す形に留める。ただし **配置 (パス一覧) だけ** は収集スクリプトが取得し (`meta.existing_review_md_paths`)、配置先を既存の階層に寄せるために使う。
- 配置先の粒度規約は `compose-review` Step 3「ディレクトリ別方針 (monorepo 向け)」に従う (各 `REVIEW.md` はそのディレクトリ配下にだけ適用される / `node_modules/` `vendor/` 配下は読まれない / 1 ファイルに適用される祖先 `REVIEW.md` は 10 個程度が目安)。本 skill は **どこに置くかを提案するだけ** で、実際の適用は `compose-review` の責務。
- 対象は **merged PR のみ**。open / closed unmerged は対象外 (取り込み判定が安定しないため)。

## 設計上の主要トレードオフ

1. **PR 一覧は `gh pr list`、PR 詳細 (reviewThreads + commits + files) は GraphQL 統合クエリ**: `gh pr list --search` がページング込みで便利 (内部は GraphQL の search)。PR 詳細は 1 PR = 1 GraphQL query にまとめて取得することで、API rate limit (graphql 5000/h / core 5000/h) を実質ほぼ消費しない構造にする (1 PR = graphql 1 query)。
2. **commit 別 files は持たず、PR 全体 files で代用**: commit ごとの変更ファイルを REST `commits/{sha}` で引くと commit 数 × 1 query になり core 枠の rate limit に達するため、PR 全体の変更ファイル一覧 (GraphQL `pullRequest.files`) だけを取得する。そのため `file_changed_after_comment` は「PR 全体 files に該当 path を含み、かつコメント以降に commit がある」で判定し、コメント前の commit だけで完結した変更も true になる (偽陽性あり)。この偽陽性は Phase C の AI が body + diff_hunk を読んで最終判断する。
3. **reactions は取得しない**: reaction が付くコメントは稀で信号価値が低く、取得すると GraphQL の 500k ノード上限を圧迫するため。その分のノード予算は 1 PR 1 query への統合に使う。
4. **信号スコア合算を script でなく AI に委ねる**: 信号は文脈依存 (例: `is_outdated=true` 単独は「修正された」か「単に行ズレした」かの判別不能) で、機械合算するとノイズが大きい。`signals.json` には raw のまま付与し、Phase C の AI が総合判断する。
5. **クラスタリングは Phase C (AI)**: 意味類似度判定が bash/jq では困難なため。Phase B では `path` ベースの「同一ファイル指摘」フラグだけ立てる。
6. **採否は三値 (`accept` / `hold` / `reject`)**: 二値だと判断不能ケースが reject に流れて将来の蓄積機会を失う。迷ったら `hold` (`resolve-pr-threads` の保守的ルールと同思想)。
7. **REVIEW.md 既存内容との重複判定は本 skill ではしない**: 後続フロー (REVIEW.md 編集) との責務分離を保つ。AI は proposals.md に「重複可能性あり」フラグだけ立てる。
8. **バグ修正PR を検知し、その diff も抽出源にする**: バグ修正PRはレビューをすり抜けたバグの証拠であり、その修正 diff からバグを生んだリポジトリ固有の性質 (API の仕様 / データの状態 / モジュールの約束事) を読み取れば再発防止のレビュー観点になる。検知 (`pr_kind` / `bugfix_signals`) は既取得の title / commit / labels から追加 API コールなしで行い、diff のみ `pr_kind=bugfix` の subset に限定して `gh pr diff` (1 PR = 1 コール) で取得する。commit ごとに叩く REST `commits/{sha}` (commit 数 × 1 query) と違い subset 限定 + `MAX_BUGFIX_DIFFS` 件 + `DIFF_CHAR_CAP` 文字で抑えるため rate limit 影響は限定的。`is_revert` は本番に出荷されたバグの差し戻しで最も強い信号。検知は OR の粗いフィルタで false positive (例: 本体は refactor だが fix commit が混ざった PR) を許容し、観点を起こせるかの最終判断は Phase C/D の AI が diff を読んで行う。
9. **決定論的な Phase A + B (PR 一覧取得 / GraphQL / 信号付与) は bash + jq スクリプトに切り出す**: `scripts/collect-signals.sh` が `signals.json` を出力するまでを担い、AI (Phase C+D) は signals.json を読んで `proposals.md` を書き出す責務に集中する。スクリプト化のメリットは挙動の再現性と AI 側プロンプトの圧縮で、デメリットは信号定義を変えたい場合に SKILL.md + スクリプト両方を編集する必要がある点 (signals.json のスキーマを変えると Phase C の AI 解釈もズレるため、両者は本 SKILL.md の `signals.json` スキーマ定義で同期させる)。
10. **配置先 REVIEW.md の決定は Phase C の AI が行い、スクリプトは既存パス一覧だけを渡す**: 出典パスの最長共通ディレクトリ (LCD) は機械計算できるが、「そのルールがどの範囲で成立するか」(web 全体なのか auth だけなのか、リポジトリ横断なのか) は意味判断なので AI に委ねる。スクリプトは `meta.existing_review_md_paths` を渡すだけ。既存階層に寄せるのは、新規 `REVIEW.md` ファイルの乱立を避け、1 ファイルに適用される祖先 `REVIEW.md` 数 (`compose-review` の 10 個目安) を無駄に増やさないため。root を「横断ルールだけ」に絞るのは、root に何でも積むと monorepo の全パッケージに無関係な観点が効いてしまうためで、これがディレクトリ別分割の動機そのもの。
11. **一般的なレビュー観点は採用せず、プロジェクト固有の観点に絞る**: REVIEW.md は `compose-review` のレビュアー (LLM) のコンテキストに毎回載る。レビュアーが元から指摘する一般的な観点を積んでもレビュー結果はほぼ変わらず、プロンプトが長くなって固有の観点への注意が分散するだけになる。そこで一般的な観点は、出典に「このリポジトリでなぜ破られるか」を示す固有の事実があれば、それを主語に書き直し (固有化)、無ければ `accept` にしない。ただし捨てはせず、`[汎用観点]` 付きの保留 / 棄却として proposals.md に残す (規則は Step 2 判断軸 1。このリポジトリで繰り返し破られている一般原則は、人間が見れば固有の文脈を補えることがあるため。判断履歴としても監査できる)。固有性の判定は意味判断なのでスクリプトでなく Phase C の AI が行い、`signals.json` のスキーマは変えない。

## 手順

### Step 1. 信号収集スクリプトを呼ぶ (Phase A + B)

決定論的な処理 (入力正規化 → `gh pr list` → PR 単位の GraphQL 統合クエリ → 信号付与) は本 skill 配下の `scripts/collect-signals.sh` (bash + jq) に集約してある。本 step では **このスクリプトを Bash ツールから呼ぶだけ**。AI が同等処理を逐次実行しない (差異が出ないように)。

#### 呼び出し方

スクリプトの絶対パスは **本 SKILL.md と同じディレクトリの `scripts/collect-signals.sh`** で解決する。skill 起動時に渡される SKILL.md の絶対パスから dirname を取って `<dirname>/scripts/collect-signals.sh` を組み立てれば、開発時 (`plugins/pr-review/skills/distill-pr-reviews/`)・`/plugin install` 後 (`~/.claude/plugins/cache/.../skills/distill-pr-reviews/`)・`apm install` 後 (`<consumer>/.claude/skills/distill-pr-reviews/`) のいずれの展開先でも一意に解決できる。

caller から渡された入力は **環境変数として透過的にスクリプトへ転送する**。スクリプト側で正規化 (`OWNER` / `REPO` 自動推定、`SINCE` / `UNTIL` 計算、`OUTPUT_DIR` 確定) を行うので、本 step では caller 入力をそのまま env に詰めて呼ぶ。

```bash
OWNER="${OWNER:-}" REPO="${REPO:-}" \
SINCE="${SINCE:-}" UNTIL="${UNTIL:-}" DAYS="${DAYS:-7}" \
MAX_PRS="${MAX_PRS:-100}" MAX_BUGFIX_DIFFS="${MAX_BUGFIX_DIFFS:-30}" \
FILTER_AUTHOR="${FILTER_AUTHOR:-}" FILTER_LABEL="${FILTER_LABEL:-}" \
INCLUDE_AI_AUTHORED="${INCLUDE_AI_AUTHORED:-true}" \
OUTPUT_DIR="${OUTPUT_DIR:-}" \
  bash "<SKILL.md と同じディレクトリ>/scripts/collect-signals.sh"
```

スクリプトは **bash 3.2 (macOS 標準の `/bin/bash`) 互換**で書いてあるため、bash を新しく入れ直さなくても手元の macOS でそのまま実行できる (`gh` / `jq` は別途必要)。スクリプトを編集する際は本体冒頭の「bash 互換要件」コメントに従う。

スクリプトは進捗を stderr に、`signals.json` の絶対パスを stdout 最終行に出す。非 0 で exit したらエラー停止して caller に報告 (主要原因: `gh` 未認証 / gh の GraphQL が 403 で遮断されている (Claude Code のクラウドセッション) / git リポジトリ外実行 / GraphQL ノード上限超過 / GitHub API rate limit 到達)。期間内 0 件でも exit 0 で `signals.json` (空状態) を出す。

#### スクリプトの責務 (詳細は `scripts/collect-signals.sh` の本体コメント参照)

- **Step 1-1. 入力正規化**: `OWNER` / `REPO` を `gh repo view` で auto-detect、`UNTIL` は今日 (UTC)、`SINCE` は `UNTIL - DAYS` (GNU/BSD `date` 両対応)、`OUTPUT_DIR` を確定し `mkdir -p`。**`OUTPUT_DIR` がリポジトリ作業ツリー配下なら既定の `/tmp` 配下へ差し替え** (`git rev-parse --show-toplevel` と `pwd -P` で解決して比較。git リポジトリ外なら判定不能なので caller 指定を尊重)、`meta.output_dir_relocated=true` + stderr WARNING で知らせる。
- **Step 1-1.5. 既存 `REVIEW.md` の配置取得**: default branch を **commit SHA に解決してから** (`gh api repos/{owner}/{repo}/git/ref/heads/{branch}` → `.object.sha`。ブランチ名を URL パスに直接埋めると `release/main` のようなスラッシュ入り名で常に 404 になるため) tree (`gh api repos/{owner}/{repo}/git/trees/{sha}?recursive=1`) を引き、そこから **パスが `REVIEW.md` で終わる blob だけ** を抽出し `_existing_review_md.json` に書き出す (`node_modules/` / `vendor/` 配下は除外。`compose-review` がそこを読まないため配置先候補にもしない)。**中身は読まない** — Step 2 の配置先決定 (2-1 の判断軸 9) で「既存の階層に寄せる」ための入力。gh コールは PR 数に依存しない固定 3 回 (`gh repo view` + `gh api git/ref` + `gh api git/trees`)。取得失敗は `existing_review_md_paths=null` + stderr WARNING で可視化し (「0 件」と区別する。**gh の stderr 先頭 1 行を WARNING に載せる**ので 404 / rate limit / 権限不足を切り分けられる)、処理は継続する。tree API の `truncated` は `existing_review_md_truncated` に転記する。
- **Step 1-2. PR 一覧取得**: `gh pr list --search "merged:${SINCE}..${UNTIL} <filters>" --json ...` で取得し `_pr_list.json` に書き出す。`--state merged` は付けない (`merged:` 検索フィルタと重複するため)。`--limit` は `MAX_PRS + 100` で超過判定できる余裕を持たせる。0 件なら空 `signals.json` を出して即終了。
- **Step 1-3. PR 詳細 (GraphQL 統合クエリ)**: PR ごとに **1 GraphQL query** で `reviewThreads(first: 50) × comments(first: 50)` + `commits(first: 100)` + `files(first: 100)` を一括取得する。reviewThreads が 50 件超の PR は `$tafter` カーソルで追加クエリ。1 thread の comments が 50 件超の場合のみ `node(id: $threadId)` + inline fragment の追加クエリで埋める (初回クエリの内側 `comments(first: 50)` に `$cafter` を持たせると外側全ノードに同 cursor が適用されて壊れるため、内側ページングは別クエリ)。1 query あたりのノード試算は 50×50 + 100 + 100 ≈ 2,700 で GraphQL の 500,000 ノード制限に対し十分小さい。PR 数 > 50 のときは PR 間で 1 秒 sleep。
  - **rate limit 設計**: 1 PR = graphql 1 query が基本ケース。69 PR でも 70 query 前後で済み、graphql 枠 5000/h の 1〜2% しか使わない。REST `pulls/{N}/commits` および `commits/{sha}` は使わない (PR の commit 一覧と PR 全体の変更ファイルは上記の GraphQL クエリで取る。commit ごとの変更ファイルを `commits/{sha}` で引くと commit 数 × 1 query になり core 枠の rate limit に達するので、取得せずに近似する。「設計上の主要トレードオフ」2)。
  - **truncate 警告**: `files` / `commits` の `pageInfo.hasNextPage=true` (100 件超) の PR では `files_truncated` / `commits_truncated` を true にし、stderr に WARNING を出す。後段の `file_changed_after_comment` が偽陰性に倒れうる旨を Phase C の AI 判定に渡す。
- **Step 1-4. `prs.json` 組み立て + バグ修正検知**: Step 1-3 で書き出した PR ごとの中間レコード (`_pr_data.jsonl`) を `_pr_list.json` (PR メタ) と join し、各 PR に `bugfix_signals` (title / commit headline / labels / revert / keyword から jq で判定。追加 API コールなし) と `pr_kind` を付与した上で、以下の TypeScript ライクなスキーマで `${OUTPUT_DIR}/prs.json` に書き出す。
- **Step 1-5. バグ修正PR の diff 取得**: `pr_kind=bugfix` の PR に限定して `gh pr diff <N>` (1 PR = 1 コール) で unified diff を取得し `prs.json` の `bugfix_diff` にマージする。新しい順 (`merged_at` 降順に明示ソート。`gh pr list --search` の並び順は保証されないため) に `MAX_BUGFIX_DIFFS` 件まで、1 件あたり `DIFF_CHAR_CAP` (20000) 文字で truncate。上限超過は `meta.bugfix_diffs_truncated=true` + stderr WARNING で記録し、`gh pr diff` の取得失敗も空 diff と混同せず `bugfix_diff=null` のまま + stderr WARNING で可視化する (silent truncation / silent failure を避ける)。subset 限定 + 件数 / サイズ上限で core 枠への影響を抑える。

  ```ts
  type Collected = {
    meta: {
      owner: string; repo: string;
      since: string;        // YYYY-MM-DD
      until: string;        // YYYY-MM-DD
      collected_at: string; // ISO8601 UTC
      pr_count: number;
      max_prs_exceeded: boolean;
      include_ai_authored: boolean;  // caller 入力 INCLUDE_AI_AUTHORED の値をそのまま転記
      bugfix_pr_count: number;       // pr_kind=bugfix と判定された PR 数
      bugfix_diffs_truncated: boolean; // bugfix PR 数が MAX_BUGFIX_DIFFS を超え、一部の diff を未取得で打ち切ったか
      existing_review_md_paths: string[] | null; // default branch 上の既存 REVIEW.md (root 相対パス, sort 済み)。
                                     // node_modules/ vendor/ 配下は除外。`null` は取得失敗 (0 件は `[]`)。
                                     // **中身は含まない** (Step 2 の配置先決定でパスだけを使う)
      existing_review_md_truncated: boolean; // git/trees API の truncated フラグ。true なら一覧が不完全
      output_dir_relocated: boolean; // caller 指定の OUTPUT_DIR がリポジトリ作業ツリー配下だったため
                                     // 既定の /tmp 配下へ差し替えたか (Step 1-1)
    };
    prs: {
      number: number; title: string; author: string;
      merged_at: string; head_sha: string; merge_commit_sha: string | null;
      base_ref: string; head_ref: string; labels: string[]; url: string;
      pr_kind: "bugfix" | "other";    // bugfix_signals のいずれかが true なら "bugfix" (検知の OR)。確信度の最終判断は Phase C の AI
      bugfix_signals: {               // バグ修正検知の raw シグナル。機械合算しない (Phase C が総合判断)
        title_type_fix: boolean;      // title が `<scope> fix:` / `fix:` / `fix(scope):` にマッチ
        commit_type_fix: boolean;     // いずれかの commit message_headline が fix 型トークンを含む
        label_bug: boolean;           // labels に bug / bugfix / hotfix / regression / 不具合 / 障害
        is_revert: boolean;           // title に revert を含む (本番に出荷されたバグの差し戻し = 強信号)
        title_keyword: boolean;       // title に hotfix / regression / バグ / 不具合 / 障害
      };
      bugfix_diff: string | null;     // pr_kind=bugfix のみ `gh pr diff` で取得した unified diff (DIFF_CHAR_CAP=20000 文字で truncate)。other / 件数上限超過分 / 取得失敗時は null
      bugfix_diff_truncated: boolean; // diff が DIFF_CHAR_CAP を超えて切り詰められたか
      files: string[];                // PR 全体で変更されたファイル一覧 (GraphQL `pullRequest.files`)
      files_truncated: boolean;       // true なら 100 件超で取りこぼしあり (file_changed_after_comment が偽陰性に倒れる可能性)
      commits_truncated: boolean;     // true なら 100 件超 commit があり後半 commit が取れていない
      commits: {
        sha: string; committed_at: string; message_headline: string;
        // commit 別の変更ファイルは持たない (信号判定は PR 全体の `files` + コメント以降の `commits[].committed_at` で行う)。
      }[];
      review_threads: {
        thread_id: string;
        is_resolved: boolean; is_outdated: boolean;
        comments: {
          id: string;
          author_login: string;
          author_type: "User" | "Bot" | "Unknown";  // GraphQL author.__typename を転記。GitHub App / installation bot は "Bot" (gemini-code-assist / copilot-pull-request-reviewer / coderabbitai / dependabot[bot] 等)、通常アカウントは "User"、author=null (削除済みアカウント) は "Unknown"。ごく稀に User account で運用される AI レビュー bot があり得るため、Phase C の AI は author_type に加えて author_login の文字列パターン (例: `*-code-assist`, `*-reviewer`, `copilot-*`, `coderabbit*`) でも補完判定する
          body: string; created_at: string;
          path: string; line: number | null; original_line: number | null;
          diff_hunk: string; url: string;
          is_ai_authored: boolean;  // body 先頭 `^> \*\*\[AI 自動投稿\]\*\*` の test 結果
        }[];
      }[];
    }[];
  };
  ```

- **Step 1-6. 信号付与 → `signals.json`**: `prs.json` の各コメントオブジェクトに `signals` フィールドを追加した同形 JSON を `${OUTPUT_DIR}/signals.json` に書き出す (PR レベルの `pr_kind` / `bugfix_signals` / `bugfix_diff` はそのまま透過する)。**機械的なスコア合算はしない**。各信号は文脈依存で、Phase C の AI が組み合わせを見て総合判断するため。

  各信号の意味 (`signals` フィールド配下):

  - `thread_resolved`: 親スレッドの `is_resolved`
  - `thread_outdated`: 親スレッドの `is_outdated`
  - `file_changed_after_comment`: PR 全体の `files` に当該コメントの `path` が含まれており、**かつ**当該コメントの `created_at` より後に committed された commit が PR に少なくとも 1 つあるか (boolean)。コメント前の commit だけで完結した変更も true になる (偽陽性あり。理由は「設計上の主要トレードオフ」2)。最終判断は Phase C の AI が body + diff_hunk を読んで行う
  - `author_replied_affirmative`: 同一スレッドの後続コメントのうち `author_login == PR.author` のものが **肯定キーワード (`fixed` / `対応` / `修正` / `反映` / `確かに` / `その通り` / `done` / `addressed`) を body に含み、かつ否定キーワード (`対応しません` / `対応しない` / `対応せず` / `修正しません` / `修正しない` / `修正せず` / `反映しません` / `反映しない` / `反映せず` / `現状維持` / `不採用` / `不要です` / `wontfix` / `wont fix` / `not addressed` / `not fixed`) を body に含まない** か。否定キーワードは「動詞 + 否定形」または慣用句で十分な長さを持たせ、肯定キーワード (`対応` 等) との部分文字列ぶつかりと、肯定文脈で偶発的に出現する語 (例: `そのまま` 単独) との衝突を回避する。残る誤検出は許容 (Phase C の AI が body 全文を見て最終判断)
  - `severity_label`: body 内の `[must]` / `[should]` / `[nit]` / `[question]` / `[pre_existing]` を正規表現で抽出 (**body の引用行 (`> ` で始まる行) を除いた残りに対する最初のマッチを採用する仕様**、なければ `null`)。引用行を除外することで他コメントの再掲や post-pr-review マーカー直後の引用 quote で誤って severity を拾うのを防ぐ。AI 自動投稿マーカー `> **[AI 自動投稿]**` 自体は capture group の選択肢に無いため自然に skip される。body 内に複数のラベルが書かれているケース (例:「これは本来 `[must]` レベルだが本 PR では `[should]` に留める」) では最初に出てきたラベルが拾われるため、Phase C の AI は判定根拠に severity を使う際に body 全文も読んで矛盾検知すること
  - `is_ai_authored`: コメント本体の `is_ai_authored` フラグをそのまま転記
  - `author_type`: コメント本体の `author_type` (`User` / `Bot` / `Unknown`) をそのまま転記。`is_ai_authored=false` でも `author_type=Bot` なら「post-pr-review 以外の bot 経由 (例: GitHub App として登録された PR レビュー bot)」のシグナル。User account 運用の AI レビュー bot (gemini-code-assist 等) は `User` 側に分類されるため、Phase C の AI が author_login の文字列パターン (例: `*-code-assist`, `*-reviewer`, `copilot-*` 等) で補完判定する
  - `reply_count`: スレッド内コメント数 - 1
  - `comment_length`: body の文字数
  - `same_file_in_pr`: 同じ PR 内で **別 thread** に同じ `path` への指摘があるか (boolean)。同一 thread 内の reply は 1 指摘として 1 回だけカウントする (各 thread の冒頭コメントの `path` のみを集計対象にする)

  `signals` やコメントオブジェクトに上記・スキーマ以外のキーがあっても (古い版のスクリプトで生成した `signals.json` / `prs.json` に残る `reactions` / `reactions_positive` / `reactions_negative` 等)、Phase C の判定には使わない。

  クラスタリング (PR をまたいだ類似指摘の検出) は Phase C で AI が行うため、本 step では行わない。

#### スクリプト出力の取り扱い

- 中間ファイル (`_existing_review_md.json` / `_existing_review_md.err` (取得失敗時のみ) / `_pr_list.json` / `_pr_data.jsonl` / `prs.json`) は `${OUTPUT_DIR}` に残す。Phase C で AI が判定をやり直したい場合の入力として再利用できる。
- 後段 (Step 2) で AI が読むのは `signals.json` のみ。中間ファイルは AI からは触らない。
- 0 PR の場合の `signals.json` は `meta.pr_count = 0` / `prs: []` の空状態。Step 2 / Step 3 で「該当なし」分岐に倒す。

### Step 2. AI による採否判定 (Phase C)

`signals.json` を読み、各コメントを `accept` / `hold` / `reject` に分類し、採用候補には REVIEW.md に書く提案文と **配置先 REVIEW.md** を決める。判定は AI 自身が行う (本セクションは AI への指示)。

#### 2-1. 採否判断軸

以下を総合して判定する:

1. **プロジェクト固有性 (最重要)**

   REVIEW.md の価値は「差分だけからは分からない、このリポジトリ固有の知識」にある (冒頭と「設計上の主要トレードオフ」11 参照)。各候補を次の順で見る。一般的な観点の扱いを定めるのはこの判断軸だけで、他の箇所はここを参照する:

   1. **固有性で分ける**:
      - `project`: このリポジトリを知らないと言えない観点。ドメインの不変条件・業務ルール / アーキテクチャ・層・モジュール境界の約束事 / 社内 API・共通モジュール・ラッパーの使い方と落とし穴 (「この関数はこの条件で null を返す」「時刻は必ずこのヘルパー経由で扱う」等) / 命名・用語・ディレクトリ構成・テスト配置の規約 / コミット・PR の規約 / 採用ライブラリ・フレームワークの **このリポジトリでの** 使い方 (バージョン・設定・独自の制約) / 運用・デプロイ・互換性の制約 / 過去障害から得た再発防止条件 など。
      - `general`: 一般的なレビュアーなら REVIEW.md が無くても指摘する観点。null / 境界値チェック、エラーハンドリング一般、分かりやすい命名、重複の排除、テストを足す、SQL インジェクション・XSS などのセキュリティ一般、typo、言語やライブラリの一般的なベストプラクティス など。
      - 見分け方: **このリポジトリを知らないレビュアーが、同じ差分を見て同じ指摘をするか**。するなら `general`、このリポジトリの規約・仕様・経緯を知って初めて言えるなら `project`。規約が他のリポジトリにもありうる形 (Conventional Commits 等) でも、このリポジトリが選んだ約束事で、知らないレビュアーが指摘しないなら `project`。提案文にパスや固有名詞が入っているかどうかでは判定しない。
   2. **`general` は固有化を試みる**: 出典の body / 返信 / diff_hunk / バグ修正 diff に、その一般原則がこのリポジトリで **なぜ** 破られたかを示す固有の事実 (特定の関数が null を返す条件、特定 API のページ番号が 1 始まり、等) が書かれていれば、その事実を主語にした提案文に書き直して `project` として扱う。**場所 (パス / ディレクトリ) を付けただけでは固有化にならない** (「`apps/api/` では null チェックが漏れがち」は、知らないレビュアーでも同じ指摘をするので `general` のまま)。**出典に書かれていない固有名詞や条件を推測で補ってはならない** (もっともらしいが誤ったルールが REVIEW.md に入るため)。
   3. **再利用可能性を確かめる**: 固有化した後の文面で、このリポジトリの他 PR にも効くかを判定する。この PR 限定のロジック誤り、特定 issue のリグレッション、ファイル固有の名前付け修正、削除予定のコードにしか当てはまらない事実など、一回限りの話は `reject`。
   4. **`project` を重点的に抽出する**: 再利用できる `project` は以降の判断軸で採否を決める。severity が低くても採用候補になりうる (判断軸 3)。
   5. **固有化できない `general` は重要度を下げ、`accept` にしない**。上から順に決める:
      - 先に他の理由で `reject` が決まるもの (手順 3 の再利用不能 / 判断軸 3 の `[pre_existing]` と答えの無い `[question]` / 判断軸 4 の `INCLUDE_AI_AUTHORED=false`) はそれに従い、`[汎用観点]` は付けない (降格件数に数えない)。判断軸 4 の「reject 寄り」のような加減点はこれに含まない。
      - `project` か `general` か判断に迷う場合と、出典が途中までしか無く固有の文脈の有無を断定できない場合 (`bugfix_diff_truncated=true` 等) は `hold` (判断軸 10)。`reason` には判断を保留した理由を書く。
      - 3 PR 以上で同主旨が繰り返され、そのうち少なくとも 1 件が取り込まれているクラスタは `hold` (このリポジトリで繰り返し破られている弱点の可能性があり、人間なら固有の文脈を補えることがあるため)。取り込みは、レビューコメント由来なら判断軸 2 の `thread_resolved` / `file_changed_after_comment` / `author_replied_affirmative` のいずれか、`source=bugfix-diff` なら修正がマージされていること自体で判定する。ただし `[nit]` (typo・一般的な命名・好み寄りの書き方など) は、繰り返されていても `reject` (固有の文脈を足しようが無く、保留に積むとノイズになるため)。
      - それ以外は `reject` (どれも取り込まれていない繰り返しは、bot が同じ指摘を出し続けて無視されただけの可能性がある)。
      - この手順で `hold` / `reject` にしたものは、すべて `reason` の先頭に `[汎用観点]` を付ける (他のフラグと併記するときも常に先頭に置く。proposals.md の「汎用観点として降格」の件数はこのフラグで数える)。判断軸 2〜8 の `accept` 寄り / `hold` 寄りの規則 (取り込みシグナル不明 → `hold`、重複可能性 → `hold` 等) は適用しない。`[汎用観点]` の `hold` は配置先を付けず (判断軸 9-6)、`proposal_text` は一般原則のまま書く (2-2)。

2. **取り込みステータス**
   - `thread_resolved=true` かつ `file_changed_after_comment=true`: 強い「取り込まれた」シグナル → accept 寄り。
   - `thread_resolved=true` のみ: 中 (resolve が「対応」とは限らないため)。
   - `thread_outdated=true` のみ: 弱 (行ズレの可能性)。
   - `author_replied_affirmative=true`: 加点。
   - どれも該当せず未 resolved: 「不明」→ `hold`。

3. **severity**
   - `[must]` / `[should]`: 採用優先。
   - `[nit]` / `[question]`: `general` なら判断軸 1 の降格に従う。命名・用語・ディレクトリ構成などの **このリポジトリの規約** を示す `project` の nit は、REVIEW.md が無いとレビュアーが守らせられない知識なので、severity が低いことだけを理由に棄却せず、他の判断軸と同じ基準で評価する。ただし **個人の好みは規約ではない**: 規約として扱うのは、出典が規約・合意に言及している (「このリポジトリでは X に統一している」等) か、複数のレビュアーが同じ指摘をしている場合だけ。1 人のレビュアーが 1 回付けただけの好み寄りの nit は `general`、1 人のレビュアーだけが複数 PR で繰り返している nit は規約か好みかを決められないので判断に迷う場合として扱う (どちらも判断軸 1 の手順 5)。question は、スレッドの返信で設計意図・不変条件が明かされた場合だけ、明かされた内容を判断軸 1 で評価する (このリポジトリ固有の知識なら `project`、一般論なら `general`)。問うだけで答えが無い question は、提案文を推測で書くことになるので棄却。
   - `[pre_existing]`: 棄却 (本 PR の指針というより別 issue 化推奨)。
   - severity ラベルなし: body の内容から severity を推定 (推定ラベルは `severity_suggestion` に明示)。

4. **AI / bot 由来コメントの扱い**
   本 skill の `is_ai_authored=true` は **post-pr-review skill 経由で投稿された (`> **[AI 自動投稿]**` マーカー付き) コメント** のみを指す。それ以外の bot や外部 AI レビュー bot (gemini-code-assist / copilot-pull-request-reviewer / dependabot[bot] 等) は本フラグでは識別されないため、以下の補完信号を組み合わせて判定する:

   - `is_ai_authored=true`: post-pr-review 由来の AI 投稿。`thread_resolved=true` + `file_changed_after_comment=true` なら強信号で accept 寄り。未 resolved / `thread_outdated` のみなら弱信号で reject 寄り (ただし内容が明らかに再利用可能な `project` の観点なら `hold`)。
   - `author_type="Bot"` (`is_ai_authored=false`): GitHub App / installation 形式の bot 由来。主要な外部 AI レビュー bot (`gemini-code-assist`, `copilot-pull-request-reviewer`, `coderabbitai`) や `dependabot[bot]` はここに分類される。レビュー指摘である保証はないため body の内容で判定する。AI レビュー bot の指摘が `thread_resolved=true` + `file_changed_after_comment=true` ならやはり強信号で accept 寄り、未 resolved なら reject 寄り、という post-pr-review 由来 (`is_ai_authored=true`) と同じ評価軸を適用する。
   - `author_type="User"` だが `author_login` が AI レビュー bot のパターン (例: `*-code-assist`, `*-reviewer`, `copilot-*`, `coderabbit*`): ごく稀に User account として運用されている AI レビュー bot の可能性。指摘内容の妥当性を AI が body で判断する。
   - **`INCLUDE_AI_AUTHORED=false` の場合は `is_ai_authored=true` のコメントのみを一律 `reject`** (棄却理由に「AI 自動投稿を対象外として除外」と明示)。本値は `signals.json` の `meta.include_ai_authored` から取得する。**外部 AI レビュー bot 由来 (author_type=Bot / login パターン一致) のコメントはこのフラグでは除外されない** (制御対象は本 skill のスコープ内である post-pr-review 由来のみ、という設計)。caller が外部 bot も一括除外したい場合は `FILTER_AUTHOR=-author:...` を `gh pr list` 側で渡す運用にする。

5. **クラスタリング (PR 横断)**
   - 類似テーマが複数 PR で出ていたら 1 つの proposal にまとめ、`sources[]` に PR URL を集約する。
   - クラスタ ID は連番 (`cluster-001` / `cluster-002` ...) で振る。
   - 単独指摘は `cluster_id=null`。
   - 出現頻度が高いほど accept 寄り (3 PR 以上の同主旨は強い採用根拠)。ただし固有化できない `general` は、頻度が高くても判断軸 1 の降格に従う。

6. **REVIEW.md 既存内容との重複可能性**
   - 本 skill は REVIEW.md を読まない。出典の body が「REVIEW.md にある通り」のように、その観点が既存 REVIEW.md に書かれていると示しているものは、`reason` に「[既存方針と重複可能性]」とフラグを立て、`hold` に倒す。root の `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` への言及は、root に `REVIEW.md` が無いとき (`meta.existing_review_md_paths` に `REVIEW.md` が無い、または一覧を取得できていないとき) だけ同じく扱う (`compose-review` は root に `REVIEW.md` が無いときに限り、これらのうち最初に見つかった 1 つを root 方針として読む。本 skill はどれが読まれているかまでは分からないので、3 つとも安全側で重複可能性ありとする)。root に `REVIEW.md` があるときの root 候補や、配下ディレクトリの `CLAUDE.md` / `CONTRIBUTING.md` / 設計文書などへの言及は重複扱いにしない (`compose-review` が方針として読むのは `REVIEW.md` と root の候補 1 つだけなので。文書化された約束事は、むしろ `project` の根拠になる)。一般に当たり前のルールは判断軸 1 の `general` として扱う。

7. **バグ修正PR由来の加点 (`pr_kind=bugfix`)**
   - バグ修正PRに付いたレビューコメントは「レビューがすり抜けた領域」を指す指摘であり、同種バグの再発防止に効く価値が高い → accept 寄りに加点する。加点するのは `project` の観点 (固有化できたものを含む) だけで、`general` のままの観点は判断軸 1 の降格に従う。
   - `bugfix_signals` は raw のまま渡されるので、AI は確信度を文脈判断する (例: `is_revert=true` は本番に出荷されたバグの差し戻しで最も強い信号、`commit_type_fix` 単独は本体は別種別の PR に fix commit が混ざっただけの可能性があり弱い)。

8. **バグ修正diff由来の観点抽出 (`source=bugfix-diff`)**
   - `pr_kind=bugfix` かつ `bugfix_diff` がある PR は、diff を読んで「このバグを事前に検出できた、このリポジトリ固有のレビュー観点」を AI が起こす。**レビューコメントが付いていない hotfix でもここから観点を抽出できる**。
   - バグの一般的な分類 (null チェック漏れ / 境界値 等) で止めず、**このリポジトリのどの API / モジュール / データのどんな性質がバグを生んだか** まで diff から読み取って書く。読み取ってよいのは diff (修正箇所・追加されたテスト・コメント) と PR のタイトル / commit message に書かれている範囲だけで、そこから原因の性質を読み取れなければ `general` のまま判断軸 1 の降格に従う (例に合わせて原因を作文しない)。例: null チェック漏れの修正で、追加されたテストが退会済みユーザーのケースを扱っている → 「外部入力の null 経路を確認する」(`general`) ではなく「`UserRepository.find()` は退会済みユーザーで null を返す。戻り値をそのまま使う箇所は退会済みの経路を確認する」(`project`)。境界値の修正で、diff のコメントに API の仕様が書かれている → 「ページネーションの境界を確認する」ではなく「社内 Search API の `page` は 1 始まり。0 始まりのインデックスから渡す箇所は変換を確認する」。
   - 判定は判断軸 1 と同じ: 再利用可能で `project` として書ける観点を採用候補とし、diff から固有の文脈を読み取れず `general` のままなら判断軸 1 の降格に従う。この PR 固有のロジック誤り (一回限り) は `reject`。`bugfix_diff_truncated=true` の場合は diff が途中までしか無い旨を踏まえ、断定できなければ (固有の文脈の有無を断定できない場合を含む) `hold`。
   - クラスタリング (判断軸 5) はコメント由来候補とも統合してよい (同じ観点ならまとめ、`sources[]` に PR を併記)。

9. **配置先 REVIEW.md の決定 (`accept` / `hold` のみ)**

    `compose-review` は各 `REVIEW.md` を **その出典ディレクトリの配下にだけ** 適用する。したがって配置先は「そのルールが成立する範囲」と一致していなければならない。**可能な限りディレクトリ別に分割する**のが本 skill の方針で、root (`REVIEW.md`) は **リポジトリ横断で成立するルール専用** とする。手順:

    1. **出典パス集合を作る**: `source=review-comment` はコメントの `path` (クラスタなら全出典分)、`source=bugfix-diff` は `bugfix_diff` の `diff --git a/<path> b/<path>` ヘッダから取った path。**`bugfix_diff_truncated=true` の PR、および diff からパスを取れなかった PR は、当該 PR の `files` (PR 全体の変更ファイル一覧) を使う** — truncate された diff のヘッダだけでは変更範囲が実際より狭く見え、次の LCD が深すぎるディレクトリになって配置先が過度に限定されるため。**フォールバック先の `files` も `files_truncated=true` (100 件超) の場合は同じ狭まりが残る**ので、その PR については LCD を 1 段上に丸める。それでも配置先に確信が持てなければ判断軸 10 に従い `hold` に倒す。
    2. **起点 = 最長共通ディレクトリ (LCD)**: 出典が単一ファイルならそのファイルのディレクトリ。root 直下のファイル (`README.md` / `package.json` 等) を含むなら LCD は root。
    3. **ルールの適用範囲まで上げる**: LCD から、そのルールが実際に成立する範囲 (パッケージ / アプリ / 機能領域の境界) まで祖先方向へ上げる。ツリー構造は `signals.json` 全 PR の `files` から推定してよい。リポジトリ全体で成立するルール (リポジトリ共通の規約・用語、パッケージ横断のアーキテクチャ制約、コミット / PR 規約等) だけを root に置く (一般的な観点は判断軸 1 で採用しないので、言語非依存であることは root に置く理由にならない)。`[汎用観点]` の `hold` には配置先を付けない (6 参照)。**迷ったらディレクトリ側に倒す** (分割が方針。root に積むと無関係なパッケージにまで効いてしまう)。
    4. **既存 `REVIEW.md` へ寄せる**: 3 で決めたディレクトリ D から root へ辿り、`meta.existing_review_md_paths` に含まれる **最も近い祖先** (D 自身を含む) の `REVIEW.md` を探す。見つかったファイルの担当範囲全体でもそのルールが成立するならそこを配置先にし (`target_is_new=false`)、成立しない (既存が広すぎる) / 既存が D より深い位置にしか無い場合は D に新規ファイルを提案する (`target_is_new=true`)。既存に寄せるのは、新規ファイルの乱立と祖先 `REVIEW.md` 数の無駄な増加を避けるため。
       - `existing_review_md_paths=null` (取得失敗) のとき、および **`meta` に当該キー自体が無いとき** (本機能より前に生成した `signals.json` を再判定に使った場合) は 4 を丸ごとスキップし、全件 `target_is_new=null` にした上で proposals.md 冒頭にその旨を 1 行明記する。**キーの不在を「空配列 = 既存 REVIEW.md なし」と解釈してはならない** (実在するファイルと重複する新規提案になるため)。
       - `existing_review_md_truncated=true` のときも proposals.md 冒頭に 1 行明記する (既存ファイルの取りこぼしで `target_is_new=true` が過剰に付く可能性がある)。
       - **root (`REVIEW.md`) を新規で提案する場合は要注意**: `compose-review` Step 3 は root の共通方針を `REVIEW.md` → `AGENTS.md` → `.claude/CLAUDE.md` → `CLAUDE.md` の優先順で **最初に見つかった 1 つだけ** 読む。root に `REVIEW.md` が無いリポジトリで新規作成すると、それまで読まれていた `AGENTS.md` / `CLAUDE.md` の方針とエスカレーション基準が丸ごと shadowing されて無言で失効する。したがって `target_review_md=REVIEW.md` かつ **`target_is_new` が `false` 以外 (`true` / `null`)** の配置先が 1 つでもあれば、**proposals.md 冒頭と caller 報告に「root に REVIEW.md を新規作成すると既存の AGENTS.md / CLAUDE.md が読まれなくなるため、後続フローで既存 root 方針の移植を検討すること」を 1 行明記する** (本 skill は root 4 候補の有無を知らないため、警告に留めて判断は後続フローに委ねる)。root の既存 `REVIEW.md` への追記 (`target_is_new=false`) ならこの問題は起きない。
    5. **制約**: `target_review_md` は **`..` を含まず、絶対パスでもない root 相対パスで、末尾が `REVIEW.md`** でなければならない (出典パスは過去 PR のレビューコメント由来 = 第三者が書ける値なので、そのまま Step 3.5 の書き出し先に流すと `${OUTPUT_DIR}` の外に出られる)。`node_modules/` / `vendor/` 配下も配置先にしない (`compose-review` が読まないため)。**これらの条件を満たさない候補は、その proposal を `hold` に落とし `target_review_md=null` にする** (`reason` に「配置先パスが制約を満たさないため保留」と明記)。root (`REVIEW.md`) に倒してはならない — 制約違反は入力が信用できないことの証拠なのに、root 昇格は 9-3「迷ったらディレクトリ側」に逆行し、root に既存 `REVIEW.md` が無いリポジトリでは `target_is_new=true` になって 9-4 が警告している `AGENTS.md` / `CLAUDE.md` の shadowing を自ら誘発する (不正な入力ほどリポジトリ全体に効く配置先へ昇格してしまう)。判断軸 10「迷ったら `hold`」とも揃う。1 proposal = 1 配置先。クラスタの出典が無関係な top-level (`apps/web` と `apps/api` 等) にまたがる場合、ルールが両方でだけ成立するなら共通祖先 (`apps/REVIEW.md`)、リポジトリ全体で成立するなら root にする。配置先が分かれるべき内容なら **proposal を分割する**。
    6. `reject` には配置先を付けない (`target_review_md=null`)。`hold` には暫定の配置先を付ける (後続フローで採用に転じたときそのまま使えるようにするため) が、**5 の制約違反で `hold` に落とした場合と、`[汎用観点]` の `hold` は `target_review_md=null`** にする。`[汎用観点]` の保留は、採用するときに足す固有の文脈 (どのモジュールの、どんな性質か) によって効かせる範囲が決まるため、一般原則のまま配置先を決めても使えない (出典がパッケージをまたぐと root になり、採用候補が無い回にも 4 の shadowing 警告を出してしまう)。

10. **迷ったら `hold`**
    - `resolve-pr-threads` の「迷ったら resolve しない」と同じ保守的ルール。`reject` に倒すと将来の蓄積機会を失う。

#### 2-2. 各 proposal の属性

各 proposal は以下の属性を持つ:

| 属性 | 説明 |
|---|---|
| `verdict` | `accept` / `hold` / `reject` |
| `target_review_md` | 配置先 `REVIEW.md` の root 相対パス (root なら `REVIEW.md`、ディレクトリ別なら `apps/web/REVIEW.md` 等)。2-1 の判断軸 9 で決定。`reject` の場合、判断軸 9-5 の制約を満たさず `hold` に落とした場合、および `[汎用観点]` の `hold` は null。 |
| `target_is_new` | 配置先が `meta.existing_review_md_paths` に無い **新規ファイルの提案** なら true、既存ファイルへの追記なら false、一覧取得失敗 (`existing_review_md_paths=null`) なら null。`target_review_md=null` の候補も null。 |
| `source` | 抽出源。`review-comment` (レビューコメント由来) / `bugfix-diff` (バグ修正diff由来)。クラスタに両方含む場合は主たる根拠を記し `sources[]` に内訳を残す。 |
| `reason` | 採否の理由 (1〜2 文)。`[汎用観点]` (判断軸 1 で降格したもの) / `[既存方針と重複可能性]` などのフラグもここに含める。 |
| `proposal_text` | REVIEW.md に書くなら何と書くか (Markdown bullet point 1〜3 行)。一般原則の言い換えに留めず、このリポジトリの具体的な対象 (パス / モジュール / 関数 / 型 / ドメイン用語 / 条件) を名指しで書く。ただし `[汎用観点]` の `hold` は固有の対象を出典から取れなかったものなので、一般原則のまま書く (名指しのために固有名詞を作らない)。`reject` の場合は null。 |
| `severity_suggestion` | REVIEW.md に載せる場合の severity ラベル (`[must]` / `[should]` / `[nit]`)。元コメントの severity を踏襲、なければ推定 (`[question]` 由来の候補は、明かされた知識の重要度から推定する)。 |
| `sources` | 出典 PR / comment URL のリスト + body 引用 (200 文字超は先頭 200 文字 + `...`)。クラスタリングされていれば複数 PR 分。 |
| `cluster_id` | クラスタリングしたなら `cluster-NNN`、単独なら null。 |
| `signals_summary` | 判定根拠になった主要信号 3〜5 個 (raw signals 全部ではなく抜粋)。例: `thread_resolved=true, file_changed_after_comment=true, severity=[should]`。 |

### Step 3. proposals.md を出力する (Phase D)

`${OUTPUT_DIR}/proposals.md` に `Write` ツールで書き出す。`Write` ツールは中間ディレクトリの自動作成を保証しないが、`${OUTPUT_DIR}` は Step 1 のスクリプト実行時に `mkdir -p` 済みなので追加の `mkdir` は不要。`Write` ツールは「同一セッション中に `Read` されていない既存ファイルへの上書き」を拒否する仕様のため、`OUTPUT_DIR` が caller 明示指定で既存 proposals.md が残っている可能性があれば `Read` を 1 回挟んでから `Write` する。`heredoc` や `cat` リダイレクトは使わない。

スキーマ:

```markdown
# REVIEW.md 候補案 (proposals.md)

- 期間: <SINCE> 〜 <UNTIL> (UTC)
- 対象リポジトリ: <OWNER>/<REPO>
- 対象 PR 数: <N> 件 (max_prs=<MAX_PRS> <超過時のみ「超過: 信号品質低下の可能性あり」を追記>)
- バグ修正PR数: <B> 件 (うち diff 取得済み <D> 件 <bugfix_diffs_truncated=true のみ「上限 MAX_BUGFIX_DIFFS 超過で一部未取得」を追記>)
- 抽出コメント総数: <M> 件 (うち AI 自動投稿 <A> 件 / 人間 <H> 件)
- 採用候補: <X> 件 (クラスタ: <C> 個 / 単独: <S> 件 / うち bugfix-diff 由来 <BD> 件)
- 配置先 REVIEW.md: <K> ファイル (既存 <E> / 新規 <N>。`existing_review_md_paths=null` の回は内訳を出さず `既存/新規は判定不能` と書く)
- 保留: <Y> 件
- 棄却: <Z> 件
- 汎用観点として降格: <G> 件 (保留 <Gh> / 棄却 <Gr>。上の保留・棄却の内数)
- 生成日時: <ISO8601 UTC 秒精度>

<existing_review_md_paths=null のときのみ: 「既存 REVIEW.md の一覧を取得できなかったため、配置先の既存/新規は判定していない (既存ファイルと重複する提案になっている可能性がある)。後続フローは断片を適用する前に各配置先の実在を確認すること」を 1 行>
<existing_review_md_truncated=true のときのみ: 「リポジトリの tree が大きく一覧が不完全なため、既存 REVIEW.md を取りこぼして「新規」と判定している配置先がありうる。後続フローは新規扱いの配置先の実在を確認すること」を 1 行>
<root の配置先があり、その target_is_new が false 以外 (true / null) のときのみ: 「root に REVIEW.md を新規作成すると compose-review が既存の AGENTS.md / CLAUDE.md を読まなくなる (root は最初に見つかった 1 つだけを読む)。後続フローで既存 root 方針の移植を検討すること」を 1 行>

## 後続フロー

1. `review-md/<配置先>` の断片を、対応するディレクトリの REVIEW.md へ適用する PR を作成する (採用候補 0 件の回は `review-md/` 自体を出力していないので本手順は不要)。配置先ごとの根拠は本ファイルの「採用候補」を参照。適用時の注意:
   - **適用前に配置先ファイルの実在を確認する**。「新規」と書かれていても実在すれば追記に切り替える (本 skill の既存/新規判定は蒸留実行時点の default branch のスナップショットで、取得失敗・tree truncated・その後の変更でズレうる)。実在しなければ断片をそのままファイルとして作成する
   - **追記位置は `エスカレーション基準` 見出しを含むセクションの配下にしない**。`compose-review` はそのセクション配下の記述だけをエスカレーション基準として扱うため、末尾が当該セクションのファイルに単純追記すると、蒸留した観点が基準として解釈され無関係な PR で `escalate: true` が立つ。断片は見出し付きで出力されるので、当該セクションより前か、独立した節として入る位置に置く
2. 「保留」セクションは個別判断 (採用 / 棄却 / 文面修正の上で採用 のどれにするか)。採用する場合の配置先候補も各項目に併記してある。`[汎用観点]` 付きの保留は、このリポジトリで繰り返し破られている一般原則。採用するなら出典を読み、どのモジュールで・なぜ破られるかという固有の文脈を足して書き、配置先もその文脈が成立する範囲で決める (一般原則のまま書いてもレビュアーの指摘はほぼ変わらない)
3. 「棄却」セクションは記録のみ。同じ指摘が次回も繰り返し棄却されないよう判断履歴として残す

中間ファイル `prs.json` / `signals.json` は再判定時の入力として ${OUTPUT_DIR} に残してある。

---

## 採用候補

配置先 `REVIEW.md` ごとにグルーピングする (root を先頭に、以降はパス昇順)。項目番号は配置先をまたいだ通し番号。見出しの括弧内は `target_is_new` に対応させ、`false` なら `既存`、`true` なら `新規`、`null` なら `既存/新規 不明` と書く。

### 配置先: REVIEW.md (root, 既存)

#### 1. [cluster-001] [should] (source: review-comment) <ルールのタイトル>

**提案文 (REVIEW.md 追記想定)**:

> - <REVIEW.md にそのまま書く想定の bullet。1〜3 行。>

**判定根拠**: <reason 本文。クラスタの場合は出現 PR 数 / 取り込み率を併記。>

**固有性**: <このルールが依存するリポジトリ固有の知識 (モジュール / API / 規約 / ドメインの事実) を 1 文で。汎用観点を出典から固有化した場合はその旨も。>

**配置先根拠**: <出典パスの LCD → ルールが成立する範囲 → 既存ファイルへの寄せ、を 1 文で。例: 出典は全パッケージに分散しており、リポジトリ共通の規約のため root。>

**信号**: <signals_summary>

**出典**:
- https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... (人間レビュー / AI 自動投稿 の別を併記)
  > <body 引用、200 文字超は省略>
- https://github.com/<OWNER>/<REPO>/pull/<N+5>#discussion_r... (AI 自動投稿)
  > <body 引用>

### 配置先: apps/web/REVIEW.md (新規)

#### 2. [should] (source: bugfix-diff) <バグ修正diffから抽出したレビュー観点のタイトル>

**提案文 (REVIEW.md 追記想定)**:

> - <このバグを事前に検出できた、このリポジトリ固有のレビュー観点の bullet。1〜3 行。>

**判定根拠**: <どのバグ修正から観点を起こしたか。is_revert 等の強信号があれば明記。>

**固有性**: <バグを生んだ固有の性質 (どの API / モジュール / データの、どんな仕様・状態か) を 1 文で。>

**配置先根拠**: <例: 出典は apps/web/src/ 配下のみ。apps/web 独自のフォーム部品の使い方に関する観点で他パッケージには成立しないため apps/web/ に新規。>

**信号**: pr_kind=bugfix, <マッチした bugfix_signals (例: is_revert=true)>

**出典**:
- https://github.com/<OWNER>/<REPO>/pull/<N> (バグ修正PR: <title>)
  > <修正の要点。diff の該当箇所を簡潔に引用、長い場合は要約>

#### 3. <以下、配置先ごとの小見出し + 採用候補ごとに繰り返し (source を併記)>

---

## 保留

`project` の保留を先に、`[汎用観点]` で保留したもの (見出しに `[汎用観点]` を付ける) を後に並べる。

### H1. [should] <タイトル>

**判定保留理由**: <reason>

**固有性**: <`project` の保留のみ。このルールが依存するリポジトリ固有の知識を 1 文で。`[汎用観点]` の保留は省く。>

**配置先候補**: <target_review_md> (既存 / 新規 / 不明)、制約違反で保留した場合は `なし (配置先パスが制約違反)`、`[汎用観点]` の保留は `なし (固有の文脈を足してから決める)`

**信号**: <signals_summary>

**出典**:
- https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r...
  > <body 引用>

### H2. <以下、保留ごとに繰り返し>

---

## 棄却

| # | severity | 理由 | 出典 |
|---|---|---|---|
| R1 | [nit] | この PR 限定の命名修正 (再利用不能) | https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... |
| R2 | [must] | この PR 固有のロジック誤り | https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... |
| R3 | [should] | AI 自動投稿で行ズレのみ (取り込まれていない) | https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... |
| R4 | [should] | [汎用観点] 一般的なレビュアーが REVIEW.md なしで指摘する観点で、固有の文脈を出典から読み取れない | https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... |
```

期間内 0 PR でも proposals.md は空状態 (採用 0 / 保留 0 / 棄却 0、各セクションは「該当なし」と明示) で出力する (skip しない)。採用候補が 0 件なら「配置先 REVIEW.md: 0 ファイル」と書き、配置先の小見出しは置かない。

「生成日時」は実行時に `date -u +%Y-%m-%dT%H:%M:%SZ` で取得する。`date` が利用できなければ caller / 実行環境から提供される現在日時を使い、それも無ければ `<unknown>` と記載する。

### Step 3.5. 配置先ごとの断片ファイルを出力する (Phase D)

採用候補 (`verdict=accept`) を配置先ごとにまとめ、**そのまま追記できる markdown 断片** を `${OUTPUT_DIR}/review-md/<target_review_md>` に `Write` ツールで書き出す (root の配置先なら `${OUTPUT_DIR}/review-md/REVIEW.md`、`apps/web/REVIEW.md` なら `${OUTPUT_DIR}/review-md/apps/web/REVIEW.md`)。後続フローが各ディレクトリの `REVIEW.md` へコピー / 追記するだけで済む形にするのが目的。

- **ディレクトリ作成**: `Write` ツールは中間ディレクトリの自動作成を保証しないため、書き出し前に `Bash` で `mkdir -p "${OUTPUT_DIR}/review-md/<配置先のディレクトリ部分>"` を実行する。**ファイル内容の書き出しに `Bash` を使ってはならず** (`heredoc` / `cat` リダイレクトは使わない)、内容は必ず `Write` ツールで書く。書き出し系で許可される `Bash` はこの `mkdir` だけという意味であり、Step 1 の収集スクリプト実行や Step 3 の `date` 取得まで禁じるものではない。
- **内容**: その配置先に割り当てた `accept` の `proposal_text` (bullet) を並べるだけにする。`hold` / `reject` は含めない。**出典 URL / 信号 / 判定根拠などのメタ情報は入れない** — この断片は `compose-review` がそのままレビュー方針として読むファイルになるため (メタは proposals.md 側の責務)。
- **見出しを必ず付ける**: 断片の先頭は `## レビュー観点 (<生成日 YYYY-MM-DD> 蒸留)` の H2 見出し + 空行 + bullet 群にする。既存ファイルへ追記する場合に **`エスカレーション基準` 見出しのセクションを閉じる** ためで、見出し無しの bullet を末尾追記すると、その記述が `compose-review` にエスカレーション基準として解釈され無関係な PR で `escalate: true` が立つ。ただし `compose-review` は **任意のレベル (`#`〜`######`) の見出し** を基準セクションとして認めるため、追記先の `エスカレーション基準` が H1 だと H2 では閉じられない。断片側の H2 は既定の形であって完全な担保ではなく、**適用位置の判断は後続フロー (Step 3 「後続フロー」2 番目の注意) が担う**。
  - `target_is_new=true` (既存一覧に無いと確認できた新規ファイル) の場合のみ、H2 の前にさらに H1 を置く (root なら `# レビュー方針`、ディレクトリ別なら `# <dir>/ 配下のレビュー方針`)。ファイルごと作成してもそのまま成立する形にするため。
  - `target_is_new=null` (既存一覧を取得できず既存/新規が不明) の場合は **H1 を付けない** (H2 + bullet のみ)。実在する既存ファイルに追記されたときに H1 が途中へ挿入されるのを避けるため。後続フローが実在しないと確認してファイルごと作成する場合は、その時点で H1 を補う。
- **採用候補が 0 件なら `review-md/` は作らない** (空ディレクトリを残さない)。
- `OUTPUT_DIR` が caller 明示指定で既存の断片が残っている可能性がある場合は、`Write` の前に `Read` を 1 回挟む (proposals.md と同じ理由: `Write` ツールは同一セッション中に `Read` していない既存ファイルへの上書きを拒否する)。
- 本 step で書くのは `${OUTPUT_DIR}` 配下のみ。**リポジトリ内の `REVIEW.md` は作成も編集もしない**。

### Step 4. caller への報告

以下を簡潔に caller へ返す:

- 対象期間 (`SINCE`..`UNTIL`) / 対象リポジトリ
- 対象 PR 数 / バグ修正PR数 / 抽出コメント数 / 採用・保留・棄却の内訳件数 (採用のうち bugfix-diff 由来件数、保留・棄却のうち汎用観点として降格した件数も)
- 採用候補の配置先 `REVIEW.md` のファイル数 (既存 <E> / 新規 <N>。`existing_review_md_paths=null` の回は内訳を出さず「既存/新規は判定不能」と伝える) と、主な配置先パス
- 出力先パス (`OUTPUT_DIR/proposals.md` / `prs.json` / `signals.json`。採用候補が 1 件以上あるときだけ `review-md/` も案内する。0 件なら Step 3.5 が作らないので触れない)
- `MAX_PRS` 超過時 / `bugfix_diffs_truncated=true` / `existing_review_md_paths=null` (既存一覧の取得失敗) / `existing_review_md_truncated=true` / `output_dir_relocated=true` (caller 指定の `OUTPUT_DIR` がリポジトリ配下だったため既定パスへ差し替え) の場合はその旨を 1 行で追記
- root (`REVIEW.md`) の配置先があり `target_is_new` が `false` 以外だった回は、「既存の `AGENTS.md` / `CLAUDE.md` が読まれなくなるため移植の検討が要る」旨を 1 行で追記 (既存一覧を取得できなかった回ほど既存 root 方針の有無が分からないので、`null` でも必ず出す)

チャットに proposals.md / `review-md/` 断片の全文をダンプしない (件数が多いケースで後続会話のコンテキストを圧迫するため)。出力先パスと冒頭メタ + 件数内訳のみをチャットに出し、詳細は markdown ファイルを参照させる。

## 守ること

- READ-ONLY: GitHub 投稿 / PR 作成 / commit / push / `git fetch` / `git checkout` などローカル ref を書き換える操作は一切しない。`gh pr comment` / `gh pr review` / `gh api .../reviews` / `gh pr create` も使わない。**`review-md/` 断片は `${OUTPUT_DIR}` 配下に書くだけで、リポジトリ内の `REVIEW.md` は作成も編集もしない**。
- **`OUTPUT_DIR` はリポジトリの作業ツリー外に置く** (入力仕様参照)。`review-md/` 断片のファイル名が `REVIEW.md` そのものなので、リポジトリ内に出すと以降のレビューがそれを方針ファイルとして拾う。
- **ファイル書き出しは `${OUTPUT_DIR}` 配下の `proposals.md` と `review-md/<配置先>` 断片のみ**。`Bash` での書き出しは禁止で、例外は Step 3.5 の `mkdir -p "${OUTPUT_DIR}/review-md/..."` だけ (内容は必ず `Write` ツールで書く)。**`mkdir` / `Write` の前に、組み立てたパスが `${OUTPUT_DIR}/review-md/` 配下に収まることを確認する** (判断軸 9 の 5 で `target_review_md` に課した制約と二重で担保する。配置先は第三者が書けるデータから導出されるため)。
- **リポジトリ内の既存 `REVIEW.md` の中身は読まない**。配置先決定に使うのはスクリプトが取得した `meta.existing_review_md_paths` (パス一覧) だけで、AI が `Read` / `git show` / `gh api` でリポジトリ内 `REVIEW.md` の内容を追加取得してはならない (既存内容との重複判定は proposals.md のフラグに留める、という責務分離のため)。**本制約の対象はリポジトリ内のファイルだけ**で、Step 3 / 3.5 が上書き前に行う `${OUTPUT_DIR}` 配下 (`proposals.md` / `review-md/**`) の `Read` は対象外 (`Write` ツールの上書き制約を満たすために必要)。
- **配置先は可能な限りディレクトリ別に分割する**。root (`REVIEW.md`) はリポジトリ横断で成立するルール専用で、迷ったらディレクトリ側に倒す。`node_modules/` / `vendor/` 配下は配置先にしない。
- **一般的なレビュー観点は `accept` にしない**。固有化できない `general` は判断軸 1 の降格 (`[汎用観点]` 付きの `hold` / `reject`) に従う。固有化には出典に書かれた事実だけを使い、場所を付けただけの書き換えや、出典に無い固有名詞・条件の推測での補完をしない。
- `post-pr-review` / `resolve-pr-threads` / `run-pr-review` / `run-local-review` skill は呼ばない (独立 skill)。
- 既存資産 `/pr-review-style-reference` の severity ラベル定義は **slash command 経由でのみ利用** し、本 skill 内で再掲・再実装しない (二重管理を避けるため)。
- **Phase A + B (PR 一覧 / GraphQL 統合クエリ / 信号付与) は `scripts/collect-signals.sh` に集約してある**。AI 側でこれらを `gh` / `jq` 直叩きで再実装してはならない (差異が出てスクリプトとプロンプトの責務分割が崩れるため)。信号定義を変えたい場合はスクリプトと本 SKILL.md の `signals` フィールド定義をセットで更新する。
- **機械的なスコア合算は禁止**。信号は `signals.json` に raw のまま付与し、Phase C の AI が総合判断する。理由は信号の文脈依存性 (例: `outdated` 単独は行ズレ可能性)。
- 対象は **merged PR のみ**。open / closed unmerged は対象外 (取り込み判定が安定しないため)。
- 期間内 0 PR でも proposals.md は空状態で出力する (skip しない)。
- 判定に迷ったら `hold` に倒す (`resolve-pr-threads` の「迷ったら resolve しない」と同思想)。`reject` に倒すと将来の蓄積機会を失う。
- proposals.md + `review-md/` 断片は **本 skill のスコープの終点**。REVIEW.md 編集 / PR 作成は別工程で行うことを caller に明示する。
