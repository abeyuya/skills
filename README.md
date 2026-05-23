# abeyuya/skills

abeyuya 個人が利用する Claude Code 向け skill / plugin 群を集約した
[Claude Code Plugin Marketplace](https://docs.claude.com/en/docs/claude-code/plugins) リポジトリ。

## 提供 plugin

### [`pr-review`](plugins/pr-review/README.md)

PR レビューを **1 回の API コールで 1 つの Review として投稿** し、過去スレッドを安全に **resolve** するための skill 群、PR 作成前のローカルブランチを対象に AI レビューを行いチャット + markdown ファイルへ出力する skill、およびレビューコメントの **スタイル参考ガイド** をスラッシュコマンドとしてまとめて提供する。

詳細は [plugins/pr-review/README.md](plugins/pr-review/README.md) を参照。

## 利用方法 (ローカル Claude Code)

ローカルの Claude Code から本リポジトリを marketplace として登録し、plugin を install する:

```
/plugin marketplace add abeyuya/skills
/plugin install pr-review@abeyuya-skills
```

## 利用方法 (apm 経由)

[apm (Agent Package Manager)](https://github.com/microsoft/apm) は Claude Code 形式の `marketplace.json` / `plugin.json` をネイティブに解釈するため、本リポジトリの配布物 (`.claude-plugin/marketplace.json` と `plugins/<name>/`) を **そのまま** 依存として扱える。`apm.yml` も同梱しているが、配布物の二重管理は発生しない (apm-aware であることを明示するためのメタデータのみ)。

```bash
# marketplace 経由 (recommended)
apm marketplace add abeyuya/skills
apm install pr-review@abeyuya-skills

# または subdirectory を直接指定する primitive form
apm install abeyuya/skills/plugins/pr-review
```

`apm install` 後、各 plugin の skill / command は consumer 側の `.claude/skills/` および `.claude/commands/` に展開される (ローカル Claude Code 経由で `/plugin install` した場合と同じファイルがインストールされる)。

plugin 個別の利用方法 (GitHub Actions / ローカル Claude Code / 開発時) は各 plugin の README を参照:

- [`pr-review`](plugins/pr-review/README.md)

## 構成

```
apm.yml                                # apm 相互運用用マニフェスト
.claude-plugin/
  marketplace.json                     # Claude Code marketplace 索引 (apm からも参照される)
plugins/
  pr-review/
    README.md
    .claude-plugin/
      plugin.json
    skills/
      run-pr-review/
        SKILL.md
      run-local-review/
        SKILL.md
      compose-review/
        SKILL.md
        style-reference.md             # compose-review skill が Read で読み込むスタイル参考ガイド
      post-pr-review/
        SKILL.md
      resolve-pr-threads/
        SKILL.md
```
