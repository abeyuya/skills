---
name: run-local-review
description: 現在のローカルブランチを対象に、PR を作る前段階で AI レビューを行う skill。compose-review skill にローカル diff モードで処理を委譲し、生成されたレビュー JSON (body / event / comments[]) をチャットに返す。GitHub への投稿は行わない (post-pr-review / resolve-pr-threads は呼ばない)。
---

# run-local-review skill

PR 作成前のローカルブランチに対して AI レビューを行うための thin orchestrator skill。
レビュー本文の生成は `compose-review` skill (ローカル diff モード) に委譲する。本 skill は呼び出しと caller 報告のみを担う。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。

- `BASE_BRANCH`: 比較対象のベースブランチ。省略時は `compose-review` 側で `origin/HEAD` → `main` → `master` の順に解決される。本 skill / `compose-review` ともに `git fetch` を走らせないため、ローカルのベースが古いと古い基準で diff が出る。最新で比較したい場合は caller 側で fetch するか、`BASE_BRANCH=origin/main` のようにリモート追跡参照を明示する。
- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited` 扱い。`compose-review` にそのまま転送する。

caller プロジェクト固有のレビュー方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** (`REVIEW.md` / `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` の優先順で最初の 1 つだけ) に置く運用に固定する。読み込み自体は `compose-review` 側で行うため本 skill では扱わない。

## 手順

### Step 1. 報告用にブランチ情報を取得する

caller への最終報告 (Step 3) で使う情報のみ取得する。差分取得・ベース解決は `compose-review` に任せる。

- 現在ブランチ名: `git rev-parse --abbrev-ref HEAD`。`HEAD` (detached) の場合はエラーとして停止する。
- ベースブランチ: caller から `BASE_BRANCH` が渡されていればそのまま控える。未指定の場合は本 step では特定しない (`compose-review` の Step 1 内部解決に委ねる) — 報告時は `compose-review` 戻り値経由で判別する。

### Step 2. `compose-review` skill を呼び出す

Skill ツールで `compose-review` をローカル diff モードで呼ぶ。引数は以下:

- `BASE_BRANCH` (caller から渡されていれば)
- `MAX_INLINE_COMMENTS` (caller から渡されていれば)

`OWNER` / `REPO` / `PR_NUMBER` は **渡さない** (渡すと PR モードに切り替わるため)。

`compose-review` は fenced JSON ブロックで `mode: "local"` / `body` / `event` / `comments[]` を返す。`commit_id` はローカルモードでは含まれない。

### Step 3. caller への報告

`compose-review` の戻り値をそのまま chat 表示するのに加え、以下を簡潔に caller へ返す:

- レビュー対象のブランチ (Step 1 で取得)
- インライン指摘件数 (`compose-review` 戻り値の `comments[]` 長)
- 差分なしだった場合はその旨 (`compose-review` が `body` に「対象差分なし」と書いて返す)

## 守ること

- レビュー本文生成 / スタイル参考ガイドの読み込み / プロジェクト指示ファイルの探索は **すべて `compose-review` 側に集約** されている。本 skill 内で再実装してはならない。
- GitHub への投稿は行わない。`post-pr-review` / `resolve-pr-threads` skill は呼ばない。`gh pr comment` / `gh pr review` / `gh api .../reviews` も使わない。
- markdown ファイル出力は行わない。caller への成果物は `compose-review` の JSON 出力のみ。
- `git fetch` / `git pull` / `git checkout` / `git reset` 等、ワーキングツリーやローカル ref を書き換える操作はしない。本 skill で叩く git コマンドは `git rev-parse --abbrev-ref HEAD` のみで充分。
