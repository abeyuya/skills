#!/usr/bin/env bash
# compose-review skill / 5-3 の件数上限の適用と label_counts の集計 (deterministic)。
#
# label_counts は post-pr-review が Review body の機械可読サマリ行 (AI-REVIEW-RESULT) に載せる正典値で、
# CI がこの件数でマージ可否を判定する。手で数えると数え間違いがそのまま判定を誤らせるので、ここで数える。
#
# 使い方:
#   bash finalize-comments.sh [MAX_INLINE_COMMENTS=<正の整数|unlimited>] <入力 JSON>
#   入力 JSON のパスに `-` を渡すと stdin から読む。
#
# 入力 JSON:
#   {
#     "comments": [{"path": ..., "line": ..., "body": "[must] ...", ...}, ...],
#                       // マージ・重複排除・範囲外除外まで済ませた全指摘 (件数上限は未適用)。要素は object
#     "label_map": {"blocker": "must", ...}
#                       // 任意。独自ラベル → 標準ラベル。キーと値は大文字小文字と前後の `[` `]` を無視する
#   }
#   MAX_INLINE_COMMENTS : 省略 / `unlimited` なら上限なし。正の整数でない値は上限なしとして扱い warnings に残す
#   OUTPUT_PATH (環境変数) : 結果 JSON の書き出し先。省略時は一意の temp ディレクトリ配下の result.json
#
# ラベルは comments[].body 先頭の `^\[([A-Za-z_]+)\]` を小文字化して取る (post-pr-review の
# build-review-payload.sh と同じ規則)。label_map で標準ラベルに寄せ、標準 5 ラベル以外とラベル無しは other。
# 件数上限は [must] > [should] > [nit] > [question] > [pre_existing] > other の順に残し、同じ順位は入力順。
#
# 出力: OUTPUT_PATH に JSON を書き、stdout にそのパスを 1 行出す。
#   {
#     "max_inline_comments": <数値> | "unlimited",   // 実際に適用した上限
#     "label_counts": {must, should, nit, question, pre_existing, other},   // 上限適用 **前** の全指摘の件数
#     "kept_indices": [0, 2, ...],                   // 残した指摘の入力上の位置 (入力順)
#     "comments": [...],                             // 残した指摘 (入力順。要素は入力のまま)
#     "omitted_count": 0,
#     "breakdown": "[must] 1 件 / [should] 2 件",     // `## 指摘内訳` に書く文字列 (上限適用後。0 件なら "指摘なし")
#     "omitted_note": null | "上限 5 件を超えたため 3 件を省略 ([nit] 2 件 / その他 1 件)。",
#     "warnings": [string, ...]
#   }
#
# exit: 0 = 正常 / 2 = 入力エラー (JSON なし。入力を直して再実行する) / 1 = 内部エラー (JSON なし)
#
# bash 互換要件: **bash 3.2 (macOS 標準の /bin/bash) で動くこと** (distill-pr-reviews/scripts/collect-signals.sh と同じ)。

set -euo pipefail

# 想定外の失敗 (jq の異常終了など) は exit 1 に揃え、書きかけの JSON を残さない
# (jq 自身の終了コードが、このスクリプトの「入力エラー」と取り違えられないようにするため)。
EXIT_KIND=""
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$EXIT_KIND" ]; then
    [ -n "${OUTPUT_PATH:-}" ] && rm -f "$OUTPUT_PATH"
    echo "[finalize-comments] internal error (exit $rc)" >&2
    exit 1
  fi
}
trap on_exit EXIT

die_usage() { EXIT_KIND=usage; echo "[finalize-comments] usage error: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die_usage "jq が見つからない"

MAX_INLINE_COMMENTS="${MAX_INLINE_COMMENTS:-unlimited}"
IN=""
while [ $# -gt 0 ]; do
  case $1 in
    MAX_INLINE_COMMENTS=*) MAX_INLINE_COMMENTS=${1#MAX_INLINE_COMMENTS=}; shift ;;
    --) shift; [ $# -ge 1 ] || die_usage "-- の後に入力 JSON が無い"; IN=$1; shift ;;
    *=*) die_usage "不明な引数: $1" ;;
    *) [ -z "$IN" ] || die_usage "入力 JSON は 1 つだけ: $1"; IN=$1; shift ;;
  esac
