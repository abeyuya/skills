---
name: post-pr-review
description: PR レビュー結果を1つの Review として GitHub に投稿する。複数のインライン指摘や総括コメントを含むレビューを投稿する場合は必ずこの skill を使うこと。`gh pr comment` / `gh pr review` / MCP の個別コメント投稿ツールを使った個別投稿は禁止。gh CLI / GitHub MCP ツールのどちらのチャネル (`CHANNEL=gh|mcp`) でも投稿できる。
---

# post-pr-review skill

PR レビュー結果を **「1つの Review」として投稿** する手順を提供する skill。
人間レビュアーの "Submit Review" と同じ構造で投稿する。

## 守ること

- レビュー結果は **必ず「1 つの Review」** として投稿する (`CHANNEL=gh` は 1 回の API コール、`CHANNEL=mcp` は pending review を組み立ててから 1 度に submit。いずれも GitHub 上では 1 つの Review オブジェクトになり、散らばった個別コメントにはならない)。
- 個別投稿系のツール (`mcp__github_inline_comment__create_inline_comment`、`mcp__github__add_issue_comment`、`gh pr comment` 等) は **使わない**。
- `event` は **常に `COMMENT`**。`APPROVE` / `REQUEST_CHANGES` は使わない (Bot がマージブロックや承認権を持つことを避けるため)。
- インラインコメントの本文フォーマット (重要度ラベル等) は **caller のレビュー方針に従う**。本 skill は手続きのみを担い、レビュー文面の規約は規定しない。
- 総括 `body` の先頭には **AI 自動投稿マーカーを必ず付与する** (詳細は「手順 1」参照)。認証主体が人間 PAT でも投稿内容は AI 生成であることを明示するため。caller 側で事前に付与する必要はなく、本 skill が一律に prepend する。エージェント名 (Claude Code / Codex / Cursor 等) はマーカーに含めない (本 skill は複数の AI エージェントから呼ばれうる前提)。
- 総括 `body` には **機械可読サマリ行 (`AI-REVIEW-RESULT`) を必ず 1 行埋め込む** (指摘 0 件でも省略しない)。CI からの機械判定用の公開契約であり、フォーマット / 挿入位置 / 集計ルールは「機械可読サマリ行 (`AI-REVIEW-RESULT`)」節を正典とする。

## Public Payload Interface

本 skill は「レビュー本文を受け取って GitHub Review として投稿するだけ」の純粋な投稿 skill。レビュー自体をどう生成するか (どの skill / どのエージェント / どんな観点で書くか) には関与しない。

下記の Payload スキーマと呼び出し経路は **本 skill の公開インターフェース** として扱う。`run-pr-review` 等の上流 skill 経由でも、人手 / 外部システムから直接呼ぶ場合でも、同一の Payload を受け付ける。後方互換性に注意して変更すること (キー追加は可、既存キーの削除 / 型変更 / 必須化はインターフェース変更扱い)。

### 識別情報 (必須)

- `OWNER` / `REPO` / `PR_NUMBER`: 対象 PR を一意に決める 3 値。Skill 自身は PR を自動推定せず、caller が必ず渡す。

### GitHub アクセスチャネル (任意)

- `CHANNEL`: `gh` または `mcp`。投稿に使う経路。caller (`run-pr-review` Step 1) が解決済みならその値を渡す。**未指定なら `run-pr-review` Step 1-2 と同じ手順で自力解決する** (gh probe → MCP ツールの有無 → どちらも不可ならエラー停止。解決手順は `run-pr-review` Step 1-2 を正典とする)。gh と MCP は対等な正規チャネル。

### Payload スキーマ

caller が渡す Payload (TypeScript ライクに表記。マーカー prepend 前の生本文):

