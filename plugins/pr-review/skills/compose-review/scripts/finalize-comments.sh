#!/usr/bin/env bash
# compose-review skill / 5-3 の件数上限の適用と label_counts の集計 (deterministic)。
#
# label_counts は post-pr-review が Review body の機械可読サマリ行 (AI-REVIEW-RESULT) に載せる正典値で、
# CI がこの件数でマージ可否を判定する。手で数えると数え間違いがそのまま判定を誤らせるので、ここで数える。
#
# 使い方:
#   bash finalize-comments.sh [MAX_INLINE_COMMENTS=<正の整数|unlimited>] [OUTPUT_PATH=<パス>] <入力 JSON>
#   入力 JSON に `-` を渡すと stdin から読む。`=` を含むパスは `--` の後に置く。
#   値は引数でだけ受け取る (同名の環境変数は読まない。シェルに残った値で上限が黙って変わらないようにするため)。
#
# 入力 JSON:
#   {
#     "comments": [{"path": ..., "line": ..., "body": "[must] ...", ...}, ...],
#                       // マージ・重複排除・範囲外除外まで済ませた全指摘 (件数上限は未適用)。要素は object
#     "label_map": {"blocker": "must", "要修正": "must", ...}
#                       // 任意。独自ラベル → 標準ラベル。キーと値は大文字小文字と前後の空白・`[` `]` を無視する。
#                       // 標準ラベルをキーに置けるのは同じか上のラベルへの対応 ({"nit": "must"} 等) だけで、
#                       // 格下げ ({"must": "nit"} 等) は入力エラー (本文が [must] のまま must の件数を下げられるため)
#   }
#   MAX_INLINE_COMMENTS : 省略 / `unlimited` なら上限なし。正の整数でない値は上限なしとして扱い warnings に残す
#   OUTPUT_PATH         : 結果 JSON の書き出し先。省略時は一意の temp ディレクトリ配下の result.json
#
# ラベルは comments[].body 先頭の `[...]` (改行と `]` を含まない 1 文字以上) を label_map のキーと同じ規則で
# 正規化して取る (`[ must]` / `[[MUST]]` / ゼロ幅文字を挟んだ `[must]` も must)。
# post-pr-review の build-review-payload.sh (`LABEL_COUNTS` が無いときのフォールバック集計) は英字と `_` だけを
# ラベルとして取るが、ここでは `[要修正]` / `[must-fix]` のような独自ラベルも label_map で標準ラベルに寄せられるよう
# 広く取る。label_map で標準ラベルに寄せ、標準 5 ラベル以外とラベル無しは other。
# 件数上限は [must] > [should] > [nit] > [question] > [pre_existing] > other の順に残し、同じ順位は入力順。
#
# 出力: OUTPUT_PATH に JSON を書き、stdout にその絶対パスを 1 行出す。
#   {
#     "max_inline_comments": <数値> | "unlimited",   // 実際に適用した上限
#     "label_counts": {must, should, nit, question, pre_existing, other},   // 上限適用 **前** の全指摘の件数
#     "comments": [...],                             // 残した指摘 (入力順。要素は入力のまま)
#     "kept_indices": [0, 2, ...],                   // 残した指摘の入力上の位置 (0 始まり。参考)
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
OUTPUT_PATH=""
WORK_DIR=""
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$EXIT_KIND" ]; then
    [ -n "$OUTPUT_PATH" ] && rm -f "$OUTPUT_PATH"
    echo "[finalize-comments] internal error (exit $rc)" >&2
    rc=1
  fi
  # 結果を WORK_DIR に書かなかった回 (OUTPUT_PATH 指定 / エラー) は作業ディレクトリを残さない
  if [ -n "$WORK_DIR" ] && { [ "$rc" -ne 0 ] || [ "${OUTPUT_PATH%/*}" != "$WORK_DIR" ]; }; then
    rm -rf "$WORK_DIR"
  fi
  exit "$rc"
}
trap on_exit EXIT

die_usage() { EXIT_KIND=usage; echo "[finalize-comments] usage error: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die_usage "jq が見つからない"

MAX_INLINE_COMMENTS="unlimited"
IN=""
while [ $# -gt 0 ]; do
  case $1 in
    MAX_INLINE_COMMENTS=*) MAX_INLINE_COMMENTS=${1#MAX_INLINE_COMMENTS=}; shift ;;
    OUTPUT_PATH=*) OUTPUT_PATH=${1#OUTPUT_PATH=}; shift ;;
    --) shift; [ $# -eq 1 ] || die_usage "-- の後には入力 JSON を 1 つだけ置く"; IN=$1; shift ;;
    *=*) die_usage "不明な引数: $1 (= を含むパスは -- の後に置く)" ;;
    *) [ -z "$IN" ] || die_usage "入力 JSON は 1 つだけ: $1"; IN=$1; shift ;;
  esac