done
[ -n "$IN" ] || die_usage "入力 JSON が無い"

OUTPUT_PATH="${OUTPUT_PATH:-}"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/compose-review-finalize-XXXXXX")
if [ -z "$OUTPUT_PATH" ]; then
  OUTPUT_PATH="$WORK_DIR/result.json"
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"

if [ "$IN" = - ]; then
  cat >"$WORK_DIR/input.json"
else
  [ -r "$IN" ] || die_usage "入力 JSON が見つからない: $IN"
  cat "$IN" >"$WORK_DIR/input.json"
fi

def_norm='def norm: tostring | ascii_downcase | ltrimstr("[") | rtrimstr("]");
  def std: ["must", "should", "nit", "question", "pre_existing"];'

err=$(jq -s -r "$def_norm"'
  if length != 1 then "入力は JSON object 1 つ"
  elif (.[0] | type) != "object" then "入力は JSON object"
  elif (.[0].comments | type) != "array" then "comments は配列"
  elif (.[0].comments | all(type == "object") | not) then "comments の要素は object"
  elif (.[0].comments | all((.body // "") | type == "string") | not) then "comments[].body は文字列"
  elif ((.[0].label_map // {}) | type) != "object" then "label_map は object"
  elif ((.[0].label_map // {}) | to_entries | all(.value | type == "string" and (norm as $v | std | index([$v]))) | not)
    then "label_map の値は must / should / nit / question / pre_existing のいずれか"
  else "" end' "$WORK_DIR/input.json" 2>&1) || die_usage "入力 JSON を解釈できない: $err"
[ -z "$err" ] || die_usage "$err"

jq --arg max "$MAX_INLINE_COMMENTS" "$def_norm"'
  def rank($k): (std | index([$k])) // 5;
  def breakdown($xs):
    [ (std + ["other"])[] as $k | ($xs | map(select(.k == $k)) | length) as $n
      | select($n > 0) | (if $k == "other" then "その他" else "[\($k)]" end) + " \($n) 件" ] | join(" / ");
  ((.label_map // {}) | with_entries(.key |= norm | .value |= norm)) as $map
  | (if $max == "unlimited" then {limit: null, warn: []}
     elif ($max | test("^[0-9]+$")) and ($max | tonumber) >= 1 then {limit: ($max | tonumber), warn: []}
     else {limit: null, warn: ["MAX_INLINE_COMMENTS が正の整数でも unlimited でもない (\($max | tojson)) ため上限なしとして扱った"]}
     end) as $lim
  | [ .comments | to_entries[]
      | ([.value.body // "" | capture("^\\[(?<l>[A-Za-z_]+)\\]") | .l][0] // "" | ascii_downcase) as $raw
      | ($map[$raw] // $raw) as $mapped
      | {i: .key, c: .value, k: (if (std | index([$mapped])) != null then $mapped else "other" end)} ] as $all
  | (reduce $all[] as $e ({must: 0, should: 0, nit: 0, question: 0, pre_existing: 0, other: 0}; .[$e.k] += 1)) as $counts
  | (if $lim.limit == null then $all else ($all | sort_by(rank(.k), .i) | .[:$lim.limit] | sort_by(.i)) end) as $kept
  | ([$kept[].i]) as $kept_i
  | ($all | map(select(.i as $i | $kept_i | index([$i]) | not))) as $dropped
  | {
      max_inline_comments: ($lim.limit // "unlimited"),
      label_counts: $counts,
      kept_indices: $kept_i,
      comments: [$kept[].c],
      omitted_count: ($dropped | length),
      breakdown: (breakdown($kept) | if . == "" then "指摘なし" else . end),
      omitted_note: (if ($dropped | length) > 0
        then "上限 \($lim.limit) 件を超えたため \($dropped | length) 件を省略 (\(breakdown($dropped)))。"
        else null end),
      warnings: $lim.warn
    }
' "$WORK_DIR/input.json" >"$OUTPUT_PATH"

echo "$OUTPUT_PATH"
