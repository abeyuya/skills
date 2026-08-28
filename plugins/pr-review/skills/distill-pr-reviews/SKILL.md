---
name: distill-pr-reviews
description: 期間内 merged PR のレビューコメント (AI 自動投稿 + 人間レビュー両方) を集約し、REVIEW.md に追記する価値のある指摘候補を proposals.md として出力する skill。バグ修正PR (fix型title / bugラベル / revert 等で検知) の修正diffも抽出源にし、コメントの付かない hotfix からも再発防止のレビュー観点を抽出する。取り込み判定の信号収集はスクリプト、最終的な採否分類とクラスタリングは AI が行う。本 skill は read-only で、REVIEW.md の編集や PR 作成は行わない。収集スクリプトが gh CLI に依存するため gh チャネル専用 (gh が使えない web/remote セッション等では動かない)。
---

# distill-pr-reviews skill

過去 merged PR のレビューコメントから「REVIEW.md に蓄積する価値のある指摘」を抽出する skill。
出力 (`proposals.md`) を後工程 (人間 or 別 skill) が読んで REVIEW.md 編集 PR を作る、という運用を想定している。

**本 skill のスコープは proposals.md 出力で停止する。** REVIEW.md の編集 / commit / push / PR 作成は一切行わない。
状態管理ファイルは持たず、毎回期間引数を渡す方式 (運用がシンプルで監査性が高い)。

**本 skill は gh チャネル専用**: 収集ロジックが bash スクリプト (`scripts/collect-signals.sh`) にあり bash からは GitHub MCP ツールを呼べないため、`gh` CLI が使えない環境 (Claude Code の web/remote セッション等。gh が恒常 403 になる) では実行できない。その場合はエラーとして caller に報告して停止する。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `OWNER` / `REPO`: 対象リポジトリ。省略時は `gh repo view --json nameWithOwner -q .nameWithOwner` で cwd の git リポジトリから自動推定する。ドッグフーディング時の取り違え防止のため明示推奨。
- `SINCE` / `UNTIL`: merged at で絞る期間 (`YYYY-MM-DD` 形式、UTC)。`SINCE` 省略時は `UNTIL - DAYS`、`UNTIL` 省略時は今日 (UTC) を使う。両方省略時は「過去 `DAYS` 日」になる。
- `DAYS`: `SINCE` 未指定時のフォールバック期間 (日数)。省略時 `7`。`SINCE` が指定されていれば無視される。
- `MAX_PRS`: 期間内 PR 数の上限警告閾値。省略時 `100`。超過しても処理は継続し、proposals.md 冒頭に「対象 PR が多いため信号品質が低下している可能性あり」を明記する。
- `MAX_BUGFIX_DIFFS`: バグ修正PR (`pr_kind=bugfix`) の diff を取得する上限件数。省略時 `30`。バグ修正PRはレビューをすり抜けたバグの証拠であり、その修正 diff から再発防止のレビュー観点を抽出する (Phase D の新ソース)。コスト抑制のため subset 限定 + 件数上限で取得し、超過分は新しい順に打ち切って `meta.bugfix_diffs_truncated` に記録する。
- `FILTER_AUTHOR`: PR 作成者で絞り込む (例: `dependabot[bot]` を除外したい場合は `-author:dependabot[bot]` 形式で渡す)。省略時はフィルタなし。`gh pr list --search` の検索式にそのまま連結する。
- `FILTER_LABEL`: PR ラベルで絞り込む (例: `label:bug`)。省略時はフィルタなし。同上、`--search` に連結する。
- `INCLUDE_AI_AUTHORED`: `> **[AI 自動投稿]**` プレフィックス付きのコメントを採否候補に含めるか。省略時 `true`。`false` の場合でも信号 (`is_ai_authored`) は付与するが、Phase C で AI が一律 reject に倒す。値は `true` / `false` を推奨するが、scripts/collect-signals.sh では大文字小文字 / 周辺空白を正規化し `1` / `yes` / `y` / `0` / `no` / `n` も受け入れる (それ以外は `exit 2`)。
- `OUTPUT_DIR`: 出力先ディレクトリ。省略時は `/tmp/distill-pr-reviews/{repo}/{timestamp}` (例: `/tmp/distill-pr-reviews/skills/20260524T120000Z`)。caller が明示パスを指定した場合は既存ファイルがあれば上書きする。
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
- 既存 `REVIEW.md` を **読まない** (それは `run-pr-review` Step 3 / `run-local-review` Step 3 の役割)。本 skill は「REVIEW.md を育てるための候補ファイル」を出すだけで、既存内容との重複判定は AI が proposals.md 内に「重複可能性あり」フラグとして残す形に留める。
- 対象は **merged PR のみ**。open / closed unmerged は対象外 (取り込み判定が安定しないため)。

