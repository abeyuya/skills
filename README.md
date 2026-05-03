# abeyuya/skills

abeyuya 個人が利用する Claude Code 向け skill / plugin 群を集約した
[Claude Code Plugin Marketplace](https://docs.claude.com/en/docs/claude-code/plugins) リポジトリ。

## 提供 plugin

### `pr-review`

PR レビューを **1 回の API コールで 1 つの Review として投稿** し、過去スレッドを安全に **resolve** するための skill 群と、レビューコメントの **スタイル参考ガイド** をスラッシュコマンドとしてまとめて提供する。

- `skills/run-pr-review`: PR レビュー一式 (スタイル参考ガイド読み込み → PR 取得 → レビュー作成 → 投稿 → 過去スレッド resolve) を1コマンドで実行するオーケストレーション skill。caller はこれを呼ぶだけで済む。
- `skills/post-pr-review`: レビュー本文 + インラインコメント群を 1 つの GitHub Review として `gh api .../reviews` 経由で投稿する。
- `skills/resolve-pr-threads`: 過去のレビュースレッドのうち修正済みのものだけを `resolveReviewThread` で resolve する。`THREAD_RESOLVE_SCOPE` (`all` / `own` / `none`) で範囲を制御。
- `commands/pr-review-style-reference`: `/pr-review-style-reference` で呼び出す **スタイル参考ガイド** (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い)。レビューコメントの書き方・体裁が対象で、技術観点 (何を見るか) は対象外。

レビュー方針は caller (ユーザー) に委ねる前提。本スタイル参考ガイドは「そのまま採用 / 上に caller のカスタム指示を重ねる / 採用せず無視する」のいずれの使い方も可能。技術観点 (何をレビューするか) は caller 側で別途指定する想定。

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
      PROJECT_GUIDELINES: docs/ai_code_review/general.md, docs/ai_code_review/typescript.md
      THREAD_RESOLVE_SCOPE: all

      run-pr-review skill を呼び、上記の入力で PR レビュー一式 (方針読み込み・レビュー作成・投稿・過去スレッド resolve) を実行してください。
    claude_args: |
      --allowedTools "Read,Write,Glob,Grep,Bash(gh api:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh run view:*),Bash(git log:*),Bash(git blame:*)"
```

## 利用方法 (ローカル Claude Code)

```bash
/plugin marketplace add abeyuya/skills
/plugin install pr-review@abeyuya-skills
```

## マイグレーション (旧 `@skills` を使っていた caller 向け)

marketplace 名を `skills` → `abeyuya-skills` にリネームした。
旧名 `pr-review@skills` を参照していた caller (他リポジトリの GitHub Actions ワークフロー、ローカルの `/plugin install` 等) は **すべて `pr-review@abeyuya-skills` に書き換えが必要**。
書き換え漏れがあると plugin が解決できず CI が壊れるため注意。

## マイグレーション (`run-pr-review` 引数名変更)

`run-pr-review` skill の入力キーを以下のとおりリネームした。旧キーをそのまま渡しても新 skill 側は認識せず、Step 3 / Step 7 が **エラーにならずに** 該当キー無し相当 (= 観点未読込 / `THREAD_RESOLVE_SCOPE=all` 既定) で動いてしまうため、caller の Actions ワークフロー / ローカル prompt は書き換えが必要。

| 旧キー | 新キー | 補足 |
| --- | --- | --- |
| `CALLER_GUIDELINES` | `PROJECT_GUIDELINES` | 今回からカンマ区切りで複数パス指定可 (例: `docs/general.md, docs/typescript.md`) |
| `MODE` | `THREAD_RESOLVE_SCOPE` | 値 (`all` / `own` / `none`) は変更なし |

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
```
