---
name: distill-pr-reviews
description: 期間内 merged PR のレビューコメント (AI 自動投稿 + 人間レビュー両方) を集約し、REVIEW.md に追記する価値のある指摘候補を proposals.md として出力する skill。取り込み判定の信号収集はスクリプト、最終的な採否分類とクラスタリングは AI が行う。本 skill は read-only で、REVIEW.md の編集や PR 作成は行わない。
---

# distill-pr-reviews skill

過去 merged PR のレビューコメントから「REVIEW.md に蓄積する価値のある指摘」を抽出する skill。
出力 (`proposals.md`) を後工程 (人間 or 別 skill) が読んで REVIEW.md 編集 PR を作る、という運用を想定している。

**本 skill のスコープは proposals.md 出力で停止する。** REVIEW.md の編集 / commit / push / PR 作成は一切行わない。
状態管理ファイルは持たず、毎回期間引数を渡す方式 (運用がシンプルで監査性が高い)。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。省略時の挙動は各項目に記載。

- `OWNER` / `REPO`: 対象リポジトリ。省略時は `gh repo view --json nameWithOwner -q .nameWithOwner` で cwd の git リポジトリから自動推定する。ドッグフーディング時の取り違え防止のため明示推奨。
- `SINCE` / `UNTIL`: merged at で絞る期間 (`YYYY-MM-DD` 形式、UTC)。`SINCE` 省略時は `UNTIL - DAYS`、`UNTIL` 省略時は今日 (UTC) を使う。両方省略時は「過去 `DAYS` 日」になる。
- `DAYS`: `SINCE` 未指定時のフォールバック期間 (日数)。省略時 `7`。`SINCE` が指定されていれば無視される。
- `MAX_PRS`: 期間内 PR 数の上限警告閾値。省略時 `100`。超過しても処理は継続し、proposals.md 冒頭に「対象 PR が多いため信号品質が低下している可能性あり」を明記する。
- `FILTER_AUTHOR`: PR 作成者で絞り込む (例: `dependabot[bot]` を除外したい場合は `-author:dependabot[bot]` 形式で渡す)。省略時はフィルタなし。`gh pr list --search` の検索式にそのまま連結する。
- `FILTER_LABEL`: PR ラベルで絞り込む (例: `label:bug`)。省略時はフィルタなし。同上、`--search` に連結する。
- `INCLUDE_AI_AUTHORED`: `> **[AI 自動投稿]**` プレフィックス付きのコメントを採否候補に含めるか。省略時 `true`。`false` の場合でも信号 (`is_ai_authored`) は付与するが、Phase C で AI が一律 reject に倒す。
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

1. **PR 一覧は REST、reviewThreads は GraphQL の混在採用**: `gh pr list --search` がページング込みで便利、reviewThreads は GraphQL でしか取れない。
2. **信号スコア合算を script でなく AI に委ねる**: 信号は文脈依存 (例: `is_outdated=true` 単独は「修正された」か「単に行ズレした」かの判別不能) で、機械合算するとノイズが大きい。`signals.json` には raw のまま付与し、Phase C の AI が総合判断する。
3. **クラスタリングは Phase C (AI)**: 意味類似度判定が bash/jq では困難なため。Phase B では `path` ベースの「同一ファイル指摘」フラグだけ立てる。
4. **採否は三値 (`accept` / `hold` / `reject`)**: 二値だと判断不能ケースが reject に流れて将来の蓄積機会を失う。迷ったら `hold` (`resolve-pr-threads` の保守的ルールと同思想)。
5. **REVIEW.md 既存内容との重複判定は本 skill ではしない**: 後続フロー (REVIEW.md 編集) との責務分離を保つ。AI は proposals.md に「重複可能性あり」フラグだけ立てる。

## 手順

### Step 0. 入力の正規化

- `OWNER` / `REPO` 未指定なら `gh repo view --json nameWithOwner -q .nameWithOwner` で取得。git リポジトリ外で実行された / `gh` が認証されていない場合はエラー停止し、caller に `OWNER` / `REPO` を明示するよう促す。
- `UNTIL` 未指定なら `date -u +%Y-%m-%d`、`SINCE` 未指定なら `date -u -d "${UNTIL} - ${DAYS} days" +%Y-%m-%d` (BSD `date` 環境では `date -u -v -${DAYS}d -j -f %Y-%m-%d "${UNTIL}" +%Y-%m-%d`)。
- `OUTPUT_DIR` を確定し `mkdir -p "${OUTPUT_DIR}"` で作成。
- `INCLUDE_AI_AUTHORED` のデフォルトは `true`。

### Step 1. 期間内 merged PR 一覧を取得する (Phase A 開始)