```ts
type ReviewPayload = {
  body: string;                // 必須。総括コメント本文 (Markdown 可)。AI 自動投稿マーカーと機械可読サマリ行は skill 側で自動 prepend するため caller は付けない。指摘なし時も「特に指摘なし」相当の本文を入れる。
  event: "COMMENT";            // 必須。リテラル固定。"APPROVE" / "REQUEST_CHANGES" は禁止。
  comments: ReviewComment[];   // 必須。空配列 ([]) 可。
  commit_id?: string;          // 任意。head commit の SHA。force-push / rebase での行ズレ防止に推奨。省略時は GitHub 側で最新 commit を採用。
  label_counts?: Record<string, number>; // 任意。ラベル別指摘件数の正典値 (prompt 経由では `LABEL_COUNTS`)。渡されれば機械可読サマリ行の集計に優先採用される。詳細は「機械可読サマリ行」節。
};

type ReviewComment =
  | {                          // 単一行コメント
      path: string;            // 必須。リポジトリ root からの相対パス。
      line: number;            // 必須。1-based。
      side: "RIGHT" | "LEFT";  // 必須。新ファイル側 (RIGHT) / 旧ファイル側 (LEFT)。通常 "RIGHT"。
      body: string;            // 必須。本文 (重要度ラベル等は caller の方針に従う)。
    }
  | {                          // 複数行範囲コメント
      path: string;
      start_line: number;      // 必須。範囲開始行。`line` より前の行であること。
      start_side: "RIGHT" | "LEFT"; // 必須。
      line: number;            // 必須。範囲終了行。
      side: "RIGHT" | "LEFT";  // 必須。
      body: string;            // 必須。
    };
```

`commit_id` は caller 側で PR の head SHA (`headRefOid`) を取得して渡すと、force-push / rebase で行ズレが起きた際の誤コメントを防げる (`run-pr-review` Step 2 が CHANNEL に応じて `gh pr view --json headRefOid` または `mcp__github__pull_request_read` method=`get` で取得済みの値を流用する想定)。加えて **CI が「現在の head SHA に対するレビューか」を review の `commit_id` で判定する** 運用では、`commit_id` を渡さないと GitHub 側が投稿時点の最新 commit を採用するため照合が不確実になる。機械判定を前提にするなら caller は常に `COMMIT_ID` を渡すこと (詳細は「機械可読サマリ行」節の「CI 側の使い方」)。

`label_counts` は **`MAX_INLINE_COMMENTS` による省略分やラベル体系の独自定義を正しくサマリ行へ反映したい caller 向けの任意入力**。prompt 経由では 1 行の JSON (`LABEL_COUNTS={"must":1,"should":2,"nit":0,"question":0,"pre_existing":0,"other":0}`) として渡す (KEY=VALUE parse を壊さないため改行を含めない)。渡されなければ本 skill が `comments[]` から集計する (集計ルールと精度上の注意は「機械可読サマリ行」節)。

### 契約の前提 (Payload 設計上の制約)

- `body` 先頭の **AI 自動投稿マーカー** と **機械可読サマリ行** は本 skill が自動 prepend する。caller は付けない (詳細は「手順 1」のマーカー文言と「機械可読サマリ行」節を参照)。
- `event` は **常に `COMMENT`** (Bot がマージブロック / 承認権を持つことを避けるため、`APPROVE` / `REQUEST_CHANGES` は禁止)。
- `comments[].body` の本文フォーマット (`[must]` / `[should]` 等の重要度ラベル等) は **caller のレビュー方針** に従う。本 skill は手続きのみを担う。
- `comments[].body` には Review 本体側のマーカーで帰属が示されるため **個別マーカーを付けない**。

### 呼び出し経路

#### (a) 上流 skill から Skill ツール経由で呼ぶ場合

`run-pr-review` Step 4 のように、上流 skill が `OWNER` / `REPO` / `PR_NUMBER` (+ 解決済みなら `CHANNEL`) と Payload (`body` / `event` / `comments[]` / 任意で `commit_id`) を組み立てて Skill ツールの引数として渡す。投稿の実行 (CHANNEL に応じた `gh api` または MCP ツール呼び出し。詳細は「手順」) は本 skill 側で行う。caller 側で先回りして JSON を書き出したり API を叩いたりする必要はない。

#### (b) 人手 / 外部システムから prompt 経由で呼ぶ場合

