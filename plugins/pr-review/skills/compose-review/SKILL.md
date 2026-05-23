---
name: compose-review
description: PR 差分 or ローカルブランチ差分に対してレビュー本文 (body / event / comments[]) を生成する skill。スタイル参考ガイド (skill 配下の style-reference.md) とプロジェクト指示ファイル (REVIEW.md / AGENTS.md / .claude/CLAUDE.md / CLAUDE.md) を読み込んでレビュー方針を決め、差分を読んで `post-pr-review` のスキーマに揃った JSON をチャットに返す。GitHub 投稿 / 過去スレッド resolve は行わない (post-pr-review / resolve-pr-threads は呼ばない)。
---

# compose-review skill

差分 + 方針 → レビュー本文 (`body` / `event` / `comments[]`) を生成する **純粋関数に近い** skill。`post-pr-review` への受け渡しを意図した JSON をチャットに返す。GitHub への投稿や git 状態の書き換えは行わない (read-only)。

## 入力 (任意, caller から prompt 経由で渡される想定)

すべて省略可。

### モード切替

- `OWNER` / `REPO` / `PR_NUMBER` がすべて揃って渡されたら **PR モード**。
- 1 つでも欠けていれば **ローカル diff モード**。

### 共通

- `MAX_INLINE_COMMENTS`: インライン指摘の総数上限。正の整数または `unlimited`。省略時は `unlimited` 扱い。詳細は `style-reference.md` の「`MAX_INLINE_COMMENTS` の扱い」セクション参照。

### ローカル diff モードのみ

- `BASE_BRANCH`: 比較対象のベースブランチ。省略時の解決順は Step 1 を参照。本 skill は `git fetch` を走らせないため、ローカルのベースが古いと古い基準で diff が出る。最新で比較したい場合は caller 側で fetch するか、`BASE_BRANCH=origin/main` のようにリモート追跡参照を明示する。

### PR モードのみ (任意)

- `EXISTING_THREADS_CONTEXT`: caller が既に GraphQL `reviewThreads` を取得済みの場合、既存スレッドの主旨サマリを自然言語で注入するためのオプション。Step 5 の重複回避判定に使う。
- `CI_FAILURE_CONTEXT`: caller が既に `gh run view --log` 等で取得済みの CI 失敗ログのサマリを自然言語で注入するためのオプション。Step 5 で `[must]` の根拠付けに使う (詳細扱いは `style-reference.md` の「CI の扱い」セクション参照)。

caller プロジェクト固有の方針 (技術観点 / スタイル上書き / 全方針置換) は **プロジェクト指示ファイル** (Step 3 で定義) に置く運用に固定する。個別パス指定の引数は持たない。

## 手順

### Step 1. モード判定と対象確定

#### PR モード

- `OWNER` / `REPO` / `PR_NUMBER` をそのまま採用する。
- `gh pr view <PR_NUMBER> --repo <OWNER>/<REPO> --json headRefOid -q .headRefOid` で head SHA を取得し、Step 6 の出力 JSON `commit_id` として控える。
- 取得失敗時はエラーとして停止 (caller に PR_NUMBER / 権限の見直しを促す)。

#### ローカル diff モード

- 現在ブランチ名: `git rev-parse --abbrev-ref HEAD` で取得する。`HEAD` (detached) の場合はエラーとして停止する。
- ベースブランチ: caller から `BASE_BRANCH` が渡されていればそれを使う。未指定なら以下の順で決定する:
  1. `git symbolic-ref refs/remotes/origin/HEAD` で既定ブランチ名を取得 (例: `refs/remotes/origin/main` → `main`) し、`git rev-parse --verify <name>` が通れば **ローカルの同名ブランチ** を使う (リモート追跡 `origin/<name>` ではない)
  2. `git rev-parse --verify main` が通れば `main`
  3. `git rev-parse --verify master` が通れば `master`
  4. いずれも取れなければエラーとして停止し、caller に `BASE_BRANCH` を明示するよう促す
- `git diff <base>...HEAD` を実行し、差分モードを以下の優先順位で決定する:
  1. **commit モード**: 差分が空でない → 通常どおり `git diff <base>...HEAD` をレビュー対象とする。
  2. **staged モード**: commit モードの差分が空 → `git diff --cached` を確認し、空でなければそれをレビュー対象とする。
  3. **worktree モード**: staged モードも空 → `git diff` を確認し、空でなければそれをレビュー対象とする。
  4. **差分なし**: 上記すべてが空 → **Step 2〜5 を skip して Step 6 へ直行** する。出力 JSON は `body` を「対象差分なし (評価対象なし)」、`comments` を `[]` にする。