`gh pr list` の `--search` で merged 期間を絞り、JSON で取得する。`FILTER_AUTHOR` / `FILTER_LABEL` が指定されていれば検索式に連結する。

```bash
SEARCH="merged:${SINCE}..${UNTIL}"
[ -n "${FILTER_AUTHOR}" ] && SEARCH="${SEARCH} ${FILTER_AUTHOR}"
[ -n "${FILTER_LABEL}" ] && SEARCH="${SEARCH} ${FILTER_LABEL}"

gh pr list \
  --repo "${OWNER}/${REPO}" \
  --state merged \
  --search "${SEARCH}" \
  --json number,title,author,mergedAt,headRefOid,mergeCommit,baseRefName,headRefName,labels \
  --limit $((MAX_PRS + 100)) \
  > "${OUTPUT_DIR}/_pr_list.json"
```

`--limit` は `MAX_PRS + 100` 程度を渡し、超過分も拾って後段で警告判断する (`MAX_PRS` ぴったりで切ると「超過しているのか境界か」が判別できなくなるため)。

取得件数が `MAX_PRS` を超えていれば警告ログを出す (停止はしない)。0 件でも継続し、proposals.md は空状態で出力する。

### Step 2. 各 PR の reviewThreads を取得する

PR ごとに GraphQL で `reviewThreads` を取得する。`resolve-pr-threads` Step 1 のクエリを拡張し、`comments` 配下から `body` / `createdAt` / `originalLine` / `diffHunk` / `reactions` / `author.login` まで取得する。

```bash
gh api graphql \
  -F owner="${OWNER}" \
  -F name="${REPO}" \
  -F number="${PR_NUMBER}" \
  -f query='
    query($owner: String!, $name: String!, $number: Int!, $after: String, $cafter: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              isResolved
              isOutdated
              comments(first: 100, after: $cafter) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id
                  author { login }
                  body
                  createdAt
                  path
                  line
                  originalLine
                  diffHunk
                  url
                  reactions(first: 100) {
                    nodes { content }
                  }
                }
              }
            }
          }
        }
      }
    }'
```

ページネーション 2 段:

- 外側 `reviewThreads(first: 100, after: $after)`: `pageInfo.hasNextPage` が `true` なら `-F after=<endCursor>` を付けて再実行。
- 内側 `comments(first: 100, after: $cafter)`: 100 件超のスレッドがあるケースに備える。`pageInfo.hasNextPage` を見て該当スレッドだけ追加クエリで埋める。

レート制限対策として PR 数が 50 を超える場合は PR 間で 1 秒スリープを挟む。`gh api graphql` の内部リトライに任せ、明示的なリトライループは書かない (二重投稿の心配は無いが、レート制限エラー時にスクリプトが詰まらないように)。

### Step 3. 各 PR の commits と変更ファイルを取得する

`gh pr view` で commit 一覧、各 commit の変更ファイルは `gh api repos/.../commits/<sha>` で取得する。

```bash
gh pr view "${PR_NUMBER}" \
  --repo "${OWNER}/${REPO}" \
  --json commits \
  --jq '.commits[] | {sha: .oid, committed_at: .committedDate, message: .messageHeadline}'

# 変更ファイルは必要な commit についてのみ遅延取得 (N+1 を避けるため Phase B で必要分のみ)
gh api "repos/${OWNER}/${REPO}/commits/${COMMIT_SHA}" \
  --jq '.files[].filename'
```

`files[]` の取得は Phase B の `file_changed_after_comment` 判定で必要になった commit についてのみ呼ぶ。

### Step 4. 中間ファイル `prs.json` を組み立てる

Step 1〜3 の結果を 1 ファイルに集約する。スキーマ (TypeScript ライク):

```ts
type Collected = {
  meta: {
    owner: string;
    repo: string;
    since: string;        // YYYY-MM-DD
    until: string;        // YYYY-MM-DD
    collected_at: string; // ISO8601 UTC
    pr_count: number;
    max_prs_exceeded: boolean;
  };
  prs: {
    number: number;
    title: string;
    author: string;
    merged_at: string;
    head_sha: string;
    merge_commit_sha: string;
    base_ref: string;
    head_ref: string;
    labels: string[];
    url: string;
    commits: {
      sha: string;
      committed_at: string;
      message_headline: string;
      files?: string[];   // Phase B で必要な分のみ後埋め
    }[];
    review_threads: {
      thread_id: string;
      is_resolved: boolean;
      is_outdated: boolean;
      comments: {
        id: string;
        author_login: string;
        body: string;
        created_at: string;
        path: string;
        line: number | null;
        original_line: number | null;
        diff_hunk: string;
        url: string;
        reactions: { content: string }[];
        is_ai_authored: boolean;  // body 先頭 `^> \*\*\[AI 自動投稿\]\*\*` を正規表現判定
      }[];
    }[];
  }[];
};
```

