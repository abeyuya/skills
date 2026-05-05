# abeyuya/skills

abeyuya 個人が利用する Claude Code 向け skill / plugin 群を集約した
[Claude Code Plugin Marketplace](https://docs.claude.com/en/docs/claude-code/plugins) リポジトリ。

## 提供 plugin

### [`pr-review`](plugins/pr-review/README.md)

PR レビューを **1 回の API コールで 1 つの Review として投稿** し、過去スレッドを安全に **resolve** するための skill 群、PR 作成前のローカルブランチを対象に AI レビューを行いチャット + markdown ファイルへ出力する skill、およびレビューコメントの **スタイル参考ガイド** をスラッシュコマンドとしてまとめて提供する。

詳細は [plugins/pr-review/README.md](plugins/pr-review/README.md) を参照。

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
