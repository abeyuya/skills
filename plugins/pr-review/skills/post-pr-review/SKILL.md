---
name: post-pr-review
description: 'PR レビュー結果を1つの Review として GitHub に投稿する。複数のインライン指摘や総括コメントを含むレビューを投稿する場合は必ずこの skill を使うこと。`gh pr comment` / `gh pr review` / MCP の個別コメント投稿ツールを使った個別投稿は禁止。gh CLI / GitHub MCP ツールのどちらのチャネル (`CHANNEL=gh|mcp`) でも投稿できる。Review body には AI 自動投稿マーカーと、CI が required status check で機械判定するための機械可読サマリ行 (`<!-- AI-REVIEW-RESULT: must=0 should=1 ... -->`、指摘 0 件でも必ず出力) を自動で付与する。ラベル別件数は任意入力 `LABEL_COUNTS` があればそれを正典とし、無ければ `comments[]` の先頭ラベルから集計する。'
---

# post-pr-review skill

PR レビュー結果を **「1つの Review」として投稿** する手順を提供する skill。
人間レビュアーの "Submit Review" と同じ構造で投稿する。

## 守ること

- レビュー結果は **必ず「1 つの Review」** として投稿する (`CHANNEL=gh` は 1 回の API コール、`CHANNEL=mcp` は pending review を組み立ててから 1 度に submit。いずれも GitHub 上では 1 つの Review オブジェクトになり、散らばった個別コメントにはならない)。
- 個別投稿系のツール (`mcp__github_inline_comment__create_inline_comment`、`mcp__github__add_issue_comment`、`gh pr comment` 等) は **使わない**。
- `event` は **常に `COMMENT`**。`APPROVE` / `REQUEST_CHANGES` は使わない (Bot がマージブロックや承認権を持つことを避けるため)。
- インラインコメントの本文フォーマット (重要度ラベル等) は **caller のレビュー方針に従う**。本 skill は手続きのみを担い、レビュー文面の規約は規定しない。
- 総括 `body` の先頭には **AI 自動投稿マーカーを必ず付与する** (手順 1 のスクリプトが付与する。文言は `references/machine-readable-lines.md` の「body の組み立て」)。認証主体が人間 PAT でも投稿内容は AI 生成であることを明示するため。caller 側で事前に付与する必要はなく、本 skill が一律に prepend する。エージェント名 (Claude Code / Codex / Cursor 等) はマーカーに含めない (本 skill は複数の AI エージェントから呼ばれうる前提)。
- 総括 `body` には **機械可読サマリ行 (`AI-REVIEW-RESULT`) を必ず 1 行埋め込む** (指摘 0 件でも省略しない)。CI からの機械判定用の公開契約であり、フォーマット / 挿入位置 / 集計ルールは `references/machine-readable-lines.md` を正典とする。

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
  label_counts?: Record<string, number>; // 任意。ラベル別指摘件数の正典値 (prompt 経由では `LABEL_COUNTS`)。渡されれば機械可読サマリ行の集計に優先採用される。詳細は `references/machine-readable-lines.md`。
  external_review?: {          // 任意。レビュー生成側が外部レビュースキルを併用したかの記録 (prompt 経由では `EXTERNAL_REVIEW`、1 行の JSON)。渡されれば `AI-REVIEW-EXTERNAL` 行として body に埋め込む。詳細は `references/machine-readable-lines.md`。
    skill: string;             // 併用した外部レビュースキル名。未併用は "none"。
    mode: string | null;       // "agent" / "partial" / "inline" / "empty" / "external" / null。
    verify_degraded?: boolean | null;
    finders?: number | null;
    finders_expected?: number | null;
    findings?: number;
    omitted?: number;          // 外部スキル側で件数上限により落とされた指摘数。
  };
  escalation?: {               // 任意。レビュー生成側が「この PR は人にエスカレーションすべき」と判定したかの記録 (prompt 経由では `ESCALATION`、1 行の JSON。`reasons` は自由文なので **値に改行を含めない** — 折り返すと後続行が別 key として解釈され parse が壊れる)。渡されれば `AI-REVIEW-ESCALATE` 行として body に埋め込む。詳細は `references/machine-readable-lines.md`。
    escalate: boolean;         // true / false。
    reasons?: string[];        // 理由の配列 (人間向け本文)。本行には件数だけを載せ、本文は載せない。
  };
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

