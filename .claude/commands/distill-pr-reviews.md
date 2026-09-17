---
description: distill-pr-reviews skill 手順をローカル (plugin install なし) で起動するためのエイリアス。期間内 merged PR のレビューコメントとバグ修正PRの修正diffを集約し proposals.md に蒸留する。各候補は配置先 REVIEW.md (root / ディレクトリ別) ごとに振り分け、追記用の断片ファイルも出力する。
argument-hint: '[OWNER=...] [REPO=...] [SINCE=YYYY-MM-DD] [UNTIL=YYYY-MM-DD] [DAYS=N] [MAX_PRS=N] [MAX_BUGFIX_DIFFS=N] [FILTER_AUTHOR=...] [FILTER_LABEL=...] [INCLUDE_AI_AUTHORED=true|false] [OUTPUT_DIR=...]'
---

# /distill-pr-reviews (ローカルエイリアス)

このコマンドは `plugins/pr-review/skills/distill-pr-reviews/SKILL.md` へのエイリアスです。
