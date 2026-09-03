# pr-review plugin

PR レビューを **1 つの Review として投稿** し、過去スレッドを安全に **resolve** するための skill 群、PR 作成前のローカルブランチを対象に AI レビューを行いチャット + markdown ファイルへ出力する skill、およびレビューコメントの **スタイル参考ガイド** をスラッシュコマンドとしてまとめて提供する。

## 提供 skill / command

- `skills/run-pr-review`: PR レビュー一式 (PR 取得 → `compose-review` でレビュー本文生成 → 投稿 → 過去スレッド resolve) を 1 コマンドで実行する thin orchestrator skill。caller はこれを呼ぶだけで済む。
- `skills/compose-review`: PR 差分 or ローカルブランチ差分に対してレビュー本文 (`body` / `event` / `comments[]`) を生成する skill。`/pr-review-style-reference` とプロジェクト指示ファイルを読み込んでレビュー方針を決め、`post-pr-review` のスキーマに揃った JSON を **`HANDOFF_PATH` (caller が渡す書き出し先パス。省略時は `/tmp/compose-review-<UTCタイムスタンプ>-<ランダム英数字 4〜6 文字>.json`。ランダムサフィックスは同一秒の再呼び出しでの衝突回避用) にファイル書き出し**し、最終メッセージでは **「そのファイルを `Read` して続行せよ」という継続指示** を返す (caller はそのファイルを `Read` して JSON を使う)。自己完結 JSON を最終メッセージに出さないのは、それが「タスク完了」シグナルに見え、caller (orchestrator) が投稿 step を実行する前にターンを終了する停止バグを誘発するため。書き出す JSON には `body` / `event` / `comments[]` に加え、機械可読サマリ行の正典値になる `label_counts` (ラベル別件数。`MAX_INLINE_COMMENTS` で省略した指摘も含む) を含める。指摘は自前レビューを必ず行い、加えて外部レビュースキル (優先順: `code-review` (Claude Code 組み込み) → `scan-diff-findings` (本 plugin 同梱) → ホスト標準レビュースキル例 Codex `/review` → 無し) を 1 つ併用して指摘をマージする (通常は常に併用。1 つも使えなかったときだけ自前単独で、その場合は理由を総括 `body` に 1 文開示する)。`run-pr-review` / `run-local-review` のいずれからも **sub-agent として起動される** (後述「`compose-review` の呼び出し方」)。
- `skills/scan-diff-findings`: 差分 (ref range / ブランチ / staged / worktree) を対象に **観点別 finder の fan-out → 各 finding の adversarial verify → マージ** を行い、`path` / `line` / 要約 / 重大度 (`high` / `medium` / `low`) に正規化した findings JSON を `FINDINGS_PATH` にファイル書き出しする read-only レビュースキル。`compose-review` Step 5-2 が併用する外部レビュースキルの 1 つで、Claude Code 組み込みの `code-review` が `disable-model-invocation` によりモデルから呼べない環境でも外部レビュー併用を成立させるために用意している (後述「外部レビュースキルの併用」)。Agent ツールが使えない環境では観点リストを現在コンテキストで逐次自己適用するフォールバックを持つ。ファイル編集 / GitHub 投稿 / working tree を変える git 操作は行わない。
- `skills/post-pr-review`: レビュー本文 + インラインコメント群を 1 つの GitHub Review として投稿する。投稿経路は 2 チャネル対応 (`CHANNEL=gh`: `gh api .../reviews` の 1 コール / `CHANNEL=mcp`: GitHub MCP ツールで pending review を組み立てて submit。詳細は後述「GitHub アクセスチャネル」)。Review body には AI 自動投稿マーカーと **機械可読サマリ行** (`<!-- AI-REVIEW-RESULT: must=0 should=1 ... -->`) を自動で付与する (後述「機械可読サマリ行 (CI からの機械判定)」)。
- `skills/resolve-pr-threads`: 過去のレビュースレッドのうち修正済みのものだけを `resolveReviewThread` で resolve する。`THREAD_RESOLVE_SCOPE` (`all` / `own` / `none`) で範囲を制御。
- `skills/run-local-review`: 現在のローカルブランチを対象に PR 作成前の AI レビューを行い、結果を **チャット + markdown ファイル** に出力する thin orchestrator skill (GitHub 投稿は行わない)。レビュー本文生成は `compose-review` に委譲する点で `run-pr-review` と対称で、両者とも `compose-review` を sub-agent として起動する (後述「`compose-review` の呼び出し方」)。
- `skills/distill-pr-reviews`: 期間内 merged PR のレビューコメント (AI 自動投稿 + 人間レビュー両方) を集約し、REVIEW.md に追記する価値のある指摘候補を `proposals.md` として出力する skill。バグ修正PR (fix型title / bugラベル / revert 等で検知) の修正diffも抽出源にし、コメントの付かない hotfix からも再発防止のレビュー観点を抽出する (`MAX_BUGFIX_DIFFS` で diff 取得上限を制御)。信号収集はスクリプト、最終的な採否分類 (`accept` / `hold` / `reject`) とクラスタリングは AI が行う。read-only で REVIEW.md 編集 / PR 作成は行わない。**収集スクリプトが `gh` CLI に依存するため gh チャネル専用** (gh が使えない環境では動かない。後述「GitHub アクセスチャネル」参照)。
- `commands/pr-review-style-reference`: `/pr-review-style-reference` で呼び出す **スタイル参考ガイド** (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い)。レビューコメントの書き方・体裁が対象で、技術観点 (何を見るか) は対象外。`compose-review` から内部的に呼ばれる。