`commit_id` は caller 側で PR の head SHA (`headRefOid`) を取得して渡すと、force-push / rebase で行ズレが起きた際の誤コメントを防げる (`run-pr-review` 経由の場合、渡す値の決め方は `run-pr-review` Step 2 の head SHA の箇条を参照。本 skill 側では規則を持たない)。加えて **CI が「現在の head SHA に対するレビューか」を review の `commit_id` で判定する** 運用では、`commit_id` を渡さないと GitHub 側が投稿時点の最新 commit を採用するため照合が不確実になる。機械判定を前提にするなら caller は常に `COMMIT_ID` を渡すこと (詳細は `references/machine-readable-lines.md` の「CI 側の使い方」)。

`label_counts` は **`MAX_INLINE_COMMENTS` による省略分やラベル体系の独自定義を正しくサマリ行へ反映したい caller 向けの任意入力**。prompt 経由では 1 行の JSON (`LABEL_COUNTS: {"must":1,"should":2,"nit":0,"question":0,"pre_existing":0,"other":0}`) として渡す (key と値の区切りは `:` / `=` のどちらでもよく、同一 prompt 内の他キーの書き方に揃えればよい。ただし **値に改行を含めない** — 複数行に折り返すと後続行が別 key として解釈され parse が壊れる)。渡されなければ本 skill が `comments[]` から集計する (集計ルールと精度上の注意は `references/machine-readable-lines.md`)。

### 契約の前提 (Payload 設計上の制約)

- `body` 先頭の **AI 自動投稿マーカー** と **機械可読サマリ行** は本 skill が自動 prepend する。caller は付けない (詳細は `references/machine-readable-lines.md`)。
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

本節は要約。正典は下記リンク先 (他 skill の「機械可読サマリ行」節への参照もそちらを指す)。

`body` の冒頭 (マーカーと区切り線 `---` の間) に、CI がパースする機械可読行を埋め込む。**組み立ては手順 1 のスクリプトが行い、モデルは件数を数えたり行を書いたりしない**。フォーマット・キー順・集計ルール・異常系・CI 側の使い方の正典は [`references/machine-readable-lines.md`](references/machine-readable-lines.md) (公開契約。変えるときは後方互換に注意し、スクリプトとテストも同時に更新する)。

- `AI-REVIEW-RESULT` (ラベル別件数): **常に 1 行** (指摘 0 件でも)。件数は `LABEL_COUNTS` があれば正典採用、無い / 壊れている / 合計が `comments[]` 件数を下回るなら `comments[]` の先頭ラベルから集計。
- `AI-REVIEW-EXTERNAL` (外部レビュー併用の記録) / `AI-REVIEW-ESCALATE` (エスカレーション判定): `EXTERNAL_REVIEW` / `ESCALATION` が **渡されたときだけ** 1 行。値が壊れていれば行ごと省略して報告に残す (投稿は続行)。

## 手順

### 0. CHANNEL を確定する

caller から `CHANNEL` が渡されていればそれを使う。未指定なら「GitHub アクセスチャネル (任意)」の解決手順で `gh` / `mcp` を確定する。どちらも使えなければ投稿せずエラーを caller に報告して停止する。

### 1. `scripts/build-review-payload.sh` で最終 Payload を組み立てる

マーカー / 機械可読行の付与・ラベル別件数の集計・最終 Payload からのキー除外は、本 skill 配下の `scripts/build-review-payload.sh` (bash + jq) がすべて機械的に行う。本 step では **このスクリプトを Bash ツールから呼ぶだけ**。モデルが件数を数えたり `body` を手で連結したりしない (結果が入力だけで決まる処理なので、手作業にすると数え間違いがそのまま CI の判定を誤らせる)。

