# pr-review plugin

PR レビューを **1 回の API コールで 1 つの Review として投稿** し、過去スレッドを安全に **resolve** するための skill 群、PR 作成前のローカルブランチを対象に AI レビューを行う skill、およびレビュー本文生成本体を切り出した skill (compose-review) を提供する。

## Breaking changes (v0.2.0)

- 新 skill `compose-review` の追加と、`run-pr-review` / `run-local-review` の thin orchestrator 化。レビュー本文生成 / スタイル参考ガイド読み込み / プロジェクト指示ファイル読み込みが `compose-review` に集約された。
- `run-local-review` の **`OUTPUT_PATH` 引数と markdown ファイル出力を廃止**。代替: `compose-review` の JSON 戻り値を caller 側で markdown 化。`apm` / `/plugin install` でバージョン固定をしていない consumer は、本リリース後「markdown ファイルが出なくなった」状態になる点に注意。
- スラッシュコマンド `/pr-review-style-reference` を廃止し、内容を `compose-review/style-reference.md` に移設。直接 `/pr-review-style-reference` を呼んでいた caller は呼び出しを削除すること (`compose-review` が内部で `Read` する)。

## 提供 skill

- `skills/run-pr-review`: PR レビュー一式 (PR 状態取得 → 本文生成 → 投稿 → 過去スレッド resolve) を1コマンドで実行するオーケストレーション skill。caller はこれを呼ぶだけで済む。
- `skills/run-local-review`: 現在のローカルブランチを対象に PR 作成前の AI レビューを行い、結果を JSON でチャットに返す thin orchestrator skill (GitHub 投稿は行わない)。内部で `compose-review` をローカル diff モードで呼ぶ。
- `skills/compose-review`: PR 差分 or ローカルブランチ差分に対してレビュー本文 (`body` / `event` / `comments[]`) を生成する skill。`post-pr-review` のスキーマに揃った JSON をチャットに返す。レビュー本文の生成本体・スタイル参考ガイドの読み込み・プロジェクト指示ファイルの読み込みをここに集約している。
- `skills/post-pr-review`: レビュー本文 + インラインコメント群を 1 つの GitHub Review として `gh api .../reviews` 経由で投稿する。
- `skills/resolve-pr-threads`: 過去のレビュースレッドのうち修正済みのものだけを `resolveReviewThread` で resolve する。`THREAD_RESOLVE_SCOPE` (`all` / `own` / `none`) で範囲を制御。

レビュー方針は caller (ユーザー) に委ねる前提。`compose-review` 配下の `style-reference.md` (旧 `/pr-review-style-reference` 相当) は「そのまま採用 / 上に caller のカスタム指示を重ねる / 採用せず無視する」のいずれの使い方も可能。技術観点 (何をレビューするか) は caller 側で別途指定する想定。

## caller プロジェクトのレビュー方針の置き方

`compose-review` は **リポジトリ root の以下のファイルを自動で読み込む** (この順で最初に見つかった 1 つだけ):

1. `REVIEW.md` — レビュー専用の最上位指示 (推奨)
2. `AGENTS.md` — agent 全般向けの fallback
3. `.claude/CLAUDE.md` — Claude Code 全般向けの fallback (`.claude/` 配下に置く流儀)
4. `CLAUDE.md` — Claude Code 全般向けの fallback (リポジトリ root に置く流儀)

個別ファイルパスを skill 引数で渡す方式は持たない。複数ファイルを束ねたい場合は caller 側 workflow で 1 ファイルに事前生成 (例: `cat docs/general.md docs/typescript.md > REVIEW.md`) してから skill を呼ぶ。Claude Code 全般指示が `.claude/CLAUDE.md` と `CLAUDE.md` の両方に存在する場合は `.claude/CLAUDE.md` のみが採用される (連結はしない)。

### `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` を fallback として使う際の注意

`AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` はもともとレビュー専用ではなく、`claude /init` が生成する雛形には「テストを必ず走らせる」「lint をかける」「編集後に X を実行する」等の **アクション指示** が含まれることが多い。`compose-review` は read-only レビュー専念で、これらのアクション指示は **実行しない** (レビュー観点に翻訳できる範囲のみ参照する) ように内部で明示的に防いでいるが、念のため次のいずれかを推奨する:

- レビュー方針として意図されていないアクション指示が多い場合は、リポジトリ root に **`REVIEW.md` を新規作成** してレビュー方針だけを書き、`AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` は読まれないようにする (上記優先順で `REVIEW.md` が最優先)。
- `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` 内でレビュー専用セクションを設けて他から分離する。

## 重要度ラベル

インライン指摘は以下のいずれかのラベルで開始する (詳細は `compose-review` skill 配下の `style-reference.md`、ソース上の絶対パスは [`skills/compose-review/style-reference.md`](skills/compose-review/style-reference.md)):

- `[must]` 不具合・脆弱性。マージ前対応必須。
- `[should]` 設計・保守性で強く推奨される改善。放置すると次の修正で `[must]` 化する蓋然性が高いもの。
- `[nit]` 軽微・好み寄り。実装者が無視してよい。
- `[question]` 質問。実装者の意図確認のみで修正要求ではない。
- `[pre_existing]` 本 PR で導入されたものではない既存バグ。マージ判断には影響させない。

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
      --allowedTools "Read,Write,Glob,Grep,Bash(gh api:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh run view:*),Bash(git log:*),Bash(git blame:*)"
```

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

`apm install` 後、`pr-review` plugin の skill は consumer 側の `.claude/skills/` に展開される (ローカル Claude Code 経由で `/plugin install` した場合と同じファイルがインストールされる)。

## 開発時 (このリポジトリ自身で plugin を編集しながら使う)

`/plugin install` 経由だと `~/.claude/plugins/cache/` にコピーされた版が使われ、
ローカルの未コミット変更が反映されない。編集中の内容をそのまま動かすには
`--plugin-dir` でディスクを直接読ませる:

```bash
claude --plugin-dir plugins/pr-review
```

セッション中に `SKILL.md` を編集したら `/reload-plugins` で再読込できる。