レビュー方針は caller (ユーザー) に委ねる前提。本スタイル参考ガイドは「そのまま採用 / 上に caller のカスタム指示を重ねる / 採用せず無視する」のいずれの使い方も可能。技術観点 (何をレビューするか) は caller 側で別途指定する想定。

## `compose-review` の呼び出し方 (sub-agent 起動)

両 orchestrator (`run-pr-review` / `run-local-review`) は `compose-review` を **Agent ツールで sub-agent として起動する** (Agent ツールが使えなければエラー停止。直接呼びへのフォールバックは持たない)。理由:

1. **停止バグが起きにくい**: `compose-review` は完成 JSON を `HANDOFF_PATH` に書き出し、最終メッセージには継続指示文だけを返す設計だが、直接呼びではその継続指示文をそのまま orchestrator の最終メッセージにして応答を打ち切る事故が起きやすかった (レビュー本文を作っただけで投稿 / markdown 出力に進まない、この plugin で最頻の失敗)。sub-agent の完了は Agent ツールの結果として返る = 明示的な制御戻り境界ができる。**ただし完全な保証ではない** — ホストが `run_in_background: false` を無視して background 実行に回すと、その回はターンがいったん終わる。orchestrator 側に待ち合わせ・完了通知での再開・冪等ガードの規定がある (正典は `run-pr-review` Step 3-1)。
2. **コンテキストが膨らまない**: 大きい PR 差分の読解や外部レビューの中間出力が sub-agent 側に閉じ、orchestrator には `HANDOFF_PATH` のパスと短い完了報告だけが返る。

> かつては「`compose-review` Step 5-2 の外部レビュー fan-out (Agent ツール) が sub-agent コンテキストでは動かない」ため直接呼びが必須だったが、**sub-agent のネスト起動がサポートされた** (既定でメイン会話から 3 階層まで。`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` で変更可) ため、この前提は成立しない。深さ予算は orchestrator (メイン) → `compose-review` (1 階層目) → `scan-diff-findings` の finder / verifier (2 階層目) で既定の 3 に収まる。

**トレードオフ**: ネスト起動が可能でも、`compose-review` sub-agent のコンテキストで Agent ツールが実際に提示されるとは限らない (深さ上限のほか、ホストや agent 定義がツールを絞る場合がある)。提示されなければ `scan-diff-findings` は inline フォールバックに落ち、外部レビューが自前レビューと同一コンテキストの逐次自己適用になる = **独立性が失われる**。併用自体は成立し縮退も `external_review` と開示に出るが、**「sub-agent 起動 = 独立した第 2 系統が常に得られる」ではない**。もう 1 点、sub-agent からは orchestrator のセッションコンテキストが見えないため、**手動 `/code-review` 併用は成立しない** (後述)。