## 設計上の主要トレードオフ

1. **PR 一覧は REST、PR 詳細 (reviewThreads + commits + files) は GraphQL の混在採用**: `gh pr list --search` がページング込みで便利。PR 詳細は 1 PR = 1 GraphQL query にまとめて取得することで、API rate limit (graphql 5000/h / core 5000/h) を実質ほぼ消費しない構造にする (1 PR = graphql 1 query)。
2. **commit 別 files は持たず、PR 全体 files で代用**: 旧設計では REST `commits/{sha}` を commit 数 × 1 query 叩いていたが、core 枠を数百 query 消費し rate limit に到達する原因だった。新設計では PR 全体の変更ファイル一覧 (GraphQL `pullRequest.files`) のみを取得し、`file_changed_after_comment` 判定は「PR 全体 files に該当 path 含む × コメント以降に commit 存在」に変更する。コメント前 commit のみで完結した変更が false positive になる精度劣化を許容するかわりに、commit 別 REST query を全廃する。残る精度低下は Phase C の AI が body + diff_hunk で最終判断することで吸収する。
3. **reactions は廃止**: 旧設計では GraphQL の `reactions(first: 20)` を取得して `reactions_positive` / `reactions_negative` を信号化していたが、(a) 実際に reaction が付くコメントが稀で信号価値が低い、(b) GraphQL の 500k ノード上限を圧迫していた、ため廃止。ノード予算が空いた分は 1 PR 1 query への統合に振る。
4. **信号スコア合算を script でなく AI に委ねる**: 信号は文脈依存 (例: `is_outdated=true` 単独は「修正された」か「単に行ズレした」かの判別不能) で、機械合算するとノイズが大きい。`signals.json` には raw のまま付与し、Phase C の AI が総合判断する。
5. **クラスタリングは Phase C (AI)**: 意味類似度判定が bash/jq では困難なため。Phase B では `path` ベースの「同一ファイル指摘」フラグだけ立てる。
6. **採否は三値 (`accept` / `hold` / `reject`)**: 二値だと判断不能ケースが reject に流れて将来の蓄積機会を失う。迷ったら `hold` (`resolve-pr-threads` の保守的ルールと同思想)。
7. **REVIEW.md 既存内容との重複判定は本 skill ではしない**: 後続フロー (REVIEW.md 編集) との責務分離を保つ。AI は proposals.md に「重複可能性あり」フラグだけ立てる。
8. **バグ修正PR は検知 + diff 取得で「新しい抽出源」にする**: バグ修正PRはレビューをすり抜けたバグの証拠であり、その修正 diff を一般化すれば再発防止のレビュー観点になる。検知 (`pr_kind` / `bugfix_signals`) は既取得の title / commit / labels から追加 API コールなしで行い、diff のみ `pr_kind=bugfix` の subset に限定して `gh pr diff` (1 PR = 1 コール) で取得する。全廃した REST `commits/{sha}` (commit 数 × 1 query) と違い subset 限定 + `MAX_BUGFIX_DIFFS` 件 + `DIFF_CHAR_CAP` 文字で抑えるため rate limit 影響は限定的。`is_revert` は本番に出荷されたバグの差し戻しで最も強い信号。検知は OR の粗いフィルタで false positive (例: 本体は refactor だが fix commit が混ざった PR) を許容し、最終的な一般化判断は Phase C/D の AI が diff を読んで行う。
9. **決定論的な Phase A + B (PR 一覧取得 / GraphQL / 信号付与) は bash + jq スクリプトに切り出す**: `scripts/collect-signals.sh` が `signals.json` を出力するまでを担い、AI (Phase C+D) は signals.json を読んで `proposals.md` を書き出す責務に集中する。スクリプト化のメリットは挙動の再現性と AI 側プロンプトの圧縮で、デメリットは信号定義を変えたい場合に SKILL.md + スクリプト両方を編集する必要がある点 (signals.json のスキーマを変えると Phase C の AI 解釈もズレるため、両者は本 SKILL.md の `signals.json` スキーマ定義で同期させる)。

