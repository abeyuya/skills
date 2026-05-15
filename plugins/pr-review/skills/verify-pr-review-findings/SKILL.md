---
name: verify-pr-review-findings
description: PR レビュー一次案の各指摘を、独立コンテキストのサブエージェント (Agent ツール経由) で再検証し、False Positive を除いて 0-100 の confidence スコアを付与する Verifier skill。severity ハイブリッド並列で動作する。run-pr-review / run-local-review の Step 5.5 から呼ばれる。
---

# verify-pr-review-findings skill

PR レビューの一次案 (`candidate_findings[]`) を **独立コンテキストのサブエージェント (Agent ツール経由)** で再検証し、`verdicts[]` (verdict + confidence + rationale) を返す Verifier skill。

本 skill 自体は薄いオーケストレーション層で、実際の検証は Agent ツール (`subagent_type=general-purpose`) で起動するサブエージェントが行う。サブエージェントは独立した会話セッションで動き、呼び出し元 (一次レビュー) のコンテキストには影響しない。

## 守ること

- 本 skill は **read-only**。ファイル編集 / `git` 操作 / `gh` の write 系 (PR/issue 作成・コメント投稿) は行わない。
- 検証ロジックは **必ず Agent ツール経由のサブエージェントに委譲** する。本 skill 内で直接判定して `verdicts[]` を組み立ててはならない (独立コンテキスト前提の設計を崩さないため)。
- 一次レビュー側で生成された `candidate_findings[]` の `body` / `severity` / `id` / `path` / `line` を変更しない (Verifier は判定のみ、内容書き換えは caller の責務)。
- 本 skill が **canonical な単一定義点**。caller / style-ref / Check Run の HTML コメントが共有する以下 4 系は本ファイルの定義表をそのまま参照し、他ファイルに同じリテラルを書き直さない (二重定義禁止):
  - **状態 enum** (`verifier_status`): 「Verifier 状態 enum」セクション参照
  - **数値リテラル**: 「数値リテラル一覧」セクション参照 (±50 / ±10 行など)
  - **Agent prompt 同梱マトリクス**: Step 2 参照
  - **stats 集計対象 filter**: Step 7 参照

## Verifier 状態 enum (canonical)

`verifier_status` は以下 5 値のリテラルのみを取る。caller (`run-pr-review` / `run-local-review`) と Check Run HTML コメントはこの綴りをそのまま使う (プレフィックス `verifier:` は付けない)。

| 値 | 発火元 | 意味 |
|-----|--------|------|
| `ok` | Verifier 正常終了 | `stats.timeout=false` かつ skill 全体が応答 |
| `skipped:zero_candidates` | Verifier の Step 0 | `CANDIDATES` が空配列 (caller は呼んだが対象なし) |
| `skipped:timeout` | Verifier の Step 6 | `VERIFIER_TIMEOUT_SEC` 超過で skill 全体が打ち切られた |
| `skipped:error` | caller 側 | Verifier skill の呼び出しが例外 / 応答不能で完了しない (タイムアウト以外の失敗) |
| `skipped:user_flag` | caller 側 | caller の入力で `SKIP_VERIFIER=true` が指定され、Verifier 自体を呼ばなかった |

- Verifier 自身が返却する `stats.status` は前 3 値 (`ok` / `skipped:zero_candidates` / `skipped:timeout`) のいずれか。後 2 値 (`skipped:error` / `skipped:user_flag`) は caller 側で付与する。
- 出力 / ログ / Check Run の HTML コメント / markdown 出力で状態を表すときは **必ずこのリテラル** を使う。プレフィックスの付与・大文字小文字の変更・別綴り (`failed` / `error_skill` 等) は禁止。

## 数値リテラル一覧 (canonical)

caller と Verifier で共有する位置 / 範囲の数値リテラルは本ファイルが唯一の定義点。caller (`run-pr-review` / `run-local-review`) はこの値をハードコードせず、本セクションを参照する形で書く。