prompt の中に上記スキーマに沿った Payload を埋め込んで本 skill を起動する。最小例:

```
post-pr-review skill を呼んでください。

OWNER: octocat
REPO: hello-world
PR_NUMBER: 42
COMMIT_ID: 9f8e7d6c1a2b3c4d5e6f7890abcdef1234567890
LABEL_COUNTS: {"must":0,"should":1,"nit":0,"question":0,"pre_existing":0,"other":0}

body: |
  ## 総合判断
  概ね問題なし。下記 1 点のみ確認お願いします。

event: COMMENT
comments:
  - path: src/example.ts
    line: 42
    side: RIGHT
    body: "[should] ここの処理は null チェックが抜けています。"
```

caller (人 / 外部システム) は Payload を渡すだけで、投稿の実行 (CHANNEL の解決・`gh api` / MCP ツール呼び出し) は本 skill が行う。`LABEL_COUNTS` は任意なので省略してよい (省略時は `comments[]` から集計)。

## 機械可読サマリ行 (`AI-REVIEW-RESULT`)

本 skill は投稿する Review の `body` に **ラベル別指摘件数の機械可読サマリ行を必ず 1 行埋め込む**。CI (GitHub Actions の required status check 等) が「AI レビュー済みか / ブロッキング指摘が残っているか」を機械判定するための **公開契約 (CI がパースする契約)** として扱い、後方互換に注意して変更する (キー追加は可、既存キーの削除 / 意味変更 / 順序変更は契約変更扱い)。

### フォーマット

```
<!-- AI-REVIEW-RESULT: must=0 should=1 nit=2 question=0 pre_existing=0 other=0 -->
```

- **HTML コメント**なので GitHub 上の人間向け表示 (PR の Conversation タブ) には現れず、レビュー本文の可読性を汚さない。一方 REST API (`GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews`) が返す各 review の `body` にはそのまま残るため、CI から正規表現でパースできる。
- キーは **上記 6 つを固定順で必ず全て出力する**。件数 0 のキーも省略しない (「レビュー実施済みで指摘ゼロ」を CI が判別できることが本サマリ行の必須要件)。
- 値は 0 以上の整数。区切りは半角スペース 1 個。**1 つの Review body にサマリ行は 1 行だけ**。
- 挿入位置は **AI 自動投稿マーカーの直後 (区切り線 `---` より前)** に固定する (手順 1 参照)。caller 由来の総括本文の中には入れない (本文中の任意位置に散らすと 1 行契約が崩れる)。
- **指摘 0 件 (`comments: []`) でも必ず出力する**。この場合は全キーが `0` の行になる。

### 集計ルール

1. caller から `LABEL_COUNTS` (Payload の `label_counts`) が渡されていれば **それを正典として採用する**。`MAX_INLINE_COMMENTS` による省略分を含む正確な件数を持つのは caller (レビュー生成側) だけなので、渡された値を本 skill 側で再計算・上書きしない。
   - 標準 5 ラベル (`must` / `should` / `nit` / `question` / `pre_existing`) 以外のキーは `other` に合算する。標準ラベルのうち渡されなかったキーは `0` とみなす。
   - JSON として parse できない / 値が非負整数でない場合は `LABEL_COUNTS` を無視して下記 2 の `comments[]` 集計にフォールバックし、その旨を caller への報告に 1 行残す (投稿自体は継続する)。
2. `LABEL_COUNTS` が無ければ **`comments[]` の各 `body` 先頭の重要度ラベルを本 skill 側で集計する**。
   - 判定は `body` の **先頭**に対して正規表現 `^\[([A-Za-z_]+)\]` をマッチさせ (本文中に現れる `[must]` 等は数えない)、**捕捉したラベルを小文字化してから**標準ラベルと突合する (`[MUST]` のような大文字表記も `must` として数える。regex を小文字クラスに絞ると大文字表記が捕捉されず `other` に落ち、CI が `must=0` と誤判定しうる)。
   - 標準 5 ラベル (`must` / `should` / `nit` / `question` / `pre_existing`) はそれぞれのキーへ加算する。
   - **未知ラベル (caller 独自定義の `[blocker]` 等) / ラベル無しコメントは `other` に加算する** (無視して落とすと合計が `comments[]` 件数と合わなくなり、サマリ行から「集計漏れ」と「本当に指摘なし」を区別できなくなるため、`other` に寄せる方式を採る)。
   - 重要度ラベル種別は caller が独自定義できる (`/pr-review-style-reference` 参照) 一方、サマリ行のキーは上記 6 つ固定。したがって独自ラベル運用の caller は下記「制約」に従い `LABEL_COUNTS` でのマッピングを行う。