## 手順

### Step 1. 信号収集スクリプトを呼ぶ (Phase A + B)

決定論的な処理 (入力正規化 → `gh pr list` → PR 単位の GraphQL 統合クエリ → 信号付与) は本 skill 配下の `scripts/collect-signals.sh` (bash + jq) に集約してある。本 step では **このスクリプトを Bash ツールから呼ぶだけ**。AI が同等処理を逐次実行しない (差異が出ないように)。

#### 呼び出し方

スクリプトの絶対パスは **本 SKILL.md と同じディレクトリの `scripts/collect-signals.sh`** で解決する。skill 起動時に渡される SKILL.md の絶対パスから dirname を取って `<dirname>/scripts/collect-signals.sh` を組み立てれば、開発時 (`plugins/pr-review/skills/distill-pr-reviews/`)・`/plugin install` 後 (`~/.claude/plugins/cache/.../skills/distill-pr-reviews/`)・`apm install` 後 (`<consumer>/.claude/skills/distill-pr-reviews/`) のいずれの展開先でも一意に解決できる (`compose-review` Step 2 の `style-reference.md` パス解決と同じパターン)。

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

スクリプトは **bash 3.2 (macOS 標準の `/bin/bash`) 互換**で書いてあるため、追加インストールなしで手元の macOS でも実行できる (スクリプトを編集する際は本体冒頭の「bash 互換要件」コメントに従う)。

スクリプトは進捗を stderr に、`signals.json` の絶対パスを stdout 最終行に出す。非 0 で exit したらエラー停止して caller に報告 (主要原因: `gh` 未認証 / git リポジトリ外実行 / GraphQL ノード上限超過 / GitHub API rate limit 到達)。期間内 0 件でも exit 0 で `signals.json` (空状態) を出す。

#### スクリプトの責務 (詳細は `scripts/collect-signals.sh` の本体コメント参照)

