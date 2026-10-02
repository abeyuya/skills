#!/usr/bin/env bash
# post-pr-review skill / 手順 1 (deterministic) の最終 Payload 組み立て。
#
# 使い方:
#   bash build-review-payload.sh --init
#     一意の作業ディレクトリ (mktemp -d、ランダムサフィックス付き) を作り、
#     caller が入力 JSON を書き出すべきパス `<dir>/input.json` を stdout に 1 行出す。
#     ファイル自体は作らない (Write ツールで新規作成でき、事前 Read が要らない)。
#   bash build-review-payload.sh <dir>/input.json
#     入力 JSON から最終 Payload を組み立てて `<dir>/payload.json` に書き、
#     報告 JSON を `<dir>/report.json` に書いたうえで stdout にも 1 行で出す。
#
# 入力 JSON (`input.json`) — caller から受け取った Payload をそのまま詰める:
#   {
#     "body": string,                 必須。caller の総括本文 (マーカー / 機械可読行は付けない)
#     "event": "COMMENT",             任意。何が来ても最終 Payload は "COMMENT" 固定
#     "comments": [ ... ],            必須。空配列可。要素はそのまま最終 Payload に渡す
#     "commit_id": string,            任意。空 / null なら最終 Payload に含めない
#     "label_counts": object|string,  任意。LABEL_COUNTS。受け取った 1 行 JSON をそのまま文字列で入れてもよい
#     "external_review": object|string, 任意。EXTERNAL_REVIEW。同上
#     "escalation": object|string     任意。ESCALATION。同上
#   }
#   上記以外のキー (`mode` 等) は読まずに捨てる。
#   string で渡された 3 キーはスクリプト側で JSON として parse を試み、失敗すれば異常系として扱う
#   (壊れた値を caller 側で直そうとしない。parse 判定はここで一元的に行う)。
#
# 出力:
#   <dir>/payload.json  GitHub Review API にそのまま渡せる最終 Payload
#                       ({commit_id?, body, event:"COMMENT", comments})。gh 経路は `--input` に渡す。
#                       MCP 経路は `body` / `comments` / `commit_id` を各ツール引数にそのまま使う。
#   <dir>/report.json   {
#                         "payload_path": string,
#                         "counts": {must, should, nit, question, pre_existing, other},
#                         "counts_source": "label_counts" | "comments",
#                         "lines": {"result": "emitted",
#                                   "external": "emitted" | "absent" | "omitted",
#                                   "escalate": "emitted" | "absent" | "omitted"},
#                         "warnings": [{"input": "LABEL_COUNTS" | "EXTERNAL_REVIEW" | "ESCALATION" | "event",
#                                       "action": "fallback_to_comments" | "line_omitted" | "reasons_zeroed" | "forced_comment",
#                                       "reason": string}]
#                       }
#                       `absent` = 入力に無かったので出していない / `omitted` = 渡されたが異常値で省略した。
# stdout: report.json と同内容 (1 行)
# stderr: エラーメッセージ
# exit  : 0 = 正常 (warnings があっても 0。投稿は継続する) /
#         2 = 入力不正 (引数 / ファイル不在 / JSON 不正 / body が string でない / comments が配列でない)。
#             この場合 payload.json は書かない。
#
# 規則の正典は ../references/machine-readable-lines.md。本スクリプトはその実装で、両者は同期させる。
#
# bash 互換要件: **bash 3.2 (macOS 標準の /bin/bash) で動くこと**
#   (../../distill-pr-reviews/scripts/collect-signals.sh と同じ要件)。
#   代表的な NG: mapfile / readarray, declare -A (連想配列), ${var^^} / ${var,,}, wait -n, coproc。
#   加えて bash 4.4 未満では set -u 下で要素 0 件の配列を `"${arr[@]}"` 展開すると unbound variable
#   になるため、配列展開は `${arr[@]+"${arr[@]}"}` の形で書く。

set -euo pipefail