### CI 側の使い方 (参考)

- **パース例** (`must` / `should` だけ見る最小形):

  ```
  must=(\d+) should=(\d+)
  ```

  全キーを取る場合 (空白の揺れに耐える形):

  ```
  <!--\s*AI-REVIEW-RESULT:\s*must=(\d+)\s+should=(\d+)\s+nit=(\d+)\s+question=(\d+)\s+pre_existing=(\d+)\s+other=(\d+)\s*-->
  ```

- **合格条件の例**: 「PR の現在の head SHA に対して AI レビューが投稿済み、かつ `must` / `should` が 0 件」→ サマリ行を含む review が head SHA に対して存在し、その `must=0` かつ `should=0`。
- **head SHA に対するレビューかの判定** は review の `commit_id` を PR の head SHA と比較する (本 skill は `COMMIT_ID` が渡された場合のみ `commit_id` を送るため、機械判定を前提にするなら caller は常に `COMMIT_ID` を渡す。`run-pr-review` は Step 2 で取得した `headRefOid` を常時転送するので、その経路なら常に付く)。`COMMIT_ID` を渡さないと GitHub 側が投稿時点の最新 commit を採用するため、force-push と競合したときに照合が不確実になる。本改修で `COMMIT_ID` まわりの挙動自体は変更していない。
- 同一 head SHA に対してサマリ行を含む review が複数ある場合 (再レビュー等) は **最新の review** を採用する。
- 1 つの review body 内に同形の文字列が複数現れた場合は **最初のマッチを採用する**。本 skill が prepend する 1 行は常に body の冒頭側 (マーカー直後) にあり、caller 由来の総括本文はその後ろに連結されるため、最初のマッチが必ず本 skill の出力になる (本 plugin のドキュメント自体をレビューして総括にフォーマット例を引用した場合など、caller 本文側に同形の文字列が混ざるケースの取り違え防止)。
- サマリ行を含む review が 1 つも無い状態は「本 skill によるレビューが未投稿」(または本改修より前の版で投稿された review しかない) を意味する。CI は合格扱いにせず未実施 (不合格 / pending) として扱う。

### 制約 (既知の非厳密性)

- **`MAX_INLINE_COMMENTS` 省略分**: `comments[]` 集計 (上記ルール 2) では、上限超過で `comments[]` から落ちた指摘は数えられない。ただし省略は優先度順 (`[must]` > `[should]` > `[nit]` > `[question]` > `[pre_existing]`) に低い方から行われる契約なので、**`must` が 1 件以上あるのに `must=0` になることはない** (上限 N ≧ 1 なら must が存在すれば最低 1 件は残る)。`should` が存在するのに `should=0` になるのは must だけで上限に達したケースのみで、そのときは `must>0` なので「must=0 かつ should=0」判定は安全側に倒れる。一方で **個々の件数は実際より小さくなりうる**ため、正確な件数が必要な caller は `LABEL_COUNTS` を渡す (`compose-review` → `run-pr-review` 経路は省略分込みの `label_counts` を引き回すため常に正確)。
- **caller 独自ラベル**: caller が標準 5 ラベルを廃止し独自ラベル (`[blocker]` 等) を使う場合、`comments[]` 集計では全件が `other` に入り `must=0 should=0` になる。CI が must/should だけを見ていると誤って合格するため、独自ラベル運用の caller は **`LABEL_COUNTS` で標準 5 ラベルへマッピングして渡す** (例: `[blocker]` → `must`)。それができない場合は CI 側の合格条件に `other=0` も加える。

