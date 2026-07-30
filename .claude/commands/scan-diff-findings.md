---
description: scan-diff-findings skill 手順をローカル (plugin install なし) で起動するためのエイリアス。差分 (ref range / ブランチ / staged / worktree) に対して観点別 finder の fan-out → adversarial verify → マージ を行い、findings JSON を `FINDINGS_PATH` (省略時は temp パス) にファイル書き出ししたうえで「そのファイルを Read して続行せよ」という継続指示を返す read-only レビュースキル。通常は `compose-review` Step 5-2 から現在コンテキストで直接 Skill ツール経由で呼び出される。
argument-hint: '[TARGET=<base>...<head>|<branch>] [DIFF_MODE=ref_range|branch|staged|worktree] [MAX_FINDINGS=N|unlimited] [FINDINGS_PATH=...] [EXTRA_FOCUS=...]'
---

# /scan-diff-findings (ローカルエイリアス)

このコマンドは `plugins/pr-review/skills/scan-diff-findings/SKILL.md` へのエイリアスです。
