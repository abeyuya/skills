# pr-review plugin

PR レビューを **1 回の API コールで 1 つの Review として投稿** し、過去スレッドを安全に **resolve** するための skill 群、PR 作成前のローカルブランチを対象に AI レビューを行いチャット + markdown ファイルへ出力する skill、およびレビューコメントの **スタイル参考ガイド** をスラッシュコマンドとしてまとめて提供する。

## 提供 skill / command

- `skills/run-pr-review`: PR レビュー一式 (スタイル参考ガイド読み込み → PR 取得 → レビュー作成 → 投稿 → 過去スレッド resolve) を1コマンドで実行するオーケストレーション skill。caller はこれを呼ぶだけで済む。
- `skills/post-pr-review`: レビュー本文 + インラインコメント群を 1 つの GitHub Review として `gh api .../reviews` 経由で投稿する。
- `skills/resolve-pr-threads`: 過去のレビュースレッドのうち修正済みのものだけを `resolveReviewThread` で resolve する。`THREAD_RESOLVE_SCOPE` (`all` / `own` / `none`) で範囲を制御。
- `skills/run-local-review`: 現在のローカルブランチを対象に PR 作成前の AI レビューを行い、結果を **チャット + markdown ファイル** に出力する skill (GitHub 投稿は行わない)。スタイル参考ガイドと caller 固有観点の読み込みは `run-pr-review` と共通。
- `commands/pr-review-style-reference`: `/pr-review-style-reference` で呼び出す **スタイル参考ガイド** (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い)。レビューコメントの書き方・体裁が対象で、技術観点 (何を見るか) は対象外。

レビュー方針は caller (ユーザー) に委ねる前提。本スタイル参考ガイドは「そのまま採用 / 上に caller のカスタム指示を重ねる / 採用せず無視する」のいずれの使い方も可能。技術観点 (何をレビューするか) は caller 側で別途指定する想定。

## caller プロジェクトのレビュー方針の置き方

`run-pr-review` / `run-local-review` は **リポジトリ root の以下のファイルを自動で読み込む** (この順で最初に見つかった 1 つだけ):

1. `REVIEW.md` — レビュー専用の最上位指示 (推奨)
2. `AGENTS.md` — agent 全般向けの fallback
3. `.claude/CLAUDE.md` — Claude Code 全般向けの fallback (`.claude/` 配下に置く流儀)
4. `CLAUDE.md` — Claude Code 全般向けの fallback (リポジトリ root に置く流儀)

個別ファイルパスを skill 引数で渡す方式は持たない。複数ファイルを束ねたい場合は caller 側 workflow で 1 ファイルに事前生成 (例: `cat docs/general.md docs/typescript.md > REVIEW.md`) してから skill を呼ぶ。Claude Code 全般指示が `.claude/CLAUDE.md` と `CLAUDE.md` の両方に存在する場合は `.claude/CLAUDE.md` のみが採用される (連結はしない)。

### `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` を fallback として使う際の注意

`AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` はもともとレビュー専用ではなく、`claude /init` が生成する雛形には「テストを必ず走らせる」「lint をかける」「編集後に X を実行する」等の **アクション指示** が含まれることが多い。本 skill (`run-pr-review` / `run-local-review`) は read-only レビュー専念で、これらのアクション指示は **実行しない** (レビュー観点に翻訳できる範囲のみ参照する) ように Step 3 で明示的に防いでいるが、念のため次のいずれかを推奨する:

- レビュー方針として意図されていないアクション指示が多い場合は、リポジトリ root に **`REVIEW.md` を新規作成** してレビュー方針だけを書き、`AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` は読まれないようにする (上記優先順で `REVIEW.md` が最優先)。
- `AGENTS.md` / `.claude/CLAUDE.md` / `CLAUDE.md` 内でレビュー専用セクションを設けて他から分離する。

## `post-pr-review` を他から呼ぶ場合

`skills/post-pr-review` は **「レビュー本文を受け取って GitHub Review として 1 回の API コールで投稿する」専用の投稿 skill** として、`run-pr-review` 経由だけでなく外部 skill / 外部ワークフロー / 人手起動からも直接呼べる設計になっている。「レビューを書く」フェーズと「レビューを投稿する」フェーズを分離したい場合、書く側 (別 skill / 別エージェント / 人) が下記 Payload を生成して post-pr-review に流し込めばよい。

Payload (caller が渡す JSON 相当) の概要:

- `body` (string, 必須): 総括コメント本文。AI 自動投稿マーカーは skill 側で自動 prepend するため caller は付けない。
- `event` (literal `"COMMENT"`, 必須): `APPROVE` / `REQUEST_CHANGES` は禁止。
- `comments` (array, 必須・空配列可): インライン指摘の配列。各要素は単一行 (`path` / `line` / `side` / `body`) または複数行範囲 (上に加えて `start_line` / `start_side`)。
- `commit_id` (string, 任意): head commit の SHA。force-push / rebase での行ズレ防止に推奨。

詳細なスキーマ・呼び出し経路 (Skill ツール経由 / prompt 経由) は [`skills/post-pr-review/SKILL.md`](skills/post-pr-review/SKILL.md#public-payload-interface) を参照。インライン指摘本文の規約 (`[must]` / `[should]` 等の重要度ラベル) は本 skill では規定せず caller のレビュー方針に従う想定で、当 plugin 既定の体裁は `/pr-review-style-reference` を参考にできる。

## 重要度ラベル

インライン指摘は以下のいずれかのラベルで開始する (詳細は `/pr-review-style-reference`):

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

`apm install` 後、`pr-review` plugin の skill / command は consumer 側の `.claude/skills/` および `.claude/commands/` に展開される (ローカル Claude Code 経由で `/plugin install` した場合と同じファイルがインストールされる)。

## 開発時 (このリポジトリ自身で plugin を編集しながら使う)

`/plugin install` 経由だと `~/.claude/plugins/cache/` にコピーされた版が使われ、
ローカルの未コミット変更が反映されない。編集中の内容をそのまま動かすには
`--plugin-dir` でディスクを直接読ませる:

```bash
claude --plugin-dir plugins/pr-review
```

セッション中に `SKILL.md` や `commands/*.md` を編集したら `/reload-plugins` で再読込できる。
