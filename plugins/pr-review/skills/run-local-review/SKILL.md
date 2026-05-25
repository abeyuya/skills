---
name: run-local-review
description: 現在のローカルブランチを対象に、PR を作る前段階で AI レビューを行う skill。compose-review skill にローカル diff モードで処理を委譲し、生成されたレビュー JSON (body / event / comments[]) をチャットに返す。GitHub への投稿は行わない (post-pr-review / resolve-pr-threads は呼ばない)。
---

# run-local-review skill

PR 作成前のローカルブランチに対して AI レビューを行うための thin orchestrator skill。
レビュー本文の生成は `compose-review` skill (ローカル diff モード) に委譲する。本 skill は呼び出しと caller 報告のみを担う。

> **Breaking change (v0.2.0)**: 旧版 (v0.1.x) の `OUTPUT_PATH` 引数と markdown ファイル出力 (`/tmp/run-local-review/...`) は廃止された。新版は `compose-review` の JSON 戻り値をそのまま chat に出す挙動のみ。旧 caller が `OUTPUT_PATH=...` を渡しても黙って無視される (エラーにはならない)。markdown 形式が必要な場合は caller 側で JSON 戻り値を加工する。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。

- `BASE_BRANCH`: 比較対象のベースブランチ。省略時は `compose-review` 側で `origin/HEAD` → `main` → `master` の順に解決される。本 skill / `compose-review` ともに `git fetch` を走らせないため、ローカルのベースが古いと古い基準で diff が出る。最新で比較したい場合は caller 側で fetch するか、`BASE_BRANCH=origin/main` のようにリモート追跡参照を明示する。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited` 扱い。`compose-review` にそのまま転送する。

caller プロジェクト固有のレビュー方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** (`REVIEW.md` / `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` の優先順で最初の 1 つだけ) に置く運用に固定する。読み込み自体は `compose-review` 側で行うため本 skill では扱わない。

## 手順

### Step 0. 廃止入力の検知 (silent failure 防止)

caller から **v0.1.x で受け付けていた廃止入力** (`OUTPUT_PATH` 等) が渡されていないか確認し、渡されていれば **chat に 1 行警告** を出してから次の step に進む (skill 自体は停止しない)。本 skill は v0.2.0 でこれらを silent ignore する仕様だが、`apm` / `/plugin install` でバージョン固定をしていない consumer (CI / GitHub Actions) が旧入力を渡し続けたまま「markdown ファイルだけ出なくなる」silent failure を踏むのを防ぐため、明示的に気付かせる。

検知ロジック (機械的に再現できるよう手順を固定):

- 対象: Skill ツールに渡された `args` 文字列 (caller からの prompt 全体)。
- マッチ規則: 各廃止入力名 `<NAME>` について、**正規表現 `(?:^|\s)<NAME>=` (大文字小文字を区別する)** で 1 件以上ヒットしたら警告対象とする。トークン形式 (`OUTPUT_PATH=...`) のみを拾い、自由文中の `OUTPUT_PATH` への言及 (例: 「過去の OUTPUT_PATH 議論」) は誤検知しない。
- 1 つの args 内に複数の廃止入力があれば、それぞれ 1 行ずつ警告する (1 廃止入力 = 1 warning 行)。
- 警告は **必ず chat に出力する** (本 skill のレポート本文より前、Step 1 開始前に出すこと)。

警告フォーマット (固定文言、逐語):

```
[run-local-review] WARNING: 廃止された入力 `<NAME>=...` が渡されましたが、v0.2.0 で廃止済みのため無視します。代替: <代替手段の 1 行>
```

廃止入力と代替の対応:

- `OUTPUT_PATH=...`: 代替 = 「`compose-review` の JSON 戻り値を caller 側で markdown 化する」

将来廃止入力を追加する場合は本リスト (廃止入力名 + 代替手段) を更新する。マッチ規則と警告フォーマットは共通のまま使い回す。

### Step 1. 報告用にブランチ情報を取得する

caller への最終報告 (Step 3) で使う「現在ブランチ名」だけ取得する。`BASE_BRANCH` と差分モードの確定は `compose-review` に委譲し、その戻り値経由で受け取る。

- 現在ブランチ名: `git rev-parse --abbrev-ref HEAD`。`HEAD` (detached) の場合はエラーとして停止する (このチェックは `compose-review` 側にも入っているが、orchestrator 段階で早期に弾くことで Skill 呼び出しコストを節約する)。

### Step 2. `compose-review` skill を呼び出す

Skill ツールで `compose-review` をローカル diff モードで呼ぶ。引数は以下:

- `BASE_BRANCH` (caller から渡されていれば)
- `MAX_INLINE_COMMENTS` (caller から渡されていれば)

`OWNER` / `REPO` / `PR_NUMBER` は **渡さない** (渡すと PR モードに切り替わるため。空文字を渡すのも不可 — `compose-review` 側は空文字を未指定と同等に扱うがミスの温床なので **そもそも渡さない**)。

`OUTPUT_DESTINATION` も **渡さない** (デフォルト `chat` を採用する)。`compose-review` から chat に fenced JSON が出力され、それを本 skill 経由で caller (人間) が直接読む運用にする (`run-pr-review` は orchestrator 経由で `post-pr-review` まで連鎖させるために `file` を指定するが、本 skill は Step 4 以降を持たないため file 出力にする必要がない)。

`compose-review` は fenced JSON ブロックで以下のフィールドを返す:

- `_intermediate: false` (ローカル diff モードでは本 skill が最終 caller なので最終成果物扱い)
- `mode`: `"local"`
- `base_branch`: 解決済みのベースブランチ名 (`main` / `master` / caller 指定値)
- `diff_mode`: `"commit"` / `"staged"` / `"worktree"` / `"none"`
- `body` / `event` / `comments[]`
- `_summary_meta`: 集計値 (`inline_count` / `inline_count_by_severity` / `main_concerns_count` / `praises_count` / `omitted_count`)。Step 3 の caller 報告で参照する。

`commit_id` / `next_step` はローカルモードでは含まれない (chat モード仕様により `next_step` は PR モード chat 出力でも省略される)。本 skill は Step 4 以降を持たないため、`_intermediate: false` を確認してそのまま caller に提示する。

### Step 3. caller への報告

Step 2 で `compose-review` が **既に fenced JSON ブロックを chat に出力済み** なので、本 skill から **同じ JSON を再出力しない**。本 skill が追加で出す chat は以下の人間向けサマリ 1 段落のみ:

- レビュー対象のブランチ (Step 1 で取得した現在ブランチ名) と ベース (`compose-review` 戻り値の `base_branch`)
- 差分モード (`compose-review` 戻り値の `diff_mode`)
- 集計値 (`compose-review` 戻り値の `_summary_meta` を参照): `inline_count` / `inline_count_by_severity` / `main_concerns_count` / `praises_count` / `omitted_count`。`body` の Markdown を機械パースしない (集計責務は `compose-review` 側)。
- `diff_mode == "none"` だった場合はその旨を明示する

最終的に chat には「`compose-review` 由来の fenced JSON ブロック (`OUTPUT_DESTINATION=chat` のデフォルト挙動による)」+「本 skill の追加サマリ 1 段落」の **2 つが並ぶ** 形になる。

## 守ること

- レビュー本文生成 / スタイル参考ガイドの読み込み / プロジェクト指示ファイルの探索は **すべて `compose-review` 側に集約** されている。本 skill 内で再実装してはならない。
- GitHub への投稿は行わない。`post-pr-review` / `resolve-pr-threads` skill は呼ばない。`gh pr comment` / `gh pr review` / `gh api .../reviews` も使わない。
- markdown ファイル出力は行わない。caller への成果物は `compose-review` の JSON 出力のみ。
- `git fetch` / `git pull` / `git checkout` / `git reset` 等、ワーキングツリーやローカル ref を書き換える操作はしない。本 skill で叩く git コマンドは `git rev-parse --abbrev-ref HEAD` のみで充分。