## 手順

### 0. CHANNEL を確定する

caller から `CHANNEL` が渡されていればそれを使う。未指定なら「GitHub アクセスチャネル (任意)」の解決手順で `gh` / `mcp` を確定する。どちらも使えなければ投稿せずエラーを caller に報告して停止する。

### 1. `body` 先頭に AI 自動投稿マーカーと機械可読サマリ行を付与し、最終 Payload を確定する

caller から渡された総括本文 (Markdown 可) は、マーカー → 機械可読サマリ行 → 区切り線 (`---`) の後ろに連結する。指摘なしの場合 (`comments` が `[]`) も同じマーカーとサマリ行を付ける (サマリ行は全キー `0` になる)。

サマリ行の件数は「機械可読サマリ行」節の集計ルールで確定する (`LABEL_COUNTS` があればそれを正典に、無ければ `comments[]` の先頭ラベルを集計。未知ラベル / ラベル無しは `other`)。

マーカー文言 (エージェント非依存・固定) とサマリ行の配置:

```markdown
> **[AI 自動投稿]** このレビューは AI エージェントによって自動生成されました。レビュー内容の判断は AI が行っています。

<!-- AI-REVIEW-RESULT: must=0 should=1 nit=2 question=0 pre_existing=0 other=0 -->

---

<caller から渡された総括本文 (指摘なし時は「特に指摘なし」相当)>
```

サマリ行はマーカー行との間に **空行を 1 行入れる** (マーカーは blockquote なので直後の行に置くと lazy continuation で blockquote に取り込まれ、行の構造が崩れうる)。サマリ行の前後をこの形に固定することで、CI 側は「マーカー直後の 1 行」を安定してパースできる。

確定した最終 Payload のスキーマは以下のとおり (`body` は上記マーカー + サマリ行込みの文字列)。`CHANNEL=gh` ではこれを `/tmp/review.json` に **`Write` ツールで** 書き出す (`heredoc` や `cat` リダイレクトは使わない)。`CHANNEL=mcp` ではファイルには書き出さず、手順 2 の各ツール引数として直接渡す:

```json
{
  "commit_id": "9f8e7d6c1a2b3c4d5e6f7890abcdef1234567890",
  "body": "> **[AI 自動投稿]** このレビューは AI エージェントによって自動生成されました。レビュー内容の判断は AI が行っています。\n\n<!-- AI-REVIEW-RESULT: must=1 should=1 nit=0 question=0 pre_existing=0 other=0 -->\n\n---\n\n総括コメント本文 (Markdown可)",
  "event": "COMMENT",
  "comments": [
    {
      "path": "src/example.ts",
      "line": 42,
      "side": "RIGHT",
      "body": "[should] ここの処理は..."
    },
    {
      "path": "src/example.ts",
      "start_line": 50,
      "start_side": "RIGHT",
      "line": 55,
      "side": "RIGHT",
      "body": "[must] この複数行ブロックは..."
    }
  ]
}
```

- 単一行コメントは `path` / `line` / `side` を指定する。
- 複数行範囲のコメントは上記に加えて `start_line` / `start_side` を併用する (`start_line` は `line` より前の行)。
- `commit_id` は caller から `COMMIT_ID` が渡された場合のみ含める (詳細は「Public Payload Interface」セクションの「Payload スキーマ」参照)。
- **`label_counts` / `LABEL_COUNTS` は GitHub へ送る最終 Payload に含めない** (本 skill 内でサマリ行を組み立てるためだけに使う入力。GitHub の Review API が受け付けないキーであり `--input` に混ぜると 422 になる)。
- 指摘がない場合: `body` はマーカー + 全キー `0` のサマリ行 (`<!-- AI-REVIEW-RESULT: must=0 should=0 nit=0 question=0 pre_existing=0 other=0 -->`) + 区切り線 + 「特に指摘なし」相当の文言、`comments` は `[]`、`event` は `COMMENT` で投稿する。指摘 0 件でもサマリ行を省略しない (CI が「レビュー実施済みで指摘ゼロ」を判別するための必須要件)。
- インラインコメント (`comments[].body`) には個別マーカーを付けない (Review 本文側のマーカーで帰属は十分であり、`[must]` 等の重要度ラベルとの衝突や冗長さも避けるため)。