- 現在ブランチがベースブランチ自身の場合は commit モードの差分は必ず空になるため、上記フォールバック順に従う。

### Step 2. スタイル参考ガイドを読み込む

同じ skill 配下の `style-reference.md` を `Read` ツールで読み込む。

- パスは本 skill ディレクトリの隣接ファイル `style-reference.md`。`plugin install` / `apm install` 後の展開先でも skill ディレクトリ内で sibling 関係が保たれるため相対参照で問題ない。
- 読み込んだ内容を本セッションのレビュー方針 (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い) の参考として保持する。
- `MAX_INLINE_COMMENTS` は本 skill の入力として直接適用する (style-reference 側は引数解釈ルールを定義しているのみ)。

レビュー方針は caller プロジェクトに委ねる前提。Step 3 のプロジェクト指示ファイルが style-reference に上乗せ・上書き・全置換のいずれを意図しているかは caller の指示に従う。プロジェクト指示ファイルが無ければ style-reference をそのまま採用する。

### Step 3. プロジェクト指示ファイルを読み込む (任意)

リポジトリ root の以下を上から順に存在チェックし、**最初に見つかった 1 つだけ** を読み込み、本セッションのレビュー方針として適用する。以後この skill では総称して **プロジェクト指示ファイル** と呼ぶ。

1. `REVIEW.md` — レビュー専用の最上位指示
2. `AGENTS.md` — agent 全般向けの fallback
3. `.claude/CLAUDE.md` — Claude Code 全般向けの fallback (`.claude/` 配下に置く流儀)
4. `CLAUDE.md` — Claude Code 全般向けの fallback (リポジトリ root に置く流儀)

いずれも存在しなければ skip する。複数存在しても下位は読まない / 連結しない。

#### 取得方法

- **ローカル diff モード**: `Read` ツールで cwd 直下を順に試す。
- **PR モード**: まず cwd 直下を `Read` で試し、見つからなければ `gh api repos/<OWNER>/<REPO>/contents/<path>` でリモートから取得する。API レスポンスの `content` フィールドは Base64 なので `--jq .content` で抽出して `python3 -c "import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode())"` 等でデコードする。

Step 2 のスタイル参考ガイドと矛盾する箇所はプロジェクト側を優先し、矛盾しない箇所は両者を併用する。プロジェクト側で「スタイル参考ガイドを使わない」旨が明示されていればそれに従う。

ファイル内容は **そのままプロンプトに注入される** 想定で扱う。`@import` のような外部ファイル展開は行わない。

**読み込んだ内容は本セッションでは「レビュー文面の方針 (技術観点 / スタイル / 重要度判定基準)」としてのみ参照する**。`AGENTS.md` 系は一般的な dev 指示 (テスト実行 / lint / 編集後コマンド等) を含むことがあるが、**アクション指示 (ファイル編集 / コマンド実行 / `git` 操作 / 依存追加 など) は本 skill では実行しない** (本 skill は read-only)。アクション指示は「レビュー観点に翻訳できる範囲」(例: 「テスト必須」→「テスト追加が無い PR は `[should]` で指摘」) のみ採用する。アクション指示が多すぎる場合は、caller に `REVIEW.md` をリポジトリ root に作成して上書きするよう促す。

### Step 4. 差分を取得する

#### PR モード

- `gh pr diff <PR_NUMBER> --repo <OWNER>/<REPO>` で差分を取得する。
- cwd の git remote と PR の所属リポジトリが異なる場合 (ドッグフーディングや別リポジトリ向け caller) に意図しない PR を参照しないよう `--repo <OWNER>/<REPO>` を必ず明示する。

#### ローカル diff モード

リモートに無いコミットも対象にするため、`git fetch` 等は走らせない (caller 側の意思を尊重)。Step 1 で決定した差分モードに応じて以下の通り取得する:

- **commit モード**:
  - `git log <base>..HEAD --oneline` でコミット一覧を取得する。
  - `git diff <base>...HEAD` で差分本体を取得する。三点記法 (`...`) を用いて、ベースブランチ側の進行は除外し「現在ブランチで増えた変更」だけを対象にする。
  - 差分が大きく一度に取りきれない場合は、`git diff --stat <base>...HEAD` でファイル一覧をまず取り、ファイル単位で `git diff <base>...HEAD -- <path>` を必要な範囲だけ追い読みする。