## 外部レビュースキルの併用 (自前レビュー + 外部スキル → マージ)

`compose-review` は **自前レビューを必ず行った上で**、ホストの外部レビュースキルを **優先順で 1 つ** 併用し、両者の指摘をマージする (重複は同一 `path:line` + 同主旨で 1 件に集約、重要度競合は高い方を採用)。**外部スキル併用は通常常に実施**され、外部スキルが 1 つも使えないときだけ自前単独になる。

優先順位:

1. `code-review` (Claude Code 組み込み) — **多くの環境ではモデルから呼び出せない** (後述「`code-review` が呼べない問題」)。かつ **同梱の orchestrator 経由では成立しない** (sub-agent からはセッションコンテキストが見えない。後述「外部レビューの手動併用」)。
2. `scan-diff-findings` (本 plugin 同梱) — **リポジトリ / ユーザー管理下の、モデル呼び出し可能なレビュースキル**の枠。1 が使えない環境での正規経路で、`code-review` と同じ「観点別 finder の fan-out → adversarial verify → マージ」構成を持つ。Agent ツールが無い環境でも現在コンテキストでの逐次自己適用にフォールバックするため、1 の失敗モード (Agent 依存 / `disable-model-invocation`) を引き継がない。caller 側リポジトリに同等の read-only レビュースキルがあればそれを使ってもよい。
3. ホスト coding agent の標準レビュースキル (例: Codex の `/review`) — 環境依存で存在しないことが多く、当てにはしない。
4. いずれも無ければ自前レビュー単独。**この場合 `compose-review` は「外部レビュー未併用」の事実と理由を総括 `body` (`## 総合判断` 末尾) に 1 文記載する** (黙って自前単独へ退化しない)。

`compose-review` は 5-2 の結末を **機械可読フィールド `external_review`** (8 キー固定: `{"skill": "scan-diff-findings"|"code-review"|…|"none", "mode": "agent"|"partial"|"inline"|"empty"|"external"|null, "verify_degraded": true|false|null, "finders": N|null, "finders_expected": N|null, "findings": N, "omitted": N, "reason": "…"|null}`。正典は [`skills/compose-review/SKILL.md`](skills/compose-review/SKILL.md) Step 6) としてハンドオフ JSON に必ず含める。人間向けの開示文 (総括 `body`) と機械向けの `external_review` の両方を必須にしているのは、開示が prose だけだと 1 文の書き漏らしで「黙って退化していた」状態に戻るため。`run-pr-review` は Step 6 の報告に、`run-local-review` は markdown ヘッダと報告にこの値を必ず載せる。

- `skill == "none"` → 外部レビュー未併用。
- `mode == "inline"` → 外部スキルが Agent ツール不可で同一コンテキストの逐次自己適用にフォールバックした (自前レビューとの独立性が限定的)。
- `mode == "partial"` (= `finders < finders_expected`) → fan-out したが一部の観点の結果しか得られなかった (網羅性が限定的)。
- `mode == "empty"` → 外部スキルは応答したが「対象差分なし」を返した (scope 不一致で実質未併用)。
- `verify_degraded == true` → 外部スキルの adversarial verify が全件成立しなかった (指摘は未検証)。
- 上記の縮退は総括 `body` の開示対象。**`mode == "agent"` (かつ verify 正常) と `mode == "external"` は、いずれも `omitted == 0` なら開示不要** (開示が必要なケースは `compose-review` 5-5 が列挙する) — `"external"` は `code-review` / Codex `/review` 等が `fanout` 相当の内訳を返さないだけで縮退ではないため。