| 名前 | 値 | 用途 |
|------|-----|------|
| `FILE_EXCERPT_RANGE` | 候補行の前後 50 行 (start = max(1, line-50), end = line+50) | `FILE_EXCERPTS` の抽出範囲。ファイル境界では利用可能範囲をそのまま渡す (下方/上方の不足は許容)。 |
| `RELATED_THREAD_RANGE` | 候補行の前後 10 行 (\|line_thread - line_candidate\| <= 10 かつ path 一致) | `RELATED_THREADS` の同梱対象 (HIGH 群 / LOW 群いずれも同じ閾値)。 |
| `MAX_LOW_BATCH_SIZE` | 5 | LOW 群 1 バッチあたりの最大 findings 件数。 |
| `MAX_PARALLEL` | 4 | Agent ツール同時起動上限 (HIGH + LOW バッチの合計)。 |
| `DEFAULT_VERIFIER_TIMEOUT_SEC` | 300 | skill 全体のデフォルトタイムアウト。caller が `VERIFIER_TIMEOUT_SEC` 入力で override 可能。 |

`MAX_PARALLEL` の根拠は Agent ツール API レート (経験則) と一次レビューの待ち時間許容範囲。caller 側で並列度を上げたい場合は本ファイルを更新し、caller では参照のみとする。

## 入力 (caller から prompt 経由で渡される想定)

```json
{
  "MODE": "pr" | "local",
  "REPO_CONTEXT": { "OWNER": "...", "REPO": "...", "PR_NUMBER": 123 },
  "DIFF": "<git diff text>",
  "FILE_EXCERPTS": [
    { "path": "src/auth.ts", "start": 1, "end": 120, "content": "<file content lines 1-120>" }
  ],
  "RELATED_THREADS": [
    { "path": "src/auth.ts", "line": 42, "body": "<過去の関連スレッド本文>" }
  ],
  "CANDIDATES": [
    {
      "id": "finding-001",
      "path": "src/auth.ts",
      "line": 42,
      "severity": "must",
      "body": "[must] Token refresh races with logout..."
    }
  ],
  "VERIFIER_TIMEOUT_SEC": 300
}
```

- `FILE_EXCERPTS`: 各 candidate の周辺 ±50 行を caller が事前抽出して渡す。Verifier 側で `git show` を再実行しない (skill 間で git 状態を持ち回らないため)。
- `RELATED_THREADS`: 同 path / 近接 line の過去 review thread (重複検知を兼ねた FP 判定材料)。なければ `[]`。`MODE=local` では常に `[]`。
- `CANDIDATES`: 一次レビュー側で `id` (`finding-NNN`) を採番済み。`severity` は `must` / `should` / `nit` / `question` / `pre_existing` の小文字リテラル。
- `VERIFIER_TIMEOUT_SEC`: skill 全体タイムアウト (秒)。省略時 300。

## 出力 (caller への返却)

```json
{
  "verdicts": [
    {
      "id": "finding-001",
      "verdict": "confirmed",
      "confidence": 87,
      "severity_suggestion": "must",
      "rationale": "src/auth.ts:48 で middleware が token を invalidate しているため race は起きない (FP)。",
      "suggested_body": null
    }
  ],
  "stats": {
    "status": "ok",
    "total": 5,
    "confirmed": 3,
    "false_positive": 1,
    "uncertain": 1,
    "mean_conf": 78,
    "min_conf": 45,
    "agents_invoked": 3,
    "parallel_max": 3,
    "timeout": false
  }
}
```