スクリプトの絶対パスは **本 SKILL.md と同じディレクトリの `scripts/build-review-payload.sh`** で解決する (SKILL.md の絶対パスの dirname に `scripts/build-review-payload.sh` を連結する。`distill-pr-reviews` Step 1 と同じ規則で、開発時・`/plugin install` 後・`apm install` 後のいずれでも一意に決まる)。スクリプトは bash 3.2 互換 (`jq` は別途必要)。以下のコマンドは **この形のまま使い、引数や手順を変えない**。

1. **作業パスを取得する**:

   ```bash
   bash "<SKILL.md と同じディレクトリ>/scripts/build-review-payload.sh" --init
   ```

   stdout の 1 行が入力ファイルのパス (`<一意の temp ディレクトリ>/input.json`。ランダムサフィックス付きで並行実行でも衝突せず、ファイルは未作成なので `Write` の前に `Read` は要らない)。
2. **入力 JSON を `Write` ツールでそのパスに書く** (`heredoc` や `cat` リダイレクトは使わない)。中身は caller から受け取った Payload をそのまま詰めた 1 つの JSON object:

   ```json
   {
     "body": "<caller の総括本文そのまま (マーカー等は付けない)>",
     "event": "COMMENT",
     "comments": ["<caller の comments[] の各要素をそのまま>"],
     "commit_id": "<COMMIT_ID。渡されなければキーごと省く>",
     "label_counts": "<LABEL_COUNTS。渡されなければキーごと省く>",
     "external_review": "<EXTERNAL_REVIEW。渡されなければキーごと省く>",
     "escalation": "<ESCALATION。渡されなければキーごと省く>"
   }
   ```

   - `label_counts` / `external_review` / `escalation` は受け取った 1 行 JSON を **文字列値のまま** 入れてよい (object でも可)。**壊れた値を直したり省いたりしない** — parse 可否と異常時の扱いはスクリプトが判定する。上記以外のキー (`mode` 等) は無視される。
3. **スクリプトを実行する**:

   ```bash
   bash "<SKILL.md と同じディレクトリ>/scripts/build-review-payload.sh" "<--init が出力した input.json のパス>"
   ```

#### 出力の扱い

- **exit 0**: stdout に報告 JSON が 1 行出る (同内容が同じディレクトリの `report.json` にもある。キー: `payload_path` / `counts` / `counts_source` / `lines` / `warnings`。スキーマはスクリプト冒頭コメント参照)。
  - `payload_path` の `payload.json` が GitHub へ送る最終 Payload (`{commit_id?, body, event: "COMMENT", comments}`)。`body` はマーカー → 空行 → 機械可読行 (行間に空行なし) → 空行 → `---` → 空行 → caller の総括本文 の順に組み立て済み。**この内容を手で編集しない**。
  - `counts_source`: `label_counts` (正典採用) / `comments` (`comments[]` から集計)。`lines.external` / `lines.escalate`: `emitted` (出力) / `absent` (入力に無く省略) / `omitted` (渡されたが異常値で省略)。
  - **`warnings[]` の各要素は caller への報告に 1 行ずつ転記する** (投稿は止めない)。`action` は `fallback_to_comments` (`LABEL_COUNTS` を無視して `comments[]` 集計にした) / `line_omitted` (その入力の機械可読行を省略した) / `reasons_zeroed` (`reasons` が配列でなく `reasons=0` にした) / `forced_comment` (`event` を `COMMENT` に固定した)。`run-pr-review` は `line_omitted` / `fallback_to_comments` を自身の報告に転記する (同 Step 6)。
- **exit 2** (入力不正: `body` が文字列でない / `comments` が配列でない / 入力が JSON でない 等): `payload.json` は書かれない。投稿せず、stderr のメッセージを caller に報告して停止する。

`label_counts` / `external_review` / `escalation` / `mode` 等は最終 Payload に含まれない (GitHub の Review API が受け付けないキーで、`--input` に混ぜると 422 になる)。`commit_id` は `COMMIT_ID` が渡されたときだけ含まれる。インラインコメント (`comments[].body`) には個別マーカーを付けない (Review 本文側のマーカーで帰属は十分なため)。