done
[ -n "$IN" ] || die_usage "入力 JSON が無い"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/compose-review-finalize-XXXXXX")
WORK_DIR=$(cd "$WORK_DIR" && pwd -P)
if [ -z "$OUTPUT_PATH" ]; then
  OUTPUT_PATH="$WORK_DIR/result.json"
else
  case $OUTPUT_PATH in /*) ;; *) OUTPUT_PATH="$PWD/$OUTPUT_PATH" ;; esac
  mkdir -p "$(dirname "$OUTPUT_PATH")"
fi

if [ "$IN" = - ]; then
  SRC="$WORK_DIR/input.json"
  cat >"$SRC"
else
  [ -f "$IN" ] && [ -r "$IN" ] || die_usage "入力 JSON が読めるファイルではない: $IN"
  SRC=$IN
fi

defs='def norm: tostring | gsub("\\p{Cf}"; "") | ascii_downcase | gsub("^[\\s\\[]+"; "") | gsub("[\\s\\]]+$"; "");
  def std: ["must", "should", "nit", "question", "pre_existing"];
  def is_std: . as $x | std | index([$x]) != null;
  def rank: . as $x | (std | index([$x])) // 5;'

err=$(jq -s -r "$defs"'
  if length != 1 then "入力は JSON object 1 つ"
  elif (.[0] | type) != "object" then "入力は JSON object"
  elif (.[0].comments | type) != "array" then "comments は配列"
  elif (.[0].comments | all(type == "object") | not) then "comments の要素は object"
  elif (.[0].comments | all((.body // "") | type == "string") | not) then "comments[].body は文字列"
  elif ((.[0].label_map // {}) | type) != "object" then "label_map は object"
  else [(.[0].label_map // {}) | to_entries[] | {k: (.key | norm), v: .value}] as $e
    | if ($e | all(.k | length > 0 and (test("[\\]\\n]") | not)) | not)
        then "label_map のキーは空でなく、改行と ] を含まないラベル名"
      elif ([$e[].k] | length) != ([$e[].k] | unique | length)
        then "label_map のキーが大文字小文字と前後の空白・[ ] を無視すると重複している"
      elif ($e | all(.v | type == "string" and (norm | is_std)) | not)
        then "label_map の値は must / should / nit / question / pre_existing のいずれか"
      elif ($e | any((.k | is_std) and ((.v | norm | rank) > (.k | rank))))
        then "label_map で標準ラベルを格下げする対応 (must → nit 等) は置けない (本文が [must] のまま must / should の件数を下げられるため)"
      else "" end
  end' "$SRC" 2>&1) || die_usage "入力 JSON を解釈できない: $err"
[ -z "$err" ] || die_usage "$err"

jq --arg max "$MAX_INLINE_COMMENTS" "$defs"'
  def breakdown($xs):
    [ (std + ["other"])[] as $k | ($xs | map(select(.k == $k)) | length) as $n
      | select($n > 0) | (if $k == "other" then "その他" else "[\($k)]" end) + " \($n) 件" ] | join(" / ");
  ((.label_map // {}) | with_entries(.key |= norm | .value |= norm)) as $map
  | (if $max == "unlimited" then {limit: null, warn: []}
     elif ($max | test("^[0-9]+$")) and ($max | tonumber) >= 1 then {limit: ($max | tonumber), warn: []}
     else {limit: null, warn: ["MAX_INLINE_COMMENTS が正の整数でも unlimited でもない (\($max | tojson)) ため上限なしとして扱った"]}
     end) as $lim
  | [ .comments | to_entries[]
      | ([.value.body // "" | capture("^\\[(?<l>[^\\]\\n]+)\\]") | .l][0] // "" | norm) as $raw
      | (if $raw == "" then "" else ($map[$raw] // $raw) end) as $mapped
      | {i: .key, c: .value, k: (if ($mapped | is_std) then $mapped else "other" end)} ] as $all
  | (reduce $all[] as $e ({must: 0, should: 0, nit: 0, question: 0, pre_existing: 0, other: 0}; .[$e.k] += 1)) as $counts
  | (if $lim.limit == null then $all else ($all | sort_by((.k | rank), .i) | .[:$lim.limit] | sort_by(.i)) end) as $kept
  | ([$kept[].i]) as $kept_i
  | ($all | map(select(.i as $i | $kept_i | index([$i]) | not))) as $dropped
  | {
      max_inline_comments: ($lim.limit // "unlimited"),
      label_counts: $counts,
      comments: [$kept[].c],
      kept_indices: $kept_i,
      omitted_count: ($dropped | length),
      breakdown: (breakdown($kept) | if . == "" then "指摘なし" else . end),
      omitted_note: (if ($dropped | length) > 0
        then "上限 \($lim.limit) 件を超えたため \($dropped | length) 件を省略 (\(breakdown($dropped)))。"
        else null end),
      warnings: $lim.warn
    }
' "$SRC" >"$OUTPUT_PATH"

rm -f "$WORK_DIR/input.json"
echo "$OUTPUT_PATH"