- `verdict`: `confirmed` / `likely_false_positive` / `uncertain` のいずれか。
- `confidence`: 0-100 の整数 (詳細は「Confidence の意味づけ」参照)。
- `severity_suggestion`: 元 severity と異なる提案があれば書き、なければ元 severity をそのまま入れる。**本リポジトリの caller (`run-pr-review` / `run-local-review`) は常時破棄する方針** (severity と confidence を独立軸として扱うため)。判定リソース節約のため、Verifier 側でも元 severity と同じ値で問題ない場合は元 severity をそのまま返してよい。
- `rationale`: 確認したコード位置 (`path:line`) を最低 1 つ含む。
- `suggested_body`: `verdict=confirmed` で本文の書き換え案がある場合のみ。それ以外は `null`。
- `stats.status`: 「Verifier 状態 enum」のうち Verifier 自身が返却可能な 3 値 (`ok` / `skipped:zero_candidates` / `skipped:timeout`) のいずれか。
- `stats.timeout`: `VERIFIER_TIMEOUT_SEC` を超えて打ち切った場合 `true` (`stats.status="skipped:timeout"` と整合)。未完了分は `verdict=uncertain` / `confidence=0` で埋めて返す。

## Confidence の意味づけ

| range | 意味 |
|-------|------|
| 90-100 | 当該 diff と周辺コードから根拠が完結。前提仮定なし |
| 80-89 | 軽い前提 (一般的ライブラリ/フレームワーク挙動) はあるが合理的に成立。**デフォルト閾値の下限** |
| 60-79 | 1-2 個の未確認仮定あり (runtime 設定 / 他モジュール状態) |
| 40-59 | 複数前提に依存。コード外情報が必要 |
| 0-39 | 仮説レベル |

`verdict` と `confidence` は別軸:
- `confirmed` + `confidence=92`: バグであることに高い確信
- `confirmed` + `confidence=65`: バグだと思うが前提に未確認仮定あり
- `likely_false_positive` + `confidence=88`: FP であることに高い確信 (caller 側で除外推奨)
- `likely_false_positive` + `confidence=55`: FP の疑いはあるが確信なし (caller 側で除外しない)
- `uncertain`: 判断できず。caller 側の閾値判定にゆだねる。

## 手順

### Step 0. 入力検証

- `CANDIDATES` が空配列 → 以下の完全 JSON を返して終了。

```json
{
  "verdicts": [],
  "stats": {
    "status": "skipped:zero_candidates",
    "total": 0,
    "confirmed": 0,
    "false_positive": 0,
    "uncertain": 0,
    "mean_conf": null,
    "min_conf": null,
    "agents_invoked": 0,
    "parallel_max": 0,
    "timeout": false
  }
}
```

- 必須フィールド (`DIFF` / `CANDIDATES`) が無い場合は caller にエラーを返す。
- `FILE_EXCERPTS` が空配列の場合は許容する (Verifier は DIFF と Agent 内 Read のみで判定する degrade モード)。`FILE_EXCERPTS` の特定 candidate 該当範囲が欠損している場合も同様に当該 prompt の `FILE_EXCERPT` 欄を `"なし"` で埋めて続行する (uncertain で打ち切らない)。

### Step 1. candidate を severity で 2 群に分ける

- **HIGH 群**: `severity in {must, should}`
- **LOW 群**: `severity in {nit, question, pre_existing}`

各群を個別に並列化する (HIGH は精度優先、LOW はコスト効率優先)。

### Step 2. Agent ツール呼び出しを構築する

各群の Agent prompt に同梱する入力を **同梱マトリクス** で明示する。HIGH / LOW で同梱対象が同じものはそう書き、異なるものだけ列を分ける (LOW 群の暗黙省略を許さない)。

| 入力 | HIGH 群 (1 件 1 呼び出し) | LOW 群 (1 バッチ最大 `MAX_LOW_BATCH_SIZE` 件) |
|------|------|------|
| `DIFF` (該当 path の `--unified=20` 相当) | 同梱 | 同梱 (バッチ内の path 集合) |
| `FILE_EXCERPT` (`FILE_EXCERPT_RANGE`) | 該当 1 件分 | バッチ内 findings 全件分 |
| `RELATED_THREADS` (`RELATED_THREAD_RANGE`) | 同梱 | 同梱 (バッチ内 findings に同 path / 近接 line のあるものすべて) |
| `FINDINGS` 配列 | 1 件 | 最大 `MAX_LOW_BATCH_SIZE` 件 |

