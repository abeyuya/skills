# abeyuya/skills

abeyuya 個人が利用する Claude Code 向け skill / plugin 群を集約した
[Claude Code Plugin Marketplace](https://docs.claude.com/en/docs/claude-code/plugins) リポジトリ。

## 提供 plugin

### `pr-review`

PR レビューを **1 回の API コールで 1 つの Review として投稿** し、過去スレッドを安全に **resolve** するための skill 群と、**共通レビュー方針** をスラッシュコマンドとしてまとめて提供する。

- `skills/post-pr-review`: レビュー本文 + インラインコメント群を 1 つの GitHub Review として `gh api .../reviews` 経由で投稿する。
- `skills/resolve-pr-threads`: 過去のレビュースレッドのうち修正済みのものだけを `resolveReviewThread` で resolve する。`mode` (`all` / `own` / `none`) で範囲を制御。
- `commands/pr-review-guidelines`: `/pr-review-guidelines` で呼び出す **共通レビュー方針** (重要度ラベル / ノイズ抑制 / 粒度ガイド / 重複回避 / CI 扱い)。

プロジェクト固有のレビュー観点は本プラグインには含まれないため、caller リポジトリ側で別途用意し、上記共通方針と併用して prompt で参照させる前提。

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
      REPO: ${{ github.repository }}
      PR NUMBER: ${{ github.event.pull_request.number }}

      まず /pr-review-guidelines を実行し、共通レビュー方針を読み込んでください。
      加えて docs/ai_code_review/all.md (caller 固有観点) を読み、両方の方針に従って PR をレビューしてください。
      レビュー結果は post-pr-review skill で1つの Review として投稿してください。
      投稿後、resolve-pr-threads skill を mode=all で呼び、修正済みの過去スレッドを resolve してください。
    claude_args: |
      --allowedTools "Read,Write,Glob,Grep,Bash(gh api:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh run view:*)"
```

## 利用方法 (ローカル Claude Code)

```bash
/plugin marketplace add abeyuya/skills
/plugin install pr-review@abeyuya-skills
```

## 構成

```
.claude-plugin/
  marketplace.json
plugins/
  pr-review/
    .claude-plugin/
      plugin.json
    commands/
      pr-review-guidelines.md
    skills/
      post-pr-review/
        SKILL.md
      resolve-pr-threads/
        SKILL.md
```