PR 経路では `run-pr-review` が `external_review` を `post-pr-review` に転送し、Review body に `<!-- AI-REVIEW-EXTERNAL: skill=… mode=… verify_degraded=… finders=n/m findings=n omitted=n -->` の 1 行として埋め込まれる。これにより GitHub 上にも機械可読な痕跡が残り、CI は総括本文の prose を読まずに「外部レビューが併用されたか / 縮退したか」を判定できる (詳細は `post-pr-review` SKILL.md の「外部レビュー行 (`AI-REVIEW-EXTERNAL`)」節)。

外部レビュースキルは **read-only** で呼ぶ (投稿 / 自動修正フラグは付けない。`code-review` なら `--comment` / `--fix` を付けない)。`REVIEW.md` 等のプロジェクト方針は `code-review` / ホスト標準スキルには渡さない (scope 引数専用で free-text 非対応) が、`scan-diff-findings` は `EXTRA_FOCUS` で観点を free text で受け取れる。いずれの経路でも最終的なラベル付け・正規化は `compose-review` 側の責務。

### `code-review` が呼べない問題 (`disable-model-invocation`)

Claude Code 組み込みの `code-review` は skill 定義の frontmatter に `disable-model-invocation: true` を持つため、**モデルから Skill ツール経由で呼び出せない**。

- Skill ツールの検証段階で `Skill code-review cannot be used with Skill tool due to disable-model-invocation` として拒否される。
- モデルに提示される available-skills 一覧からも除外されるため、そもそも候補として見えない。
- この挙動は skill 定義の frontmatter が唯一の入力源で、settings.json のオプトインや `permissions.allow` では解除できない (検証が権限判定より前段のため)。

つまり `code-review` を第 1 候補に置いた解決順だけでは、外部レビュー併用は多くの環境で構造的に不成立になる。`scan-diff-findings` (優先順 2) はこの枠を埋めるために用意されており、**`disable-model-invocation` を持たない** ことが要件そのもの。同種の自前レビュースキルを追加する場合も同様に付けてはならない。

### 外部レビューの手動併用 (`/code-review` を先に実行する運用)

`code-review` は **ユーザーがスラッシュコマンドとして手で叩く分には制約を受けない**。そこで、`code-review` の findings をどうしても併用したい場合は次の順で実行する:

1. `/code-review` を手動で実行する (レビュー対象を引数で指定。`--fix` / `--comment` は付けない)。
2. **同じセッションのまま** `/run-pr-review` (または `/run-local-review`) を実行する。

1 の findings はセッションのコンテキストに残るため、`compose-review` Step 5-2 はそれを外部レビュー結果として採用できる。

**ただし両 orchestrator は `compose-review` を sub-agent として起動するので、この運用は成立しない** — sub-agent からは orchestrator のセッションコンテキストが見えず、先行実行された findings を観測できない。**既知の制限**として受け入れており、その場合は優先順 2 の `scan-diff-findings` が使われる。外部レビュー併用そのものは成立するので、失われるのは「手動 `code-review` の findings が加わる」分だけで、自前レビュー単独への黙った退化にはならない (この例外が効くのは、`compose-review` を直接呼ぶ他 caller の回だけ)。

## caller プロジェクトのレビュー方針の置き方

`compose-review` (`run-pr-review` / `run-local-review` のいずれからも呼ばれる) は **リポジトリ root の以下のファイルを自動で読み込む** (この順で最初に見つかった 1 つだけ):

1. `REVIEW.md` — レビュー専用の最上位指示 (推奨)
2. `AGENTS.md` — agent 全般向けの fallback
3. `.claude/CLAUDE.md` — Claude Code 全般向けの fallback (`.claude/` 配下に置く流儀)
4. `CLAUDE.md` — Claude Code 全般向けの fallback (リポジトリ root に置く流儀)

個別ファイルパスを skill 引数で渡す方式は持たない。複数ファイルを束ねたい場合は caller 側 workflow で 1 ファイルに事前生成 (例: `cat docs/general.md docs/typescript.md > REVIEW.md`) してから skill を呼ぶ。Claude Code 全般指示が `.claude/CLAUDE.md` と `CLAUDE.md` の両方に存在する場合は `.claude/CLAUDE.md` のみが採用される (連結はしない)。

### `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` を fallback として使う際の注意

`AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` はもともとレビュー専用ではなく、`claude /init` が生成する雛形には「テストを必ず走らせる」「lint をかける」「編集後に X を実行する」等の **アクション指示** が含まれることが多い。本 plugin (`compose-review`) は read-only レビュー専念で、これらのアクション指示は **実行しない** (レビュー観点に翻訳できる範囲のみ参照する) ように `compose-review` Step 3 で明示的に防いでいるが、念のため次のいずれかを推奨する:

- レビュー方針として意図されていないアクション指示が多い場合は、リポジトリ root に **`REVIEW.md` を新規作成** してレビュー方針だけを書き、`AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` は読まれないようにする (上記優先順で `REVIEW.md` が最優先)。
- `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` 内でレビュー専用セクションを設けて他から分離する。

## `post-pr-review` を他から呼ぶ場合

`skills/post-pr-review` は **「レビュー本文を受け取って GitHub Review として 1 つの Review として投稿する」専用の投稿 skill** として、`run-pr-review` 経由だけでなく外部 skill / 外部ワークフロー / 人手起動からも直接呼べる設計になっている (投稿経路は `CHANNEL=gh|mcp` の 2 チャネル対応。前述「GitHub アクセスチャネル」参照)。「レビューを書く」フェーズと「レビューを投稿する」フェーズを分離したい場合、書く側 (別 skill / 別エージェント / 人) が下記 Payload を生成して post-pr-review に流し込めばよい。

Payload (caller が渡す JSON 相当) の概要:

- `body` (string, 必須): 総括コメント本文。AI 自動投稿マーカーと機械可読サマリ行は skill 側で自動 prepend するため caller は付けない。
- `event` (literal `"COMMENT"`, 必須): `APPROVE` / `REQUEST_CHANGES` は禁止。
- `comments` (array, 必須・空配列可): インライン指摘の配列。各要素は単一行 (`path` / `line` / `side` / `body`) または複数行範囲 (上に加えて `start_line` / `start_side`)。
- `commit_id` (string, 任意): head commit の SHA。force-push / rebase での行ズレ防止に推奨。CI が「head SHA に対するレビューか」を review の `commit_id` で判定する運用では常に渡す。
- `label_counts` (object, 任意): ラベル別指摘件数 (`{"must":1,"should":2,...}`)。機械可読サマリ行の件数の正典値になる。省略時は `comments[]` の先頭ラベルから skill 側が集計する。