- `RELATED_THREAD_RANGE` / `FILE_EXCERPT_RANGE` / `MAX_LOW_BATCH_SIZE` は「数値リテラル一覧」参照。
- **LOW バッチ分割は LOW 群全体に対して `id` 昇順で詰める** (severity を跨いで同一バッチに混在させて OK)。例: nit×4 + question×1 + pre_existing×2 = 7 件 → `id` 昇順で 5 件 / 2 件のバッチ 2 つに分割し、各バッチ内で nit / question / pre_existing が混在しても良い。severity ごとに別バッチに分けると LOW 群の API コストが増えるため一括化する設計。
- 各 Agent 呼び出しは独立した会話セッションで動くため、prompt は self-contained にする (過去会話の前提を一切持たない)。

### Step 3. 同時並列度を `MAX_PARALLEL` までに制御

同時起動上限は「数値リテラル一覧」の `MAX_PARALLEL` (= 4)。HIGH 呼び出し + LOW バッチ呼び出しの合計がこれを超える場合は、`MAX_PARALLEL` 件ずつ順番に並列起動して完了を待ち、次の `MAX_PARALLEL` 件を起動する。

起動順は **決定論的に「HIGH 群 → LOW 群」、群内は `id` 昇順** で並べてから先頭から `MAX_PARALLEL` 件ずつラウンドに切る。これにより `stats.parallel_max` が再現可能になる。

並列起動は「**同一メッセージ内で複数の Agent tool use ブロック**」で実現する。複数メッセージに分けると逐次実行になるので注意。

例: HIGH 6 件 + LOW 2 バッチ = 計 8 呼び出し → HIGH 4 件並列 (round 1) → HIGH 2 件 + LOW 2 バッチ並列 (round 2)。

### Step 4. 各 Agent ツール呼び出しの prompt 骨子

`subagent_type=general-purpose` を指定し、`description` には `Verify finding(s): <id1>, <id2>...` を入れる (デバッグ可視性のため)。以下の骨子に candidate 情報を埋め込んだ self-contained prompt を渡す。