### 2. CHANNEL に応じて「1 つの Review」として投稿する

`<OWNER>` / `<REPO>` / `<PR_NUMBER>` は caller から渡された値で置き換える。

#### 2-a. `CHANNEL=gh` — `gh api` を 1 回だけ実行する

手順 1 の報告 JSON の `payload_path` をそのまま `--input` に渡し、1 回の API コールで投稿する:

```bash
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  /repos/<OWNER>/<REPO>/pulls/<PR_NUMBER>/reviews \
  --input "<payload_path>"
```

#### 2-b. `CHANNEL=mcp` — pending review を組み立てて submit する

MCP には Payload 全体を 1 コールで受けるツールが無いため、pending review を組み立ててから 1 度に submit する (GitHub 上では 2-a と同じ 1 つの Review オブジェクトになる)。手順 1 の `payload_path` を `Read` し、その `body` / `comments` / `commit_id` を **そのまま** 下記の各ツール引数に使う (値を書き換えない)。`comments` の有無で分岐する:

- **`comments` が空配列 (`[]`) の場合 — 1 呼び出しで submit**: `mcp__github__pull_request_review_write` を method=`create` で呼ぶ。`owner` / `repo` / `pullNumber` に加え、`body` = `payload.json` の `body`、`event` = `"COMMENT"`、`commitID` = `commit_id` (Payload に含まれる場合のみ) を渡す (`event` を付けると作成と同時に submit される)。
- **`comments` が非空の場合 — pending review 組み立て**:
  1. **pending review 作成**: `mcp__github__pull_request_review_write` を method=`create` で、**`event` を省略して** 呼ぶ (event 省略で pending review になる)。`owner` / `repo` / `pullNumber` と、`commitID` = `commit_id` (Payload に含まれる場合のみ) をここで渡す。`body` はここでは渡さず submit 時に渡す。
     - **既存 pending review との衝突に注意**: GitHub は 1 ユーザー 1 PR につき pending review を 1 つしか持てない。`create` が「既に pending review がある」旨で失敗した場合、その既存 pending review は**別プロセス / 人間が作成した未 submit のドラフトかもしれない**ため、**勝手に `delete_pending` してはならない** (他者のドラフトを破壊する / add_comment が他者のドラフトに混入する危険)。この場合は投稿を中止し、「既存の未 submit pending review があるため投稿できない。手動で確認してほしい」と caller に報告して停止する。既存 pending review が明らかに本 skill 自身の直前の中断に由来すると確証できる場合に限り、`delete_pending` 後に再作成してよい。
  2. **各インラインコメントを追加**: `payload.json` の `comments[]` の各要素について `mcp__github__add_comment_to_pending_review` を呼ぶ: `owner` / `repo` / `pullNumber`、`path` / `body` / `subjectType`=`"LINE"`、`line` / `side`。複数行範囲コメントは加えて `startLine` = `start_line` / `startSide` = `start_side` を渡す。
  3. **submit**: `mcp__github__pull_request_review_write` を method=`submit_pending` で呼ぶ: `owner` / `repo` / `pullNumber`、`body` = `payload.json` の `body`、`event` = `"COMMENT"`。

**失敗時のクリーンアップ**: 2-b の組み立ては複数呼び出しに分かれるため、2-a の単一 atomic コールと違い途中失敗で pending review が宙に浮きうる。**本 skill が 2-b の 1 で `create` に成功して以降** (= 本 skill 自身が作った pending review が存在する状態) にコメント追加または submit が失敗したら、`mcp__github__pull_request_review_write` を method=`delete_pending` (`owner` / `repo` / `pullNumber`) で **本 skill が作った pending review を破棄** してから caller にエラーを報告する (submit されないまま残った pending review は他の投稿の妨げになるため残さない)。2-b の 1 の `create` 自体が失敗したケース (上記の既存 pending review 衝突など) では本 skill は pending review を作っていないので `delete_pending` は呼ばない。
