# abeyuya/skills

abeyuya 個人が利用する Claude Code 向け skill / plugin 群を集約した
[Claude Code Plugin Marketplace](https://docs.claude.com/en/docs/claude-code/plugins) リポジトリ。

## 提供 plugin

### `pr-review`

PR レビューを **1 回の API コールで 1 つの Review として投稿** し、過去スレッドを安全に **resolve** するための skill 群。

- `post-pr-review`: レビュー本文 + インラインコメント群を 1 つの GitHub Review として `gh api .../reviews` 経由で投稿する。
- `resolve-pr-threads`: 過去のレビュースレッドのうち修正済みのものだけを `resolveReviewThread` で resolve する。`mode` (`all` / `own` / `none`) で範囲を制御。

レビューの観点・トーン・重要度ラベル規約等の **方針** は含まない。手続きのみを提供する設計のため、
caller リポジトリ側でレビュー方針を別途用意し、prompt で参照させる前提。

## 利用方法 (GitHub Actions)

```yaml
- uses: anthropics/claude-code-action@v1
  with:
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    plugin_marketplaces: |
      https://github.com/abeyuya/skills.git
    plugins: |
      pr-review@skills
    prompt: |
      REPO: ${{ github.repository }}
      PR NUMBER: ${{ github.event.pull_request.number }}

      docs/ai_code_review/all.md を読み、その方針に従って PR をレビューしてください。
      レビュー結果は post-pr-review skill で1つの Review として投稿してください。
      投稿後、resolve-pr-threads skill を mode=all で呼び、修正済みの過去スレッドを resolve してください。
    claude_args: |
      --allowedTools "Read,Write,Glob,Grep,Bash(gh api:*),Bash(gh pr view:*),Bash(gh pr diff:*),Bash(gh run view:*)"
```

## 利用方法 (ローカル Claude Code)

```bash
/plugin marketplace add abeyuya/skills
/plugin install pr-review@skills
```

## 構成

```
.claude-plugin/
  marketplace.json
plugins/
  pr-review/
    .claude-plugin/
      plugin.json
    skills/
      post-pr-review/
        SKILL.md
      resolve-pr-threads/
        SKILL.md
```