`is_ai_authored` の判定は `jq` で次のように行う:

```bash
jq '(.body | test("^> \\*\\*\\[AI 自動投稿\\]\\*\\*"))'
```

ファイルパス: `${OUTPUT_DIR}/prs.json`

### Step 5. 信号を抽出する (Phase B)

`prs.json` を読み、各コメントに raw signals を付与した `signals.json` を作る。**機械的なスコア合算はしない**。各信号は文脈依存で、Phase C の AI が組み合わせを見て総合判断するため。

抽出する信号:

- `thread_resolved`: 親スレッドの `is_resolved`
- `thread_outdated`: 親スレッドの `is_outdated`
- `file_changed_after_comment`: 当該コメントの `created_at` 以降に committed された commit のうち `files[]` に `comment.path` を含むものがあるか (boolean)。判定のために Step 3 の files 取得を遅延実行する。
- `author_replied_affirmative`: 同一スレッドの後続コメントのうち `author_login == PR.author` のものが「fixed / 対応 / 修正 / 反映 / 確かに / その通り / done / addressed」等のキーワードを body に含むか。キーワードリストは固定 (誤検出は許容、Phase C の AI が body 全文を見て最終判断する)。
- `severity_label`: body 先頭の `[must]` / `[should]` / `[nit]` / `[question]` / `[pre_existing]` を正規表現で抽出 (なければ null)。AI 自動投稿マーカーの後に severity ラベルが来るケースも考慮 (マーカー行を skip して次の非空行先頭を見る)。
- `is_ai_authored`: Phase A で計算済みのフラグをそのまま転記。
- `reply_count`: スレッド内コメント数 - 1。
- `reactions_positive`: `+1` / `heart` / `hooray` / `rocket` のリアクション数合計。
- `reactions_negative`: `-1` / `confused` のリアクション数合計。
- `comment_length`: body の文字数 (nit ほど短い傾向の補助信号)。
- `same_file_in_pr`: 同じ PR 内で同じ `path` に複数指摘があるか (boolean)。横展開信号。

クラスタリング (PR をまたいだ類似指摘の検出) は Phase C で AI が行うため、Phase B では行わない。

出力ファイル: `${OUTPUT_DIR}/signals.json`。スキーマは `prs.json` と同形で、各コメントオブジェクトに `signals` フィールドを追加した構造。

### Step 6. AI による採否判定 (Phase C)

`signals.json` を読み、各コメントを `accept` / `hold` / `reject` に分類し、採用候補には REVIEW.md に書く提案文を作る。判定は AI 自身が行う (本セクションは AI への指示)。

#### 6-1. 採否判断軸

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

4. **AI 自動投稿の扱い** (`is_ai_authored=true`)
   - AI 指摘 + `thread_resolved=true` + `file_changed_after_comment=true`: 「AI 指摘 → 人間が取り込み」= 強信号で accept 寄り。
   - AI 指摘 + 未 resolved / `thread_outdated` のみ: 「AI 指摘 → 無視 or 行ズレ」= 弱信号で reject 寄り。ただし内容が明らかに一般化可能なら `hold` に倒す。
   - `INCLUDE_AI_AUTHORED=false` の場合は内容を問わず一律 `reject` (棄却理由に「AI 自動投稿を対象外として除外」と明示)。

5. **クラスタリング (PR 横断)**
   - 類似テーマが複数 PR で出ていたら 1 つの proposal にまとめ、`sources[]` に PR URL を集約する。
   - クラスタ ID は連番 (`cluster-001` / `cluster-002` ...) で振る。
   - 単独指摘は `cluster_id=null`。
   - 出現頻度が高いほど accept 寄り (3 PR 以上の同主旨は強い採用根拠)。

6. **REVIEW.md 既存内容との重複可能性**
   - 本 skill は REVIEW.md を読まない。「これは一般に当たり前のルールで、おそらく既存 REVIEW.md に既出かも」と AI が判断したものは `reason` に「[既存方針と重複可能性]」とフラグを立て、`hold` に倒す。

7. **迷ったら `hold`**
   - `resolve-pr-threads` の「迷ったら resolve しない」と同じ保守的ルール。`reject` に倒すと将来の蓄積機会を失う。

#### 6-2. 各 proposal の属性

各 proposal は以下の属性を持つ:

