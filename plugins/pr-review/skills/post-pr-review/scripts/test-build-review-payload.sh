#!/usr/bin/env bash
# build-review-payload.sh の回帰テスト。
#
# 使い方: bash test-build-review-payload.sh
# exit  : 0 = 全ケース成功 / 1 = 失敗あり
#
# bash 互換要件: build-review-payload.sh と同じく bash 3.2 互換で書く。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
BUILD="${SCRIPT_DIR}/build-review-payload.sh"

pass=0
fail=0
current=""
work=""
report=""
payload=""

MARKER='> **[AI 自動投稿]** このレビューは AI エージェントによって自動生成されました。レビュー内容の判断は AI が行っています。'
ZERO_LINE='<!-- AI-REVIEW-RESULT: must=0 should=0 nit=0 question=0 pre_existing=0 other=0 -->'

ok() { pass=$((pass + 1)); }
ng() { fail=$((fail + 1)); echo "FAIL [$current] $*" >&2; }

# run <case名> <input JSON>: --init で作業パスを取り、入力を書いてスクリプトを実行する。
run() {
  current="$1"
  local input
  input="$(bash "$BUILD" --init)"
  work="$(dirname "$input")"
  printf '%s\n' "$2" > "$input"
  if ! report="$(bash "$BUILD" "$input")"; then
    ng "スクリプトが非 0 で終了した"
    report='{}'
    payload='{}'
    return
  fi
  payload="$(cat "${work}/payload.json")"
}

# eq <説明> <jq 式> <期待値 (jq -r の出力)> [payload|report]
eq() {
  local target="${4:-payload}" json actual
  if [ "$target" = "report" ]; then json="$report"; else json="$payload"; fi
  actual="$(printf '%s\n' "$json" | jq -r "$2")"
  if [ "$actual" = "$3" ]; then ok; else ng "$1: expected <$3> got <$actual>"; fi
}

# body の機械可読行ブロック (マーカー行の 2 行後〜空行の手前) を返す jq 式
LINES='.body | split("\n") | .[2:] | .[:(index("") )] | join("\n")'

# ---------------------------------------------------------------------------
run "指摘 0 件" '{"body":"特に指摘なし","event":"COMMENT","comments":[]}'
eq "body 全体" '.body' "$(printf '%s\n\n%s\n\n---\n\n%s' "$MARKER" "$ZERO_LINE" "特に指摘なし")"
eq "event" '.event' "COMMENT"
eq "comments" '.comments | length' "0"
eq "キー集合 (commit_id なし)" 'keys | join(",")' "body,comments,event"
eq "counts_source" '.counts_source' "comments" report
eq "warnings なし" '.warnings | length' "0" report
eq "external absent" '.lines.external' "absent" report
eq "escalate absent" '.lines.escalate' "absent" report
eq "payload_path" '.payload_path' "${work}/payload.json" report
eq "report.json と stdout が一致" "$(cat "${work}/report.json" | jq -c .) == ." "true" report

# ---------------------------------------------------------------------------
run "[MUST] 大文字・未知ラベル・ラベル無し・本文中ラベル" '{"body":"b","event":"COMMENT","comments":[
  {"path":"a.ts","line":1,"side":"RIGHT","body":"[MUST] 大文字"},
  {"path":"a.ts","line":2,"side":"RIGHT","body":"[Should] 混在"},
  {"path":"a.ts","line":3,"side":"RIGHT","body":"[pre_existing] 既存"},
  {"path":"a.ts","line":4,"side":"RIGHT","body":"[blocker] 未知"},
  {"path":"a.ts","line":5,"side":"RIGHT","body":"ラベル無し [must] は本文中"},
  {"path":"a.ts","line":6,"side":"RIGHT","body":"\n[must] 先頭が改行"}
]}'
eq "RESULT 行" "$LINES" '<!-- AI-REVIEW-RESULT: must=1 should=1 nit=0 question=0 pre_existing=1 other=3 -->'
eq "counts_source" '.counts_source' "comments" report

# ---------------------------------------------------------------------------
run "LABEL_COUNTS 正典採用 (省略分込み・非標準キーは other)" '{"body":"b","comments":[
  {"path":"a","line":1,"side":"RIGHT","body":"[must] x"}],
  "label_counts":"{\"must\":2,\"nit\":1,\"blocker\":3,\"other\":1}"}'
eq "RESULT 行" "$LINES" '<!-- AI-REVIEW-RESULT: must=2 should=0 nit=1 question=0 pre_existing=0 other=4 -->'
eq "counts_source" '.counts_source' "label_counts" report
eq "warnings なし" '.warnings | length' "0" report
eq "label_counts を除外" 'has("label_counts")' "false"

run "LABEL_COUNTS を object で渡す" '{"body":"b","comments":[],"label_counts":{"should":1}}'
eq "RESULT 行" "$LINES" '<!-- AI-REVIEW-RESULT: must=0 should=1 nit=0 question=0 pre_existing=0 other=0 -->'