- **Step 1-1. 入力正規化**: `OWNER` / `REPO` を `gh repo view` で auto-detect、`UNTIL` は今日 (UTC)、`SINCE` は `UNTIL - DAYS` (GNU/BSD `date` 両対応)、`OUTPUT_DIR` を確定し `mkdir -p`。
- **Step 1-2. PR 一覧取得**: `gh pr list --search "merged:${SINCE}..${UNTIL} <filters>" --json ...` で取得し `_pr_list.json` に書き出す。`--state merged` は付けない (`merged:` 検索フィルタと重複するため)。`--limit` は `MAX_PRS + 100` で超過判定できる余裕を持たせる。0 件なら空 `signals.json` を出して即終了。
- **Step 1-3. PR 詳細 (GraphQL 統合クエリ)**: PR ごとに **1 GraphQL query** で `reviewThreads(first: 50) × comments(first: 50)` + `commits(first: 100)` + `files(first: 100)` を一括取得する。reviewThreads が 50 件超の PR は `$tafter` カーソルで追加クエリ。1 thread の comments が 50 件超の場合のみ `node(id: $threadId)` + inline fragment の追加クエリで埋める (初回クエリの内側 `comments(first: 50)` に `$cafter` を持たせると外側全ノードに同 cursor が適用されて壊れるため、内側ページングは別クエリ)。1 query あたりのノード試算は 50×50 + 100 + 100 ≈ 2,700 で GraphQL の 500,000 ノード制限に対し十分小さい。PR 数 > 50 のときは PR 間で 1 秒 sleep。
  - **rate limit 設計**: 1 PR = graphql 1 query が基本ケース。69 PR でも 70 query 前後で済み、graphql 枠 5000/h の 1〜2% しか使わない。REST `pulls/{N}/commits` および `commits/{sha}` は使わない (旧設計ではこれが core 枠を数百 query 消費して rate limit 到達の主因だった)。
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
        // 旧スキーマにあった `files: string[]` (commit 別 files) は廃止。
        // 信号判定では PR 全体の `files` + コメント以降の `commits[].committed_at` で代用する。
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
          // 旧スキーマにあった `reactions: { content: string }[]` は廃止 (GraphQL のノード予算と信号価値のトレードオフで)。
        }[];
      }[];
    }[];
  };
  ```

- **Step 1-6. 信号付与 → `signals.json`**: `prs.json` の各コメントオブジェクトに `signals` フィールドを追加した同形 JSON を `${OUTPUT_DIR}/signals.json` に書き出す (PR レベルの `pr_kind` / `bugfix_signals` / `bugfix_diff` はそのまま透過する)。**機械的なスコア合算はしない**。各信号は文脈依存で、Phase C の AI が組み合わせを見て総合判断するため。

  各信号の意味 (`signals` フィールド配下):

  - `thread_resolved`: 親スレッドの `is_resolved`
  - `thread_outdated`: 親スレッドの `is_outdated`
  - `file_changed_after_comment`: PR 全体の `files` に当該コメントの `path` が含まれており、**かつ**当該コメントの `created_at` より後に committed された commit が PR に少なくとも 1 つあるか (boolean)。旧設計 (commit 別 files の一致判定) と比較すると、コメント前 commit のみで完結した変更を false positive として拾う精度劣化があるが、その精度差を取るために必要だった REST `commits/{sha}` (commit 数 × 1 query) を全廃して rate limit を救うトレードオフ。残る精度低下は Phase C の AI が body + diff_hunk で最終判断することで吸収する
  - `author_replied_affirmative`: 同一スレッドの後続コメントのうち `author_login == PR.author` のものが **肯定キーワード (`fixed` / `対応` / `修正` / `反映` / `確かに` / `その通り` / `done` / `addressed`) を body に含み、かつ否定キーワード (`対応しません` / `対応しない` / `対応せず` / `修正しません` / `修正しない` / `修正せず` / `反映しません` / `反映しない` / `反映せず` / `現状維持` / `不採用` / `不要です` / `wontfix` / `wont fix` / `not addressed` / `not fixed`) を body に含まない** か。否定キーワードは「動詞 + 否定形」または慣用句で十分な長さを持たせ、肯定キーワード (`対応` 等) との部分文字列ぶつかりと、肯定文脈で偶発的に出現する語 (例: `そのまま` 単独) との衝突を回避する。残る誤検出は許容 (Phase C の AI が body 全文を見て最終判断)
  - `severity_label`: body 内の `[must]` / `[should]` / `[nit]` / `[question]` / `[pre_existing]` を正規表現で抽出 (**body の引用行 (`> ` で始まる行) を除いた残りに対する最初のマッチを採用する仕様**、なければ `null`)。引用行を除外することで他コメントの再掲や post-pr-review マーカー直後の引用 quote で誤って severity を拾うのを防ぐ。AI 自動投稿マーカー `> **[AI 自動投稿]**` 自体は capture group の選択肢に無いため自然に skip される。body 内に複数のラベルが書かれているケース (例:「これは本来 `[must]` レベルだが本 PR では `[should]` に留める」) では最初に出てきたラベルが拾われるため、Phase C の AI は判定根拠に severity を使う際に body 全文も読んで矛盾検知すること
  - `is_ai_authored`: コメント本体の `is_ai_authored` フラグをそのまま転記
  - `author_type`: コメント本体の `author_type` (`User` / `Bot` / `Unknown`) をそのまま転記。`is_ai_authored=false` でも `author_type=Bot` なら「post-pr-review 以外の bot 経由 (例: GitHub App として登録された PR レビュー bot)」のシグナル。User account 運用の AI レビュー bot (gemini-code-assist 等) は `User` 側に分類されるため、Phase C の AI が author_login の文字列パターン (例: `*-code-assist`, `*-reviewer`, `copilot-*` 等) で補完判定する
  - `reply_count`: スレッド内コメント数 - 1
  - `comment_length`: body の文字数
  - `same_file_in_pr`: 同じ PR 内で **別 thread** に同じ `path` への指摘があるか (boolean)。同一 thread 内の reply は 1 指摘として 1 回だけカウントする (各 thread の冒頭コメントの `path` のみを集計対象にする)

  > `reactions_positive` / `reactions_negative` は旧設計にあったが廃止。GraphQL の `reactions` フィールド取得を Step 1-3 のクエリから外しているため信号としても出さない。Phase C の AI 判定でも reaction の有無は参照しない。

  クラスタリング (PR をまたいだ類似指摘の検出) は Phase C で AI が行うため、本 step では行わない。

#### スクリプト出力の取り扱い

- 中間ファイル (`_pr_list.json` / `_pr_data.jsonl` / `prs.json`) は `${OUTPUT_DIR}` に残す。Phase C で AI が判定をやり直したい場合の入力として再利用できる。
- 後段 (Step 2) で AI が読むのは `signals.json` のみ。中間ファイルは AI からは触らない。
- 0 PR の場合の `signals.json` は `meta.pr_count = 0` / `prs: []` の空状態。Step 2 / Step 3 で「該当なし」分岐に倒す。

### Step 2. AI による採否判定 (Phase C)

`signals.json` を読み、各コメントを `accept` / `hold` / `reject` に分類し、採用候補には REVIEW.md に書く提案文を作る。判定は AI 自身が行う (本セクションは AI への指示)。

#### 2-1. 採否判断軸

以下を総合して判定する:

1. **一般化可能性**
   - `accept`: ライブラリ / 言語機能 / 設計パターン / セキュリティ / テスト方針など他 PR にも応用できる指針。
   - `reject`: この PR 限定のロジック誤り、特定 issue のリグレッション、ファイル固有の名前付け修正など一回限りの話。

2. **取り込みステータス**
   - `thread_resolved=true` かつ `file_changed_after_comment=true`: 強い「取り込まれた」シグナル → accept 寄り。
   - `thread_resolved=true` のみ: 中 (resolve が「対応」とは限らないため)。
   - `thread_outdated=true` のみ: 弱 (行ズレの可能性)。
   - `author_replied_affirmative=true`: 加点。
   - どれも該当せず未 resolved: 「不明」→ `hold`。

3. **severity**
   - `[must]` / `[should]`: 採用優先。
   - `[nit]` / `[question]`: 基本棄却。ただし複数 PR で同じ nit が繰り返し出ているならクラスタとして再評価する。
   - `[pre_existing]`: 棄却 (本 PR の指針というより別 issue 化推奨)。
   - severity ラベルなし: body の内容から severity を推定 (推定ラベルは `severity_suggestion` に明示)。

4. **AI / bot 由来コメントの扱い**
   本 skill の `is_ai_authored=true` は **post-pr-review skill 経由で投稿された (`> **[AI 自動投稿]**` マーカー付き) コメント** のみを指す。それ以外の bot や外部 AI レビュー bot (gemini-code-assist / copilot-pull-request-reviewer / dependabot[bot] 等) は本フラグでは識別されないため、以下の補完信号を組み合わせて判定する:

   - `is_ai_authored=true`: post-pr-review 由来の AI 投稿。`thread_resolved=true` + `file_changed_after_comment=true` なら強信号で accept 寄り。未 resolved / `thread_outdated` のみなら弱信号で reject 寄り (ただし内容が明らかに一般化可能なら `hold`)。
   - `author_type="Bot"` (`is_ai_authored=false`): GitHub App / installation 形式の bot 由来。主要な外部 AI レビュー bot (`gemini-code-assist`, `copilot-pull-request-reviewer`, `coderabbitai`) や `dependabot[bot]` はここに分類される。レビュー指摘である保証はないため body の内容で判定する。AI レビュー bot の指摘が `thread_resolved=true` + `file_changed_after_comment=true` ならやはり強信号で accept 寄り、未 resolved なら reject 寄り、という post-pr-review 由来 (`is_ai_authored=true`) と同じ評価軸を適用する。
   - `author_type="User"` だが `author_login` が AI レビュー bot のパターン (例: `*-code-assist`, `*-reviewer`, `copilot-*`, `coderabbit*`): ごく稀に User account として運用されている AI レビュー bot の可能性。指摘内容の妥当性を AI が body で判断する。
   - **`INCLUDE_AI_AUTHORED=false` の場合は `is_ai_authored=true` のコメントのみを一律 `reject`** (棄却理由に「AI 自動投稿を対象外として除外」と明示)。本値は `signals.json` の `meta.include_ai_authored` から取得する。**外部 AI レビュー bot 由来 (author_type=Bot / login パターン一致) のコメントはこのフラグでは除外されない** (制御対象は本 skill のスコープ内である post-pr-review 由来のみ、という設計)。caller が外部 bot も一括除外したい場合は `FILTER_AUTHOR=-author:...` を `gh pr list` 側で渡す運用にする。

5. **クラスタリング (PR 横断)**
   - 類似テーマが複数 PR で出ていたら 1 つの proposal にまとめ、`sources[]` に PR URL を集約する。
   - クラスタ ID は連番 (`cluster-001` / `cluster-002` ...) で振る。
   - 単独指摘は `cluster_id=null`。
   - 出現頻度が高いほど accept 寄り (3 PR 以上の同主旨は強い採用根拠)。

6. **REVIEW.md 既存内容との重複可能性**
   - 本 skill は REVIEW.md を読まない。「これは一般に当たり前のルールで、おそらく既存 REVIEW.md に既出かも」と AI が判断したものは `reason` に「[既存方針と重複可能性]」とフラグを立て、`hold` に倒す。

7. **バグ修正PR由来の加点 (`pr_kind=bugfix`)**
   - バグ修正PRに付いたレビューコメントは「レビューがすり抜けた領域」を指す指摘であり、同種バグの再発防止に効く一般化価値が高い → accept 寄りに加点する。
   - `bugfix_signals` は raw のまま渡されるので、AI は確信度を文脈判断する (例: `is_revert=true` は本番に出荷されたバグの差し戻しで最も強い信号、`commit_type_fix` 単独は本体は別種別の PR に fix commit が混ざっただけの可能性があり弱い)。

8. **バグ修正diff由来の観点抽出 (新ソース, `source=bugfix-diff`)**
   - `pr_kind=bugfix` かつ `bugfix_diff` がある PR は、diff を読んで「このバグを事前に検出できた汎用レビュー観点」を AI が起こす。**レビューコメントが付いていない hotfix でもここから観点を抽出できる** (本 skill の従来ギャップの解消)。
   - 例: null チェック漏れの修正 → 「外部入力の null / undefined 経路を確認する」。境界値の修正 → 「ページネーション / 配列インデックスの境界を確認する」。
   - 一般化判断は axis 1 と同じ: 他 PR にも応用できる観点のみ `accept`。この PR 固有のロジック誤り (一回限り) は `reject`。`bugfix_diff_truncated=true` の場合は diff が途中までしか無い旨を踏まえ、断定できなければ `hold`。
   - クラスタリング (axis 5) はコメント由来候補とも統合してよい (同じ観点ならまとめ、`sources[]` に PR を併記)。

9. **迷ったら `hold`**
   - `resolve-pr-threads` の「迷ったら resolve しない」と同じ保守的ルール。`reject` に倒すと将来の蓄積機会を失う。

#### 2-2. 各 proposal の属性

各 proposal は以下の属性を持つ:

| 属性 | 説明 |
|---|---|
| `verdict` | `accept` / `hold` / `reject` |
| `source` | 抽出源。`review-comment` (レビューコメント由来) / `bugfix-diff` (バグ修正diff由来)。クラスタに両方含む場合は主たる根拠を記し `sources[]` に内訳を残す。 |
| `reason` | 採否の理由 (1〜2 文)。重複可能性 / 一般化不能などのフラグもここに含める。 |
| `proposal_text` | REVIEW.md に書くなら何と書くか (Markdown bullet point 1〜3 行)。`reject` の場合は null。 |
| `severity_suggestion` | REVIEW.md に載せる場合の severity ラベル (`[must]` / `[should]` / `[nit]`)。元コメントの severity を踏襲、なければ推定。 |
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
- 保留: <Y> 件
- 棄却: <Z> 件
- 生成日時: <ISO8601 UTC 秒精度>

## 後続フロー

1. 本ファイルを人間または別 skill が読み、「採用候補」セクションの提案文を REVIEW.md へ追記する PR を作成する
2. 「保留」セクションは個別判断 (採用 / 棄却 / 文面修正の上で採用 のどれにするか)
3. 「棄却」セクションは記録のみ。同じ指摘が次回も繰り返し棄却されないよう判断履歴として残す

中間ファイル `prs.json` / `signals.json` は再判定時の入力として ${OUTPUT_DIR} に残してある。

---

## 採用候補

### 1. [cluster-001] [should] (source: review-comment) <一般化したルールのタイトル>

**提案文 (REVIEW.md 追記想定)**:

> - <REVIEW.md にそのまま書く想定の bullet。1〜3 行。>

**判定根拠**: <reason 本文。クラスタの場合は出現 PR 数 / 取り込み率を併記。>

**信号**: <signals_summary>

**出典**:
- https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... (人間レビュー / AI 自動投稿 の別を併記)
  > <body 引用、200 文字超は省略>
- https://github.com/<OWNER>/<REPO>/pull/<N+5>#discussion_r... (AI 自動投稿)
  > <body 引用>

### 2. [should] (source: bugfix-diff) <バグ修正diffから一般化したレビュー観点のタイトル>

**提案文 (REVIEW.md 追記想定)**:

> - <このバグを事前に検出できた汎用レビュー観点の bullet。1〜3 行。>

**判定根拠**: <どのバグ修正からどう一般化したか。is_revert 等の強信号があれば明記。>

**信号**: pr_kind=bugfix, <マッチした bugfix_signals (例: is_revert=true)>

**出典**:
- https://github.com/<OWNER>/<REPO>/pull/<N> (バグ修正PR: <title>)
  > <修正の要点。diff の該当箇所を簡潔に引用、長い場合は要約>

### 3. <以下、採用候補ごとに繰り返し (source を併記)>

---

## 保留

### H1. [should] <タイトル>

**判定保留理由**: <reason>

**信号**: <signals_summary>

**出典**:
- https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r...
  > <body 引用>

### H2. <以下、保留ごとに繰り返し>

---

## 棄却

| # | severity | 理由 | 出典 |
|---|---|---|---|
| R1 | [nit] | 好み寄り / 一般化不能 | https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... |
| R2 | [must] | この PR 固有のロジック誤り | https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... |
| R3 | [should] | AI 自動投稿で行ズレのみ (取り込まれていない) | https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... |
```