詳細なスキーマ・呼び出し経路 (Skill ツール経由 / prompt 経由) は [`skills/post-pr-review/SKILL.md`](skills/post-pr-review/SKILL.md#public-payload-interface) を参照。インライン指摘本文の規約 (`[must]` / `[should]` 等の重要度ラベル) は本 skill では規定せず caller のレビュー方針に従う想定で、当 plugin 既定の体裁は `/pr-review-style-reference` を参考にできる。

## 機械可読サマリ行 (CI からの機械判定)

`post-pr-review` は投稿する Review の `body` に、ラベル別指摘件数の **機械可読サマリ行を必ず 1 行埋め込む** (指摘 0 件でも省略しない)。「AI レビュー済みかつブロッキング指摘なし」を CI の required status check で判定する用途を想定した **公開契約** で、正典は [`skills/post-pr-review/SKILL.md`](skills/post-pr-review/SKILL.md#機械可読サマリ行-ai-review-result) の「機械可読サマリ行」節。

```
<!-- AI-REVIEW-RESULT: must=0 should=1 nit=2 question=0 pre_existing=0 other=0 -->
```

- **HTML コメント**なので人間向け表示は汚さないが、REST API (`GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews`) が返す review の `body` には残るので正規表現でパースできる (例: `AI-REVIEW-RESULT:.*?must=(\d+)\s+should=(\d+)`。**係留キー `AI-REVIEW-RESULT` を必ず前置する** — 省くと body 中のプレーンな `must=0 should=0` にもマッチし、サマリ行が無い review を「レビュー済み」と誤判定する)。
- 挿入位置は AI 自動投稿マーカーの直後 (区切り線 `---` の前) に固定。キーは 6 つを固定順で常に全出力し、値は 0 以上の整数。
- 件数の正典は caller から渡される `label_counts`。`run-pr-review` 経路では `compose-review` が **`MAX_INLINE_COMMENTS` で省略した指摘も含めた** 件数を算出して引き回すため常に正確。`label_counts` が無い場合は `post-pr-review` が `comments[]` の先頭ラベルから集計する (省略分は数えられないため個々の件数は実際より小さくなりうる。安全側に倒れるのは **「`must=0` かつ `should=0`」という複合条件**のみで、`should` 単独では倒れない — 例えば `MAX_INLINE_COMMENTS=1` で `[must]` 1 件 + `[should]` 2 件なら結果は `must=1 should=0` になるため、`should` 単独の条件を組むと実在する should 指摘を「なし」と扱ってしまう)。
- 標準 5 ラベル以外 / ラベル無しの指摘は `other` に合算する。ラベル体系を独自定義している caller は、`label_counts` で標準ラベルへマッピングして渡す (でなければ CI 側の合格条件に `other=0` も加える)。
- CI が「PR の現在の head SHA に対するレビューか」を判定する場合は review の `commit_id` を head SHA と比較する。`post-pr-review` は `COMMIT_ID` が渡されたときだけ `commit_id` を送るため (未指定時は GitHub が投稿時点の最新 commit を採用)、`run-pr-review` は取得済みの `headRefOid` を常時転送する。
- caller が `EXTERNAL_REVIEW` を渡した場合、サマリ行の直後に **外部レビュー行** も 1 行埋め込まれる。こちらは「レビュー体制が健全だったか (外部レビューを併用できたか / 縮退したか)」を機械判定するための行で、`run-pr-review` 経路では常に付く。

  ```
  <!-- AI-REVIEW-EXTERNAL: skill=scan-diff-findings mode=agent verify_degraded=false finders=5/5 findings=9 omitted=0 -->
  ```

  `skill=none` / `mode=inline|partial|empty` / `verify_degraded=true` はレビュー体制の縮退シグナル (前述「外部レビュースキルの併用」参照)。パース時は `AI-REVIEW-RESULT` と同様に係留キーを前置する。

- caller が `ESCALATION` を渡した場合、外部レビュー行の直後に **エスカレーション行** も 1 行埋め込まれる。「この PR は重要な判断 (仕様 / 挙動 / 設計) を含むので第三者の確認が要る」と `compose-review` が判定したかを機械判定するための行。

  ```
  <!-- AI-REVIEW-ESCALATE: escalate=1 reasons=2 -->
  ```

  `escalate` は `1` / `0`、`reasons` は理由の **件数** (人間向けの理由本文はレビュー本文の `## エスカレーション` セクションに出る)。用途は **CI が該当者をレビュアーに追加するためのルーティング**で、マージをブロックするゲートではない (`event` は常に `COMMENT`)。required status check にするかは利用側の判断。

  **判定基準は当 plugin 側に持たない** — `compose-review` はプロジェクト指示ファイル (`REVIEW.md` / `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` の優先順で最初の 1 つ) に **見出しタイトルが `エスカレーション基準` を含むセクション** があるときだけ判定し、そのセクション配下の記述だけを基準として扱う (opt-in の閾値を自由文の解釈に委ねると、`CLAUDE.md` によくある「破壊的変更は相談して」の一文でこの機能を使う気のないリポジトリまで判定が走ってしまうため)。**opt-out = 見出しを置かない**。見出しが無い利用側では判定を行わず `escalate: false` になり、`run-pr-review` は **`escalate: true` の回だけ `ESCALATION` を転送する**ため **この行自体が出ない** (= 従来と同じ出力)。したがって CI が見るべきは `escalate=1` の存在だけで、行が無い状態は「エスカレーション不要」と「基準が無く判定なし」の両方を含む。**本行は常在しないため、パースは body 冒頭のマーカー行から最初の `---` までの範囲に限る** (総括本文中のフォーマット例を拾わないため)。利用側は (1) プロジェクト指示ファイルへの `## エスカレーション基準` セクションの記述、(2) この行をパースしてレビュアーを追加する workflow を自前で用意する (誰をアサインするかはプロジェクト固有なので plugin 側では行わない)。

## 重要度ラベル

インライン指摘は以下のいずれかのラベルで開始する (詳細は `/pr-review-style-reference`):

- `[must]` 不具合・脆弱性。マージ前対応必須。
- `[should]` 設計・保守性で強く推奨される改善。放置すると次の修正で `[must]` 化する蓋然性が高いもの。
- `[nit]` 軽微・好み寄り。実装者が無視してよい。
- `[question]` 質問。実装者の意図確認のみで修正要求ではない。
- `[pre_existing]` 本 PR で導入されたものではない既存バグ。マージ判断には影響させない。

## GitHub アクセスチャネル (gh / GitHub MCP)

GitHub API 操作 (PR メタ取得 / CI ログ / reviewThreads / Review 投稿 / スレッド resolve) は実行環境によって使える経路が異なるため、`run-pr-review` は実行時にチャネルを検出して選ぶ (`CHANNEL=gh|mcp`)。gh と GitHub MCP ツールは**対等な正規チャネル**であり、どちらか一方への決め打ちはしない:

| 環境 | gh CLI | GitHub MCP ツール (`mcp__github__*`) |
|---|---|---|
| GitHub Actions (claude-code-action) | ✅ (`github_token` で動く) | ❌ 通常無い |
| ローカル Claude Code | ✅ (`gh auth login` 済みなら) | △ 接続していれば有る |
| Claude Code web/remote セッション | ❌ 恒常 403 (GitHub API 直接アクセスが遮断され、curl 直叩きも同様に不可) | ✅ 唯一の到達経路 |

チャネル解決手順は `run-pr-review` Step 1-2 を正典とし (`gh api repos/<OWNER>/<REPO> --jq .full_name` の成否 → MCP ツールの有無 → どちらも不可ならエラー)、`run-pr-review` が 1 回だけ解決して `post-pr-review` / `resolve-pr-threads` へ `CHANNEL` として転送する。各 skill を単独で呼ぶ場合は skill 側が `run-pr-review` Step 1-2 と同じ手順で自力解決する (手順の全文は各 skill には再掲せず正典を参照)。

例外は `distill-pr-reviews`: 収集ロジックが bash スクリプト (`scripts/collect-signals.sh`) にあり、bash からは MCP ツールを呼べないため **gh チャネル専用** (gh が使えない環境では実行できない)。

なお PR 差分の取得 (`compose-review`) はどちらのチャネルにも依存せず pure-git (read-only fetch + `git diff`) で完結する。

## 利用方法 (GitHub Actions)

`run-pr-review` の動作には以下の権限が必要。job の `permissions:` で明示する (Review 投稿 / 過去スレッド resolve で使用):

```yaml
permissions:
  contents: read         # PR 差分 / リポジトリ root のレビュー方針ファイル参照
  pull-requests: write   # Review 投稿 / 過去スレッドへの reply / resolve (GraphQL)
```

> 本 skill 群はトップレベル PR コメント (`POST /repos/.../issues/{n}/comments` 経路) を投稿しないため `issues: write` は不要。caller が `claude-code-action` 等を経由している場合は action 側の要件で `issues: write` が要求されることがあるため、その場合のみ caller が追加する。

```yaml
- uses: anthropics/claude-code-action@v1
  with:
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    plugin_marketplaces: |
      https://github.com/abeyuya/skills.git
    plugins: |
      pr-review@abeyuya-skills
    prompt: |
      OWNER: ${{ github.repository_owner }}
      REPO: ${{ github.event.repository.name }}
      PR_NUMBER: ${{ github.event.pull_request.number }}
      THREAD_RESOLVE_SCOPE: all

      run-pr-review skill を呼び、上記の入力で PR レビュー一式 (方針読み込み・レビュー作成・投稿・過去スレッド resolve) を実行してください。
      caller プロジェクトのレビュー方針はリポジトリ root の REVIEW.md / AGENTS.md / .claude/CLAUDE.md / CLAUDE.md のいずれかに置けば自動で読み込まれます (この順で最初に見つかった 1 つだけ)。
    claude_args: |
      --allowedTools "Read,Write,Glob,Grep,Agent,Task,Skill,Bash(gh api:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh run view:*),Bash(git log:*),Bash(git blame:*),Bash(git diff:*),Bash(git rev-list:*),Bash(git rev-parse:*),Bash(git symbolic-ref:*),Bash(git remote:*)"
```

> 上記 `--allowedTools` は GitHub Actions (= gh チャネル) 用。GitHub MCP ツールが使える環境 (web/remote セッション等) では `CHANNEL=mcp` が選ばれ、`mcp__github__pull_request_read` / `mcp__github__pull_request_review_write` (投稿・resolve 兼用) / `mcp__github__add_comment_to_pending_review` / `mcp__github__add_reply_to_pull_request_comment` / `mcp__github__get_job_logs` / `mcp__github__list_pull_requests` が代わりに使われる (詳細は「GitHub アクセスチャネル」)。この一覧は許可設定の目安であり、実際に各 skill が使うツールの正典は各 `SKILL.md` の手順を参照。

## 利用方法 (ローカル Claude Code)

```bash
/plugin marketplace add abeyuya/skills
/plugin install pr-review@abeyuya-skills
```

## 利用方法 (apm 経由)

[apm (Agent Package Manager)](https://github.com/microsoft/apm) は Claude Code 形式の `marketplace.json` / `plugin.json` をネイティブに解釈するため、本リポジトリの配布物 (`.claude-plugin/marketplace.json` と `plugins/pr-review/`) を **そのまま** 依存として扱える。配布ファイルの二重管理は不要。

```bash
# marketplace 経由 (recommended)
apm marketplace add abeyuya/skills
apm install pr-review@abeyuya-skills

# または subdirectory を直接指定する primitive form
apm install abeyuya/skills/plugins/pr-review
```

`apm install` 後、`pr-review` plugin の skill / command は consumer 側の `.claude/skills/` および `.claude/commands/` に展開される (ローカル Claude Code 経由で `/plugin install` した場合と同じファイルがインストールされる)。

## 開発時 (このリポジトリ自身で plugin を編集しながら使う)

`/plugin install` 経由だと `~/.claude/plugins/cache/` にコピーされた版が使われ、
ローカルの未コミット変更が反映されない。編集中の内容をそのまま動かすには
`--plugin-dir` でディスクを直接読ませる:

```bash
claude --plugin-dir plugins/pr-review
```

セッション中に `SKILL.md` や `commands/*.md` を編集したら `/reload-plugins` で再読込できる。

### 別ブランチで新規 skill を追加した PR を試す場合 (`Unknown skill: <name>` エラー対処)

ローカルでブランチをチェックアウトしても Claude Code は **自動的に plugin install を更新しない**。`/plugin install` 済みの main 版に compose-review が無ければ、本ブランチをチェックアウトしても `Skill ツール (skill: "compose-review")` 呼び出しが `Unknown skill: compose-review` で失敗する (`run-pr-review` / `run-local-review` のどちらから呼んでも、sub-agent 経路 / 直接呼び経路のどちらでも同じ)。対処:

1. **推奨**: `claude --plugin-dir plugins/pr-review` で起動する。`--plugin-dir` 指定は同名の install 済み plugin より優先され、本ブランチの未コミット内容も含めてその場で読み込まれる。
2. **代替**: `/plugin marketplace add abeyuya/skills && /plugin install pr-review@abeyuya-skills` を再実行する (marketplace の HEAD コミットを再 fetch して install を更新)。
3. **緊急 workaround**: orchestrator (`/run-pr-review` / `/run-local-review`) を手動で停止し、`compose-review/SKILL.md` を `Read` で直接読んで手順を実行する (skill 経由ではなくなるので戻り値の構造化は崩れる)。

これは plugin marketplace 仕様であり本 plugin のバグではない。PR merge 後 marketplace の HEAD が更新されれば通常の `/plugin install` で同梱される。