```
あなたは PR レビューの False Positive 検証専門のサブエージェントとして起動された。あなたの唯一の役割は、入力された指摘候補 (findings) について「本当にバグか・指摘内容が事実として成立するか」を判定し、JSON で結果を返すこと。新規指摘の発見・スタイル改善・好み寄りの追記は一切しない。Read ツール以外は使ってはならない (Bash / Edit / Write 等は禁止)。もし Read 以外のツールを呼ばないと判定できないと感じた場合は、その候補を verdict=uncertain / confidence=0 / rationale="needs non-read tool: <理由>" で返して打ち切ること (ツール制約違反を自己抑制する)。

スコープ外の取り扱い (打ち切りルール):
- 指摘内容の判定に **同リポジトリ内のコード読みだけでは到達できない事実確認** が必要な場合、当該候補は verdict=uncertain / confidence=0 / rationale="non-code verification required: <何を確認すれば判定可能か>" で返して打ち切る。
- 純粋打ち切り対象 (Read で同リポジトリ内のコードを追っても判定不能):
  - 外部 URL のリンク切れ / 外部仕様書 (RFC・他社 API 仕様等) との整合 / 人間運用 (リリース手順書・運用フロー) との整合
  - コードファイル外 (`*.md` / `*.txt` / `docs/**` / `README*` 等) の **文章表現の好み・誤字脱字・スタイル**
- 打ち切らずコード判定に含めるケース (path がドキュメントでもコード読みで判定可能):
  - ドキュメントの記述と **同リポジトリ内のコードの実挙動** の整合 (例: README に書かれた API 名 / 引数 / 戻り値が実装と一致するか) → Read で実装ファイルを読めば判定可能なのでコード判定として扱う
  - コードファイル (`*.ts` / `*.py` 等) の docstring 内記述とコード実挙動の整合 → 同上
- 迷ったら: 「Read ツールで同リポジトリ内のファイルを n 回読めば確信を持って判定できるか?」を自問する。Yes ならコード判定、No なら非コード打ち切り。

判定手順:
1. 指摘本文の前提 (該当コード / 状態 / 呼び出しパターン) が file_excerpt 上で実在するか確認
2. 同コードベース内の暗黙の安全策 (上位ガード / middleware / 型システム / 既存テスト / フレームワーク保証) を走査 (必要なら Read ツールで該当ファイルの未提供部分を読む)
3. 「指摘どおりに動けば確かにバグ」と「指摘そのものが事実誤認 (存在しない API 呼び出し・誤読した制御フロー)」を区別
4. severity の妥当性を以下の定義で照合: must=不具合・脆弱性・本番事故直結 / should=設計・保守性で強く推奨 / nit=軽微・好み寄り / question=質問 / pre_existing=既存バグ

confidence (0-100) の意味:
- 90-100: 当該 diff と周辺コードから根拠が完結。前提仮定なし
- 80-89: 軽い前提はあるが合理的に成立。閾値の下限
- 60-79: 1-2 個の未確認仮定あり
- 40-59: 複数前提に依存、コード外情報が必要
- 0-39: 仮説レベル

verdict と confidence は別軸:
- confirmed: 指摘どおりバグであると判断 (confidence で確信の度合いを表現)
- likely_false_positive: 指摘が事実誤認 / 既存安全策で問題が成立しない (confidence で「FP であることの確信度」を表現)
- uncertain: コードや情報からは判断できない

出力は必ず以下の JSON ブロック形式で返すこと。他のテキストは前後に書かない:
```json
{"verdicts":[{"id":"finding-001","verdict":"confirmed","confidence":87,"severity_suggestion":"must","rationale":"src/auth.ts:48 で ... (path:line を最低 1 つ含める)","suggested_body":null}]}
```

rationale には確認したコード位置 (path:line) を必ず 1 つ以上含める。severity_suggestion は元 severity と異なる提案がある場合のみ書き、なければ元 severity をそのまま入れる。

rationale の接頭辞ルール (集計から正しく除外するため厳守):
- ツール制約による打ち切り → `needs non-read tool: <理由>` で始める (`Needs` / `NEEDS` 等の大文字始まりは禁止)
- コード外確認による打ち切り → `non-code verification required: <理由>` で始める (大文字始まり禁止)
- 通常の判定結果の rationale には上記接頭辞を使わない (path:line と判定根拠を直接書く)

---

# 入力

DIFF (該当箇所):
<該当 path の差分 --unified=20 相当>

FILE_EXCERPT:
<path>:<start>-<end>
<該当ファイル抜粋>

RELATED_THREADS:
<該当 path/line 近接の過去スレッド本文。なければ "なし">

FINDINGS:
[
  {
    "id": "finding-001",
    "path": "src/auth.ts",
    "line": 42,
    "severity": "must",
    "body": "[must] Token refresh races with logout..."
  }
  <LOW 群バッチの場合は最大 5 件並ぶ>
]
```

- HIGH 群: `FINDINGS` 配列は 1 件のみ。
- LOW 群: 最大 `MAX_LOW_BATCH_SIZE` 件 (= 5)。

### Step 5. 結果を集約する

各 Agent 呼び出しの返却テキストから JSON ブロック (` ```json ... ``` ` または直接 `{...}`) を抽出し、`verdicts[]` をマージする。

抽出ロジック:
1. 返却テキストの ` ```json` から ` ``` ` の間を取り出して `JSON.parse`
2. 失敗したら `{` から末尾の `}` まで貪欲マッチで取り出して `JSON.parse`
3. それも失敗したら、その Agent 呼び出しに含まれていた全 candidate を `verdict=uncertain` / `confidence=0` / `rationale="verifier agent failed: JSON parse error"` で埋める

個別 Agent ツールの応答監視は **ランタイム側の Agent タイムアウトに委ねる** (本 skill 側で個別計測しない)。個別 Agent が例外 / 応答不能で完了しない場合も同様に該当 candidate を `verdict=uncertain` / `confidence=0` / `rationale="verifier agent failed: no response"` で埋める。

### Step 6. タイムアウト管理

skill 開始から `VERIFIER_TIMEOUT_SEC` (デフォルト = 「数値リテラル一覧」の `DEFAULT_VERIFIER_TIMEOUT_SEC`) を超えても全 Agent 呼び出しが完了しない場合 (skill 側で計測する):

- 未完了の Agent 呼び出しはキャンセル相当として扱い、その呼び出しに含まれていた candidate を `verdict=uncertain` / `confidence=0` / `rationale="verifier skill timeout"` で埋める。
- `stats.timeout=true` / `stats.status="skipped:timeout"` を立てて返す。

完了済みの `verdicts[]` は通常通り返却に含める。

### Step 7. stats を計算して返す

集計対象の `verdicts[]` には Step 5 / Step 6 の失敗埋めや Step 4 の自己抑制打ち切り (`confidence=0`) も含む (全 candidate が `verdicts[]` に登場する不変)。`mean_conf` / `min_conf` の精度を下げないため、これらの **判定不能による打ち切り行** は集計対象から除外する。除外対象は `confidence=0` かつ `verdict="uncertain"` かつ `rationale` が以下のいずれかで始まる行:

- `verifier agent failed` (Step 5: Agent 例外 / JSON パース失敗)
- `verifier skill timeout` (Step 6: skill 全体タイムアウト)
- `needs non-read tool` (Step 4 自己抑制: Read 以外のツールが必要)
- `non-code verification required` (Step 4 自己抑制: コード外の事実確認が必要)

```
let real = verdicts.filter(v =>
  !(v.confidence == 0 && v.verdict == "uncertain"
    && /^(verifier agent failed|verifier skill timeout|needs non-read tool|non-code verification required)/i.test(v.rationale))
);

stats.status          = (Step 6 で打ち切った) ? "skipped:timeout" : "ok"
stats.total           = CANDIDATES.length
stats.confirmed       = verdicts.filter(v => v.verdict == "confirmed").length
stats.false_positive  = verdicts.filter(v => v.verdict == "likely_false_positive").length
stats.uncertain       = verdicts.filter(v => v.verdict == "uncertain").length
stats.mean_conf       = real.length > 0 ? round(mean(real.map(v => v.confidence))) : null
stats.min_conf        = real.length > 0 ? min(real.map(v => v.confidence))         : null
stats.agents_invoked  = (HIGH 群件数) + (LOW 群バッチ数)
stats.parallel_max    = max(各ラウンドで同一メッセージ内に発行した Agent tool use ブロック数)
stats.timeout         = Step 6 で打ち切ったか否か
```

`stats.parallel_max` の観測タイミングは **発行時の bunch size** (同一メッセージ内 tool use ブロック数) で確定する。実行完了の重なりまでは追わない (決定論性のため)。

候補が 0 件の場合 (Step 0 早期 return) は `mean_conf` / `min_conf` を `null` にする。Step 5/6 の失敗埋めしか残らなかった場合 (`real.length == 0`) も `null` にする。

最終的に `{"verdicts": [...], "stats": {...}}` の JSON を caller に返す。caller (run-pr-review / run-local-review の Step 5.5) がフィルタ / ソート / 本文書き換えを担う。