# ---------------------------------------------------------------------------
run "LABEL_COUNTS 下限違反" '{"body":"b","comments":[
  {"path":"a","line":1,"side":"RIGHT","body":"[must] 1"},
  {"path":"a","line":2,"side":"RIGHT","body":"[must] 2"},
  {"path":"a","line":3,"side":"RIGHT","body":"[must] 3"}],
  "label_counts":{"must":0,"should":0,"nit":0,"question":0,"pre_existing":0,"other":0}}'
eq "RESULT 行 (comments 集計)" "$LINES" '<!-- AI-REVIEW-RESULT: must=3 should=0 nit=0 question=0 pre_existing=0 other=0 -->'
eq "counts_source" '.counts_source' "comments" report
eq "warning" '.warnings[0] | "\(.input) \(.action)"' "LABEL_COUNTS fallback_to_comments" report

run "LABEL_COUNTS が {} で comments 非空" '{"body":"b","comments":[{"path":"a","line":1,"side":"RIGHT","body":"[must] 1"}],"label_counts":"{}"}'
eq "RESULT 行 (comments 集計)" "$LINES" '<!-- AI-REVIEW-RESULT: must=1 should=0 nit=0 question=0 pre_existing=0 other=0 -->'
eq "warning" '.warnings[0].action' "fallback_to_comments" report

# ---------------------------------------------------------------------------
for broken in '"{\"must\":1,"' '"not json"' '{"must":-1}' '{"must":1.5}' '{"must":"1"}' '[1,2]' '""'; do
  run "LABEL_COUNTS 破損: $broken" '{"body":"b","comments":[{"path":"a","line":1,"side":"RIGHT","body":"[should] x"}],"label_counts":'"$broken"'}'
  eq "RESULT 行 (comments 集計)" "$LINES" '<!-- AI-REVIEW-RESULT: must=0 should=1 nit=0 question=0 pre_existing=0 other=0 -->'
  eq "counts_source" '.counts_source' "comments" report
  eq "warning" '.warnings | map(select(.input == "LABEL_COUNTS" and .action == "fallback_to_comments")) | length' "1" report
done

# ---------------------------------------------------------------------------
run "EXTERNAL_REVIEW 正常 (空白置換 / 全キー)" '{"body":"b","comments":[],
  "external_review":"{\"skill\":\"scan diff\",\"mode\":\"agent\",\"verify_degraded\":false,\"finders\":5,\"finders_expected\":5,\"findings\":9,\"omitted\":0,\"reason\":\"日本語 の 理由\"}"}'
eq "機械可読行" "$LINES" "$(printf '%s\n%s' "$ZERO_LINE" '<!-- AI-REVIEW-EXTERNAL: skill=scan_diff mode=agent verify_degraded=false finders=5/5 findings=9 omitted=0 -->')"
eq "external emitted" '.lines.external' "emitted" report
eq "external_review を除外" 'has("external_review")' "false"

run "EXTERNAL_REVIEW finders が null / 無いキーは出さない / mode=null" '{"body":"b","comments":[],
  "external_review":{"skill":"code-review","mode":"external","verify_degraded":null,"finders":null,"finders_expected":null,"findings":2}}'
eq "EXTERNAL 行" "$LINES"' | split("\n")[1]' '<!-- AI-REVIEW-EXTERNAL: skill=code-review mode=external verify_degraded=null finders=n/a findings=2 -->'

run "EXTERNAL_REVIEW 最小 (skill=none, mode=null)" '{"body":"b","comments":[],"external_review":{"skill":"none","mode":null}}'
eq "EXTERNAL 行" "$LINES"' | split("\n")[1]' '<!-- AI-REVIEW-EXTERNAL: skill=none mode=null -->'

for broken in '{"skill":"x","mode":"turbo"}' '{"mode":"agent"}' '{"skill":"x"}' '"{broken"' '[]' \
  '{"skill":"a-->b","mode":"agent"}' '{"skill":"x","mode":"agent","findings":"3 -->"}' \
  '{"skill":"x","mode":"agent","omitted":null}' '{"skill":"x","mode":"agent","verify_degraded":"no"}' \
  '{"skill":"x","mode":"agent","finders":"5","finders_expected":5}'; do
  run "EXTERNAL_REVIEW 異常: $broken" '{"body":"b","comments":[],"external_review":'"$broken"'}'
  eq "行ごと省略" "$LINES" "$ZERO_LINE"
  eq "external omitted" '.lines.external' "omitted" report
  eq "warning" '.warnings | map(select(.input == "EXTERNAL_REVIEW" and .action == "line_omitted")) | length' "1" report
done

# ---------------------------------------------------------------------------
run "ESCALATION 正常 (EXTERNAL の直後)" '{"body":"b","comments":[],
  "external_review":{"skill":"none","mode":null},
  "escalation":"{\"escalate\":true,\"reasons\":[\"a\",\"b\"]}"}'