### 2. CHANNEL に応じて「1 つの Review」として投稿する

`<OWNER>` / `<REPO>` / `<PR_NUMBER>` は caller から渡された値で置き換える。

#### 2-a. `CHANNEL=gh` — `gh api` を 1 回だけ実行する

手順 1 で書き出した `/tmp/review.json` を使い、1 回の API コールで投稿する:

```bash
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  /repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/reviews \
  --input /tmp/review.json
```

#### 2-b. `CHANNEL=mcp` — pending review を組み立てて submit する

MCP には Payload 全体を 1 コールで受けるツールが無いため、pending review を組み立ててから 1 度に submit する (GitHub 上では 2-a と同じ 1 つの Review オブジェクトになる)。`comments` の有無で分岐する:

- **`comments` が空配列 (`[]`) の場合 — 1 呼び出しで submit**: `mcp__github__pull_request_review_write` を method=`create` で呼ぶ。`owner` / `repo` / `pullNumber` に加え、`body` = 手順 1 のマーカー + 機械可読サマリ行込み総括本文、`event` = `"COMMENT"`、`commitID` = `commit_id` (Payload に含まれる場合のみ) を渡す (`event` を付けると作成と同時に submit される)。
- **`comments` が非空の場合 — pending review 組み立て**:
  1. **pending review 作成**: `mcp__github__pull_request_review_write` を method=`create` で、**`event` を省略して** 呼ぶ (event 省略で pending review になる)。`owner` / `repo` / `pullNumber` と、`commitID` = `commit_id` (Payload に含まれる場合のみ) をここで渡す。`body` はここでは渡さず submit 時に渡す。
     - **既存 pending review との衝突に注意**: GitHub は 1 ユーザー 1 PR につき pending review を 1 つしか持てない。`create` が「既に pending review がある」旨で失敗した場合、その既存 pending review は**別プロセス / 人間が作成した未 submit のドラフトかもしれない**ため、**勝手に `delete_pending` してはならない** (他者のドラフトを破壊する / add_comment が他者のドラフトに混入する危険)。この場合は投稿を中止し、「既存の未 submit pending review があるため投稿できない。手動で確認してほしい」と caller に報告して停止する。既存 pending review が明らかに本 skill 自身の直前の中断に由来すると確証できる場合に限り、`delete_pending` 後に再作成してよい。
  2. **各インラインコメントを追加**: `comments[]` の各要素について `mcp__github__add_comment_to_pending_review` を呼ぶ: `owner` / `repo` / `pullNumber`、`path` / `body` / `subjectType`=`"LINE"`、`line` / `side`。複数行範囲コメントは加えて `startLine` = `start_line` / `startSide` = `start_side` を渡す。
  3. **submit**: `mcp__github__pull_request_review_write` を method=`submit_pending` で呼ぶ: `owner` / `repo` / `pullNumber`、`body` = 手順 1 のマーカー + 機械可読サマリ行込み総括本文、`event` = `"COMMENT"`。

**失敗時のクリーンアップ**: 2-b の組み立ては複数呼び出しに分かれるため、2-a の単一 atomic コールと違い途中失敗で pending review が宙に浮きうる。**本 skill が手順 1 で `create` に成功して以降** (= 本 skill 自身が作った pending review が存在する状態) にコメント追加または submit が失敗したら、`mcp__github__pull_request_review_write` を method=`delete_pending` (`owner` / `repo` / `pullNumber`) で **本 skill が作った pending review を破棄** してから caller にエラーを報告する (submit されないまま残った pending review は他の投稿の妨げになるため残さない)。手順 1 の `create` 自体が失敗したケース (上記の既存 pending review 衝突など) では本 skill は pending review を作っていないので `delete_pending` は呼ばない。