期間内 0 PR でも proposals.md は空状態 (採用 0 / 保留 0 / 棄却 0、各セクションは「該当なし」と明示) で出力する (skip しない)。

「生成日時」は実行時に `date -u +%Y-%m-%dT%H:%M:%SZ` で取得する。`date` が利用できなければ caller / 実行環境から提供される現在日時を使い、それも無ければ `<unknown>` と記載する。

### Step 4. caller への報告

以下を簡潔に caller へ返す:

- 対象期間 (`SINCE`..`UNTIL`) / 対象リポジトリ
- 対象 PR 数 / バグ修正PR数 / 抽出コメント数 / 採用・保留・棄却の内訳件数 (採用のうち bugfix-diff 由来件数も)
- 出力先パス (`OUTPUT_DIR/proposals.md` / `prs.json` / `signals.json`)
- `MAX_PRS` 超過時 / `bugfix_diffs_truncated=true` の場合はその旨を 1 行で追記

チャットに proposals.md 全文をダンプしない (件数が多いケースで後続会話のコンテキストを圧迫するため)。出力先パスと冒頭メタ + 件数内訳のみをチャットに出し、詳細は markdown ファイルを参照させる。

## 守ること

- READ-ONLY: GitHub 投稿 / PR 作成 / commit / push / `git fetch` / `git checkout` などローカル ref を書き換える操作は一切しない。`gh pr comment` / `gh pr review` / `gh api .../reviews` / `gh pr create` も使わない。
- `post-pr-review` / `resolve-pr-threads` / `run-pr-review` / `run-local-review` skill は呼ばない (独立 skill)。
- 既存資産 `/pr-review-style-reference` の severity ラベル定義は **slash command 経由でのみ利用** し、本 skill 内で再掲・再実装しない (二重管理を避けるため)。
- **Phase A + B (PR 一覧 / GraphQL 統合クエリ / 信号付与) は `scripts/collect-signals.sh` に集約してある**。AI 側でこれらを `gh` / `jq` 直叩きで再実装してはならない (差異が出てスクリプトとプロンプトの責務分割が崩れるため)。信号定義を変えたい場合はスクリプトと本 SKILL.md の `signals` フィールド定義をセットで更新する。
- **機械的なスコア合算は禁止**。信号は `signals.json` に raw のまま付与し、Phase C の AI が総合判断する。理由は信号の文脈依存性 (例: `outdated` 単独は行ズレ可能性)。
- 対象は **merged PR のみ**。open / closed unmerged は対象外 (取り込み判定が安定しないため)。
- 期間内 0 PR でも proposals.md は空状態で出力する (skip しない)。
- 判定に迷ったら `hold` に倒す (`resolve-pr-threads` の「迷ったら resolve しない」と同思想)。`reject` に倒すと将来の蓄積機会を失う。
- proposals.md は **本 skill のスコープの終点**。REVIEW.md 編集 / PR 作成は別工程で行うことを caller に明示する。
