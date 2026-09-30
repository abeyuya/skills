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
  external_review?: {          // 任意。レビュー生成側が外部レビュースキルを併用したかの記録 (prompt 経由では `EXTERNAL_REVIEW`、1 行の JSON)。渡されれば `AI-REVIEW-EXTERNAL` 行として body に埋め込む。詳細は「機械可読サマリ行」節。
    skill: string;             // 併用した外部レビュースキル名。未併用は "none"。
    mode: string | null;       // "agent" / "partial" / "inline" / "empty" / "external" / null。
    verify_degraded?: boolean | null;
    finders?: number | null;
    finders_expected?: number | null;
    findings?: number;
    omitted?: number;          // 外部スキル側で件数上限により落とされた指摘数。
  };
  escalation?: {               // 任意。レビュー生成側が「この PR は人にエスカレーションすべき」と判定したかの記録 (prompt 経由では `ESCALATION`、1 行の JSON。`reasons` は自由文なので **値に改行を含めない** — 折り返すと後続行が別 key として解釈され parse が壊れる)。渡されれば `AI-REVIEW-ESCALATE` 行として body に埋め込む。詳細は「機械可読サマリ行」節。
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

`commit_id` は caller 側で PR の head SHA (`headRefOid`) を取得して渡すと、force-push / rebase で行ズレが起きた際の誤コメントを防げる (`run-pr-review` 経由の場合、渡す値の決め方は `run-pr-review` Step 2 の head SHA の箇条を参照。本 skill 側では規則を持たない)。加えて **CI が「現在の head SHA に対するレビューか」を review の `commit_id` で判定する** 運用では、`commit_id` を渡さないと GitHub 側が投稿時点の最新 commit を採用するため照合が不確実になる。機械判定を前提にするなら caller は常に `COMMIT_ID` を渡すこと (詳細は「機械可読サマリ行」節の「CI 側の使い方」)。

`label_counts` は **`MAX_INLINE_COMMENTS` による省略分やラベル体系の独自定義を正しくサマリ行へ反映したい caller 向けの任意入力**。prompt 経由では 1 行の JSON (`LABEL_COUNTS: {"must":1,"should":2,"nit":0,"question":0,"pre_existing":0,"other":0}`) として渡す (key と値の区切りは `:` / `=` のどちらでもよく、同一 prompt 内の他キーの書き方に揃えればよい。ただし **値に改行を含めない** — 複数行に折り返すと後続行が別 key として解釈され parse が壊れる)。渡されなければ本 skill が `comments[]` から集計する (集計ルールと精度上の注意は「機械可読サマリ行」節)。

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

本 skill は投稿する Review の `body` に **ラベル別指摘件数の機械可読サマリ行を必ず 1 行埋め込む**。CI (GitHub Actions の required status check 等) が「AI レビュー済みか / ブロッキング指摘が残っているか」を機械判定するための **公開契約 (CI がパースする契約)** として扱い、後方互換に注意して変更する (キー追加は可、既存キーの削除 / 意味変更 / 順序変更は契約変更扱い)。**この但し書きは本節が規定する 3 行すべて (`AI-REVIEW-RESULT` / `AI-REVIEW-EXTERNAL` / `AI-REVIEW-ESCALATE`) に適用される**。

**本節の規則は `scripts/build-review-payload.sh` が機械的に実行する** (手順 1)。モデルが件数を数えたり行を手で組み立てたりしない — 1 回の数え間違いで must 指摘のある PR が required check を通ってしまうため。本節は契約の正典で、スクリプトはその実装 (規則を変えるときは両方と `scripts/test-build-review-payload.sh` を同時に更新する)。

### フォーマット

```
<!-- AI-REVIEW-RESULT: must=0 should=1 nit=2 question=0 pre_existing=0 other=0 -->
```

- **HTML コメント**なので GitHub 上の人間向け表示 (PR の Conversation タブ) には現れず、レビュー本文の可読性を汚さない。一方 REST API (`GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews`) が返す各 review の `body` にはそのまま残るため、CI から正規表現でパースできる。
- キーは **上記 6 つを固定順で必ず全て出力する**。件数 0 のキーも省略しない (「レビュー実施済みで指摘ゼロ」を CI が判別できることが本サマリ行の必須要件)。
- 値は 0 以上の整数。区切りは半角スペース 1 個。**1 つの Review body にサマリ行は 1 行だけ**。
- 挿入位置は **AI 自動投稿マーカーの直後 (区切り線 `---` より前)** に固定する (手順 1 参照)。caller 由来の総括本文の中には入れない (本文中の任意位置に散らすと 1 行契約が崩れる)。
- **指摘 0 件 (`comments: []`) でも必ず出力する**。この場合は全キーが `0` の行になる。

### 外部レビュー行 (`AI-REVIEW-EXTERNAL`)

caller から `external_review` (prompt 経由では `EXTERNAL_REVIEW`。1 行の JSON) が渡された場合のみ、`AI-REVIEW-RESULT` の **直後の行** (空行を挟まない) に 1 行出力する。渡されなければ行ごと省略する (本 skill が値を捏造しない)。

```
<!-- AI-REVIEW-EXTERNAL: skill=scan-diff-findings mode=agent verify_degraded=false finders=5/5 findings=9 omitted=0 -->
```

- 目的: レビュー生成側 (`compose-review`) が **外部レビュースキルを併用できたか / 縮退したか** を、Review body の日本語本文を読まずに CI から判定できるようにする。
- キーと値 (この順): `skill` (未併用は `none`) / `mode` (`agent` / `partial` / `inline` / `empty` / `external` / `null`) / `verify_degraded` (`true` / `false` / `null`) / `finders` (`<finders>/<finders_expected>`。どちらかが `null` なら `finders=n/a`) / `findings` (整数) / `omitted` (整数。外部スキル側で件数上限により落とされた指摘数)。値の半角スペース等の空白は `_` に置換する。`external_review` に無いキーは出力しない。`reason` は本行には出力しない (人間向けの理由は総括本文の開示文が担う)。
- **異常系**: JSON として parse できない / 必須キー (`skill` / `mode`) を欠く / `mode` が enum 外 の場合は **行ごと省略し、その旨を caller への報告に 1 行残す** (投稿自体は継続する)。壊れた値をそのまま埋め込まない。
- CI 側は係留キー `AI-REVIEW-EXTERNAL` を前置してパースする (例: `AI-REVIEW-EXTERNAL:.*?skill=(\S+).*?mode=(\S+)`)。`skill=none` / `mode=inline|partial|empty` / `verify_degraded=true` はいずれも「レビュー体制が縮退している」シグナル。
- **1 つの Review body にこの行も 1 行だけ**。caller 由来の総括本文には入れない。

### エスカレーション行 (`AI-REVIEW-ESCALATE`)

caller から `escalation` (prompt 経由では `ESCALATION`。1 行の JSON。`reasons` は自由文なので **値に改行を含めない**) が渡された場合のみ、`AI-REVIEW-EXTERNAL` の **直後の行** (空行を挟まない。`AI-REVIEW-EXTERNAL` を出力しない場合は `AI-REVIEW-RESULT` の直後) に 1 行出力する。渡されなければ行ごと省略する。

```
<!-- AI-REVIEW-ESCALATE: escalate=1 reasons=2 -->
```

- 目的: レビュー生成側が「この PR は人 (第三者) の確認が要る」と判定したかを CI から判定できるようにする。**CI 側が該当者をレビュアーに追加するためのルーティング信号** であり、**マージをブロックするゲートではない** (`escalate=1` でも `event` は `COMMENT` のまま、レビュアーの追加も行わない。それは caller / CI の責務)。
- キーと値: `escalate` (`escalation.escalate` が `true` なら `1`、`false` なら `0`) / `reasons` (`escalation.reasons` の **件数**。無い / 空配列なら `0`)。**理由の本文はこの行に載せない** (HTML コメントに自由文を入れると 1 行契約が壊れるため。人間向けの理由は総括本文の `## エスカレーション` セクションが担う)。`escalate=1` かつ `reasons=0` も有効な行。
- **異常系**: JSON として parse できない / `escalate` を欠く / `escalate` が boolean でない 場合は **行ごと省略し、その旨を caller への報告に 1 行残す** (投稿自体は継続する)。`reasons` が配列でない場合は `reasons=0` として行を出す。
- CI 側は係留キー `AI-REVIEW-ESCALATE` を前置してパースする (例: `AI-REVIEW-ESCALATE:.*?escalate=([01])`)。**行の有無だけで「判定が行われたか」を判断しない** — `run-pr-review` 経路では `escalate: true` の回だけ `ESCALATION` が転送される (詳細は `run-pr-review` Step 4) ので、行が無い状態は「エスカレーション不要」と「判定なし」の両方を含む。CI が分岐すべきは `escalate=1` の存在のみ。`escalate=0` の行を出したい caller は `escalate: false` を明示的に渡せばよい。
- **パース範囲を body 冒頭のサマリ行ブロックに限定する (本行固有の注意)**: 本行は常在しないため、行が出ていない回に総括本文中のフォーマット例 (本 plugin のドキュメント自体をレビューする PR など) が唯一のマッチになりうる。CI は本行を **マーカー行から最初の区切り線 `---` までの範囲に限って** 探し、その外側のマッチは無視すること。
- **1 つの Review body にこの行も 1 行だけ**。caller 由来の総括本文には入れない。

### 集計ルール

1. `LABEL_COUNTS` (`label_counts`) が渡されていれば **それを正典として採用する** (`MAX_INLINE_COMMENTS` の省略分を含む正確な件数を持つのは caller だけなので、再計算・上書きしない)。
   - 標準 5 ラベル (`must` / `should` / `nit` / `question` / `pre_existing`) 以外のキーは `other` に合算する。渡されなかった標準ラベルは `0`。
   - JSON として parse できない / object でない / 値が非負整数でない場合は無視して下記 2 にフォールバックし、その旨を caller への報告に 1 行残す。
   - **下限チェック**: 合計が `comments[]` の件数を **下回る** 場合は caller 側の組み立て不整合 (例: `[must]` 3 件なのに `{}`) とみなし、下記 2 にフォールバックして報告に 1 行残す (省略は件数を増やす方向にしか働かないため、合計 ≧ `comments[]` 件数が不変条件)。合計が件数以上なら正典採用のまま。
2. それ以外は **`comments[]` の各 `body` の先頭**に `^\[([A-Za-z_]+)\]` をマッチさせ、**捕捉したラベルを小文字化してから**標準 5 ラベルと突合して加算する (`[MUST]` も `must`。本文中の `[must]` は数えない)。**未知ラベル (`[blocker]` 等) / ラベル無しは `other` に加算する** (落とすと合計が `comments[]` 件数と合わず「集計漏れ」と「指摘なし」を区別できなくなるため)。独自ラベル運用の caller は下記「制約」に従い `LABEL_COUNTS` でマッピングする。

### CI 側の使い方 (参考)

- **パース例** (`must` / `should` だけ見る最小形。**係留キー `AI-REVIEW-RESULT` を必ず前置する**):

  ```
  AI-REVIEW-RESULT:.*?must=(\d+)\s+should=(\d+)
  ```

  係留キーを省いた `must=(\d+) should=(\d+)` だけでは、body 中のどこかにあるプレーンな `must=0 should=0` (本改修より前の版で投稿された review や、この plugin の仕様を議論した人間のレビュー本文など) にもマッチし、**サマリ行が無い review を「レビュー済み・ブロッキングなし」と誤判定する** (後述の「サマリ行が 1 つも無ければ未実施扱い」と噛み合わなくなる。「最初のマッチを採用する」ルールもサマリ行が実在する前提でのみ安全側に働く)。

  全キーを取る場合 (空白の揺れに耐える形):

  ```
  <!--\s*AI-REVIEW-RESULT:\s*must=(\d+)\s+should=(\d+)\s+nit=(\d+)\s+question=(\d+)\s+pre_existing=(\d+)\s+other=(\d+)\s*-->
  ```

- **合格条件の例**: 「PR の現在の head SHA に対して AI レビューが投稿済み、かつ `must` / `should` が 0 件」→ サマリ行を含む review が head SHA に対して存在し、その `must=0` かつ `should=0`。
- **head SHA に対するレビューかの判定** は review の `commit_id` を PR の head SHA と比較する (本 skill は `COMMIT_ID` が渡された場合のみ `commit_id` を送るため、機械判定を前提にするなら caller は常に `COMMIT_ID` を渡す。`run-pr-review` は `COMMIT_ID` を常時転送するので、その経路なら常に付く。値の決め方は `run-pr-review` Step 2 参照)。`COMMIT_ID` を渡さないと GitHub 側が投稿時点の最新 commit を採用するため、force-push と競合したときに照合が不確実になる。
- 同一 head SHA に対してサマリ行を含む review が複数ある場合 (再レビュー等) は **最新の review** を採用する。
- 1 つの review body 内に同形の文字列が複数現れた場合は **最初のマッチを採用する**。本 skill が prepend する 1 行は常に body の冒頭側 (マーカー直後) にあり、caller 由来の総括本文はその後ろに連結されるため、最初のマッチが必ず本 skill の出力になる (本 plugin のドキュメント自体をレビューして総括にフォーマット例を引用した場合など、caller 本文側に同形の文字列が混ざるケースの取り違え防止)。
- サマリ行を含む review が 1 つも無い状態は「本 skill によるレビューが未投稿」(または本改修より前の版で投稿された review しかない) を意味する。CI は合格扱いにせず未実施 (不合格 / pending) として扱う。

### 制約 (既知の非厳密性)

- **`MAX_INLINE_COMMENTS` 省略分**: `comments[]` 集計 (上記ルール 2) では、上限超過で `comments[]` から落ちた指摘は数えられない。ただし省略は優先度順 (`[must]` > `[should]` > `[nit]` > `[question]` > `[pre_existing]`) に低い方から行われる契約なので、**`must` が 1 件以上あるのに `must=0` になることはない** (上限 N ≧ 1 なら must が存在すれば最低 1 件は残る)。`should` が存在するのに `should=0` になるのは must だけで上限に達したケースのみで、そのときは `must>0` なので「must=0 かつ should=0」判定は安全側に倒れる。一方で **個々の件数は実際より小さくなりうる**ため、正確な件数が必要な caller は `LABEL_COUNTS` を渡す (`compose-review` → `run-pr-review` 経路は省略分込みの `label_counts` を引き回すため常に正確)。
- **caller 独自ラベル**: caller が標準 5 ラベルを廃止し独自ラベル (`[blocker]` 等) を使う場合、`comments[]` 集計では全件が `other` に入り `must=0 should=0` になる。CI が must/should だけを見ていると誤って合格するため、独自ラベル運用の caller は **`LABEL_COUNTS` で標準 5 ラベルへマッピングして渡す** (例: `[blocker]` → `must`)。それができない場合は CI 側の合格条件に `other=0` も加える。

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
     "comments": [ /* caller の comments[] をそのまま */ ],
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

参考: マーカー文言 (エージェント非依存・固定) と組み立て後の `body` の形:

```markdown
> **[AI 自動投稿]** このレビューは AI エージェントによって自動生成されました。レビュー内容の判断は AI が行っています。

<!-- AI-REVIEW-RESULT: must=0 should=1 nit=2 question=0 pre_existing=0 other=0 -->
<!-- AI-REVIEW-EXTERNAL: skill=scan-diff-findings mode=agent verify_degraded=false finders=5/5 findings=9 omitted=0 -->
<!-- AI-REVIEW-ESCALATE: escalate=1 reasons=2 -->

---

<caller から渡された総括本文 (指摘なし時は「特に指摘なし」相当)>
```

マーカー行の後の空行は、blockquote の lazy continuation で機械可読行が取り込まれるのを防ぐためのもの。

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
