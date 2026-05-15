# create-pullrequest plugin

コミット済みブランチに対して、コミット履歴・差分・リポジトリの PR テンプレートから Pull Request のタイトルと本文を組み立て、Draft PR を作成する skill を提供する。

## 提供 skill

- `skills/create-pullrequest`: PR 作成前の前提確認、push 状態確認、重複 PR 確認、履歴・差分の読み取り、タイトル・本文案の組み立て、ユーザー承認、Draft PR 作成までを扱う。

## 利用方法 (GitHub Actions)

`create-pullrequest` の動作には以下の権限が必要。job の `permissions:` で明示する:

```yaml
permissions:
  contents: write        # ブランチ push が必要な場合
  pull-requests: write   # PR 作成
```

```yaml
- uses: anthropics/claude-code-action@v1
  with:
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    plugin_marketplaces: |
      https://github.com/abeyuya/skills.git
    plugins: |
      create-pullrequest@abeyuya-skills
    prompt: |
      create-pullrequest skill を呼び、現在のブランチから Draft PR を作成してください。
    claude_args: |
      --allowedTools "Read,Write,Glob,Grep,Bash(git status:*),Bash(git rev-parse:*),Bash(git log:*),Bash(git diff:*),Bash(git push:*),Bash(gh repo view:*),Bash(gh auth status:*),Bash(gh pr list:*),Bash(gh pr create:*),Bash(mktemp:*),Bash(date:*)"
```

## 利用方法 (ローカル Claude Code)

```bash
/plugin marketplace add abeyuya/skills
/plugin install create-pullrequest@abeyuya-skills
```

## 利用方法 (apm 経由)

[apm (Agent Package Manager)](https://github.com/microsoft/apm) は Claude Code 形式の `marketplace.json` / `plugin.json` をネイティブに解釈するため、本リポジトリの配布物 (`.claude-plugin/marketplace.json` と `plugins/create-pullrequest/`) を **そのまま** 依存として扱える。配布ファイルの二重管理は不要。

```bash
# marketplace 経由 (recommended)
apm marketplace add abeyuya/skills
apm install create-pullrequest@abeyuya-skills

# または subdirectory を直接指定する primitive form
apm install abeyuya/skills/plugins/create-pullrequest
```

`apm install` 後、`create-pullrequest` plugin の skill は consumer 側の `.claude/skills/` に展開される。

## 開発時 (このリポジトリ自身で plugin を編集しながら使う)

`/plugin install` 経由だと `~/.claude/plugins/cache/` にコピーされた版が使われ、
ローカルの未コミット変更が反映されない。編集中の内容をそのまま動かすには
`--plugin-dir` でディスクを直接読ませる:

```bash
claude --plugin-dir plugins/create-pullrequest
```

セッション中に `SKILL.md` を編集したら `/reload-plugins` で再読込できる。