eq "機械可読行" "$LINES" "$(printf '%s\n%s\n%s' "$ZERO_LINE" '<!-- AI-REVIEW-EXTERNAL: skill=none mode=null -->' '<!-- AI-REVIEW-ESCALATE: escalate=1 reasons=2 -->')"
eq "escalation を除外" 'has("escalation")' "false"

run "ESCALATION escalate=false・reasons 無し (EXTERNAL 無しなら RESULT の直後)" '{"body":"b","comments":[],"escalation":{"escalate":false}}'
eq "機械可読行" "$LINES" "$(printf '%s\n%s' "$ZERO_LINE" '<!-- AI-REVIEW-ESCALATE: escalate=0 reasons=0 -->')"
eq "warnings なし" '.warnings | length' "0" report

run "ESCALATION reasons が配列でない" '{"body":"b","comments":[],"escalation":{"escalate":true,"reasons":"理由"}}'
eq "ESCALATE 行" "$LINES"' | split("\n")[1]' '<!-- AI-REVIEW-ESCALATE: escalate=1 reasons=0 -->'
eq "escalate emitted" '.lines.escalate' "emitted" report
eq "warning" '.warnings[0] | "\(.input) \(.action)"' "ESCALATION reasons_zeroed" report

for broken in '{"escalate":"true"}' '{"escalate":1}' '{"reasons":["a"]}' '"{\"escalate\":tru"' '"true"'; do
  run "ESCALATION 異常: $broken" '{"body":"b","comments":[],"escalation":'"$broken"'}'
  eq "行ごと省略" "$LINES" "$ZERO_LINE"
  eq "escalate omitted" '.lines.escalate' "omitted" report
  eq "warning" '.warnings | map(select(.input == "ESCALATION" and .action == "line_omitted")) | length' "1" report
done

# ---------------------------------------------------------------------------
run "複数行範囲コメント + commit_id あり + 余計なキー除外" '{"body":"総括\n本文","event":"COMMENT","mode":"pr","commit_id":"9f8e7d6c",
  "comments":[{"path":"src/x.ts","start_line":50,"start_side":"RIGHT","line":55,"side":"RIGHT","body":"[must] 範囲"}]}'
eq "キー集合" 'keys | join(",")' "body,comments,commit_id,event"
eq "commit_id" '.commit_id' "9f8e7d6c"
eq "範囲コメントはそのまま" '.comments[0] | "\(.start_line) \(.start_side) \(.line) \(.side)"' "50 RIGHT 55 RIGHT"
eq "RESULT 行" "$LINES" '<!-- AI-REVIEW-RESULT: must=1 should=0 nit=0 question=0 pre_existing=0 other=0 -->'
eq "caller 本文は区切り線の後ろ" '.body | split("\n\n---\n\n")[1]' "$(printf '総括\n本文')"

run "commit_id が空文字 / null" '{"body":"b","comments":[],"commit_id":""}'
eq "commit_id を含めない" 'has("commit_id")' "false"
run "commit_id が null" '{"body":"b","comments":[],"commit_id":null}'
eq "commit_id を含めない" 'has("commit_id")' "false"

# ---------------------------------------------------------------------------
run "event が COMMENT 以外" '{"body":"b","event":"APPROVE","comments":[]}'
eq "event 固定" '.event' "COMMENT"
eq "warning" '.warnings[0].action' "forced_comment" report

# ---------------------------------------------------------------------------
current="入力不正は exit 2 で payload を書かない"
for bad in '{"comments":[]}' '{"body":"b","comments":{}}' '{"body":"b"}' 'not json'; do
  input="$(bash "$BUILD" --init)"
  printf '%s\n' "$bad" > "$input"
  set +e
  bash "$BUILD" "$input" >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then ok; else ng "$bad: exit $rc"; fi
  if [ ! -e "$(dirname "$input")/payload.json" ]; then ok; else ng "$bad: payload.json が書かれた"; fi
done

current="複数の JSON 値を連結した入力は exit 2"
input="$(bash "$BUILD" --init)"
printf '%s\n%s\n' '{"body":"a","comments":[]}' '{"body":"b","comments":[]}' > "$input"
set +e
bash "$BUILD" "$input" >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 2 ]; then ok; else ng "exit $rc"; fi

current="--init は毎回別パスを返し、ファイルを作らない"
a="$(bash "$BUILD" --init)"
b="$(bash "$BUILD" --init)"
if [ "$a" != "$b" ]; then ok; else ng "同じパス: $a"; fi
if [ ! -e "$a" ] && [ -d "$(dirname "$a")" ]; then ok; else ng "input.json が既に存在する / dir が無い"; fi

echo "passed: ${pass}, failed: ${fail}"
[ "$fail" -eq 0 ]
