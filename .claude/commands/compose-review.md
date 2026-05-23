---
description: compose-review skill 手順をローカル (plugin install なし) で起動するためのエイリアス。PR 差分またはローカルブランチ差分に対してレビュー本文 (body / event / comments[]) を生成し、JSON でチャットに返す。GitHub 投稿は行わない。
argument-hint: '[OWNER=... REPO=... PR_NUMBER=...] [BASE_BRANCH=...] [MAX_INLINE_COMMENTS=N|unlimited]'
---

# /compose-review (ローカルエイリアス)

このコマンドは `plugins/pr-review/skills/compose-review/SKILL.md` へのエイリアスです。

`OWNER` / `REPO` / `PR_NUMBER` が揃って渡された場合は PR モード、揃わない場合はローカル diff モードで動作します。