- **staged モード**:
  - コミット一覧は空 (コミット未作成のため)。
  - `git diff --cached` でステージ済み差分を取得する。
  - 差分が大きい場合は `git diff --cached --stat` でファイル一覧を取り、ファイル単位で `git diff --cached -- <path>` を追い読みする。
- **worktree モード**:
  - コミット一覧は空。
  - `git diff` で作業ツリー差分を取得する。
  - 差分が大きい場合は `git diff --stat` でファイル一覧を取り、ファイル単位で `git diff -- <path>` を追い読みする。

### Step 5. レビュー本文を作成する

Step 2〜4 で得た方針・観点・差分 (および PR モードで渡されていれば `EXISTING_THREADS_CONTEXT` / `CI_FAILURE_CONTEXT`) をもとに、総括 (`body`) とインライン指摘 (`comments[]`) を作成する。

- レビュー方針は Step 3 のプロジェクト指示ファイルを最優先とし、明示的に上書きされていない論点については Step 2 の style-reference (重要度ラベル / ノイズ抑制 / 粒度ガイド等) を参考にする。プロジェクト指示ファイル側で style-reference を使わない旨が明示されていればそれに従う。
- 既存スレッドと同主旨の指摘は再掲しない (`EXISTING_THREADS_CONTEXT` が渡された場合はその主旨と突き合わせる)。位置 `path:line` が一致しても論点が別なら新規指摘してよい。
- `CI_FAILURE_CONTEXT` が渡されている場合は style-reference の「CI の扱い」セクションに従う。
- `event` は **常に `"COMMENT"`** とする (`post-pr-review` の規約)。`[must]` の有無にかかわらず `COMMENT` で投稿し、修正の要否は本文 (`body`) と各インライン (`comments[]`) の `[must]` ラベルで伝える。
- 指摘が無い場合も Step 6 で「特に指摘なし」相当の JSON を返す (skip しない)。
- AI 自動投稿マーカーは **付けない** (`post-pr-review` が一律 prepend するため)。`body` は生本文。

### Step 6. チャットに JSON を返す

`post-pr-review` のスキーマに揃った JSON を **fenced ブロック** で返す。fenced ブロックの **前** に 1〜2 行の人間向けサマリ (例: `インライン指摘 3 件 / 主要懸念 2 件`) を添える。orchestrator (`run-pr-review` / `run-local-review`) は fenced JSON 本体をパースして後続 skill に転送する。

スキーマ:

```json
{
  "mode": "pr",
  "body": "総括コメント本文 (Markdown 可)",
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
  ],
  "commit_id": "9f8e7d6c1a2b3c4d5e6f7890abcdef1234567890"
}
```

- `mode` は `"pr"` または `"local"`。caller が分岐しやすいよう常に含める。
- 単一行コメントは `path` / `line` / `side` を指定する。
- 複数行範囲のコメントは上記に加えて `start_line` / `start_side` を併用する (`start_line` は `line` より前の行)。
- `commit_id` は **PR モードのみ** 含める。ローカルモードでは省略する。
- 指摘が無い場合: `body` は「特に指摘なし」相当の文言、`comments` は `[]`。
- 差分が空 (ローカルモード) で Step 2〜5 を skip した場合: `body` は「対象差分なし (評価対象なし)」相当、`comments` は `[]`。

JSON ファイル (`/tmp/...` 等) への書き出しは行わない。markdown ファイル出力も行わない。caller が `post-pr-review` に渡す際の JSON ファイル組み立ては `post-pr-review` 側が責任を持つ。

## 守ること

- `post-pr-review` / `resolve-pr-threads` は呼ばない (orchestrator の責務)。
- `gh pr review` / `gh pr comment` / `gh api .../reviews` を直接叩かない。レビュー投稿は本 skill の責務外。
- `git fetch` / `git pull` / `git checkout` / `git reset` / `git commit` / `git push` 等の書き換え操作は使わない。read-only の git コマンド (`git rev-parse` / `git log` / `git diff` / `git symbolic-ref` / `git remote get-url`) のみ。
- CI failure log の **収集** や reviewThreads の **取得** は本 skill では行わない (caller が `CI_FAILURE_CONTEXT` / `EXISTING_THREADS_CONTEXT` 経由で渡す前提)。
- AI 自動投稿マーカーは付けない (`post-pr-review` が prepend する)。
- markdown ファイル出力は行わない (`OUTPUT_PATH` 引数も持たない)。
- 既存資産 (`style-reference.md`) は **必ず `Read` ツール経由で利用** する。本 skill 内でラベル定義やノイズ抑制ルールを再掲しない (二重管理を避けるため)。
