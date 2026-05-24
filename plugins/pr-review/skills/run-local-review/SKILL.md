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

### Step 1. 報告用にブランチ情報を取得する

caller への最終報告 (Step 3) で使う「現在ブランチ名」だけ取得する。`BASE_BRANCH` と差分モードの確定は `compose-review` に委譲し、その戻り値経由で受け取る。

- 現在ブランチ名: `git rev-parse --abbrev-ref HEAD`。`HEAD` (detached) の場合はエラーとして停止する (このチェックは `compose-review` 側にも入っているが、orchestrator 段階で早期に弾くことで Skill 呼び出しコストを節約する)。

### Step 2. `compose-review` skill を呼び出す

Skill ツールで `compose-review` をローカル diff モードで呼ぶ。引数は以下:

- `BASE_BRANCH` (caller から渡されていれば)
- `MAX_INLINE_COMMENTS` (caller から渡されていれば)

`OWNER` / `REPO` / `PR_NUMBER` は **渡さない** (渡すと PR モードに切り替わるため。空文字を渡すのも不可 — `compose-review` 側は空文字を未指定と同等に扱うがミスの温床なので **そもそも渡さない**)。

`compose-review` は fenced JSON ブロックで以下のフィールドを返す:

- `mode`: `"local"`
- `base_branch`: 解決済みのベースブランチ名 (`main` / `master` / caller 指定値)
- `diff_mode`: `"commit"` / `"staged"` / `"worktree"` / `"none"`
- `body` / `event` / `comments[]`

`commit_id` はローカルモードでは含まれない。

### Step 3. caller への報告

`compose-review` の戻り値をそのまま chat 表示するのに加え、以下を簡潔に caller へ返す:

- レビュー対象のブランチ (Step 1 で取得した現在ブランチ名) と ベース (`compose-review` 戻り値の `base_branch`)
- 差分モード (`compose-review` 戻り値の `diff_mode`)
- インライン指摘件数 (`compose-review` 戻り値の `comments[]` 長)
- `diff_mode == "none"` だった場合はその旨を明示する

## 守ること

- レビュー本文生成 / スタイル参考ガイドの読み込み / プロジェクト指示ファイルの探索は **すべて `compose-review` 側に集約** されている。本 skill 内で再実装してはならない。
- GitHub への投稿は行わない。`post-pr-review` / `resolve-pr-threads` skill は呼ばない。`gh pr comment` / `gh pr review` / `gh api .../reviews` も使わない。
- markdown ファイル出力は行わない。caller への成果物は `compose-review` の JSON 出力のみ。
- `git fetch` / `git pull` / `git checkout` / `git reset` 等、ワーキングツリーやローカル ref を書き換える操作はしない。本 skill で叩く git コマンドは `git rev-parse --abbrev-ref HEAD` のみで充分。
