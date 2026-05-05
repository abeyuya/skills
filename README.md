# abeyuya/skills

abeyuya 個人が利用する Claude Code 向け skill / plugin 群を集約した
[Claude Code Plugin Marketplace](https://docs.claude.com/en/docs/claude-code/plugins) リポジトリ。

## 提供 plugin

### `pr-review`

PR レビューを **1 回の API コールで 1 つの Review として投稿** し、過去スレッドを安全に **resolve** するための skill 群、PR 作成前のローカルブランチを対象に AI レビューを行いチャット + markdown ファイルへ出力する skill、およびレビューコメントの **スタイル参考ガイド** をスラッシュコマンドとしてまとめて提供する。

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
3. `CLAUDE.md` — Claude Code 全般向けの fallback

個別ファイルパスを skill 引数で渡す方式は持たない。複数ファイルを束ねたい場合は caller 側 workflow で 1 ファイルに事前生成 (例: `cat docs/general.md docs/typescript.md > REVIEW.md`) してから skill を呼ぶ。

## 重要度ラベル

インライン指摘は以下のいずれかのラベルで開始する (詳細は `/pr-review-style-reference`):

- `[must]` 不具合・脆弱性。マージ前対応必須。
- `[should]` 設計・保守性で強く推奨される改善。放置すると次の修正で `[must]` 化する蓋然性が高いもの。
- `[nit]` 軽微・好み寄り。実装者が無視してよい。
- `[question]` 質問。実装者の意図確認のみで修正要求ではない。
- `[pre_existing]` 本 PR で導入されたものではない既存バグ。マージ判断には影響させない。

## Check Run 出力 (`run-pr-review` のみ)

`run-pr-review` は GitHub Review 投稿に加えて、PR の Checks タブに **`pr-review (abeyuya/skills)`** という名前の check run を作成する。Details ページに severity 順の指摘索引表 (`file:line` + 1 行サマリ) が出力され、末尾に機械可読な集計 JSON が HTML コメントとして埋め込まれる:

```
<!-- pr-review-severity: {"must":2,"should":1,"nit":2,"question":0,"pre_existing":0} -->
```

caller 側 CI で merge gate を組みたい場合は次のように parse できる:

```bash
gh api repos/$OWNER/$REPO/check-runs/$CHECK_RUN_ID \
  --jq '.output.text | match("pr-review-severity: ({[^}]+})") | .captures[0].string | fromjson'
```

`conclusion` は常に `neutral` 固定で、本 check run 自体は merge を block しない。check run 作成は best-effort で、403 等の権限不足 (fork PR 等) で失敗しても Review 投稿は成功扱いとする。check run 作成には `checks: write` 権限が必要。

## 利用方法 (GitHub Actions)

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

      run-pr-review skill を呼び、上記の入力で PR レビュー一式 (方針読み込み・レビュー作成・投稿・check run サマリ出力・過去スレッド resolve) を実行してください。
      caller プロジェクトのレビュー方針はリポジトリ root の REVIEW.md / AGENTS.md / CLAUDE.md のいずれかに置けば自動で読み込まれます (この順で最初に見つかった 1 つだけ)。
    claude_args: |
      --allowedTools "Read,Write,Glob,Grep,Bash(gh api:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh run view:*),Bash(git log:*),Bash(git blame:*)"
```

## 利用方法 (ローカル Claude Code)

```bash
/plugin marketplace add abeyuya/skills
/plugin install pr-review@abeyuya-skills
```

## 開発時 (このリポジトリ自身で plugin を編集しながら使う)

`/plugin install` 経由だと `~/.claude/plugins/cache/` にコピーされた版が使われ、
ローカルの未コミット変更が反映されない。編集中の内容をそのまま動かすには
`--plugin-dir` でディスクを直接読ませる:

```bash
claude --plugin-dir plugins/pr-review
```

セッション中に `SKILL.md` や `commands/*.md` を編集したら `/reload-plugins` で再読込できる。

## 構成

```
.claude-plugin/
  marketplace.json
plugins/
  pr-review/
    .claude-plugin/
      plugin.json
    commands/
      pr-review-style-reference.md
    skills/
      run-pr-review/
        SKILL.md
      post-pr-review/
        SKILL.md
      resolve-pr-threads/
        SKILL.md
      run-local-review/
        SKILL.md
```
