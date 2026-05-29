---
description: compose-review skill 手順をローカル (plugin install なし) で起動するためのエイリアス。差分 (PR or ローカルブランチ) に対してレビュー本文 (body / event / comments[]) を生成し JSON で返す前提のため、通常は `run-pr-review` / `run-local-review` から現在コンテキストで直接 Skill ツール経由で呼び出される。手で `/compose-review` を直接叩くユースケースは想定していないため argument-hint は持たない。
---

# /compose-review (ローカルエイリアス)

このコマンドは `plugins/pr-review/skills/compose-review/SKILL.md` へのエイリアスです。