| 属性 | 説明 |
|---|---|
| `verdict` | `accept` / `hold` / `reject` |
| `reason` | 採否の理由 (1〜2 文)。重複可能性 / 一般化不能などのフラグもここに含める。 |
| `proposal_text` | REVIEW.md に書くなら何と書くか (Markdown bullet point 1〜3 行)。`reject` の場合は null。 |
| `severity_suggestion` | REVIEW.md に載せる場合の severity ラベル (`[must]` / `[should]` / `[nit]`)。元コメントの severity を踏襲、なければ推定。 |
| `sources` | 出典 PR / comment URL のリスト + body 引用 (200 文字超は先頭 200 文字 + `...`)。クラスタリングされていれば複数 PR 分。 |
| `cluster_id` | クラスタリングしたなら `cluster-NNN`、単独なら null。 |
| `signals_summary` | 判定根拠になった主要信号 3〜5 個 (raw signals 全部ではなく抜粋)。例: `thread_resolved=true, file_changed_after_comment=true, severity=[should]`。 |

### Step 7. proposals.md を出力する (Phase D)

`${OUTPUT_DIR}/proposals.md` に `Write` ツールで書き出す。`run-local-review` Step 6 と同じく、書き出し前に `mkdir -p` で親ディレクトリを作成し、既存ファイルがあれば `Read` を 1 回挟んでから `Write` する。`heredoc` や `cat` リダイレクトは使わない。

スキーマ:

```markdown
# REVIEW.md 候補案 (proposals.md)

- 期間: <SINCE> 〜 <UNTIL> (UTC)
- 対象リポジトリ: <OWNER>/<REPO>
- 対象 PR 数: <N> 件 (max_prs=<MAX_PRS> <超過時のみ「超過: 信号品質低下の可能性あり」を追記>)
- 抽出コメント総数: <M> 件 (うち AI 自動投稿 <A> 件 / 人間 <H> 件)
- 採用候補: <X> 件 (クラスタ: <C> 個 / 単独: <S> 件)
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

### 1. [cluster-001] [should] <一般化したルールのタイトル>

**提案文 (REVIEW.md 追記想定)**:

> - <REVIEW.md にそのまま書く想定の bullet。1〜3 行。>

**判定根拠**: <reason 本文。クラスタの場合は出現 PR 数 / 取り込み率を併記。>

**信号**: <signals_summary>

**出典**:
- https://github.com/<OWNER>/<REPO>/pull/<N>#discussion_r... (人間レビュー / AI 自動投稿 の別を併記)
  > <body 引用、200 文字超は省略>
- https://github.com/<OWNER>/<REPO>/pull/<N+5>#discussion_r... (AI 自動投稿)
  > <body 引用>

### 2. <以下、採用候補ごとに繰り返し>

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

### Step 8. caller への報告

以下を簡潔に caller へ返す:

- 対象期間 (`SINCE`..`UNTIL`) / 対象リポジトリ
- 対象 PR 数 / 抽出コメント数 / 採用・保留・棄却の内訳件数
- 出力先パス (`OUTPUT_DIR/proposals.md` / `prs.json` / `signals.json`)
- `MAX_PRS` 超過時はその旨を 1 行で追記

チャットに proposals.md 全文をダンプしない (件数が多いケースで後続会話のコンテキストを圧迫するため)。詳細は markdown を参照させる方式は `run-local-review` Step 6-2 と同じ。

## 守ること

- READ-ONLY: GitHub 投稿 / PR 作成 / commit / push / `git fetch` / `git checkout` などローカル ref を書き換える操作は一切しない。`gh pr comment` / `gh pr review` / `gh api .../reviews` / `gh pr create` も使わない。
- `post-pr-review` / `resolve-pr-threads` / `run-pr-review` / `run-local-review` skill は呼ばない (独立 skill)。
- 既存資産 `/pr-review-style-reference` の severity ラベル定義は **slash command 経由でのみ利用** し、本 skill 内で再掲・再実装しない (二重管理を避けるため)。
- **機械的なスコア合算は禁止**。信号は `signals.json` に raw のまま付与し、Phase C の AI が総合判断する。理由は信号の文脈依存性 (例: `outdated` 単独は行ズレ可能性)。
- 対象は **merged PR のみ**。open / closed unmerged は対象外 (取り込み判定が安定しないため)。
- 期間内 0 PR でも proposals.md は空状態で出力する (skip しない)。
- 判定に迷ったら `hold` に倒す (`resolve-pr-threads` の「迷ったら resolve しない」と同思想)。`reject` に倒すと将来の蓄積機会を失う。
- proposals.md は **本 skill のスコープの終点**。REVIEW.md 編集 / PR 作成は別工程で行うことを caller に明示する。
