---
description: delegate-pr-review skill 手順をローカル (plugin install なし) で起動するためのエイリアス。作成済み PR のレビューを、実装した会話を引き継がないレビュー用のサブエージェントか別のセッションに委譲し (run-pr-review を実行させる)、投稿されたレビューに元のセッションで対応する。サブエージェントのネスト起動が使える環境ではサブエージェント、使えないクラウドセッションでは別のセッションを使う。
argument-hint: '[OWNER=...] [REPO=...] [PR_NUMBER=...] [MAX_REVIEW_ROUNDS=N] [REVIEW_MODEL=...] [REVIEW_EFFORT=low|medium|high|xhigh|max] [REVIEW_OPTIONS="..."]'
---

# /delegate-pr-review (ローカルエイリアス)

このコマンドは `plugins/pr-review/skills/delegate-pr-review/SKILL.md` へのエイリアスです。