die() { echo "[build-review-payload] ERROR: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die "jq が見つからない"

if [ "$#" -ne 1 ]; then
  die "usage: build-review-payload.sh --init | build-review-payload.sh <dir>/input.json"
fi

if [ "$1" = "--init" ]; then
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/post-pr-review.XXXXXXXX")" || die "mktemp -d に失敗"
  echo "${work_dir%/}/input.json"
  exit 0
fi

input="$1"
[ -f "$input" ] || die "入力ファイルが無い: $input"
jq -e -s 'length == 1 and (.[0] | type == "object")' "$input" >/dev/null 2>&1 \
  || die "入力が単一の JSON object として parse できない: $input"
jq -e '.body | type == "string"' "$input" >/dev/null || die "body が string でない"
jq -e '.comments | type == "array"' "$input" >/dev/null || die "comments が配列でない"

out_dir="$(cd "$(dirname "$input")" && pwd -P)"
payload_path="${out_dir}/payload.json"
report_path="${out_dir}/report.json"

result="$(jq -c --arg payload_path "$payload_path" '
  def labels: ["must", "should", "nit", "question", "pre_existing"];
  def zero: {must: 0, should: 0, nit: 0, question: 0, pre_existing: 0, other: 0};
  def is_nonneg_int: type == "number" and . >= 0 and . == floor;
  # string なら JSON として parse を試みる。失敗は {"__unparseable": true} で表す。
  def parse_opt:
    if type == "string" then (try fromjson catch {"__unparseable": true}) else . end;
  def unparseable: type == "object" and .__unparseable == true;
  # 機械可読行の値: 空白を _ に置換する。
  def render_value:
    if type == "string" then gsub("\\s"; "_")
    elif type == "null" then "null"
    else tojson | gsub("\\s"; "_")
    end;
  def std_key($k): if (labels | any(. == $k)) then $k else "other" end;
  def add_to($k): .[std_key($k)] += 1;

  . as $in
  | ($in.comments) as $comments

  # ---- 集計ルール 2: comments[] の先頭ラベル集計 ----
  | (reduce $comments[] as $c (zero;
      ((if ($c | type) == "object" then $c.body else null end) as $b
       | if ($b | type) == "string" and ($b | test("^\\[[A-Za-z_]+\\]"))
         then add_to($b | capture("^\\[(?<l>[A-Za-z_]+)\\]").l | ascii_downcase)
         else add_to("other")
         end))) as $from_comments

  # ---- 集計ルール 1: LABEL_COUNTS を正典採用 (異常時はフォールバック) ----
  | (if ($in.label_counts == null) then {counts: $from_comments, source: "comments", warn: []}
     else ($in.label_counts | parse_opt) as $lc
     | if ($lc | unparseable) then
         {counts: $from_comments, source: "comments",
          warn: [{input: "LABEL_COUNTS", action: "fallback_to_comments", reason: "JSON として parse できない"}]}
       elif ($lc | type) != "object" then
         {counts: $from_comments, source: "comments",
          warn: [{input: "LABEL_COUNTS", action: "fallback_to_comments", reason: "JSON object でない"}]}
       elif ([$lc[] | is_nonneg_int] | all | not) then
         {counts: $from_comments, source: "comments",
          warn: [{input: "LABEL_COUNTS", action: "fallback_to_comments", reason: "値に非負整数でないものがある"}]}
       else
         (reduce ($lc | to_entries[]) as $e (zero;
            .[std_key($e.key | ascii_downcase)] += $e.value)) as $mapped
         | ([$mapped[]] | add) as $sum
         | if $sum < ($comments | length) then
             {counts: $from_comments, source: "comments",
              warn: [{input: "LABEL_COUNTS", action: "fallback_to_comments",
                      reason: "合計 (\($sum)) が comments[] の件数 (\($comments | length)) を下回る"}]}
           else {counts: $mapped, source: "label_counts", warn: []}
           end
       end
     end) as $lcres

  | ("<!-- AI-REVIEW-RESULT: "
     + ([ "must", "should", "nit", "question", "pre_existing", "other"]
        | map("\(.)=\($lcres.counts[.])") | join(" "))
     + " -->") as $result_line

  # ---- AI-REVIEW-EXTERNAL ----
  | (if ($in.external_review == null) then {line: null, state: "absent", warn: []}
     else ($in.external_review | parse_opt) as $er
     | (if ($er | unparseable) then "JSON として parse できない"
        elif ($er | type) != "object" then "JSON object でない"
        elif ($er | has("skill") | not) then "必須キー skill が無い"
        elif ($er | has("mode") | not) then "必須キー mode が無い"
        elif ($er.skill | type) != "string" or ($er.skill == "") then "skill が空でない string でない"
        elif ([null, "agent", "partial", "inline", "empty", "external"] | any(. == $er.mode) | not)
          then "mode が enum 外 (\($er.mode | tojson))"
        elif ($er.skill | contains("-->")) then "skill に HTML コメント終端 --> を含む"
        elif ($er | has("verify_degraded")) and ([$er.verify_degraded | type] | inside(["boolean", "null"]) | not)
          then "verify_degraded が boolean / null でない"
        elif ([$er.finders, $er.finders_expected] | map(select(. != null) | is_nonneg_int | not) | any)
          then "finders / finders_expected が非負整数 / null でない"
        elif (["findings", "omitted"] | map(. as $k | $er | has($k) and (.[$k] | is_nonneg_int | not)) | any)
          then "findings / omitted が非負整数でない"
        else null
        end) as $err
     | if $err != null then
         {line: null, state: "omitted",
          warn: [{input: "EXTERNAL_REVIEW", action: "line_omitted", reason: $err}]}
       else
         {line: ("<!-- AI-REVIEW-EXTERNAL: "
            + ([ "skill=\($er.skill | render_value)",
                 "mode=\($er.mode | render_value)",
                 (if $er | has("verify_degraded") then "verify_degraded=\($er.verify_degraded | render_value)" else empty end),
                 (if ($er | has("finders")) or ($er | has("finders_expected")) then
                    (if ($er.finders == null) or ($er.finders_expected == null) then "finders=n/a"
                     else "finders=\($er.finders | render_value)/\($er.finders_expected | render_value)"
                     end)
                  else empty end),
                 (if $er | has("findings") then "findings=\($er.findings | render_value)" else empty end),
                 (if $er | has("omitted") then "omitted=\($er.omitted | render_value)" else empty end)
               ] | join(" "))
            + " -->"),
          state: "emitted", warn: []}
       end
     end) as $ext

  # ---- AI-REVIEW-ESCALATE ----
  | (if ($in.escalation == null) then {line: null, state: "absent", warn: []}
     else ($in.escalation | parse_opt) as $es
     | (if ($es | unparseable) then "JSON として parse できない"
        elif ($es | type) != "object" then "JSON object でない"
        elif ($es | has("escalate") | not) then "escalate が無い"
        elif ($es.escalate | type) != "boolean" then "escalate が boolean でない (\($es.escalate | tojson))"
        else null
        end) as $err
     | if $err != null then
         {line: null, state: "omitted",
          warn: [{input: "ESCALATION", action: "line_omitted", reason: $err}]}
       else
         (($es | has("reasons")) and ($es.reasons != null) and (($es.reasons | type) != "array")) as $bad_reasons
         | {line: "<!-- AI-REVIEW-ESCALATE: escalate=\(if $es.escalate then 1 else 0 end) reasons=\(if ($es.reasons | type) == "array" then ($es.reasons | length) else 0 end) -->",
            state: "emitted",
            warn: (if $bad_reasons then
                     [{input: "ESCALATION", action: "reasons_zeroed", reason: "reasons が配列でないため reasons=0 として出力"}]
                   else [] end)}
       end
     end) as $esc

  | (if ($in | has("event")) and ($in.event != "COMMENT") then
       [{input: "event", action: "forced_comment", reason: "event \($in.event | tojson) は使えないため COMMENT に固定"}]
     else [] end) as $event_warn

  # ---- 手順 1: body の組み立て ----
  | ("> **[AI 自動投稿]** このレビューは AI エージェントによって自動生成されました。レビュー内容の判断は AI が行っています。\n\n"
     + ([$result_line, $ext.line, $esc.line] | map(select(. != null)) | join("\n"))
     + "\n\n---\n\n"
     + $in.body) as $body

  | {
      payload: (
        (if ($in.commit_id | type) == "string" and $in.commit_id != "" then {commit_id: $in.commit_id} else {} end)
        + {body: $body, event: "COMMENT", comments: $comments}
      ),
      report: {
        payload_path: $payload_path,
        counts: $lcres.counts,
        counts_source: $lcres.source,
        lines: {result: "emitted", external: $ext.state, escalate: $esc.state},
        warnings: ($lcres.warn + $ext.warn + $esc.warn + $event_warn)
      }
    }
' "$input")" || die "jq による組み立てに失敗"

printf '%s\n' "$result" | jq '.payload' > "$payload_path"
printf '%s\n' "$result" | jq '.report' > "$report_path"
printf '%s\n' "$result" | jq -c '.report'
